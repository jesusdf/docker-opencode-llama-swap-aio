FROM debian:13-slim

# Install runtime dependencies for opencode + SSH access.
# sudo is deliberately NOT installed, and is purged in case a base layer ships
# it: the interactive user must not be able to escalate to root. Root-level
# customisation goes through APT_PACKAGES and the INIT_SCRIPT hook instead.
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
        openssh-server \
        python3 \
        python3-pip \
    && apt-get purge -y --auto-remove sudo \
    && rm -rf /var/lib/apt/lists/* /etc/sudoers.d/*

# Install opencode
RUN npm install -g opencode-ai \
    && npm cache clean --force

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
