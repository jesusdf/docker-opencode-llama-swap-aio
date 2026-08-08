# Documentation (Q&A)

A Stack Overflow–style reference for running the **opencode + llama-swap** stack.
Each section is a self-contained question with a worked answer.

---

## Q: What is this stack and how do the two containers fit together?

**A:** There are two services wired together on a private bridge network:

- **`llama-swap`** — serves a local GGUF model through llama.cpp behind an
  OpenAI-compatible API on port `8080`. On first start it downloads the model
  from Hugging Face and generates its own `config.yaml` from environment
  variables (via [`init-llama-swap.sh`](init-llama-swap.sh)).
- **`opencode`** — an SSH-accessible container with [opencode](https://opencode.ai)
  pre-installed and pre-configured to talk to `llama-swap`. It **waits for
  `llama-swap` to be healthy** before it starts (`depends_on: service_healthy`).

```
you ──ssh:22──▶ opencode ──http://llama-swap:8080/v1──▶ llama-swap ──▶ GPU
                   │                                          │
                   └────────── opencode-net (bridge) ────────┘
you ──http:8080──▶ llama-swap  (direct API access)
```

Nothing is hardcoded: the model, quantization, context size, sampling
parameters and SSH key are all driven by environment variables.

---

## Q: What are all the environment variables and what do they do?

**A:** Copy [`.env.example`](.env.example) to `.env` and edit it. The variables:

### Model / llama-swap

| Variable | Example | Description |
|---|---|---|
| `MODEL_REPO` | `unsloth/gemma-4-12b-it-GGUF` | Hugging Face repo to download the GGUF from. **Required.** |
| `MODEL_QUANT` | `UD-Q4_K_XL` | Quant pattern to match when downloading (`*<MODEL_QUANT>*.gguf`). Split shards are picked up automatically. |
| `MODEL_ID` | `gemma4-12b` | Internal name used for the llama-swap model (`swap/<MODEL_ID>`) and the opencode model. |
| `MMPROJ_ENABLED` | `false` | Accept images/audio by loading the multimodal projector. **Off by default** because a loaded projector disables llama.cpp's prompt cache reuse, which costs far more in a text-only coding session than vision is worth. See [the vision Q&A](#q-does-vision--multimodal-work). |
| `MMPROJ_QUANT` | `F16` | Which projector to download when the repo ships several (`BF16`/`F16`/`F32`). Empty downloads them all. Only used when `MMPROJ_ENABLED=true`. |
| `HF_TOKEN` | *(empty)* | Hugging Face token; only needed for gated/private repos. |
| `CTX_SIZE` | `262144` | Context window (`--ctx-size`). |
| `N_PREDICT` | `8192` | Max tokens to generate (`--n-predict`). |
| `KV_CACHE_TYPE` | `q8_0` | KV cache quantization (`-ctk`/`-ctv`). |
| `MODEL_TTL` | `900` | Seconds llama-swap keeps the model loaded while idle. |
| `TEMP` / `TOP_P` / `TOP_K` | `0.7` / `0.95` / `64` | Sampling parameters. |
| `LLAMA_API_KEY` | `your_api_key_here` | Protects the llama-swap API and is used by opencode. Leave empty to disable auth. |

### User / runtime

| Variable | Example | Description |
|---|---|---|
| `PUID` / `PGID` | `1000` / `1000` | uid/gid the `user` account is remapped to (matches host file ownership). |
| `TZ` | `Europe/Madrid` | Container timezone. |
| `LLAMA_SWAP_URL` | `http://llama-swap:8080` | Internal URL opencode uses to reach llama-swap (compose service name). |
| `APT_PACKAGES` | `vim tmux ripgrep` | Extra Debian packages installed into the **opencode** container at boot (space-separated). Empty = install nothing. See [the customisation Q&A](#q-how-do-i-install-extra-packages-or-run-my-own-setup-in-the-opencode-container). |

### Host paths

| Variable | Example | Description |
|---|---|---|
| `USER_HOME_PATH` | `/home/docker/opencode` | Host path persisted as the user's `/home/user`. |
| `MODELS_PATH` | `/home/docker/llama-swap/models` | Host path where downloaded models and the generated `config.yaml` live. |

### SSH

| Variable | Example | Description |
|---|---|---|
| `SSH_PORT` | `2222` | Host port mapped to the container's SSH (`22`). Set to `22` to expose it directly. |
| `SSH_PUBLIC_KEY` | `ssh-ed25519 AAAA...` | Authorized public key for login (user: `user`). |

### AMD-only (optional)

| Variable | Example | Description |
|---|---|---|
| `HSA_OVERRIDE_GFX_VERSION` | `11.0.0` | Forces the gfx target for AMD GPUs not officially in the ROCm support list (many consumer RDNA cards). Passed straight through via `env_file`. |

---

## Q: How do I start the stack?

**A:** Create your `.env`, then bring up the compose file for your GPU vendor.

```bash
cp .env.example .env
# edit .env: MODEL_REPO/MODEL_QUANT, LLAMA_API_KEY, SSH_PUBLIC_KEY, paths…

# NVIDIA (CUDA):
docker compose -f docker-compose.nvidia.yml up -d --build

# AMD (ROCm):
docker compose -f docker-compose.amd.yml up -d --build
```

The **first boot downloads the model**, so `llama-swap` may take a while to
become healthy. The healthcheck `start_period` (30 min) allows for this, and
`opencode` starts automatically once `llama-swap` is healthy.

Watch progress:

```bash
docker compose -f docker-compose.nvidia.yml logs -f llama-swap
```

---

## Q: How do I actually use opencode once it's running?

**A:** SSH into the opencode container with the private key matching
`SSH_PUBLIC_KEY`, then run `opencode`:

```bash
ssh -p ${SSH_PORT:-2222} user@<host>
opencode
```

The provider config is generated at
`~/.config/opencode/opencode.json` on first boot and points at
`swap/<MODEL_ID>` through llama-swap. It is created only if absent, so any edits
you make persist across restarts.

You can also hit the model API directly on port `8080`:

```bash
curl http://<host>:8080/v1/models -H "Authorization: Bearer $LLAMA_API_KEY"
```

---

## Q: What are the requirements for NVIDIA?

**A:**

1. NVIDIA GPU with a recent proprietary driver installed on the host.
2. **NVIDIA Container Toolkit** so Docker can expose the GPU
   (`nvidia-ctk`, the `nvidia` runtime).
3. Docker Engine with Compose v2.

Verify the GPU is visible to Docker:

```bash
docker run --rm --gpus all nvidia/cuda:12.4.0-base-ubuntu22.04 nvidia-smi
```

The NVIDIA compose requests the GPU via:

```yaml
deploy:
  resources:
    reservations:
      devices:
        - driver: nvidia
          count: all
          capabilities: [gpu]
```

---

## Q: What are the requirements for AMD?

**A:**

1. AMD GPU supported by **ROCm**, with ROCm kernel drivers on the host
   (`/dev/kfd` and `/dev/dri` must exist).
2. Your user in the `render`/`video` groups on the host (for local testing).
3. Docker Engine with Compose v2.

The AMD compose passes the GPU through directly (no special runtime needed):

```yaml
devices:
  - /dev/kfd
  - /dev/dri
group_add:
  - video
security_opt:
  - seccomp:unconfined
ipc: host
```

Verify ROCm sees the GPU:

```bash
rocminfo | grep -i gfx
```

If the card is **not** in ROCm's official support list (common for consumer
RDNA GPUs) llama.cpp may fail to load. Force the gfx target in `.env`:

```bash
# gfx1100 → 11.0.0, gfx1030 → 10.3.0, etc.
HSA_OVERRIDE_GFX_VERSION=11.0.0
```

---

## Q: Why does `opencode` wait, and how is the dependency ordering guaranteed?

**A:** Two layers:

1. Compose `depends_on: llama-swap: condition: service_healthy` — opencode is
   not started until llama-swap's healthcheck (`curl /health`) passes.
2. Belt-and-suspenders: `entrypoint.sh` also polls `${LLAMA_SWAP_URL}/health`
   before launching sshd, so the container is still correct if run outside
   compose.

---

## Q: The model download is slow or fails. What can I check?

**A:**

- **Gated/private repo?** Set `HF_TOKEN` in `.env`.
- **Wrong quant?** `MODEL_QUANT` must match a substring of the actual GGUF
  filenames in the repo (e.g. `UD-Q4_K_XL`). Check the repo's "Files" tab.
- **Re-download from scratch?** Delete the model directory under
  `MODELS_PATH/<MODEL_ID>` on the host and restart llama-swap.
- **Watch it:** `docker compose -f docker-compose.nvidia.yml logs -f llama-swap`.

Downloads use the Xet backend in high-performance mode
(`HF_XET_HIGH_PERFORMANCE=1`) for speed.

---

## Q: How do I change the model or its parameters later?

**A:** Edit `.env` and restart. If you change `MODEL_REPO`/`MODEL_QUANT`/`MODEL_ID`
the new model downloads on next boot; `config.yaml` is regenerated every start,
so parameter changes (`CTX_SIZE`, `TEMP`, …) apply immediately:

```bash
docker compose -f docker-compose.nvidia.yml up -d
```

Note the opencode config (`~/.config/opencode/opencode.json`) is only generated
once. If you changed `MODEL_ID`, update that file or delete it to regenerate.

---

## Q: How do I install extra packages or run my own setup in the opencode container?

**A:** There are two independent mechanisms; use either or both.

### 1. Install OS packages with `APT_PACKAGES`

Set `APT_PACKAGES` in `.env` to a **space-separated** list of Debian packages.
On every boot, [`entrypoint.sh`](entrypoint.sh) runs `apt-get install` for them
(as root, before `sshd` starts):

```bash
# .env
APT_PACKAGES=vim tmux ripgrep htop
```

```bash
docker compose -f docker-compose.nvidia.yml up -d
```

Notes:

- The list is re-installed on **every** start. `apt-get` is idempotent, so
  already-present packages are a fast no-op — the cost is one `apt-get update`.
- Installation happens **before** SSH is available. A bad/unknown package name
  makes `apt-get` fail and, because the entrypoint runs under `set -e`, aborts
  container startup — check `docker compose logs opencode` if the container
  won't come up.
- This is for *system* packages only. It does not touch npm, pip, or per-user
  config.
- The image ships `nodejs` but **not** the `npm` CLI (see
  [the compile-from-source Q&A](#q-why-is-opencode-compiled-from-source-instead-of-installed-from-npm)).
  If you want it — for your own work, or for the ESLint language server, which
  is the one part of opencode that shells out to it — set `APT_PACKAGES="npm"`.

### 2. Run your own setup via the mapped `~/.bashrc`

The user's home directory is bind-mounted from the host (`USER_HOME_PATH` →
`/home/user`), so it **persists across restarts and rebuilds**. Anything you put
in `~/.bashrc` there runs on each interactive SSH login as `user` — the natural
place for setup that doesn't need root or that you'd rather keep out of `.env`:

```bash
# on the host: $USER_HOME_PATH/.bashrc  (e.g. /home/docker/opencode/.bashrc)

# per-user tools that don't need apt
pipx install --quiet some-cli 2>/dev/null || true

# environment / aliases
export EDITOR=vim
alias ll='ls -la'

# one-shot bootstrap guarded by a sentinel so it only runs once
if [ ! -f "$HOME/.setup-done" ]; then
    git config --global user.name "Your Name"
    touch "$HOME/.setup-done"
fi
```

Note that `.bashrc` runs as the unprivileged `user`, which has **no sudo** — it
cannot install system packages or touch anything outside the home directory.
Root-level work belongs in `APT_PACKAGES` or the `INIT_SCRIPT` hook below.

**Which to use?** `APT_PACKAGES` for declarative system packages that belong in
`.env` and should exist before login; `INIT_SCRIPT` for root-level configuration
that packages alone cannot express; `~/.bashrc` for per-user tooling, env vars,
aliases, or richer bootstrap logic. They compose cleanly.

---

## Q: How do I run something as root at boot? (INIT_SCRIPT)

**A:** The image ships **no sudo** and the `user` account has no route to root,
so root-level customisation is driven from the host instead of from inside the
container. Mount a directory read-only at `/opt/init` and put an `init.sh` in it:

```yaml
volumes:
  - ${INIT_PATH:-./init}:/opt/init:ro
```

`entrypoint.sh` runs `$INIT_SCRIPT` (default `/opt/init/init.sh`) **as root** on
every start — after `APT_PACKAGES` is installed and the opencode config is
generated, before `sshd` starts. If the file does not exist, the step is skipped.

Start from [`init/init.sh.example`](init/init.sh.example):

```bash
cp init/init.sh.example init/init.sh
sudo chown -R root:root init && sudo chmod 755 init && sudo chmod 644 init/init.sh
```

**Why the ownership matters.** A script that runs as root is a privilege
escalation path if the unprivileged user can edit it — they would just rewrite
it and wait for a restart. So `entrypoint.sh` checks, as `user`, whether the
script or its parent directory is writable and **refuses to run it** if so:

```
ERROR: refusing to run '/opt/init/init.sh': it is writable by 'user'.
       Mount it read-only (:ro) and owned by root, then restart.
```

Keep the directory owned by `root`, mounted `:ro`, and **outside**
`USER_HOME_PATH` (which the user owns by definition).

Two more things to know: the hook runs on **every** start, so make it
idempotent; and a non-zero exit is logged as a warning but does **not** stop the
container, so a broken hook can't lock you out of SSH.

---

## Q: How do I serve more than one model?

**A:** Just put it in `MODELS_PATH`. Every subdirectory of `/models` containing a
GGUF becomes a model, named after the directory:

```
/models/
  gemma4-12b/    gemma-4-12b-it-UD-Q4_K_XL.gguf        -> swap/gemma4-12b
  qwen-coder/    qwen-coder-Q8_0.gguf                  -> swap/qwen-coder
  big-70b/       big-70b-…-00001-of-00003.gguf         -> swap/big-70b
                 mmproj-F16.gguf                          (vision, only if MMPROJ_ENABLED)
```

`MODEL_REPO`/`MODEL_QUANT`/`MODEL_ID` only decide what gets **downloaded** on
first boot; anything already sitting in `/models` is picked up too. To add a
model, download it into its own directory and restart llama-swap.

Per directory the entrypoint prefers the first shard of a split GGUF, prefers
`MODEL_QUANT` when several quants coexist, and ignores `mmproj*` when choosing
the model file (it is the vision projector, attached via `--mmproj` instead —
and only when `MMPROJ_ENABLED=true`, which it is not by default).

All models go into one `exclusive` swap group, since a single GPU can only hold
one at a time — llama-swap unloads the current one before starting another.

On the opencode side, `entrypoint.sh` asks llama-swap's `/v1/models` what is
actually being served and writes every model into `opencode.json`, so you can
switch between them from the model picker. `MODEL_ID` stays the default. Note
the config is only regenerated when it is missing or when
`REGENERATE_OPENCODE_CONFIG=true` — set that after adding models.

---

## Q: The model barely fits in VRAM. What can I offload to RAM?

**A:** There is a dedicated variable per lever. All defaults keep everything on
the GPU, which is what the stack did before these existed.

| Variable | llama-server flag | What it does |
|---|---|---|
| `CTX_SIZE` | `--ctx-size` | **Try this first.** At large context the KV cache costs more VRAM than the weights. |
| `N_GPU_LAYERS` | `-ngl` | Layers kept in VRAM. `99` = all. Lower it to push the rest to RAM. Simplest lever, costliest in speed. |
| `CPU_MOE` | `-cmoe` | MoE models: **all** expert weights to RAM, attention stays on GPU. |
| `N_CPU_MOE` | `-ncmoe N` | Same, but only the first N layers' experts. Finer grained. |
| `OVERRIDE_TENSOR` | `-ot` | Placement by tensor-name regex, when the above are too coarse. |
| `KV_OFFLOAD` | `-nkvo` | `false` keeps the KV cache in RAM. Frees a lot, usually a big slowdown. |
| `KV_CACHE_TYPE` | `-ctk`/`-ctv` | KV quantisation. `q8_0` default; `q4_0` halves it with some quality loss. |
| `EXTRA_LLAMA_ARGS` | *(verbatim)* | Escape hatch for flags with no variable here. |

For a **MoE** model, `CPU_MOE`/`N_CPU_MOE` beats lowering `N_GPU_LAYERS`: the
experts are the bulk of the weights but only a few are active per token, so
parking them in RAM costs far less speed than evicting whole layers.

### Example 1 — dense model, 100 % in VRAM

`gemma4-12b` at a modest context fits on a 24 GB card with everything on the GPU.
This is also exactly the default configuration:

```bash
MODEL_REPO=unsloth/gemma-4-12b-it-GGUF
MODEL_QUANT=UD-Q4_K_XL
MODEL_ID=gemma4-12b
MMPROJ_ENABLED=false    # no vision: keeps prompt cache reuse (and VRAM) free

CTX_SIZE=32768          # the single biggest VRAM lever
KV_CACHE_TYPE=q8_0
N_GPU_LAYERS=99         # all layers on the GPU
KV_OFFLOAD=true         # KV cache on the GPU too
CPU_MOE=false           # dense model: nothing to offload
N_CPU_MOE=
OVERRIDE_TENSOR=
```

### Example 2 — MoE model, experts in RAM

`Qwen3.6-35B-A3B` is a Mixture-of-Experts model: 35 B total parameters but only
~3 B active per token. The experts are most of the weight and are what you want
in RAM:

```bash
MODEL_REPO=unsloth/Qwen3.6-35B-A3B-GGUF
MODEL_QUANT=UD-Q3_K_XL
MODEL_ID=qwen36-35b-a3b
MMPROJ_ENABLED=false    # skip the projector: VRAM is already tight here

CTX_SIZE=32768
KV_CACHE_TYPE=q8_0
N_GPU_LAYERS=99         # keep attention + non-expert tensors on the GPU
CPU_MOE=true            # -cmoe: all expert weights to RAM
KV_OFFLOAD=true
```

Still short on VRAM? Trade back gradually, in this order: swap `CPU_MOE=true`
for `N_CPU_MOE=<N>` and tune N (only the first N layers' experts go to RAM, the
rest stay on the GPU — raise N until it fits); then lower `CTX_SIZE`; then
`KV_CACHE_TYPE=q4_0`; and only then `N_GPU_LAYERS`.

**One caveat:** these variables are global — they apply to every model
llama-swap serves, not per model. If you keep both examples above in the same
`/models` directory, `CPU_MOE=true` is the setting to use: it is a no-op on a
dense model (verified — `-cmoe` starts fine against a dense GGUF, there are
simply no expert tensors to move), so gemma still runs fully on the GPU while
Qwen's experts go to RAM. `N_GPU_LAYERS` and `CTX_SIZE`, by contrast, hit both.

---

## Q: Does vision / multimodal work?

**A:** Yes, but it is **off by default** — set `MMPROJ_ENABLED=true`.

With it on, `init-llama-swap.sh` downloads the projector alongside the weights,
attaches it to every model directory that has one with `--mmproj`, and
llama-server serves images through the OpenAI-compatible API. Verified end to
end: an image posted to `/v1/chat/completions` as an `image_url` content part is
described correctly. With it off, the projector is neither downloaded nor
passed, and a projector already sitting in the directory is ignored.

### Why it defaults to off: `MMPROJ_ENABLED`

Because loading a projector makes llama.cpp **turn off prompt cache reuse**
(`--cache-reuse`). The command line still carries the flag, but it has no effect
while an mmproj is loaded, so every request reprocesses the entire prompt
instead of resuming from the common prefix.

In an opencode session that is the wrong trade. The prompt is long (system
prompt + tool definitions + accumulated conversation), it grows turn by turn,
and each turn shares almost all of its prefix with the previous one — exactly
the case cache reuse exists for. Paying full prompt processing on every turn to
keep a capability that a coding session almost never uses is a bad deal, so you
have to ask for it.

Switching it on later is safe: the projector download is tracked separately from
the weights, so a model that is already on disk gets its projector fetched on
the next start rather than being skipped as "already present".

### Choosing the projector: `MMPROJ_QUANT`

Repos often ship several projectors — unsloth publishes `mmproj-BF16.gguf`,
`mmproj-F16.gguf` and `mmproj-F32.gguf`. `MMPROJ_QUANT` (default `F16`) picks
one instead of downloading all three and using whichever sorts first.

Matching is **case-insensitive** and **boundary-aware**, which matters more than
it sounds:

- Case: unsloth writes `F16`, ggml-org `mmproj-model-f16.gguf`, bartowski
  `mmproj-google_gemma-3-12b-it-f16.gguf`. One value covers all three.
- Boundary: a naive `*F16*` also matches `mmproj-**BF**16.gguf`, so you would
  still download the extra projector this variable exists to avoid. The quant
  must be preceded by `-`, `_` or `.`.

Set it empty to go back to downloading every projector in the repo.

If a directory has projectors but none matching `MMPROJ_QUANT`, the first
available one is used and the reason is logged:

```
>> NOTE: no mmproj matching 'F16' in /models/foo, using mmproj-BF16.gguf
```

That fallback is deliberate: a model downloaded before this variable existed
keeps its vision instead of silently losing it.

On the opencode side, `MMPROJ_ENABLED` decides what the generated
`opencode.json` advertises. With it on, every model is declared
attachment-capable:

```json
"attachment": true,
"modalities": { "input": ["text", "image", "audio"], "output": ["text"] }
```

With it off, `"attachment": false` and the input modality list is `["text"]`.

It is all-or-nothing rather than per model, and deliberately so: the opencode
container never sees `/models` — it only learns model *ids* from llama-swap's
`/v1/models` — so it cannot tell which models have a projector. The one thing it
does know is whether llama-server was told to load one at all, which is what it
keys off. With the flag on, the attachment option is offered everywhere; against
a model with no projector the request just fails at llama-server, which is a
more useful outcome than the option silently never appearing. `video` and `pdf`
are left out because llama.cpp does not handle them.

Without these fields opencode treats a custom-provider model as text-only — that
is opencode's own default for a custom provider, which is why they have to be
written out explicitly when multimodal input is wanted.

Remember that `opencode.json` is generated once. After flipping
`MMPROJ_ENABLED`, either delete it or set `REGENERATE_OPENCODE_CONFIG=true` so
the capabilities are rewritten.

**Caveat worth knowing:** `opencode run` (the non-interactive CLI) does **not**
expand `@file` mentions into attachments — the path is sent as literal text, so
the model never sees the image regardless of the config above. Attaching images
is an interactive-TUI path. opencode is primarily a text tool; treat multimodal
input as a bonus rather than a supported workflow here.

---

## Q: How do I control whether the model "thinks"? (REASONING_ENABLED)

**A:** `REASONING_ENABLED` takes `auto` (default, the template decides), `true`,
or `false`, and `REASONING_EFFORT` takes `low`/`medium`/`high`. Both are applied
on **both** sides of the stack, because neither alone is enough:

- **llama-server** gets `--reasoning on|off` (nothing for `auto`, which is its
  own default).
- **opencode** gets `chat_template_kwargs` in the model options —
  `enable_thinking` (the boolean Qwen3, DeepSeek-R1 and GLM templates read) and
  `reasoning_effort` (what the gpt-oss family reads). Templates ignore whichever
  variable they don't use, so sending both is free.

### Why not just `reasoningEffort`?

Because it does nothing against llama.cpp. opencode's `@ai-sdk/openai-compatible`
provider turns a model's `options.reasoningEffort` into a **top-level**
`reasoning_effort` request field, and llama-server accepts that field without
error and then silently drops it — it never reaches the chat template, not even
with an invalid value. Only `chat_template_kwargs` gets through.

What makes this work is that the provider forwards **unknown** keys in `options`
verbatim as top-level request fields, so `chat_template_kwargs` declared there
lands in the request body as-is. `reasoningEffort` is still emitted alongside it:
harmless for llama.cpp, and correct if the config is ever pointed at a provider
that honours it.

So the generated `opencode.json` looks like this for `REASONING_ENABLED=true`:

```json
"options": {
  "reasoningEffort": "high",
  "chat_template_kwargs": { "reasoning_effort": "high", "enable_thinking": true }
}
```

and like this for `false` (no point advertising an effort level you're disabling):

```json
"options": { "chat_template_kwargs": { "enable_thinking": false } }
```

Remember `opencode.json` is only regenerated when missing or when
`REGENERATE_OPENCODE_CONFIG=true` — set that after changing either variable.

Related server-side flags, reachable through `EXTRA_LLAMA_ARGS`:
`--reasoning-budget N` (cap thinking tokens) and `--reasoning-format`
(`deepseek` puts thoughts in `message.reasoning_content`, `none` leaves them
inline in the content).

---

## Q: How do I stop the agent from reaching the rest of my LAN?

**A:** Set `BLOCK_LOCAL_NETWORK=true`. The entrypoint then installs iptables
rules on the OUTPUT chain that reject traffic to:

| Range             | What it is                                    |
|-------------------|-----------------------------------------------|
| `10.0.0.0/8`      | RFC1918 private                               |
| `172.16.0.0/12`   | RFC1918 private                               |
| `192.168.0.0/16`  | RFC1918 private                               |
| `169.254.0.0/16`  | link-local, incl. cloud metadata (`169.254.169.254`) |

The IPv6 equivalents (`fc00::/7`, `fe80::/10`) are handled too when IPv6 is
available. Everything else — the whole internet — stays reachable, and so does
llama-swap: it lives on the compose bridge inside `172.16.0.0/12`, so its
address is resolved at boot and allowed explicitly *before* the reject rules.
Inbound SSH keeps working because reply traffic matches the ESTABLISHED rule.

This needs `NET_ADMIN`, already present in both compose files. Without it the
entrypoint logs an error and starts anyway with the LAN **not** blocked — check
the logs rather than assuming.

The unprivileged user cannot undo any of this: changing iptables needs
`CAP_NET_ADMIN`, which only the root entrypoint has, and there is no sudo.

To adjust the policy, use the `INIT_SCRIPT` hook — it runs as root *after* the
firewall is set up, precisely so it can amend it:

```bash
# /opt/init/init.sh — allow one specific host on the LAN
iptables -I OUTPUT 1 -d 192.168.1.50 -p tcp --dport 443 -j ACCEPT
```

Position `1` always lands ahead of the reject rules, whatever the entrypoint
added before it. `init/init.sh.example` ships this and a few variants
(whole subnet, LAN DNS server) ready to uncomment.

Note DNS keeps working because Docker's resolver lives on `127.0.0.11`
(loopback). If you point the container at a DNS server on your LAN instead, add
an exception for it, or name resolution will break.

---

## Q: Can the SSH user become root inside the container?

**A:** No, by design. The container is reachable over SSH by whoever holds the
key, so the account it lands on is treated as untrusted:

- **No sudo.** It is not installed, is explicitly purged at build time, and
  `/etc/sudoers.d` is removed. There is no sudoers entry for `user`.
- **No root password**, so `su` cannot be used either (root's shadow entry is
  locked in the base image).
- **`no-new-privileges:true`** on the opencode service in both compose files.
  This is what neutralises the setuid binaries Debian ships (`su`, `passwd`,
  `mount`, …): with `NoNewPrivs` set, executing them cannot raise privileges.
  The flag is inherited by every process in the container, SSH sessions
  included — verify with `grep NoNewPrivs /proc/self/status` after logging in.
- **The root-run hook is not user-writable.** `entrypoint.sh` refuses to execute
  `$INIT_SCRIPT` if `user` can write to it or its directory, which is what stops
  the hook from becoming an escalation path. See the `INIT_SCRIPT` question above.

Root-level changes are therefore driven from the host, through `.env`:
`APT_PACKAGES` for packages, `INIT_SCRIPT` for everything else. For one-off
debugging you can always take a root shell from the host with
`docker exec -u 0 -it opencode bash` — that path is controlled by whoever can
talk to the Docker daemon, not by the SSH user.

Note this hardens the account *inside* the container; it is not a sandbox
boundary for the host. Standard container practice still applies (don't expose
port 22 to the internet unnecessarily, keep the private key safe).

---

## Q: Which compose file do I use — and how do I build the image myself?

**A:** The two GPU files are for **end users** and pull the published image:

```bash
docker compose -f docker-compose.nvidia.yml up -d     # CUDA
docker compose -f docker-compose.amd.yml    up -d     # ROCm
```

`docker-compose.build.yml` is a **build override** for developing this repo.
Stack it on top of either GPU file to build from the local `Dockerfile`:

```bash
docker compose -f docker-compose.nvidia.yml -f docker-compose.build.yml up -d --build
```

It sets the same image name (`jesusdf/opencode-llama-swap-aio:latest`) plus
`pull_policy: build`, so the local build wins and everything else — volumes,
ports, capabilities — is inherited unchanged from the GPU file. Keeping the
build in a separate file is why the two GPU files stay identical apart from the
image tag and the GPU passthrough block.

Expect the build to take a few minutes: opencode is **compiled from source**
inside the image (see the next question), so the first stage runs a full
dependency install of the opencode monorepo. None of that reaches the final
image, which ends up *smaller* than the npm-based one it replaced.

---

## Q: Why is opencode compiled from source instead of installed from npm?

**A:** Because the npm package is not JavaScript. `opencode-ai` ships a ~183 MB
standalone binary with OpenTUI's native `libopentui.so` **embedded**, and
starting the TUI makes it unpack that library into a temporary directory before
loading it. Where that directory is missing, or mounted `noexec` — both common
in containers and on hardened hosts — opencode dies before drawing anything:

```
Failed to initialize OpenTUI render library: Failed to open library
"/<tmpdir>/.<hash>-00000001.so": cannot open shared object file
```

The `Dockerfile` therefore builds opencode itself in a first stage and keeps the
native library as an ordinary file, pointed at through `OTUI_ASSET_ROOT`. There
is no unpacking at runtime, so the failure cannot happen. Two build arguments
control it, both settable from `.env`:

| Variable | Example | Description |
|---|---|---|
| `OPENCODE_REF` | `v1.18.15` | Git revision to compile — tag, branch or commit SHA. Pinned in the `Dockerfile`; builds are reproducible until it is bumped. |
| `OPENCODE_VERSION` | *(empty)* | Version reported by `opencode --version`. Derived from the ref when empty: `vX.Y.Z` → `X.Y.Z`, otherwise `0.0.0-<short sha>`. |

These are **build**-time only, so they do nothing unless you build the image
yourself with `docker-compose.build.yml`. To move to a newer opencode:

```bash
echo 'OPENCODE_REF=v1.19.0' >> .env
docker compose -f docker-compose.nvidia.yml -f docker-compose.build.yml up -d --build
```

Leave them unset to get the revision pinned in the `Dockerfile`.

**What this changed about node/npm.** The image still installs `nodejs`, because
opencode installs its language servers itself and then runs them straight out of
`node_modules/.bin` — those are `#!/usr/bin/env node` scripts, so without node
every JS/TS language server fails to start. The `npm` **CLI** is no longer
installed: it costs ~220 MB (more than twice what nodejs does), opencode uses a
bundled installer rather than the npm binary, and the only feature that shells
out to it is the ESLint language server. Set `APT_PACKAGES="npm"` if you want it
back.

---

## Q: How does CI build the image?

**A:** [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml)
builds and pushes the **opencode** image (`linux/amd64`) to Docker Hub on pushes
to `main` and `v*` tags. It needs two repository secrets:

- `DOCKER_USER` — Docker Hub username
- `DOCKER_PASSWORD` — Docker Hub access token

It tags `:latest` and `:<short-sha>`, and syncs this repo's README to the Docker
Hub description.

The opencode revision it compiles comes from the `ARG OPENCODE_REF` line in the
`Dockerfile`. A manual run (`workflow_dispatch`) can override it with the
`opencode_ref` input without committing anything; whichever is used ends up on
the image as the `org.opencode.ref` label:

```bash
docker buildx imagetools inspect jesusdf/opencode-llama-swap-aio:latest \
    --format '{{ index .Image.Config.Labels "org.opencode.ref" }}'
```
