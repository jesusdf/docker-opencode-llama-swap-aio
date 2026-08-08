# Git revision of opencode to compile. Any tag, branch or commit SHA works.
# Pinned on purpose: a build is reproducible until this value is bumped.
# Local builds can override it from .env (see docker-compose.build.yml).
ARG OPENCODE_REF=v1.18.15
# Version string baked into the binary. Left empty it is derived from the ref:
# a "vX.Y.Z" tag becomes "X.Y.Z", anything else becomes "0.0.0-<short sha>".
ARG OPENCODE_VERSION=

# ---------------------------------------------------------------------------
# Stage 1 — compile opencode from source
# ---------------------------------------------------------------------------
# Why not `npm install -g opencode-ai`: that package ships a Bun standalone
# binary with libopentui.so embedded, and Bun has to unpack the library into a
# temporary directory on every start. When that directory is missing, or is
# mounted noexec, the TUI dies before drawing anything:
#
#   Failed to initialize OpenTUI render library: Failed to open library
#   "/<tmp>/.<hash>-00000001.so": cannot open shared object file
#
# Compiling here lets us keep the native library as an ordinary file in the
# image and point OpenTUI at it with OTUI_ASSET_ROOT, so nothing is unpacked at
# runtime and the failure mode disappears. Everything heavy stays in this
# stage: the final image only receives the binary and ~32 MB of assets.
FROM debian:13-slim AS opencode-build

ARG OPENCODE_REF
ARG OPENCODE_VERSION

# build-essential + python3 are for node-gyp: a couple of tree-sitter grammars
# in the dependency tree compile native addons during install.
RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        git \
        python3 \
        unzip \
    && rm -rf /var/lib/apt/lists/*

# `git fetch <ref>` takes a tag, a branch or a bare commit SHA; `git clone
# --branch` would reject the last one.
WORKDIR /opt/opencode
RUN git init -q . \
    && git remote add origin https://github.com/anomalyco/opencode.git \
    && git fetch -q --depth 1 origin "${OPENCODE_REF}" \
    && git checkout -q FETCH_HEAD

# Bun comes from the checked-out tree's `packageManager` field, never from
# whatever is current: opencode's build script hard-fails on a mismatch.
ENV BUN_INSTALL=/usr/local
RUN bun_version="$(grep -oP '"packageManager"\s*:\s*"bun@\K[^"]+' package.json)" \
    && echo "Building with bun ${bun_version} (pinned by the opencode tree)" \
    && curl -fsSL https://bun.sh/install | bash -s "bun-v${bun_version}"

RUN bun install --frozen-lockfile

# --single builds only the host platform. --skip-install stops the build script
# from re-resolving @opentui/core for every platform, which the workspace
# catalog cannot express anyway.
RUN set -eux; \
    version="${OPENCODE_VERSION}"; \
    if [ -z "$version" ]; then \
        case "$OPENCODE_REF" in \
            v[0-9]*) version="${OPENCODE_REF#v}" ;; \
            *)       version="0.0.0-$(git rev-parse --short HEAD)" ;; \
        esac; \
    fi; \
    echo "Compiling opencode ${version} from ${OPENCODE_REF}"; \
    OPENCODE_CHANNEL=latest OPENCODE_VERSION="$version" \
        bun run --cwd packages/opencode script/build.ts --single --skip-install; \
    arch="$(uname -m | sed 's/x86_64/x64/; s/aarch64/arm64/')"; \
    cp "packages/opencode/dist/opencode-linux-${arch}/bin/opencode" /opt/opencode-bin

# Relocatable OpenTUI asset root. OTUI_ASSET_ROOT is resolved as
# <root>/<package>/<file>, and OpenTUI throws if any asset it asks for is
# missing, so whole packages are copied rather than hand-picked files.
# Paths are asked of bun so they follow wherever the install put the packages.
RUN set -eux; \
    core="$(bun --cwd packages/opencode \
        -e 'console.log(require.resolve("@opentui/core/package.json"))' | xargs dirname)"; \
    lib="$(cd "$core" && bun \
        -e 'console.log((await import("@opentui/core-linux-x64")).default)')"; \
    wts="$(bun --cwd packages/opencode \
        -e 'console.log(require.resolve("web-tree-sitter/package.json"))' | xargs dirname)"; \
    mkdir -p /opt/otui-assets/@opentui/core-linux-x64; \
    cp -rL "$core" /opt/otui-assets/@opentui/core; \
    cp -L "$lib" /opt/otui-assets/@opentui/core-linux-x64/libopentui.so; \
    cp -rL "$wts" /opt/otui-assets/web-tree-sitter; \
    test -f /opt/otui-assets/@opentui/core/parser.worker.js; \
    test -f /opt/otui-assets/web-tree-sitter/tree-sitter.wasm

# ---------------------------------------------------------------------------
# Stage 2 — the runtime image
# ---------------------------------------------------------------------------
FROM debian:13-slim

# Install runtime dependencies for opencode + SSH access.
# sudo is deliberately NOT installed, and is purged in case a base layer ships
# it: the interactive user must not be able to escalate to root. Root-level
# customisation goes through APT_PACKAGES and the INIT_SCRIPT hook instead.
#
# nodejs stays even though opencode no longer comes from npm: opencode installs
# its language servers itself (bundled @npmcli/arborist, no npm CLI involved)
# but then executes them straight from node_modules/.bin, and those are
# `#!/usr/bin/env node` scripts. Without node, every JS/TS language server dies.
# The npm CLI itself is *not* installed: it costs ~220 MB, more than twice what
# nodejs does, and the only thing in opencode that shells out to it is the
# ESLint language server. Add it back per-deployment with APT_PACKAGES="npm".
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        iproute2 \
        iptables \
        nodejs \
        openssh-server \
        python3 \
        python3-pip \
    && apt-get purge -y --auto-remove sudo \
    && rm -rf /var/lib/apt/lists/* /etc/sudoers.d/*

# opencode, compiled in the first stage, plus the OpenTUI native library and
# parser assets it loads through OTUI_ASSET_ROOT instead of unpacking to /tmp.
COPY --from=opencode-build /opt/opencode-bin /usr/local/bin/opencode
COPY --from=opencode-build /opt/otui-assets /opt/otui-assets
ENV OTUI_ASSET_ROOT=/opt/otui-assets
RUN opencode --version

# Install the Hugging Face download CLI (huggingface-cli / hf) + Xet fast transfer
RUN pip install --no-cache-dir --break-system-packages \
        "huggingface_hub[cli,hf_xet]"
ENV HF_XET_HIGH_PERFORMANCE=1

# Harden SSH: key-only auth, no root login
RUN mkdir -p /var/run/sshd \
    && sed -i \
        -e 's/#\?PermitRootLogin.*/PermitRootLogin no/' \
        -e 's/#\?PasswordAuthentication.*/PasswordAuthentication no/' \
        -e 's/#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' \
        /etc/ssh/sshd_config

# Create the interactive user (uid/gid overridable at runtime via the entrypoint).
# No sudoers entry: the account is unprivileged and has no path to root.
RUN useradd -m -u 1000 -s /bin/bash user

# Mount point for the operator's root-run init script (see INIT_SCRIPT).
# Owned by root and not writable by 'user', so the hook cannot be hijacked.
RUN install -d -m 755 -o root -g root /opt/init

ENV USER_HOME_PATH=/home/user
WORKDIR /home/user

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SSH
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
