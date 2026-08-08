# opencode + llama-swap All In One 

A ready-to-run stack that pairs [opencode](https://opencode.ai) (used as a coding
agent over SSH) with [llama-swap](https://github.com/mostlygeek/llama-swap)
serving a local GGUF model through llama.cpp.

Two services:

- **llama-swap** — downloads the model from Hugging Face on first start,
  generates its `config.yaml` from environment variables, and serves an
  OpenAI-compatible API on port `8080`.
- **opencode** — an SSH-accessible container with opencode pre-installed and
  pre-configured to talk to llama-swap. It waits for llama-swap to be healthy
  before starting.

Everything (model, quantization, context size, sampling, SSH key…) is driven by
environment variables — nothing is hardcoded.

## Ports exposed to the user

| Port | Service    | Purpose                          |
|------|------------|----------------------------------|
| 22   | opencode   | SSH access (login user: `user`)  |
| 8080 | llama-swap | OpenAI-compatible model API      |

## Quick start

```bash
cp .env.example .env
# edit .env: set MODEL_REPO/MODEL_QUANT, LLAMA_API_KEY, SSH_PUBLIC_KEY, paths…

# NVIDIA (CUDA):
docker compose -f docker-compose.nvidia.yml up -d

# AMD (ROCm):
docker compose -f docker-compose.amd.yml up -d
```

These pull the published image `jesusdf/opencode-llama-swap-aio`. To build it
from this repo instead, stack the build override on top:

```bash
docker compose -f docker-compose.nvidia.yml -f docker-compose.build.yml up -d --build
```

The first boot downloads the model, so llama-swap may take a while to become
healthy (the healthcheck `start_period` allows for it). Once it is up, opencode
starts automatically.

Then connect:

```bash
ssh -p ${SSH_PORT:-2222} user@<host>
opencode
```

It is also possible to enter the container using:

```bash
docker exec -it opencode bash
```

The `user` account is unprivileged and **sudo is not installed** — there is no
way to become root from an SSH session. To change anything that needs root, use
`APT_PACKAGES` for packages and the `INIT_SCRIPT` hook for everything else (both
run as root at boot, from the host-controlled `.env`). If you really need a root
shell for debugging, go through the host: `docker exec -u 0 -it opencode bash`.

For a full Q&A-style reference (every variable, NVIDIA/AMD requirements,
troubleshooting) see [`DOCUMENTATION.md`](DOCUMENTATION.md).

## Configuration

See [`.env.example`](.env.example) for all variables. Highlights:

- `MODEL_REPO` / `MODEL_QUANT` — Hugging Face GGUF repo and quant pattern to
  download.
- `MMPROJ_ENABLED` — multimodal (image/audio) input, **off by default**: loading
  the projector disables llama.cpp's prompt cache reuse, which costs far more in
  a text-only coding session than vision is worth. Set `true` to enable it on
  both llama-server (`--mmproj`) and opencode (attachment capability).
- `MMPROJ_QUANT` — which multimodal projector to fetch when a repo ships several
  (default `F16`); empty downloads them all. Only used when `MMPROJ_ENABLED`.
- `MODEL_ID` — name of the model directory under `MODELS_PATH`, and the default
  model in opencode. It only controls what gets *downloaded*: llama-swap serves
  every model directory it finds, and opencode is configured with all of them.
- `CTX_SIZE`, `N_PREDICT`, `KV_CACHE_TYPE`, `MODEL_TTL`, `TEMP`, `TOP_P`,
  `TOP_K` — inference parameters.
- `REASONING_ENABLED` / `REASONING_EFFORT` — whether the model thinks
  (`auto`/`true`/`false`) and how hard (`low`/`medium`/`high`). Applied to both
  llama-server (`--reasoning`) and opencode (`chat_template_kwargs`).
- `N_GPU_LAYERS`, `CPU_MOE`, `N_CPU_MOE`, `OVERRIDE_TENSOR`, `KV_OFFLOAD`,
  `EXTRA_LLAMA_ARGS` — VRAM tuning for models that barely fit; defaults keep
  everything on the GPU. See
  [`DOCUMENTATION.md`](DOCUMENTATION.md#q-the-model-barely-fits-in-vram-what-can-i-offload-to-ram).
- `REGENERATE_OPENCODE_CONFIG` — set to `true` to rewrite `opencode.json` on
  every start (manual edits are lost); `false` generates it only if missing.
- `LLAMA_API_KEY` — protects the llama-swap API and is used by opencode.
- `SSH_PUBLIC_KEY` — authorized key for SSH login.
- `USER_HOME_PATH`, `MODELS_PATH` — host paths for persistence.
- `BLOCK_LOCAL_NETWORK` — when `true`, blocks egress to the LAN (RFC1918 plus
  link-local) while leaving the internet and llama-swap reachable.
- `INIT_SCRIPT` / `INIT_PATH` — root-run hook. `INIT_PATH` is mounted read-only
  at `/opt/init`; if `INIT_SCRIPT` (default `/opt/init/init.sh`) exists it is
  executed as root at boot. Refused if the container user can write to it. See
  [`init/init.sh.example`](init/init.sh.example).
- `APT_PACKAGES` — extra Debian packages (space-separated) installed into the
  opencode container at boot. For richer per-user setup you can also edit
  `~/.bashrc` in the mapped home directory — see
  [`DOCUMENTATION.md`](DOCUMENTATION.md#q-how-do-i-install-extra-packages-or-run-my-own-setup-in-the-opencode-container).
