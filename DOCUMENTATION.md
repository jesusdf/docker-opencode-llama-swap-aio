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
| `MODEL_QUANT` | `UD-Q4_K_XL` | Quant pattern to match when downloading (`*<MODEL_QUANT>*.gguf`). Split shards and `mmproj*` (vision) files are picked up automatically. |
| `MODEL_ID` | `gemma4-12b` | Internal name used for the llama-swap model (`swap/<MODEL_ID>`) and the opencode model. |
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

### Host paths

| Variable | Example | Description |
|---|---|---|
| `USER_HOME_PATH` | `/home/docker/opencode_user` | Host path persisted as the user's `/home/user`. |
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

Downloads use `hf_transfer` (`HF_HUB_ENABLE_HF_TRANSFER=1`) for speed.

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

## Q: How does CI build the image?

**A:** [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml)
builds and pushes the **opencode** image (`linux/amd64`) to Docker Hub on pushes
to `main` and `v*` tags. It needs two repository secrets:

- `DOCKER_USER` — Docker Hub username
- `DOCKER_PASSWORD` — Docker Hub access token

It tags `:latest` and `:<short-sha>`, and syncs this repo's README to the Docker
Hub description.
