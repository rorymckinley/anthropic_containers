FROM node:22

ARG TZ
ENV TZ="$TZ"

# Install basic development tools, iptables/ipset, and native build
# dependencies for the Ruby/Rust/Elixir toolchains installed later via
# RVM/asdf/mise (root fs is read_only at runtime, so these need to be
# generous up front -- there's no apt-get available once the container
# is running).
RUN apt update && apt install -y less \
  git \
  procps \
  sudo \
  fzf \
  man-db \
  unzip \
  gnupg2 \
  gh \
  git \
  curl \
  wget \
  iptables \
  ipset \
  iproute2 \
  dnsutils \
  aggregate \
  jq \
  build-essential \
  pkg-config \
  autoconf \
  m4 \
  libssl-dev \
  libreadline-dev \
  zlib1g-dev \
  libyaml-dev \
  libncurses-dev \
  libffi-dev \
  libgdbm-dev \
  libdb-dev \
  libpq-dev \
  postgresql-client \
  cmake \
  clang \
  llvm \
  unixodbc-dev \
  libxslt1-dev

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

ARG USERNAME=node

# Create a directory for persisted bash history (wired into .bashrc below).
RUN mkdir /commandhistory \
  && touch /commandhistory/.bash_history \
  && chown -R $USERNAME /commandhistory

# Create workspace and config directories and set permissions
RUN mkdir -p /workspace /home/node/.claude && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

RUN ARCH=$(dpkg --print-architecture) && \
  wget "https://github.com/dandavison/delta/releases/download/0.18.2/git-delta_0.18.2_${ARCH}.deb" && \
  sudo dpkg -i "git-delta_0.18.2_${ARCH}.deb" && \
  rm "git-delta_0.18.2_${ARCH}.deb"

# Set up non-root user
USER node

# Install global packages
ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH=$PATH:/usr/local/share/npm-global/bin

ENV SHELL=/bin/bash

# RVM (Ruby-only), asdf and mise (both multi-language) -- plumbing only.
# No language versions are installed here; each project picks its own
# manager/version (.tool-versions, .ruby-version, etc.) once running.
RUN gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys \
    409B6B1796C275462A1703113804BB82D39DC0E3 \
    7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
  curl -sSL https://get.rvm.io | bash -s stable

RUN ARCH=$(dpkg --print-architecture) && \
  ASDF_VERSION=$(curl -fsSL https://api.github.com/repos/asdf-vm/asdf/releases/latest | grep '"tag_name"' | cut -d '"' -f4) && \
  mkdir -p /home/node/.asdf/bin && \
  curl -fL "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/asdf-${ASDF_VERSION}-linux-${ARCH}.tar.gz" | \
    tar -xz -C /home/node/.asdf/bin

RUN curl https://mise.run | sh

# Wire history persistence, fzf bindings, and RVM/asdf/mise into bash --
# the only shell this image sets up (the container entrypoint is bash).
RUN cat <<'RC' >> /home/node/.bashrc
export PROMPT_COMMAND='history -a'
export HISTFILE=/commandhistory/.bash_history
source /usr/share/doc/fzf/examples/key-bindings.bash
source /usr/share/doc/fzf/examples/completion.bash
[ -s "$HOME/.rvm/scripts/rvm" ] && source "$HOME/.rvm/scripts/rvm"
export PATH="$HOME/.asdf/bin:$PATH"
export PATH="$HOME/.local/bin:$PATH"
command -v mise >/dev/null 2>&1 && eval "$(mise activate bash)"
RC

# Install Claude
RUN npm install -g @anthropic-ai/claude-code
