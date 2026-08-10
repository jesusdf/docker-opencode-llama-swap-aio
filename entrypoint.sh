#!/bin/bash
set -euo pipefail

: "${PUID:=1000}"
: "${PGID:=1000}"
: "${MODEL_ID:=model}"
: "${CTX_SIZE:=262144}"
: "${N_PREDICT:=8192}"
: "${REASONING_EFFORT:=high}"
: "${REASONING_ENABLED:=auto}"
# Must match the default in init-llama-swap.sh: the two sides of the reasoning
# config have to agree.
: "${PRESERVE_REASONING:=true}"
: "${MMPROJ_ENABLED:=false}"
: "${REGENERATE_OPENCODE_CONFIG:=false}"
: "${LLAMA_API_KEY:=}"
: "${LLAMA_SWAP_URL:=http://llama-swap:8080}"
: "${SSH_PUBLIC_KEY:=}"
: "${APT_PACKAGES:=}"
: "${INIT_SCRIPT:=/opt/init/init.sh}"
: "${BLOCK_LOCAL_NETWORK:=false}"

# --- Align the 'user' account with the requested uid/gid ---
CUR_UID="$(id -u user)"
CUR_GID="$(id -g user)"
[ "$PGID" != "$CUR_GID" ] && groupmod -o -g "$PGID" user
[ "$PUID" != "$CUR_UID" ] && usermod  -o -u "$PUID" user

# --- Home directory ---
# Always resolve the home from the passwd entry, never from the environment:
# USER_HOME_PATH in .env is the *host* path used as the bind-mount source, and
# compose also injects it into the container via env_file. Trusting it here made
# the entrypoint write .ssh/authorized_keys and opencode.json to a host path that
# does not exist inside the container, while sshd kept reading /home/user.
USER_HOME_PATH="$(getent passwd user | cut -d: -f6)"
export USER_HOME_PATH
echo "Using home directory $USER_HOME_PATH"
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
    # Both components, so ~/.config does not end up owned by root and unusable
    # for anything else the user wants to put there.
    install -d -o "$PUID" -g "$PGID" "$USER_HOME_PATH/.config" "$OPENCODE_CFG_DIR"

    # llama-swap serves every model found under /models, not just MODEL_ID, so
    # ask it what it actually has instead of assuming. Falls back to MODEL_ID
    # alone if the query fails (llama-swap down, wrong key, no python3).
    AUTH=()
    [ -n "$LLAMA_API_KEY" ] && AUTH=(-H "Authorization: Bearer ${LLAMA_API_KEY}")
    MODEL_LIST=""
    if MODELS_JSON="$(curl -fsS --max-time 10 "${AUTH[@]}" "${LLAMA_SWAP_URL}/v1/models" 2>/dev/null)"; then
        MODEL_LIST="$(printf '%s' "$MODELS_JSON" | python3 -c \
            'import json,sys; print("\n".join(m["id"] for m in json.load(sys.stdin).get("data",[]) if m.get("id")))' \
            2>/dev/null || true)"
    fi
    if [ -n "$MODEL_LIST" ]; then
        # grep -c, not wc -l: the last id has no trailing newline.
        echo "Discovered $(printf '%s' "$MODEL_LIST" | grep -c .) model(s) from llama-swap."
    else
        echo "WARNING: could not list models from llama-swap — using MODEL_ID only." >&2
        MODEL_LIST="swap/${MODEL_ID}"
    fi

    case "${REASONING_ENABLED,,}" in
        1|true|yes|on)  REASONING_MODE=true ;;
        0|false|no|off) REASONING_MODE=false ;;
        *)              REASONING_MODE=auto ;;
    esac

    # Must mirror MMPROJ_ENABLED on the llama-swap side: llama-server only loads
    # a projector when that variable is set, so advertising attachments here
    # while it is off would just produce requests that fail.
    case "${MMPROJ_ENABLED,,}" in
        1|true|yes|on) MMPROJ_MODE=true ;;
        *)             MMPROJ_MODE=false ;;
    esac

    # Every value the generator reads has to be exported: the defaults above are
    # plain shell variables, not part of the environment.
    # Preserved reasoning is requested on both sides on purpose — see the note
    # in the generator below for why the server flag alone is not enough.
    case "${PRESERVE_REASONING,,}" in
        1|true|yes|on)  PRESERVE_MODE=true ;;
        0|false|no|off) PRESERVE_MODE=false ;;
        *)              PRESERVE_MODE=auto ;;
    esac

    MODEL_LIST="$MODEL_LIST" DEFAULT_MODEL="swap/${MODEL_ID}" \
    CTX_SIZE="$CTX_SIZE" N_PREDICT="$N_PREDICT" REASONING_EFFORT="$REASONING_EFFORT" \
    REASONING_MODE="$REASONING_MODE" MMPROJ_MODE="$MMPROJ_MODE" \
    PRESERVE_MODE="$PRESERVE_MODE" \
    LLAMA_SWAP_URL="$LLAMA_SWAP_URL" LLAMA_API_KEY="$LLAMA_API_KEY" \
    python3 > "$OPENCODE_CFG" <<'PY'
import json, os

ids = [m for m in os.environ["MODEL_LIST"].splitlines() if m.strip()]
default = os.environ["DEFAULT_MODEL"]
# Keep MODEL_ID as the default when it is actually being served, otherwise fall
# back to whatever llama-swap listed first.
if default not in ids:
    default = ids[0]

# Reasoning controls.
#
# `reasoningEffort` alone is a no-op against llama.cpp: the provider turns it
# into a top-level `reasoning_effort` field, which llama-server accepts and then
# silently drops — it never reaches the chat template. What the template does
# see is `chat_template_kwargs`, and unknown keys in this options dict are
# forwarded verbatim as top-level request fields, so that is how we pass it.
#
# `enable_thinking` is the boolean most thinking models use (Qwen3, DeepSeek-R1,
# GLM…); `reasoning_effort` is what the gpt-oss family reads. Sending both costs
# nothing — a template simply ignores the variable it does not use.
effort = os.environ["REASONING_EFFORT"]
mode = os.environ["REASONING_MODE"]

if mode == "false":
    # Off: don't advertise an effort level we are also disabling.
    model_options = {"chat_template_kwargs": {"enable_thinking": False}}
else:
    kwargs = {"reasoning_effort": effort}
    if mode == "true":
        kwargs["enable_thinking"] = True

    # Preserved reasoning, belt and braces.
    #
    # llama-server has `--reasoning-preserve`, which init-llama-swap.sh passes,
    # but it only applies to templates llama.cpp recognises as having the
    # `supports_preserve_reasoning` capability — a detection keyed to a specific
    # variable name. Qwen3.6's template gates the same behaviour on its own
    # `preserve_thinking`, so sending the kwarg too covers the case where the
    # server-side detection does not fire. Whichever route applies, the effect
    # is identical, and a template that reads neither ignores both.
    #
    # Only meaningful if the client actually sends prior reasoning back in the
    # history; when it does not, this is inert rather than harmful.
    preserve = os.environ["PRESERVE_MODE"]
    if preserve != "auto":
        kwargs["preserve_thinking"] = preserve == "true"

    # `reasoningEffort` is kept as well: harmless here, and correct if this
    # config is ever pointed at a provider that does honour it.
    #
    # `extraBody` is a third route to the same setting: the provider merges it
    # into the request body verbatim, and `think` is the field some llama.cpp
    # builds and proxies read instead of `chat_template_kwargs`. Same effort
    # level as everything else, so whichever one the server honours agrees.
    model_options = {
        "reasoningEffort": effort,
        "chat_template_kwargs": kwargs,
        "extraBody": {"think": effort},
    }

# Attachment support follows MMPROJ_ENABLED, and applies to every model.
#
# opencode treats a custom-provider model as text-only unless it declares these
# fields, and this container cannot tell which models are multimodal anyway: it
# never sees /models, only the list of ids from llama-swap. So the switch is
# all-or-nothing, and it tracks the one thing we do know — whether llama-server
# was told to load a projector at all. With it off, an attachment could only
# ever fail, so the option is not offered; with it on it is offered for every
# model, and a model that has no projector fails at llama-server, which is a
# clearer outcome than the attachment button never appearing.
#
# `image` and `audio` are the two llama.cpp actually handles (both through the
# same mmproj); video and pdf are deliberately left out.
multimodal = os.environ["MMPROJ_MODE"] == "true"
capabilities = {
    "attachment": multimodal,
    "modalities": {
        "input": ["text", "image", "audio"] if multimodal else ["text"],
        "output": ["text"],
    },
    # The documented capability field is `tool_call`; `tools` is not part of the
    # model schema and was being ignored.
    "tool_call": True,
}

models = {
    mid: {
        "name": mid.split("/", 1)[-1],
        "limit": {
            "context": int(os.environ["CTX_SIZE"]),
            "output": int(os.environ["N_PREDICT"]),
        },
        **capabilities,
        "options": model_options,
    }
    for mid in ids
}

print(json.dumps({
    "$schema": "https://opencode.ai/config.json",
    "provider": {
        "llamaswap": {
            "npm": "@ai-sdk/openai-compatible",
            "name": "llama-swap",
            "options": {
                "baseURL": os.environ["LLAMA_SWAP_URL"] + "/v1",
                "apiKey": os.environ["LLAMA_API_KEY"],
            },
            "models": models,
        }
    },
    "model": "llamaswap/" + default,
    "small_model": "llamaswap/" + default,
    "autoshare": False,
}, indent=2))
PY
    chown "$PUID:$PGID" "$OPENCODE_CFG"
else
    # Kept config: check it still points at a model llama-swap actually serves.
    # This is the failure people hit after changing MODEL_ID (or after pulling a
    # release that changed the default), because opencode.json is written once
    # and then left alone — so it silently keeps naming a model that is gone,
    # and every request 404s with nothing obvious in the logs.
    AUTH=()
    [ -n "$LLAMA_API_KEY" ] && AUTH=(-H "Authorization: Bearer ${LLAMA_API_KEY}")
    if MODELS_JSON="$(curl -fsS --max-time 10 "${AUTH[@]}" "${LLAMA_SWAP_URL}/v1/models" 2>/dev/null)"; then
        CFG_MODEL="$(python3 -c \
            'import json,sys; print(json.load(open(sys.argv[1])).get("model",""))' \
            "$OPENCODE_CFG" 2>/dev/null || true)"
        SERVED="$(printf '%s' "$MODELS_JSON" | python3 -c \
            'import json,sys; print("\n".join("llamaswap/"+m["id"] for m in json.load(sys.stdin).get("data",[]) if m.get("id")))' \
            2>/dev/null || true)"
        if [ -n "$CFG_MODEL" ] && [ -n "$SERVED" ] \
           && ! printf '%s\n' "$SERVED" | grep -qxF "$CFG_MODEL"; then
            echo "WARNING: $OPENCODE_CFG selects '$CFG_MODEL', which llama-swap is not serving." >&2
            echo "         Served right now:" >&2
            printf '           %s\n' $SERVED >&2
            echo "         The config is only written once, so a changed MODEL_ID leaves it stale." >&2
            echo "         Fix it by editing the file, or set REGENERATE_OPENCODE_CONFIG=true to" >&2
            echo "         rewrite it from .env (this discards any manual edits, MCP servers" >&2
            echo "         included)." >&2
        fi
    fi
fi

# --- Egress firewall (optional) ---
# Keeps the agent from reaching the rest of the LAN while leaving the internet
# open. Applied BEFORE the init hook on purpose, so the operator's script can
# append its own exceptions (or flush the chain entirely).
# Requires NET_ADMIN on the container; without it iptables cannot write rules.
case "${BLOCK_LOCAL_NETWORK,,}" in
    1|true|yes|on) BLOCK_LAN=1 ;;
    *)             BLOCK_LAN=0 ;;
esac
if [ "$BLOCK_LAN" = 1 ]; then
    # RFC1918 plus link-local, which carries the cloud metadata endpoint
    # (169.254.169.254) — a well-known way to reach credentials.
    PRIVATE_NETS="10.0.0.0/8 172.16.0.0/12 192.168.0.0/16 169.254.0.0/16"

    if ! command -v iptables >/dev/null 2>&1; then
        echo "ERROR: BLOCK_LOCAL_NETWORK is set but iptables is missing — LAN is NOT blocked." >&2
    elif ! iptables -L OUTPUT -n >/dev/null 2>&1; then
        echo "ERROR: BLOCK_LOCAL_NETWORK is set but iptables cannot run — LAN is NOT blocked." >&2
        echo "       Add NET_ADMIN to the container (cap_add: [NET_ADMIN] in compose)." >&2
    else
        echo "Blocking local network egress (BLOCK_LOCAL_NETWORK is set) ..."

        # Loopback and replies to already-accepted connections (this is what
        # keeps inbound SSH working, since its reply packets traverse OUTPUT).
        iptables -A OUTPUT -o lo -j ACCEPT
        iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

        # llama-swap sits on the compose bridge, inside 172.16.0.0/12, so it has
        # to be allowed explicitly before the private-range rejects below.
        SWAP_HOSTPORT="${LLAMA_SWAP_URL#*://}"; SWAP_HOSTPORT="${SWAP_HOSTPORT%%/*}"
        SWAP_HOST="${SWAP_HOSTPORT%%:*}"
        SWAP_PORT="${SWAP_HOSTPORT##*:}"
        [ "$SWAP_PORT" = "$SWAP_HOST" ] && SWAP_PORT=80
        SWAP_IPS="$(getent ahostsv4 "$SWAP_HOST" 2>/dev/null | awk '{print $1}' | sort -u)"
        if [ -n "$SWAP_IPS" ]; then
            for ip in $SWAP_IPS; do
                echo "  allowing llama-swap at ${ip}:${SWAP_PORT}"
                iptables -A OUTPUT -d "$ip" -p tcp --dport "$SWAP_PORT" -j ACCEPT
            done
        else
            echo "WARNING: could not resolve '$SWAP_HOST' — allowing the whole bridge subnet instead." >&2
            # Fall back to the container's own /16 so the stack still works.
            BRIDGE_NET="$(ip -4 -o addr show scope global | awk '{print $4}' | head -1)"
            [ -n "$BRIDGE_NET" ] && iptables -A OUTPUT -d "$BRIDGE_NET" -j ACCEPT
        fi

        for net in $PRIVATE_NETS; do
            iptables -A OUTPUT -d "$net" -j REJECT --reject-with icmp-admin-prohibited
        done

        # Same treatment for IPv6 (unique-local + link-local). Best effort: many
        # setups run IPv6-less containers where ip6tables has nothing to do.
        if command -v ip6tables >/dev/null 2>&1 && ip6tables -L OUTPUT -n >/dev/null 2>&1; then
            ip6tables -A OUTPUT -o lo -j ACCEPT
            ip6tables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
            for net in fc00::/7 fe80::/10; do
                ip6tables -A OUTPUT -d "$net" -j REJECT --reject-with adm-prohibited || true
            done
        fi

        echo "Egress rules in place; everything outside the private ranges is still reachable."
    fi
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

# --- Run SSH in the foreground as the container's main process ---
exec /usr/sbin/sshd -D -e
