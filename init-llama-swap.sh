#!/bin/bash
set -euo pipefail
shopt -s nullglob

# ----------------------------------------------------------------------------
# Defaults (overridable via environment / .env)
# ----------------------------------------------------------------------------
: "${MODEL_REPO:?MODEL_REPO is required, e.g. unsloth/gemma-4-12b-it-GGUF}"
: "${MODEL_QUANT:=UD-Q4_K_XL}"
# Load the multimodal projector (vision/audio input). Off by default: llama.cpp
# turns off prompt cache reuse whenever an mmproj is attached, so every request
# reprocesses the whole prompt — a heavy price for a capability most coding
# sessions never use. When false the projector is neither downloaded nor passed
# to llama-server.
: "${MMPROJ_ENABLED:=false}"
# Which multimodal projector to fetch when the repo ships several (unsloth
# publishes BF16/F16/F32). Empty means "any", i.e. download them all — hence
# '=' and not ':=', which would treat an explicitly empty value as unset.
: "${MMPROJ_QUANT=F16}"
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

# VRAM tuning. The defaults reproduce the previous hardcoded behaviour: all
# layers on the GPU, KV cache on the GPU, no MoE/tensor overrides.
: "${N_GPU_LAYERS:=99}"
: "${CPU_MOE:=false}"
: "${N_CPU_MOE:=}"
: "${OVERRIDE_TENSOR:=}"
: "${KV_OFFLOAD:=true}"
: "${EXTRA_LLAMA_ARGS:=}"

# Reasoning: 'auto' lets the chat template decide (llama-server's own default).
: "${REASONING_ENABLED:=auto}"

case "${MMPROJ_ENABLED,,}" in
    1|true|yes|on) USE_MMPROJ=1 ;;
    *)             USE_MMPROJ=0 ;;
esac

MODELS_DIR="/models"
MODEL_DIR="${MODELS_DIR}/${MODEL_ID}"
CONFIG_FILE="${MODELS_DIR}/config.yaml"

# ----------------------------------------------------------------------------
# Download the model (GGUF from Hugging Face) if it is not present yet
# ----------------------------------------------------------------------------
mkdir -p "$MODEL_DIR"

# The weights and the projector are tracked separately so that turning
# MMPROJ_ENABLED on later still fetches the projector for a model that is
# already downloaded — otherwise the "model present, skip" shortcut would leave
# vision permanently unavailable.
existing=("$MODEL_DIR"/*"${MODEL_QUANT}"*.gguf)
existing_mmproj=("$MODEL_DIR"/*[mM][mM][pP][rR][oO][jJ]*.gguf)

NEED_MODEL=0
NEED_MMPROJ=0
[ ${#existing[@]} -eq 0 ] && NEED_MODEL=1
[ "$USE_MMPROJ" = 1 ] && [ ${#existing_mmproj[@]} -eq 0 ] && NEED_MMPROJ=1

if [ "$NEED_MODEL" = 1 ] || [ "$NEED_MMPROJ" = 1 ]; then
    [ "$NEED_MODEL" = 1 ] \
        && echo ">> Model '${MODEL_REPO}' (${MODEL_QUANT}) not found in ${MODEL_DIR}, downloading..."
    [ "$NEED_MMPROJ" = 1 ] \
        && echo ">> Projector (mmproj) not found in ${MODEL_DIR}, downloading..."

    if ! command -v huggingface-cli >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends python3 python3-pip
        rm -rf /var/lib/apt/lists/*
        pip install --break-system-packages -q "huggingface_hub[hf_xet]" \
            || pip install -q "huggingface_hub[hf_xet]"
    fi

    # Projector patterns. Repos disagree on both placement and case:
    # unsloth ships 'mmproj-F16.gguf', ggml-org 'mmproj-model-f16.gguf' and
    # bartowski 'mmproj-<model>-f16.gguf'. hf's --include is case-sensitive
    # fnmatch, so pass the quant in every casing that differs from the input.
    #
    # The [-_.] before the quant is what stops 'F16' from also pulling 'BF16':
    # fnmatch has no word boundaries, so a bare '*F16*' matches 'mmproj-BF16'
    # and we would keep downloading the extra projector this variable exists to
    # avoid. Every real-world name puts a separator there.
    DOWNLOAD_INCLUDES=()
    [ "$NEED_MODEL" = 1 ] && DOWNLOAD_INCLUDES+=(--include "*${MODEL_QUANT}*.gguf")

    if [ "$NEED_MMPROJ" = 1 ]; then
        if [ -n "$MMPROJ_QUANT" ]; then
            for variant in "$MMPROJ_QUANT" "${MMPROJ_QUANT,,}" "${MMPROJ_QUANT^^}"; do
                case " ${DOWNLOAD_INCLUDES[*]} " in
                    *"[-_.]${variant}*.gguf "*) continue ;;
                esac
                DOWNLOAD_INCLUDES+=(--include "*mmproj*[-_.]${variant}*.gguf")
            done
        else
            DOWNLOAD_INCLUDES+=(--include "*mmproj*.gguf")
        fi
    fi

    export HF_XET_HIGH_PERFORMANCE=1
    hf download "$MODEL_REPO" \
        "${DOWNLOAD_INCLUDES[@]}" \
        --local-dir "$MODEL_DIR" \
        ${HF_TOKEN:+--token "$HF_TOKEN"}
else
    echo ">> Model already present in ${MODEL_DIR}, skipping download."
fi

# ----------------------------------------------------------------------------
# Resolve the GGUF to serve for a given model directory.
# Prefers the first shard of a split model, ignores mmproj (that is the vision
# projector, not a model), and prefers MODEL_QUANT when several quants coexist.
# Echoes the chosen path, or nothing if the directory holds no usable GGUF.
# ----------------------------------------------------------------------------
resolve_model_file() {
    local dir="$1" f
    local -a candidates=()

    # Preference order: requested quant first shard, requested quant, any first
    # shard, any GGUF.
    for f in "$dir"/*"${MODEL_QUANT}"*-00001-of-*.gguf \
             "$dir"/*"${MODEL_QUANT}"*.gguf \
             "$dir"/*-00001-of-*.gguf \
             "$dir"/*.gguf; do
        # Substring, not prefix: some repos name it '<model>-mmproj-f16.gguf'.
        case "$(basename "${f,,}")" in
            *mmproj*) continue ;;
        esac
        candidates+=("$f")
    done

    [ ${#candidates[@]} -gt 0 ] && printf '%s\n' "${candidates[0]}"
    # Always succeed: an empty directory is a normal case, and under `set -e` a
    # non-zero return here would abort the whole script.
    return 0
}

# ----------------------------------------------------------------------------
# Resolve the multimodal projector for a model directory, preferring
# MMPROJ_QUANT. Falls back to any projector present, so a model downloaded
# before this variable existed (or with a different quant) keeps its vision.
# ----------------------------------------------------------------------------
resolve_mmproj() {
    local dir="$1" f base
    local -a preferred=() any=()

    # Delimited match, not a plain substring: 'F16' must not match 'mmproj-BF16'
    # (the B is part of the quant name, so bf16 is a different file). Anything
    # that is not a letter or digit counts as a boundary: '-', '_', '.'.
    local re="(^|[^a-z0-9])${MMPROJ_QUANT,,}([^a-z0-9]|$)"

    for f in "$dir"/*[mM][mM][pP][rR][oO][jJ]*.gguf; do
        any+=("$f")
        base="$(basename "${f,,}")"
        if [ -n "$MMPROJ_QUANT" ] && [[ "$base" =~ $re ]]; then
            preferred+=("$f")
        fi
    done

    if [ ${#preferred[@]} -gt 0 ]; then
        printf '%s\n' "${preferred[0]}"
    elif [ ${#any[@]} -gt 0 ]; then
        if [ -n "$MMPROJ_QUANT" ]; then
            echo ">> NOTE: no mmproj matching '${MMPROJ_QUANT}' in ${dir}, using $(basename "${any[0]}")" >&2
        fi
        printf '%s\n' "${any[0]}"
    fi
    return 0
}

# ----------------------------------------------------------------------------
# Discover every downloaded model. Each subdirectory of /models is one model,
# named after the directory — so MODEL_ID/MODEL_REPO only decide what gets
# *downloaded*, while anything already sitting in /models is served too.
# ----------------------------------------------------------------------------
declare -a MODEL_IDS=() MODEL_FILES=() MODEL_MMPROJS=()

for dir in "$MODELS_DIR"/*/; do
    dir="${dir%/}"
    id="$(basename "$dir")"
    file="$(resolve_model_file "$dir")"
    if [ -z "$file" ]; then
        echo ">> Skipping '${id}': no GGUF found in ${dir}"
        continue
    fi

    # Only look for a projector when it is going to be used; a stale one left in
    # the directory must not silently re-enable vision (and kill cache reuse).
    mmproj_file=""
    [ "$USE_MMPROJ" = 1 ] && mmproj_file="$(resolve_mmproj "$dir")"

    MODEL_IDS+=("$id")
    MODEL_FILES+=("$file")
    MODEL_MMPROJS+=("$mmproj_file")

    echo ">> Found model '${id}': ${file}${mmproj_file:+ (+mmproj ${mmproj_file})}"
done

if [ ${#MODEL_IDS[@]} -eq 0 ]; then
    echo "ERROR: no usable GGUF found under ${MODELS_DIR}" >&2
    exit 1
fi
echo ">> Serving ${#MODEL_IDS[@]} model(s)."
if [ "$USE_MMPROJ" = 1 ]; then
    echo ">> Multimodal input enabled — note that --cache-reuse is inert while an mmproj is loaded."
else
    echo ">> Multimodal input disabled (MMPROJ_ENABLED=false); prompt cache reuse stays effective."
fi

# ----------------------------------------------------------------------------
# Optional llama-server flags, shared by every model.
# Each one is omitted entirely when left at its default, so the generated
# command line stays identical to the previous version out of the box.
# NOTE: llama-swap splits cmd on whitespace, so no value here may contain spaces.
# ----------------------------------------------------------------------------
TUNING=()

case "${CPU_MOE,,}" in
    1|true|yes|on)
        # All MoE expert weights on the CPU; attention stays on the GPU.
        TUNING+=("-cmoe")
        if [ -n "$N_CPU_MOE" ]; then
            echo ">> WARNING: CPU_MOE=true overrides N_CPU_MOE=${N_CPU_MOE}" >&2
        fi
        ;;
    *)
        if [ -n "$N_CPU_MOE" ]; then
            # Same idea, but only for the first N layers.
            TUNING+=("-ncmoe" "$N_CPU_MOE")
        fi
        ;;
esac

if [ -n "$OVERRIDE_TENSOR" ]; then
    TUNING+=("-ot" "$OVERRIDE_TENSOR")
fi

case "${KV_OFFLOAD,,}" in
    0|false|no|off) TUNING+=("-nkvo") ;;
esac

# 'auto' is llama-server's own default, so emit nothing for it.
case "${REASONING_ENABLED,,}" in
    1|true|yes|on)  TUNING+=("--reasoning" "on") ;;
    0|false|no|off) TUNING+=("--reasoning" "off") ;;
esac

if [ -n "$EXTRA_LLAMA_ARGS" ]; then
    # shellcheck disable=SC2206  # intentional word-splitting on spaces
    TUNING+=($EXTRA_LLAMA_ARGS)
fi

TUNING_LINE=""
[ ${#TUNING[@]} -gt 0 ] && TUNING_LINE="      ${TUNING[*]}"
echo ">> Extra llama-server flags:${TUNING_LINE:- (none)}"

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

    echo "models:"
    for i in "${!MODEL_IDS[@]}"; do
        MMPROJ_LINE=""
        [ -n "${MODEL_MMPROJS[$i]}" ] && MMPROJ_LINE="      --mmproj ${MODEL_MMPROJS[$i]}"
        cat <<YAML
  "swap/${MODEL_IDS[$i]}":
    name: "${MODEL_IDS[$i]}"
    cmd: |
      /app/llama-server
      --host 0.0.0.0 --port \${PORT}
      -m ${MODEL_FILES[$i]}
${MMPROJ_LINE}
      --jinja -ngl ${N_GPU_LAYERS} -fa on
      -ctk ${KV_CACHE_TYPE} -ctv ${KV_CACHE_TYPE}
      --ctx-size ${CTX_SIZE} --n-predict ${N_PREDICT}
      --temp ${TEMP} --top-p ${TOP_P} --top-k ${TOP_K}
      --cache-reuse 256 --parallel 1
${TUNING_LINE}
    ttl: ${MODEL_TTL}
YAML
    done

    # One exclusive group: a single GPU can only host one of these at a time,
    # so llama-swap unloads the current model before starting another.
    echo ""
    echo "groups:"
    echo "  principal:"
    echo "    swap: true"
    echo "    exclusive: true"
    echo "    members:"
    for id in "${MODEL_IDS[@]}"; do
        echo "      - \"swap/${id}\""
    done
} > "$CONFIG_FILE"

echo ">> Generated ${CONFIG_FILE}:"
cat "$CONFIG_FILE"

# ----------------------------------------------------------------------------
# Start llama-swap
# ----------------------------------------------------------------------------
exec llama-swap --config "$CONFIG_FILE" --listen ":${PORT}"
