#!/usr/bin/env bash
# Shared environment for every script in this repo: puts the pinned toolchain on
# PATH and exports the versions from versions.env.
#   source scripts/env.sh   (called by bootstrap.sh and the demo scripts)

set -euo pipefail

ENV_SH_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$ENV_SH_DIR/.." && pwd)"
WORKSPACE_ROOT="$(cd -- "$REPO_DIR/.." && pwd)"

TOOLS_DIR="${TOOLS_DIR:-$WORKSPACE_ROOT/.tools/bin}"
CACHE_DIR="${CACHE_DIR:-$WORKSPACE_ROOT/.tools/cache}"

# shellcheck source=../versions.env
source "$REPO_DIR/versions.env"

PATH="$TOOLS_DIR:$PATH"
export TOOLS_DIR CACHE_DIR REPO_DIR WORKSPACE_ROOT PATH

# kubectl and kind need a cluster context name; keep it in one place.
export CLUSTER_NAME="${CLUSTER_NAME:-gitops}"
export APP_NAMESPACE="${APP_NAMESPACE:-gitops-demo}"
