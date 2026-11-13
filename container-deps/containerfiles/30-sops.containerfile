ARG SOPS_VERSION=latest

RUN case "$(uname -m)" in \
    x86_64) sops_arch=amd64 ;; \
    aarch64|arm64) sops_arch=arm64 ;; \
    *) echo "Unsupported SOPS architecture: $(uname -m)" >&2; exit 1 ;; \
  esac \
  && if [ "${SOPS_VERSION}" = "latest" ]; then \
    sops_version="$(curl -fsSL https://api.github.com/repos/getsops/sops/releases/latest | jq -r .tag_name)" \
    && sops_version="${sops_version#v}"; \
  else \
    sops_version="${SOPS_VERSION#v}"; \
  fi \
  && curl -fsSL -o /usr/local/bin/sops "https://github.com/getsops/sops/releases/download/v${sops_version}/sops-v${sops_version}.linux.${sops_arch}" \
  && chmod 755 /usr/local/bin/sops \
  && sops --version --check-for-updates
