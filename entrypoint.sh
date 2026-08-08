#!/bin/bash
set -euo pipefail

: "${USER_HOME_PATH:=/home/user}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${MODEL_ID:=model}"
: "${CTX_SIZE:=262144}"
: "${N_PREDICT:=8192}"
: "${REASONING_EFFORT:=high}"
: "${REGENERATE_OPENCODE_CONFIG:=false}"
: "${LLAMA_API_KEY:=}"
: "${LLAMA_SWAP_URL:=http://llama-swap:8080}"
: "${SSH_PUBLIC_KEY:=}"
: "${APT_PACKAGES:=}"
: "${INIT_SCRIPT:=/opt/init/init.sh}"

# --- Align the 'user' account with the requested uid/gid ---
CUR_UID="$(id -u user)"
CUR_GID="$(id -g user)"
[ "$PGID" != "$CUR_GID" ] && groupmod -o -g "$PGID" user
[ "$PUID" != "$CUR_UID" ] && usermod  -o -u "$PUID" user

# --- Home directory ---
mkdir -p "$USER_HOME_PATH"
chown "$PUID:$PGID" "$USER_HOME_PATH"

# --- Optional extra OS packages requested via APT_PACKAGES (space-separated) ---
if [ -n "$APT_PACKAGES" ]; then
    echo "Installing extra packages: $APT_PACKAGES"
    apt-get update
    # shellcheck disable=SC2086  # intentional word-splitting on spaces
    apt-get install -y --no-install-recommends $APT_PACKAGES
    rm -rf /var/lib/apt/lists/*
fi

# --- SSH authorized_keys ---
if [ -n "$SSH_PUBLIC_KEY" ]; then
    install -d -m 700 -o "$PUID" -g "$PGID" "$USER_HOME_PATH/.ssh"
    echo "$SSH_PUBLIC_KEY" > "$USER_HOME_PATH/.ssh/authorized_keys"
    chmod 600 "$USER_HOME_PATH/.ssh/authorized_keys"
    chown "$PUID:$PGID" "$USER_HOME_PATH/.ssh/authorized_keys"
else
    echo "WARNING: SSH_PUBLIC_KEY is empty — no one will be able to log in over SSH." >&2
fi

# --- opencode config ---
# Generated once and then left for the user to edit, unless
# REGENERATE_OPENCODE_CONFIG is truthy, in which case it is rewritten on every
# start (any manual edits are lost).
OPENCODE_CFG_DIR="$USER_HOME_PATH/.config/opencode"
OPENCODE_CFG="$OPENCODE_CFG_DIR/opencode.json"
case "${REGENERATE_OPENCODE_CONFIG,,}" in
    1|true|yes|on) REGEN_CFG=1 ;;
    *)             REGEN_CFG=0 ;;
esac
if [ ! -f "$OPENCODE_CFG" ] || [ "$REGEN_CFG" = 1 ]; then
    if [ -f "$OPENCODE_CFG" ]; then
        echo "Regenerating opencode config at $OPENCODE_CFG (REGENERATE_OPENCODE_CONFIG is set) ..."
    else
        echo "Creating default opencode config at $OPENCODE_CFG ..."
    fi
    install -d -o "$PUID" -g "$PGID" "$OPENCODE_CFG_DIR"
    cat > "$OPENCODE_CFG" <<JSON
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "llamaswap": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "llama-swap",
      "options": {
        "baseURL": "${LLAMA_SWAP_URL}/v1",
        "apiKey": "${LLAMA_API_KEY}"
      },
      "models": {
        "swap/${MODEL_ID}": {
          "name": "${MODEL_ID}",
          "limit": { "context": ${CTX_SIZE}, "output": ${N_PREDICT} },
          "tools": true,
          "options": {
            "reasoningEffort": "${REASONING_EFFORT}"
          }
        }
      }
    }
  },
  "model": "llamaswap/swap/${MODEL_ID}",
  "small_model": "llamaswap/swap/${MODEL_ID}",
  "autoshare": false
}
JSON
    chown "$PUID:$PGID" "$OPENCODE_CFG"
fi

# --- Operator init hook (runs as root, before dropping into sshd) ---
# The image ships no sudo, so this is the only way to make root-level tweaks.
# It therefore MUST NOT be writable by the unprivileged account, otherwise the
# user could edit it and get arbitrary root execution on the next restart.
# Mount it read-only and owned by root, e.g.:
#   volumes:
#     - ./init:/opt/init:ro
if [ -e "$INIT_SCRIPT" ]; then
    if [ ! -f "$INIT_SCRIPT" ]; then
        echo "ERROR: INIT_SCRIPT '$INIT_SCRIPT' is not a regular file — skipping." >&2
    elif runuser -u user -- test -w "$INIT_SCRIPT" 2>/dev/null \
      || runuser -u user -- test -w "$(dirname "$INIT_SCRIPT")" 2>/dev/null; then
        # Writable by 'user' (or sitting in a directory they can write) means the
        # script could be replaced and executed as root — refuse to run it.
        echo "ERROR: refusing to run '$INIT_SCRIPT': it is writable by 'user'." >&2
        echo "       Mount it read-only (:ro) and owned by root, then restart." >&2
    else
        echo "Running init script $INIT_SCRIPT ..."
        if bash "$INIT_SCRIPT"; then
            echo "Init script finished successfully."
        else
            # Do not abort: a broken hook must not lock the operator out of SSH.
            echo "WARNING: init script exited with status $? — continuing." >&2
        fi
    fi
fi

# --- Wait for llama-swap (belt-and-suspenders; compose already gates on healthcheck) ---
echo "Waiting for llama-swap at ${LLAMA_SWAP_URL}/health ..."
for _ in $(seq 1 60); do
    if curl -fsS --max-time 5 "${LLAMA_SWAP_URL}/health" >/dev/null 2>&1; then
        echo "llama-swap is ready."
        break
    fi
    printf '.'
    sleep 5
done

# --- Run SSH in the foreground as the container's main process ---
exec /usr/sbin/sshd -D -e
