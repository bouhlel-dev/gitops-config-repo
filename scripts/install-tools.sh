#!/usr/bin/env bash
# Installs the pinned local toolchain into <workspace>/.tools/bin.
# Nothing is installed system-wide and nothing needs admin rights, so the demo
# machine only needs Docker Desktop + Git Bash + curl.
# Re-runnable: already-installed tools are verified and skipped.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
source ./env.sh

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
# awk instead of `head -1`: with pipefail, head closing the pipe early kills the
# command that produced the output.
first_line() { awk 'NF && !seen++ { print }'; }

mkdir -p "$TOOLS_DIR" "$CACHE_DIR"

# fetch URL ARTIFACT_NAME EXPECTED_SHA256
fetch() {
  local url="$1" name="$2" want="$3" dest="$CACHE_DIR/$name" got
  got="$(sha256sum "$dest" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -f "$dest" ] && [ "$got" = "$want" ]; then
    log "cached  $name"
    return
  fi
  rm -f "$dest"
  log "downloading $name"
  curl --fail --location --proto "=https" --retry 3 --connect-timeout 15 \
    --max-time 300 -o "$dest" "$url" || die "download failed: $url"
  got="$(sha256sum "$dest" | cut -d' ' -f1)"
  [ "$got" = "$want" ] || die "checksum mismatch for $name
  expected $want
  actual   $got"
}

# install_binary NAME TARGET_NAME SHA256 URL
install_binary() {
  local name="$1" target="$2" want="$3" url="$4"
  if [ -f "$TOOLS_DIR/$target" ]; then log "installed $target (skipped)"; return; fi
  fetch "$url" "$name" "$want"
  cp "$CACHE_DIR/$name" "$TOOLS_DIR/$target"
  chmod +x "$TOOLS_DIR/$target"
  log "installed $target"
}

# install_from_zip NAME ARTIFACT SHA256 URL INNER_FILENAME TARGET_NAME
install_from_zip() {
  local name="$1" artifact="$2" want="$3" url="$4" inner="$5" target="$6"
  if [ -f "$TOOLS_DIR/$target" ]; then log "installed $target (skipped)"; return; fi
  fetch "$url" "$name" "$want"
  local tmp; tmp="$(mktemp -d)"
  unzip -q "$CACHE_DIR/$name" -d "$tmp" || die "cannot unzip $CACHE_DIR/$name"
  local found
  found="$(find "$tmp" -type f -iname "$inner" -print -quit)"
  [ -n "$found" ] || die "$inner not found inside $artifact"
  cp "$found" "$TOOLS_DIR/$target"
  chmod +x "$TOOLS_DIR/$target"
  rm -rf "$tmp"
  log "installed $target"
}

log "toolchain -> $TOOLS_DIR"

install_binary kind-windows-amd64 kind.exe "$KIND_SHA256" \
  "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-windows-amd64"
install_binary kubectl.exe kubectl.exe "$KUBECTL_SHA256" \
  "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/windows/amd64/kubectl.exe"
install_from_zip helm.zip "helm-$HELM_VERSION-windows-amd64.zip" "$HELM_SHA256" \
  "https://get.helm.sh/helm-$HELM_VERSION-windows-amd64.zip" helm.exe helm.exe
install_from_zip kustomize.zip "kustomize_${KUSTOMIZE_VERSION#v}_windows_amd64.zip" "$KUSTOMIZE_SHA256" \
  "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F$KUSTOMIZE_VERSION/kustomize_${KUSTOMIZE_VERSION#v}_windows_amd64.zip" \
  kustomize.exe kustomize.exe
install_binary kubectl-argo-rollouts kubectl-argo-rollouts.exe "$ARGO_ROLLOUTS_SHA256" \
  "https://github.com/argoproj/argo-rollouts/releases/download/$ARGO_ROLLOUTS_VERSION/kubectl-argo-rollouts-windows-amd64"
install_from_zip gh.zip "gh_${GH_VERSION#v}_windows_amd64.zip" "$GH_SHA256" \
  "https://github.com/cli/cli/releases/download/$GH_VERSION/gh_${GH_VERSION#v}_windows_amd64.zip" \
  gh.exe gh.exe

# Deliberately not installed locally:
#   trivy   -- scanning is a CI gate (see TRIVY_VERSION in versions.env); the
#            local run would also fetch a ~50 MB vulnerability DB.
#   argocd  -- in this design you never sync by hand. Git is the trigger; the
#            Argo CD web UI and `kubectl` cover inspection.

log "version check"
printf '%-24s %s\n' "kind"      "$(kind version 2>&1 | first_line)"
printf '%-24s %s\n' "kubectl"   "$(kubectl version --client 2>&1 | first_line)"
printf '%-24s %s\n' "helm"      "$(helm version --short 2>&1 | first_line)"
printf '%-24s %s\n' "kustomize" "$(kustomize version 2>&1 | first_line)"
printf '%-24s %s\n' "rollouts"  "$(kubectl argo rollouts version 2>&1 | first_line)"
printf '%-24s %s\n' "gh"        "$(gh --version 2>&1 | first_line)"

log "done. In a new shell, run:  source $REPO_DIR/scripts/env.sh"
