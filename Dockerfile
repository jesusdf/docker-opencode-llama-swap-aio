FROM debian:13-slim

# Install runtime dependencies for opencode + SSH access
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        nodejs \
        npm \
        openssh-server \
        python3 \
        python3-pip \
        sudo \
    && rm -rf /var/lib/apt/lists/*

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

# Create the interactive user (uid/gid overridable at runtime via the entrypoint)
RUN useradd -m -u 1000 -s /bin/bash user \
    && echo "user ALL=(ALL:ALL) NOPASSWD:ALL" > /etc/sudoers.d/user

ENV USER_HOME_PATH=/home/user
WORKDIR /home/user

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# SSH
EXPOSE 22

ENTRYPOINT ["/entrypoint.sh"]
