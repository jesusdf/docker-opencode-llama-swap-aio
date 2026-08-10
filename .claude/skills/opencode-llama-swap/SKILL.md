---
name: opencode-llama-swap
description: >
  Develop and maintain the opencode + llama-swap Docker stack in this repo.
  Use when editing the Dockerfile, entrypoint.sh, init-llama-swap.sh, the
  docker-compose.{nvidia,amd}.yml files, the .env schema, or the GitHub Actions
  build. Covers the architecture, the config-generation flow, GPU passthrough
  for NVIDIA/AMD, and the gotchas that have already bitten this project.
---

# opencode + llama-swap stack — developer skill

This repo ships a two-container stack: an SSH-accessible **opencode** agent
container that talks over a private network to a **llama-swap** container serving
a local GGUF model via llama.cpp. Everything is driven by environment variables;
nothing about the model is hardcoded.

## Architecture (keep this invariant)

- `opencode` (built from this repo's `Dockerfile`): SSH on 22, opencode CLI,
  config pointing at llama-swap. Waits for llama-swap to be healthy.
- `llama-swap` (upstream image `ghcr.io/mostlygeek/llama-swap:{cuda,rocm}`,
  entrypoint overridden with `init-llama-swap.sh`): downloads the model,
  generates `config.yaml`, serves OpenAI-compatible API on 8080.
- Outward ports: **22** (SSH → opencode) and **8080** (llama-swap API).
- Dependency ordering: compose `depends_on: service_healthy` + a healthcheck on
  `/health`, AND a redundant wait loop in `entrypoint.sh` (so it also works
  outside compose). Keep both.

## Files and their jobs

| File | Role |
|---|---|
| `Dockerfile` | Two stages. Stage 1 compiles opencode from source with bun; stage 2 is the runtime image (openssh, git, nodejs, python3+`huggingface_hub[cli,hf_xet]`). Key-only SSH, no root login. |
| `entrypoint.sh` | Remaps `user` to PUID/PGID, installs `authorized_keys`, generates `~/.config/opencode/opencode.json` (once), waits for llama-swap `/health`, then `exec sshd -D -e`. |
| `init-llama-swap.sh` | Runs *inside the upstream llama-swap image*. Downloads GGUF from HF if missing, resolves the model file (+shards +mmproj), generates `/models/config.yaml`, `exec llama-swap ...`. |
| `docker-compose.nvidia.yml` | CUDA image + `deploy.resources` nvidia device reservation. |
| `docker-compose.amd.yml` | ROCm image + `/dev/kfd`,`/dev/dri` passthrough, `group_add: video`, `seccomp:unconfined`, `ipc: host`. |
| `.env.example` | The full variable schema. Source of truth for what compose reads. |
| `.github/workflows/docker-image.yml` | Builds/pushes the opencode image (linux/amd64) to Docker Hub. |

## opencode is compiled from source, not installed from npm

### Why

`npm install -g opencode-ai` does not install JavaScript. It drops a ~183 MB
Bun **standalone binary** (`bin/opencode.exe`) that carries OpenTUI's native
`libopentui.so` *embedded*. Starting the TUI makes Bun unpack that library into
a temporary directory and `dlopen` it, and on hosts where that directory is
missing or mounted `noexec` the TUI dies before drawing anything:

```
Failed to initialize OpenTUI render library: Failed to open library
"/<tmpdir>/.<hash>-00000001.so": cannot open shared object file
```

Upstream has this reported repeatedly ([opencode#4605], [opencode#5175],
[opencode#3765]) and it is a property of the packaging, not of a bad host.
Compiling in the image lets us keep the library as an ordinary file and hand
OpenTUI its path, so **nothing is unpacked at runtime**.

[opencode#4605]: https://github.com/anomalyco/opencode/issues/4605
[opencode#5175]: https://github.com/anomalyco/opencode/issues/5175
[opencode#3765]: https://github.com/anomalyco/opencode/issues/3765

### How the two stages work

Stage `opencode-build` (debian:13-slim):

1. `git init` + `git fetch --depth 1 origin "$OPENCODE_REF"` + `checkout
   FETCH_HEAD`. Fetch rather than `clone --branch` so a **bare commit SHA** is a
   valid ref, not just tags and branches.
2. Install bun at the version the checked-out tree declares in its
   `packageManager` field. `packages/script` hard-fails on `^<that version>`,
   so "whatever bun is current" is not safe.
3. `bun install --frozen-lockfile`. Needs `build-essential` + `python3`:
   a couple of tree-sitter grammars build native addons via node-gyp, and
   without them the install dies half-done with a confusing babel `ENOENT`.
4. `bun run --cwd packages/opencode script/build.ts --single --skip-install`.
   - `--single` = host platform only (12 targets otherwise).
   - `--skip-install` is **required**: without it the build script runs
     `bun install @opentui/core@catalog:`, and `catalog:` is not a version.
   - `OPENCODE_CHANNEL=latest` + `OPENCODE_VERSION=…` stamp the version;
     without them the script queries npm and/or `git branch --show-current` and
     produces a date-based `0.0.0-…` preview string.
   - Do **not** set `OPENCODE_RELEASE`: it makes the script `gh release upload`.
   - Output lands in `packages/opencode/dist/opencode-linux-<arch>/bin/opencode`.
5. Build the relocatable OpenTUI asset root, then stage 2 copies it and sets
   `ENV OTUI_ASSET_ROOT=/opt/otui-assets`.

### OTUI_ASSET_ROOT — the actual fix

OpenTUI resolves every runtime asset as `$OTUI_ASSET_ROOT/<package>/<file>`
*before* falling back to its embedded copy, so pointing it at a real directory
bypasses the unpack entirely. Verified: with it set, `/proc/<pid>/maps` shows
`/opt/otui-assets/@opentui/core-linux-x64/libopentui.so` mapped straight from
disk.

Three things must exist under the root, and OpenTUI **throws if any asset it
asks for is missing** — which is why whole packages are copied instead of
hand-picked files:

| Path under the root | Source package |
|---|---|
| `@opentui/core-linux-x64/libopentui.so` | `@opentui/core-linux-x64` (its default export *is* the `.so` path) |
| `@opentui/core/…` (incl. `parser.worker.js`, `assets/`) | `@opentui/core` |
| `web-tree-sitter/tree-sitter.wasm` | `web-tree-sitter` |

Resolve the paths through `bun -e 'require.resolve(...)'` rather than hardcoding
`node_modules/.bun/@opentui+core@0.4.5+<hash>/…`, which changes on every bump.
`@opentui/core-linux-x64` is an optional dep of `@opentui/core`, so it only
resolves **from inside the core package directory**, not from `packages/opencode`.

Sanity check a change with a negative control — a bogus root must fail loudly:

```bash
docker run --rm -t -e OTUI_ASSET_ROOT=/nonexistent <image> opencode
# Missing OpenTUI asset "@opentui/core-linux-x64/libopentui.so" at "/nonexistent/..."
```

### Pinning the revision

`ARG OPENCODE_REF` in the Dockerfile is the source of truth and is deliberately
a fixed tag — builds stay reproducible until someone bumps it. Overrides:

- **Local**: `OPENCODE_REF` / `OPENCODE_VERSION` in `.env`, wired through
  `docker-compose.build.yml`. That file uses the **list form** (`- OPENCODE_REF`)
  on purpose: an unset variable is then omitted entirely instead of being passed
  as an empty string, so the Dockerfile pin stays in charge. The mapping form
  with `${OPENCODE_REF:-}` would silently clobber it with `""`.
- **CI**: the `opencode_ref` `workflow_dispatch` input. When blank the workflow
  reads the pin back out of the Dockerfile with `sed`, so the label
  `org.opencode.ref` always records what was actually built.

`OPENCODE_VERSION` is derived from the ref when empty: `vX.Y.Z` → `X.Y.Z`,
anything else → `0.0.0-<short sha>`.

### node yes, npm no

Dropping the npm install of opencode does **not** mean node can go too — that
inference is wrong, and measured:

- **`nodejs` is required.** opencode installs language servers itself with a
  bundled `@npmcli/arborist` (no npm CLI in the loop), but then spawns them
  directly from `node_modules/.bin/<name>`, and those are `#!/usr/bin/env node`
  scripts. Remove node and every JS/TS language server dies at spawn.
  `packages/opencode/src/lsp/server.ts` → `Npm.which()` → `spawn(bin, …)`.
- **The `npm` CLI is not.** It costs ~220 MB against nodejs's ~101 MB on
  debian:13-slim, and the only runtime user is the **ESLint** language server
  (`lsp/server.ts` runs `npm install` + `npm run compile` on a downloaded
  vscode-eslint checkout). The other npm-CLI call sites are `opencode upgrade` /
  `uninstall`, which are meaningless for a binary we compiled ourselves.
  `APT_PACKAGES="npm"` puts it back per deployment.

### Things that do *not* help

- **Static linking.** OpenTUI reaches its Zig core through `bun:ffi`
  `dlopen`, which needs a dynamic loader by definition; a fully static binary
  could not load it at all. Bun's musl targets are still dynamically linked.
- **Compiling and shipping the binary alone.** `bun build --compile` re-embeds
  the same `.so`, so the failure comes straight back. The externalised asset
  root is the part that fixes it, not the compilation.
- **Running uncompiled** (`bun run packages/opencode/src/index.ts`) does fix it,
  because the `.so` is then read from `node_modules` — but it drags the
  monorepo's ~2.7 GB of `node_modules` into the final image (~3.8 GB vs
  ~1.3 GB). Rejected for that reason.

## Hard-won gotchas (do not regress these)

1. **llama-swap binary is `llama-swap`, not `llama-server`.** The proxy is
   `llama-swap --config ... --listen :PORT`; `llama-server` is what the config's
   `cmd:` invokes per-model. An earlier version `exec`ed the wrong one.
2. **`${PORT}` in config.yaml is a llama-swap macro** — it must appear literally
   in the generated YAML (escape it as `\${PORT}` in the bash heredoc). Do NOT
   let bash expand it. An empty `--port` was a bug.
3. **No hardcoded model paths/hashes.** Resolve the GGUF dynamically from
   `MODEL_REPO`/`MODEL_QUANT`. Handle split shards by preferring
   `*-00001-of-*.gguf`, and add `--mmproj` only if an `mmproj*.gguf` exists
   (use `shopt -s nullglob`).
4. **`curl` has no `--req-timeout`.** Use `--max-time`. Health endpoint is
   `/health` (returns `OK`, no auth). `/v1/models` requires the API key when
   `LLAMA_API_KEY` is set, so don't use it for healthchecks.
5. **`chmod` on `authorized_keys` fails when `SSH_PUBLIC_KEY` is empty** — guard
   the whole SSH-key block behind `if [ -n "$SSH_PUBLIC_KEY" ]`.
6. **Debian 13 is PEP 668 externally-managed.** `pip install` needs
   `--break-system-packages`.
7. **Generate `config.yaml` to a writable, persistent path** (`/models/...`),
   not a bind-mounted file — you can't generate into a file you also mount over.
8. **First-boot download is slow** — the healthcheck needs a large
   `start_period` (30 min) or opencode's `depends_on` will give up.
9. **AMD unsupported GPUs**: consumer RDNA cards often need
   `HSA_OVERRIDE_GFX_VERSION` (e.g. `11.0.0` for gfx1100). It flows through via
   `env_file: .env` — no compose change needed.
10. **`opencode.json` is generated once** and left for the user to edit; changing
    `MODEL_ID` later means the user must delete/regen it. The llama-swap
    `config.yaml`, by contrast, is regenerated every start.
11. **MTP is decided per model, not globally.** `MTP_ENABLED` is
    `auto|true|false`, default `auto`. MTP is a property of the *weights*, and
    the stack serves every model under `/models`, so the flags go into each
    model's own `cmd:` block (`MODEL_MTPS[]`, alongside `MODEL_MMPROJS[]`) —
    never into the shared `TUNING`. Scope of each constraint differs, and that
    distinction matters:
    - **`MMPROJ_ENABLED=true` → per model.** llama.cpp refuses speculative
      decoding with a projector loaded, but only models that actually get an
      `--mmproj` are affected.
    - **`N_PARALLEL != 1` → global.** `--parallel` is one flag for the whole
      server, so it takes MTP out everywhere. Check it whenever MTP could be
      used *at all*, `auto` included — not just when forced on.

    Detection reads the first 8 MiB of the GGUF for `nextn_predict_layers` (the
    `{arch}.` metadata key) or `.nextn.` (tensor names) — the same markers other
    tools key on. Both are plain strings in the header, so no GGUF parser is
    needed; the metadata key lands at byte ~2k in Qwen3.6-35B-A3B. Verified
    against real headers from both the `-MTP-GGUF` and plain repos.

    `mtp_supported()` returns 0/1/2 (yes/no/unreadable), so **call it as
    `rc=0; mtp_supported "$f" || rc=$?`** — a bare call aborts under `set -e`.

    Resolve conflicts by **disabling MTP and keeping the other setting**, with a
    loud warning. The rule is "the deliberate choice wins": both conflicting
    settings are off/1 by default, so hitting one means the operator asked for
    it. Never let llama-server fail to start over a conflict we could catch.
12. **Reasoning config lives on both sides and must agree.** `PRESERVE_REASONING`
    emits `--reasoning-preserve` in the llama-swap `cmd:` *and*
    `chat_template_kwargs.preserve_thinking` in `opencode.json`. That is not
    redundancy by accident: the server flag only fires for templates llama.cpp
    tags with `supports_preserve_reasoning`, whose detection keys on a specific
    variable name, while Qwen3.6's template reads `preserve_thinking`. Keep the
    defaults in `entrypoint.sh` and `init-llama-swap.sh` in sync — they are
    declared separately in each file.

13. **`VRAM_TRY_AUTOFIT` skips the VRAM-relief group per model.** The relief
    flags live in `VRAM_TUNING[]`, kept apart from `TUNING[]` precisely so they
    can be dropped per model; `-ngl` is forced to 99 for a model that fits,
    since `N_GPU_LAYERS` is itself a spill-to-RAM lever.

    `gguf_probe()` parses the header once and returns KV bytes, sliding window
    and `token_embd` bytes. Two corrections in it are load-bearing, and both
    came from measuring rather than reasoning — do not "simplify" either away:
    - **Subtract `token_embd`** from the weight total. It stays in system RAM.
      Usually a small share of the file, but formats that compress the body hard
      and leave the embedding alone (MXFP4) push it past 8%.
    - **Halve the cached layers when `attention.sliding_window` is set.**
      Charging every layer the full context is ~1.7x too high there.

    Tensor sizes come from the gap to the next tensor's offset, not a type
    table, so an unknown quantisation format still measures correctly.

    **Fail safe: anything unmeasurable must count as "does not fit."** No
    `nvidia-smi`/AMD counters, unreadable header, missing metadata, `token_embd`
    larger than the file — all keep the settings applied. Stripping the settings
    that were keeping a model loadable is the one outcome this must never
    produce.

    **Free VRAM is read once, at startup, before any model loads.** That number
    is therefore not comparable with `nvidia-smi` taken while a model is
    running — a reported "budget 15049 MiB" next to a live "13258 MiB / 16311
    MiB" is two moments, not a bug. This has already been raised once.
14. **Two llama-server warnings are expected, not faults.** Both appear at model
    load and neither needs fixing:
    - `cache_reuse is not supported by this context, it will be disabled` —
      sliding-window models (and loaded projectors) make `--cache-reuse` inert.
    - `chat template does NOT support preserving reasoning, --reasoning-preserve
      has no effect` — llama.cpp gates that flag on a template capability it
      detects by name. This is the observed proof that the server flag alone is
      not enough, and why opencode also sends `preserve_thinking` (gotcha 12).

## Conventions

- **All comments are written in English** — code, YAML, Dockerfile, and shell.
  This is a hard rule for the whole project regardless of the chat language.
- Compose services use `env_file: .env` instead of enumerating every variable —
  keep it that way; add new vars to `.env.example` and they're available to both
  containers automatically.
- The opencode model name must equal the llama-swap model id: `swap/<MODEL_ID>`,
  referenced from opencode as `llamaswap/swap/<MODEL_ID>`.
- Keep the two compose files identical except for the image tag and the GPU
  passthrough block.

## Verifying changes

```bash
bash -n entrypoint.sh init-llama-swap.sh                 # shell syntax
cp .env.example .env
docker compose -f docker-compose.nvidia.yml config >/dev/null   # compose valid
docker compose -f docker-compose.amd.yml   config >/dev/null
docker compose -f docker-compose.nvidia.yml -f docker-compose.build.yml config \
    | grep -A3 'args:' || true            # build args resolve as expected
rm -f .env
```

The image build itself (no GPU needed) also exercises the whole compile stage,
because stage 2 runs `opencode --version` and that would fail on a broken asset
root:

```bash
docker build -t oc:test .                # ~6 min cold, most of it `bun install`
docker run --rm -t oc:test --entrypoint bash -c 'opencode --version'
```

Full smoke test (needs a GPU host): `up -d --build`, then
`docker compose logs -f llama-swap` until `/health` is OK, then
`ssh -p $SSH_PORT user@host` and run `opencode`.
