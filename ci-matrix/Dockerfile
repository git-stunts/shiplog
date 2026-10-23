# syntax=docker/dockerfile:1

ARG BASE_IMAGE=ubuntu:24.04
ARG DISTRO_FAMILY=debian
FROM ${BASE_IMAGE} AS base

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    SHELL=/bin/bash

ARG DISTRO_FAMILY
RUN case "$DISTRO_FAMILY" in \
      debian) \
        apt-get update && \
        apt-get install -y --no-install-recommends \
          git jq bash coreutils grep gawk sed findutils ca-certificates curl bats gnupg openssh-client && \
        apt-get clean && rm -rf /var/lib/apt/lists/* ;; \
      fedora) \
        dnf install -y git jq bash coreutils grep gawk sed findutils ca-certificates curl bats gnupg openssh-clients && \
        dnf clean all ;; \
      alpine) \
        apk add --no-cache git jq bash coreutils grep gawk sed findutils ca-certificates curl bats gnupg openssh-client openssh-keygen ;; \
      arch) \
        pacman -Sy --noconfirm git jq bash coreutils grep gawk sed findutils ca-certificates curl bats gnupg openssh && \
        pacman -Scc --noconfirm ;; \
      *) echo "Unsupported DISTRO_FAMILY: $DISTRO_FAMILY" >&2 && exit 1 ;; \
    esac

RUN git config --system init.defaultBranch main || true

ARG MATRIX_NAME=unknown
# Build ARGs are not visible at container runtime; promote to ENV so the log
# header names the distro (#147).
ENV MATRIX_NAME=$MATRIX_NAME
COPY --link <<'SCRIPT' /usr/local/bin/run-tests
#!/usr/bin/env bash
set -euo pipefail
NAME="${MATRIX_NAME:-unknown}"
echo "=== $NAME ==="
if command -v cat >/dev/null 2>&1; then
  cat /etc/os-release 2>/dev/null || true
fi
echo "bash: $(bash --version | head -n1)"
echo "git:  $(git --version)"
cd /work
exec bash ./test.sh
SCRIPT
RUN chmod +x /usr/local/bin/run-tests

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/run-tests"]
