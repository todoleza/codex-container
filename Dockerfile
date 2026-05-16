FROM fedora:44

ARG TZ
ENV TZ="${TZ}"

ARG USERNAME=node

RUN dnf -y install --setopt=install_weak_deps=False \
    aggregate \
    ca-certificates \
    curl \
    bind-utils \
    fzf \
    gh \
    git \
    gnupg2 \
    iproute \
    jq \
    less \
    procps-ng \
    unzip \
    ripgrep \
    zsh \
    python3 \
    yamllint \
    ShellCheck \
    bubblewrap \
    nodejs24 \
    nodejs24-npm \
  && dnf clean all \
  && rm -rf /var/cache/dnf /var/cache/libdnf5

RUN useradd --create-home --shell /usr/bin/zsh "${USERNAME}" \
  && mkdir -p /usr/local/share/npm-global \
  && chown -R "${USERNAME}:${USERNAME}" /usr/local/share

USER "${USERNAME}"

ENV NPM_CONFIG_PREFIX=/usr/local/share/npm-global
ENV PATH="${PATH}:/usr/local/share/npm-global/bin"

COPY dist/codex.tgz codex.tgz

RUN npm install -g codex.tgz \
  && npm cache clean --force \
  && rm -rf /usr/local/share/npm-global/lib/node_modules/codex-cli/node_modules/.cache \
  && rm -rf /usr/local/share/npm-global/lib/node_modules/codex-cli/tests \
  && rm -rf /usr/local/share/npm-global/lib/node_modules/codex-cli/docs

ENV CODEX_UNSAFE_ALLOW_NO_SANDBOX=1
