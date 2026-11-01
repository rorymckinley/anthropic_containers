# Claude Code sandbox image: base tooling + a per-project toolchain baked in.
#
# Layering, slowest-changing first so the cache holds:
#   1. base packages, git-delta, asdf binary, RVM          (shared by every project)
#   2. toolchain versions from build args                   (per project; Erlang is the slow one)
#   3. Claude Code                                          (floats to latest unless pinned)
#
# The toolchain is *in the image*, on purpose: the root fs is read_only at
# runtime, so a session can't alter a ruby, a shim or an OTP install, and
# the sandbox needs no egress to ruby-lang.org/nodejs.org/github.com at
# runtime -- only to the package registries (see proxy/squid.conf).
# Changing a version = rebuild + recreate, same as everything else here.
#
# Nothing the runtime depends on is placed under /home/node. That path is
# a persistent named volume, and Docker copies image content into a volume
# only when the volume is *empty* on first attach -- a home volume that
# already exists keeps its old contents and silently hides whatever the new
# image put there. Toolchains live in /opt, shell wiring in /etc.

# Pin by tag; for full reproducibility pin by digest instead:
#   docker pull node:22-bookworm && docker inspect --format '{{index .RepoDigests 0}}' node:22-bookworm
FROM node:22-bookworm

ARG TZ=UTC
ENV TZ="$TZ"

# Native build deps for Ruby (RVM compiles from source), Erlang (kerl
# compiles from source), Postgres client libs, and general tooling. Root fs
# is read_only at runtime, so there is no apt-get later: anything missing
# is fixed here and rebuilt, never live-patched.
RUN apt-get update && apt-get install -y \
  less \
  git \
  procps \
  fzf \
  man-db \
  unzip \
  xz-utils \
  gnupg2 \
  curl \
  wget \
  ca-certificates \
  iproute2 \
  dnsutils \
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
  libxslt1-dev \
  && rm -rf /var/lib/apt/lists/*

# Ensure default node user has access to /usr/local/share
RUN mkdir -p /usr/local/share/npm-global && \
  chown -R node:node /usr/local/share

# Toolchain prefixes, outside /home/node (see header). Owned by node so the
# unprivileged build steps below can populate them; read_only at runtime
# makes ownership irrelevant for tamper-resistance.
ENV rvm_path=/opt/rvm \
    ASDF_DATA_DIR=/opt/asdf \
    MIX_HOME=/opt/mix
RUN mkdir -p /opt/rvm /opt/asdf /opt/mix /etc/claude-sandbox /workspace /home/node/.claude && \
  chown node:node /opt/rvm /opt/asdf /opt/mix /etc/claude-sandbox && \
  chown -R node:node /workspace /home/node/.claude

WORKDIR /workspace

# git-delta. GIT_DELTA_SHA256 is optional; when set, the download must match.
ARG GIT_DELTA_VERSION=0.18.2
ARG GIT_DELTA_SHA256=""
RUN ARCH=$(dpkg --print-architecture) && \
  DEB="git-delta_${GIT_DELTA_VERSION}_${ARCH}.deb" && \
  wget -q "https://github.com/dandavison/delta/releases/download/${GIT_DELTA_VERSION}/${DEB}" && \
  if [ -n "$GIT_DELTA_SHA256" ]; then echo "${GIT_DELTA_SHA256}  ${DEB}" | sha256sum -c -; fi && \
  dpkg -i "$DEB" && rm "$DEB"

# asdf (0.16+ is a single Go binary; no plugin-manager repo to clone).
# Lives in /usr/local/bin, root-owned. ASDF_SHA256 is optional, as above.
ARG ASDF_VERSION=v0.18.0
ARG ASDF_SHA256=""
RUN ARCH=$(dpkg --print-architecture) && \
  TGZ="asdf-${ASDF_VERSION}-linux-${ARCH}.tar.gz" && \
  curl -fsSLo "/tmp/${TGZ}" "https://github.com/asdf-vm/asdf/releases/download/${ASDF_VERSION}/${TGZ}" && \
  if [ -n "$ASDF_SHA256" ]; then echo "${ASDF_SHA256}  /tmp/${TGZ}" | sha256sum -c -; fi && \
  tar -xzf "/tmp/${TGZ}" -C /usr/local/bin asdf && rm "/tmp/${TGZ}"

# Shell wiring. /etc/bash.bashrc is read by every interactive bash
# (the compose entrypoint), /etc/profile.d by login shells
# (`docker exec -it <c> bash -l`). Both just source the toolchain file
# that the build steps below append to. In the image, not in ~/.bashrc:
# ~/.bashrc is on the home volume (see header) and writable by a session.
RUN cat <<'RC' >> /etc/bash.bashrc

# ---- claude sandbox ----------------------------------------------------
export HISTFILE="$HOME/.bash_history"
export PROMPT_COMMAND='history -a'
# TMPDIR is pointed at the home volume by the compose file because /tmp is
# noexec; make sure it exists before anything tries to use it.
[ -n "${TMPDIR:-}" ] && mkdir -p "$TMPDIR" 2>/dev/null
[ -r /usr/share/doc/fzf/examples/key-bindings.bash ] && source /usr/share/doc/fzf/examples/key-bindings.bash
[ -r /usr/share/doc/fzf/examples/completion.bash ] && source /usr/share/doc/fzf/examples/completion.bash
[ -r /etc/claude-sandbox/toolchain.sh ] && source /etc/claude-sandbox/toolchain.sh
RC
RUN printf '[ -r /etc/claude-sandbox/toolchain.sh ] && . /etc/claude-sandbox/toolchain.sh\n' \
  > /etc/profile.d/claude-sandbox.sh

# Set up non-root user. Everything from here runs as node.
USER node
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
# Static PATH: RVM's default-ruby wrappers and the npm global bin. asdf's
# shims are added by toolchain.sh (interactive shells), *not* here: a shim
# with no resolvable version fails, and `docker exec` doesn't read bashrc,
# so the base image's node must stay first for that path (it's what runs
# `claude` there).
ENV PATH=/opt/rvm/wrappers/default:/usr/local/share/npm-global/bin:$PATH
ENV SHELL=/bin/bash

# toolchain.sh is built up by the steps below; start it here.
RUN cat <<'TC' > /etc/claude-sandbox/toolchain.sh
# Generated at image build. Sourced by /etc/bash.bashrc and /etc/profile.d.
export PATH="/opt/asdf/shims:$PATH"
# The wrappers on the image's PATH are for non-interactive `docker exec`. RVM                          
# must not see them when it loads, or it warns and skips the default env.
PATH=$(printf '%s' "$PATH" | sed 's#/opt/rvm/wrappers/default:##g')
[ -s /opt/rvm/scripts/rvm ] && source /opt/rvm/scripts/rvm
TC

# ---- RVM (Ruby only) -----------------------------------------------------
# Installer fetched from the pinned release tag and GPG-verified against
# the two RVM signing keys before it runs -- not piped from get.rvm.io.
# --ignore-dotfiles: it would otherwise edit ~/.bashrc & co, which are on
# the home volume and ignored anyway.
# autolibs disable: RVM would otherwise try `sudo apt-get` for build deps;
# there is no sudo here and the deps are already in the apt layer above.
ARG RVM_VERSION=1.29.12
RUN gpg --keyserver hkp://keyserver.ubuntu.com --recv-keys \
    409B6B1796C275462A1703113804BB82D39DC0E3 \
    7D2BAF1CF37B13E2069D6956105BD0E739499BDB && \
  curl -fsSLo /tmp/rvm-installer     "https://raw.githubusercontent.com/rvm/rvm/${RVM_VERSION}/binscripts/rvm-installer" && \
  curl -fsSLo /tmp/rvm-installer.asc "https://raw.githubusercontent.com/rvm/rvm/${RVM_VERSION}/binscripts/rvm-installer.asc" && \
  gpg --verify /tmp/rvm-installer.asc /tmp/rvm-installer && \
  bash /tmp/rvm-installer --version "${RVM_VERSION}" --path /opt/rvm --ignore-dotfiles && \
  rm -f /tmp/rvm-installer /tmp/rvm-installer.asc && \
  source /opt/rvm/scripts/rvm && rvm autolibs disable
# Gemsets can't be created at runtime because /opt/rvm is read_only. They also
# add nothing here: gems go to BUNDLE_PATH on the per-project home volume.
# RVM reloads this file, so the flag survives its internal variable resets.
USER root
RUN echo 'rvm_ignore_gemsets_flag=1' > /etc/rvmrc
USER node

# ---- Per-project toolchain (build args from the project's .env.claude) ---
# Every ARG below defaults to empty = "don't install". Each step is a
# no-op layer when its version is empty, so projects only pay for the
# languages they use. Plugin refs default to the branch head; pin them to
# commit SHAs in .env.claude for a reproducible build.

# Ruby via RVM. Space-separated list; the first becomes `default`
# (/opt/rvm/wrappers/default is on PATH). Compiled from
# cache.ruby-lang.org; RVM checks the tarball against its built-in digests.
# Gems are *not* installable into /opt/rvm at runtime (read_only); the
# compose file sets BUNDLE_PATH onto the home volume for `bundle install`.
ARG RUBY_VERSIONS=""
RUN if [ -n "$RUBY_VERSIONS" ]; then \
      source /opt/rvm/scripts/rvm && \
      for v in $RUBY_VERSIONS; do rvm install "$v" --disable-binary; done && \
      rvm alias create default "${RUBY_VERSIONS%% *}" && \
      rvm cleanup all; \
    fi

# Erlang via asdf-erlang (kerl, compiled from source -- the slow layer:
# 10-20 min). Headless build: no wx/observer/debugger/javac. No docs.
ARG ASDF_ERLANG_PLUGIN_REF=master
ARG ERLANG_VERSION=""
ENV KERL_BUILD_DOCS=no \
    KERL_CONFIGURE_OPTIONS="--without-javac --without-wx --without-debugger --without-observer --without-et --without-megaco"
RUN if [ -n "$ERLANG_VERSION" ]; then \
      export MAKEFLAGS="-j$(nproc)" && \
      asdf plugin add erlang https://github.com/asdf-vm/asdf-erlang.git && \
      git -C "$ASDF_DATA_DIR/plugins/erlang" checkout -q "$ASDF_ERLANG_PLUGIN_REF" && \
      asdf install erlang "$ERLANG_VERSION" && \
      echo "export ASDF_ERLANG_VERSION=${ERLANG_VERSION}" >> /etc/claude-sandbox/toolchain.sh && \
      rm -rf "$ASDF_DATA_DIR/downloads" "$ASDF_DATA_DIR"/plugins/erlang/kerl-home/builds; \
    fi

# Elixir via asdf-elixir (precompiled zip from repo.hex.pm; version must
# carry the -otp-NN suffix matching ERLANG_VERSION's major). Hex and
# rebar3 are installed into MIX_HOME=/opt/mix here, so `mix deps.get`
# works at runtime without `mix local.hex` (which couldn't write /opt).
ARG ASDF_ELIXIR_PLUGIN_REF=master
ARG ELIXIR_VERSION=""
RUN if [ -n "$ELIXIR_VERSION" ]; then \
      source /etc/claude-sandbox/toolchain.sh && \
      asdf plugin add elixir https://github.com/asdf-vm/asdf-elixir.git && \
      git -C "$ASDF_DATA_DIR/plugins/elixir" checkout -q "$ASDF_ELIXIR_PLUGIN_REF" && \
      asdf install elixir "$ELIXIR_VERSION" && \
      echo "export ASDF_ELIXIR_VERSION=${ELIXIR_VERSION}" >> /etc/claude-sandbox/toolchain.sh && \
      export ASDF_ELIXIR_VERSION="$ELIXIR_VERSION" && \
      mix local.hex --force && mix local.rebar --force && \
      rm -rf "$ASDF_DATA_DIR/downloads" /home/node/.hex /home/node/.cache; \
    fi

# Node via asdf-nodejs (prebuilt from nodejs.org, SHA256-checked by the
# plugin). The base image's node 22 stays underneath for `claude` itself;
# interactive shells see this one first via the shims.
ARG ASDF_NODEJS_PLUGIN_REF=master
ARG NODEJS_VERSION=""
RUN if [ -n "$NODEJS_VERSION" ]; then \
      asdf plugin add nodejs https://github.com/asdf-vm/asdf-nodejs.git && \
      git -C "$ASDF_DATA_DIR/plugins/nodejs" checkout -q "$ASDF_NODEJS_PLUGIN_REF" && \
      asdf install nodejs "$NODEJS_VERSION" && \
      echo "export ASDF_NODEJS_VERSION=${NODEJS_VERSION}" >> /etc/claude-sandbox/toolchain.sh && \
      rm -rf "$ASDF_DATA_DIR/downloads"; \
    fi

# k6 via asdf-k6 (prebuilt from GitHub releases).
ARG ASDF_K6_PLUGIN_REF=master
ARG K6_VERSION=""
RUN if [ -n "$K6_VERSION" ]; then \
      asdf plugin add k6 https://github.com/grimoh/asdf-k6.git && \
      git -C "$ASDF_DATA_DIR/plugins/k6" checkout -q "$ASDF_K6_PLUGIN_REF" && \
      asdf install k6 "$K6_VERSION" && \
      echo "export ASDF_K6_VERSION=${K6_VERSION}" >> /etc/claude-sandbox/toolchain.sh && \
      rm -rf "$ASDF_DATA_DIR/downloads"; \
    fi

# Shims are generated at build; nothing can add one at runtime.
RUN asdf reshim 2>/dev/null || true

# ---- Claude Code -----------------------------------------------------------
# Explicit /usr/local/bin/npm = the base image's node 22, regardless of
# what asdf put on PATH above. Floats to latest unless pinned; there is no
# self-update at runtime (npm-global is read_only) -- rebuild to upgrade.
ARG CLAUDE_CODE_VERSION=latest
RUN /usr/local/bin/npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"
