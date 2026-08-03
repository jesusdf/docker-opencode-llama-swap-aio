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
| `Dockerfile` | Builds the opencode image (node/npm + opencode, openssh, git, python3+`huggingface_hub[cli]`+`hf_transfer`). Key-only SSH, no root login. |
| `entrypoint.sh` | Remaps `user` to PUID/PGID, installs `authorized_keys`, generates `~/.config/opencode/opencode.json` (once), waits for llama-swap `/health`, then `exec sshd -D -e`. |
| `init-llama-swap.sh` | Runs *inside the upstream llama-swap image*. Downloads GGUF from HF if missing, resolves the model file (+shards +mmproj), generates `/models/config.yaml`, `exec llama-swap ...`. |
| `docker-compose.nvidia.yml` | CUDA image + `deploy.resources` nvidia device reservation. |
| `docker-compose.amd.yml` | ROCm image + `/dev/kfd`,`/dev/dri` passthrough, `group_add: video`, `seccomp:unconfined`, `ipc: host`. |
| `.env.example` | The full variable schema. Source of truth for what compose reads. |
| `.github/workflows/docker-image.yml` | Builds/pushes the opencode image (linux/amd64) to Docker Hub. |

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

## Conventions

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
rm -f .env
```

Full smoke test (needs a GPU host): `up -d --build`, then
`docker compose logs -f llama-swap` until `/health` is OK, then
`ssh -p $SSH_PORT user@host` and run `opencode`.
