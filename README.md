# opencode + llama-swap All In One

A ready-to-run stack that pairs [opencode](https://opencode.ai) (used as a coding
agent over SSH) with [llama-swap](https://github.com/mostlygeek/llama-swap)
serving a local GGUF model through llama.cpp.

Everything (model, quantization, context size, sampling, SSH key…) is driven by
environment variables — nothing is hardcoded.

## Quick start

```bash
cp .env.example .env
# edit .env: set MODEL_REPO/MODEL_QUANT, LLAMA_API_KEY, SSH_PUBLIC_KEY, paths…

# NVIDIA (CUDA):
docker compose -f docker-compose.nvidia.yml up -d

# AMD (ROCm):
docker compose -f docker-compose.amd.yml up -d
```

The first boot downloads the model, so llama-swap may take a while to become
healthy (the healthcheck `start_period` allows for it). Once it is up, opencode
starts automatically. Then connect:

```bash
ssh -p ${SSH_PORT:-2222} user@<host>
opencode
```

It is also possible to enter the container using:

```bash
docker exec -it opencode bash
```

The compose files above pull the published image
`jesusdf/opencode-llama-swap-aio`. To build it from this repo instead, stack the
build override on top:

```bash
docker compose -f docker-compose.nvidia.yml -f docker-compose.build.yml up -d --build
```

## What runs

- **llama-swap** — downloads the model from Hugging Face on first start,
  generates its `config.yaml` from environment variables, and serves an
  OpenAI-compatible API on port `8080`.
- **opencode** — an SSH-accessible container with opencode compiled into the
  image and pre-configured to talk to llama-swap. It waits for llama-swap to be
  healthy before starting.

| Port | Service    | Purpose                          |
|------|------------|----------------------------------|
| 22   | opencode   | SSH access (login user: `user`)  |
| 8080 | llama-swap | OpenAI-compatible model API      |

## Configuration

Every variable is documented inline in [`.env.example`](.env.example), and in
full in [`DOCUMENTATION.md`](DOCUMENTATION.md#q-what-are-all-the-environment-variables-and-what-do-they-do).
Set these before the first run:

- `MODEL_REPO` / `MODEL_QUANT` — Hugging Face GGUF repo and quant pattern to
  download. `MODEL_ID` names the directory it lands in under `MODELS_PATH`, and
  is the default model in opencode.
- `CTX_SIZE` — context window, and the single biggest lever on VRAM.
- `SSH_PUBLIC_KEY` — authorized key for SSH login; without it nobody can log in.
- `LLAMA_API_KEY` — protects the llama-swap API and is used by opencode.
- `USER_HOME_PATH` / `MODELS_PATH` — host paths for persistence.

Some variables are **not booleans**: they take `auto`, which means "look at the
model and decide", and that is the default. `true`/`false` force the answer.

| Variable | Default | What `auto` decides |
|---|---|---|
| `MTP_ENABLED` | `auto` | Enable [multi-token prediction](DOCUMENTATION.md#q-what-is-mtp-and-what-does-it-cost-me) (~1.5-2× faster generation) only on models whose weights actually carry the heads. `true` forces it everywhere and will break models without them. |
| `REASONING_ENABLED` | `auto` | Let the model's chat template decide whether it thinks. |
| `PRESERVE_REASONING` | `true` | With `auto`, leave the template's own default alone. Defaults to `true` instead because keeping [every turn's thinking](DOCUMENTATION.md#q-how-do-i-control-whether-the-model-thinks-reasoning_enabled) in the prompt helps the agent loop. |

`VRAM_TRY_AUTOFIT` (default `true`) is a plain boolean but works the same way:
it measures each model against free VRAM and only applies the offload-to-RAM
settings to the ones that [do not fit](DOCUMENTATION.md#q-the-model-barely-fits-in-vram-what-can-i-offload-to-ram).

The rest, grouped: inference parameters (`N_PREDICT`, `KV_CACHE_TYPE`, `TEMP`…),
[VRAM tuning](DOCUMENTATION.md#q-the-model-barely-fits-in-vram-what-can-i-offload-to-ram)
for models that barely fit, [vision](DOCUMENTATION.md#q-does-vision--multimodal-work)
(`MMPROJ_ENABLED`, off by default), `BLOCK_LOCAL_NETWORK` to cut the agent off
from your LAN, and [`APT_PACKAGES`/`INIT_SCRIPT`](DOCUMENTATION.md#q-how-do-i-install-extra-packages-or-run-my-own-setup-in-the-opencode-container)
to customise the container at boot.

## Root access

The `user` account is unprivileged and **sudo is not installed** — there is no
way to become root from an SSH session. To change anything that needs root, use
`APT_PACKAGES` for packages and the `INIT_SCRIPT` hook for everything else (both
run as root at boot, from the host-controlled `.env`). If you really need a root
shell for debugging, go through the host:

```bash
docker exec -u 0 -it opencode bash
```

---

For a full Q&A-style reference (every variable, NVIDIA/AMD requirements,
troubleshooting) see [`DOCUMENTATION.md`](DOCUMENTATION.md).
