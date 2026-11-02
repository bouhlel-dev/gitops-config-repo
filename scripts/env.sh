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

# Every namespace this project touches. The two app namespaces are also written
# into bootstrap/argocd/applications/*.yaml and apps/*/overlays/*/kustomization
# .yaml: those are manifests, not scripts, so they cannot read this file, and
# Argo CD reports the mismatch as an app that syncs into the wrong namespace.
export ARGOCD_NAMESPACE=argocd
export ROLLOUTS_NAMESPACE=argo-rollouts
export MONITORING_NAMESPACE=monitoring
export INGRESS_NAMESPACE=ingress-nginx
export DEV_NAMESPACE=gitops-demo-dev
export PROD_NAMESPACE=gitops-demo-prod

# Where bootstrap.sh finds its inputs.
export BOOTSTRAP_DIR="$REPO_DIR/bootstrap"
export HELM_VALUES_DIR="$BOOTSTRAP_DIR/helm"
export APPLICATIONS_DIR="$BOOTSTRAP_DIR/argocd/applications"

# Helm release names, so a service can be named in one place.
export INGRESS_RELEASE=ingress-nginx
export MONITORING_RELEASE=kube-prometheus-stack
