#!/bin/bash
set -euo pipefail
shopt -s nullglob

# ----------------------------------------------------------------------------
# Defaults (overridable via environment / .env)
# ----------------------------------------------------------------------------
: "${MODEL_REPO:?MODEL_REPO is required, e.g. unsloth/gemma-4-12b-it-GGUF}"
: "${MODEL_QUANT:=UD-Q4_K_XL}"
: "${MODEL_ID:=model}"
: "${HF_TOKEN:=}"
: "${CTX_SIZE:=262144}"
: "${N_PREDICT:=8192}"
: "${KV_CACHE_TYPE:=q8_0}"
: "${MODEL_TTL:=900}"
: "${TEMP:=0.7}"
: "${TOP_P:=0.95}"
: "${TOP_K:=64}"
: "${LLAMA_API_KEY:=}"
: "${PORT:=8080}"

MODELS_DIR="/models"
MODEL_DIR="${MODELS_DIR}/${MODEL_ID}"
CONFIG_FILE="${MODELS_DIR}/config.yaml"

# ----------------------------------------------------------------------------
# Download the model (GGUF from Hugging Face) if it is not present yet
# ----------------------------------------------------------------------------
mkdir -p "$MODEL_DIR"

existing=("$MODEL_DIR"/*"${MODEL_QUANT}"*.gguf)
if [ ${#existing[@]} -eq 0 ]; then
    echo ">> Model '${MODEL_REPO}' (${MODEL_QUANT}) not found in ${MODEL_DIR}, downloading..."

    if ! command -v huggingface-cli >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends python3 python3-pip
        rm -rf /var/lib/apt/lists/*
        pip install --break-system-packages -q "huggingface_hub[hf_xet]" \
            || pip install -q "huggingface_hub[hf_xet]"
    fi

    export HF_XET_HIGH_PERFORMANCE=1
    huggingface-cli download "$MODEL_REPO" \
        --include "*${MODEL_QUANT}*.gguf" "mmproj*.gguf" \
        --local-dir "$MODEL_DIR" \
        ${HF_TOKEN:+--token "$HF_TOKEN"}
else
    echo ">> Model already present in ${MODEL_DIR}, skipping download."
fi

# ----------------------------------------------------------------------------
# Resolve the model file (use the first shard for split GGUFs) + optional mmproj
# ----------------------------------------------------------------------------
shards=("$MODEL_DIR"/*"${MODEL_QUANT}"*-00001-of-*.gguf)
if [ ${#shards[@]} -gt 0 ]; then
    MODEL_FILE="${shards[0]}"
else
    files=("$MODEL_DIR"/*"${MODEL_QUANT}"*.gguf)
    if [ ${#files[@]} -eq 0 ]; then
        echo "ERROR: no GGUF matching '*${MODEL_QUANT}*' found in ${MODEL_DIR}" >&2
        exit 1
    fi
    MODEL_FILE="${files[0]}"
fi
echo ">> Using model file: ${MODEL_FILE}"

MMPROJ_LINE=""
mmproj=("$MODEL_DIR"/mmproj*.gguf)
if [ ${#mmproj[@]} -gt 0 ]; then
    MMPROJ_LINE="      --mmproj ${mmproj[0]}"
    echo ">> Using mmproj (vision) file: ${mmproj[0]}"
fi

# ----------------------------------------------------------------------------
# Generate llama-swap config.yaml
# ----------------------------------------------------------------------------
{
    echo "healthCheckTimeout: 300"
    echo "logLevel: info"
    echo ""
    if [ -n "$LLAMA_API_KEY" ]; then
        echo "apiKeys:"
        echo "  - \"${LLAMA_API_KEY}\""
        echo ""
    fi
    cat <<YAML
models:
  "swap/${MODEL_ID}":
    name: "${MODEL_ID}"
    cmd: |
      /app/llama-server
      --host 0.0.0.0 --port \${PORT}
      -m ${MODEL_FILE}
${MMPROJ_LINE}
      --jinja -ngl 99 -fa on
      -ctk ${KV_CACHE_TYPE} -ctv ${KV_CACHE_TYPE}
      --ctx-size ${CTX_SIZE} --n-predict ${N_PREDICT}
      --temp ${TEMP} --top-p ${TOP_P} --top-k ${TOP_K}
      --cache-reuse 256 --parallel 1
    ttl: ${MODEL_TTL}

groups:
  principal:
    swap: true
    exclusive: true
    members:
      - "swap/${MODEL_ID}"
YAML
} > "$CONFIG_FILE"

echo ">> Generated ${CONFIG_FILE}:"
cat "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Start llama-swap
# ----------------------------------------------------------------------------
exec llama-swap --config "$CONFIG_FILE" --listen ":${PORT}"
