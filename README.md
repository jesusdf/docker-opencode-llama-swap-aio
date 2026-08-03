# docker-opencode-llama-swap-aio

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
docker compose -f docker-compose.nvidia.yml up -d --build

# AMD (ROCm):
docker compose -f docker-compose.amd.yml up -d --build
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

You can use sudo to install or modify anything in the container.

For a full Q&A-style reference (every variable, NVIDIA/AMD requirements,
troubleshooting) see [`DOCUMENTATION.md`](DOCUMENTATION.md).

## Configuration

See [`.env.example`](.env.example) for all variables. Highlights:

- `MODEL_REPO` / `MODEL_QUANT` — Hugging Face GGUF repo and quant pattern to
  download (multimodal `mmproj*` files are picked up automatically).
- `MODEL_ID` — internal name used for both the llama-swap model
  (`swap/<MODEL_ID>`) and the opencode model.
- `CTX_SIZE`, `N_PREDICT`, `KV_CACHE_TYPE`, `MODEL_TTL`, `TEMP`, `TOP_P`,
  `TOP_K` — inference parameters.
- `LLAMA_API_KEY` — protects the llama-swap API and is used by opencode.
- `SSH_PUBLIC_KEY` — authorized key for SSH login.
- `USER_HOME_PATH`, `MODELS_PATH` — host paths for persistence.
