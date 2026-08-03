#!/bin/bash
set -euo pipefail

: "${USER_HOME_PATH:=/home/user}"
: "${PUID:=1000}"
: "${PGID:=1000}"
: "${MODEL_ID:=model}"
: "${CTX_SIZE:=262144}"
: "${N_PREDICT:=8192}"
: "${LLAMA_API_KEY:=}"
: "${LLAMA_SWAP_URL:=http://llama-swap:8080}"
: "${SSH_PUBLIC_KEY:=}"
: "${APT_PACKAGES:=}"

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

# --- opencode config (generated once, then left for the user to edit) ---
OPENCODE_CFG_DIR="$USER_HOME_PATH/.config/opencode"
OPENCODE_CFG="$OPENCODE_CFG_DIR/opencode.json"
if [ ! -f "$OPENCODE_CFG" ]; then
    echo "Creating default opencode config at $OPENCODE_CFG ..."
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
          "tools": true
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
