#!/usr/bin/env bash
# Bonus demo -- an image nobody signed cannot start, and the one the pipeline
# signed can.
#
#   scripts/demo-supply-chain.sh
#
# Prerequisites: `scripts/bootstrap.sh --supply-chain` has run, and at least one
# release has been published since CI started signing (the sign step in
# app-repo's ci.yml). The two are deliberately separate: the policy is Enforce,
# so applying it while an unsigned tag is the one being rolled out would stop
# that rollout mid-canary.
#
# What this proves is narrower than "the supply chain is secure", and the
# difference matters enough to say out loud. It proves that a Pod asking for an
# image this pipeline did not build is refused in these two namespaces. It does
# not prove the build itself was honest: anyone with write access to app-repo
# could commit a workflow that signs something else, and the signature would be
# valid because GitHub issued the certificate. Provenance beyond that identity is
# what SLSA attestations and a build you do not control are for.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./demo-lib.sh
source ./demo-lib.sh

require_demo_tools
command -v cosign >/dev/null 2>&1 ||
  die "cosign not found -- run scripts/install-tools.sh, then source scripts/env.sh"
kubectl get clusterpolicy verify-gitops-demo-signature >/dev/null 2>&1 ||
  die "the ClusterPolicy is not there -- run scripts/bootstrap.sh --supply-chain"

signed_image="$(kubectl -n "$DEV_NAMESPACE" get rollout "$ROLLOUT_NAME" \
  -o jsonpath='{.spec.template.spec.containers[0].image}')"
signed_tag="${signed_image##*:}"
# The unsigned image is not a fiction: every release published before CI started
# signing is still in GHCR, pullable, running fine if a namespace still points at
# it, and carries no signature. Reusing one of those is the honest test.
unsigned_image="$(kubectl -n "$DEV_NAMESPACE" get replicasets -l app="$ROLLOUT_NAME" \
  -o jsonpath='{range .items[*]}{.spec.template.spec.containers[0].image}{"\n"}{end}' |
  sort -u | grep -v -F "$signed_image" | tail -1)"
[ -n "$unsigned_image" ] ||
  die "no second image in $DEV_NAMESPACE to test with -- ship one release, then run this after the signed one"

step 1 "what signed the image, and with what"
printf '  signed image:   %s\n' "$signed_image"
printf '  unsigned image: %s\n' "$unsigned_image"
printf '  cosign:         %s\n' "$(cosign version 2>&1 | awk 'NR==1')"
echo
echo "  cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \\"
echo "    --certificate-identity-regexp '^https://github.com/${APP_REPO_SLUG}/\.github/workflows/ci\.yml@refs/heads/main$' \\"
echo "    $signed_image"
echo

step 2 "the signature is readable from here, not just from the runner"
# Same two strings the ClusterPolicy matches on. If this prints and the policy
# still refuses, the difference is in Kyverno's copy of cosign, not in the image.
verify_out="$(cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/${APP_REPO_SLUG}/\.github/workflows/ci\.yml@refs/heads/main$" \
  "$signed_image" 2>&1)" || {
    printf '%s\n' "$verify_out" | sed 's/^/  /'
    die "the signed image does not verify from the workstation"
  }
printf '%s\n' "$verify_out" | grep -o '"identity": *"[^"]*"' | sed 's/^/  /'

step 3 "and the older tag carries nothing to verify"
cosign verify --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp "^https://github.com/${APP_REPO_SLUG}/\.github/workflows/ci\.yml@refs/heads/main$" \
  "$unsigned_image" >/dev/null 2>/tmp/unsigned-err.txt || true
printf '  %s: %s\n' "$unsigned_image" "$(awk 'NF && !seen++' /tmp/unsigned-err.txt)"

step 4 "ask the cluster for a Pod on the unsigned image"
# One manifest, two runs, differing only in the image: `kubectl run` would add
# client-side defaults an Argo CD sync never sends, and the message under test
# is the webhook's, so the request should look as ordinary as possible.
# In $CACHE_DIR, not /tmp: kubectl here is a Windows binary and Git Bash's
# path translation is the sort of thing you do not want to rely on for a file
# you are about to apply.
mkdir -p "$CACHE_DIR"
pod_manifest="$CACHE_DIR/supply-chain-pod.yaml"
rm -f "$pod_manifest"
trap 'rm -f "$pod_manifest"' EXIT
printf 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: supply-chain-check\n  namespace: %s\n  labels:\n    run: supply-chain-check\nspec:\n  containers:\n    - name: app\n      image: %s\n      command: ["sleep", "60"]\n' \
  "$DEV_NAMESPACE" '%IMAGE%' > "$pod_manifest"
denied() { # denied IMAGE -> kubectl's own output, success or not
  sed "s|%IMAGE%|$1|" "$pod_manifest" > "$pod_manifest.in"
  kubectl apply -f "$pod_manifest.in" 2>&1
}
if out="$(denied "$unsigned_image")"; then
  kubectl -n "$DEV_NAMESPACE" delete pod supply-chain-check --ignore-not-found >/dev/null
  rm -f "$pod_manifest.in"
  die "the unsigned image was ACCEPTED -- check the policy: kubectl get clusterpolicy verify-gitops-demo-signature -o yaml"
fi
printf '%s\n' "$out" | sed 's/^/  /'
echo "  (that error came from the admission webhook, before kubelet was involved)"

step 5 "ask for the same Pod on the signed image"
if ! out="$(denied "$signed_image")"; then
  printf '%s\n' "$out" | sed 's/^/  /'
  rm -f "$pod_manifest.in"
  die "the signed image was refused too -- the policy and the signature disagree"
fi
rm -f "$pod_manifest.in"
until_or_timeout 120 "the signed pod to start" \
  kubectl -n "$DEV_NAMESPACE" wait --for=condition=Ready pod/supply-chain-check --timeout=20s
printf '  admitted and running: %s on %s\n' \
  "$(kubectl -n "$DEV_NAMESPACE" get pod supply-chain-check -o jsonpath='{.status.phase}')" \
  "$(kubectl -n "$DEV_NAMESPACE" get pod supply-chain-check -o jsonpath='{.spec.containers[0].image}')"

step 6 "what the policy is and is not"
cat <<'EOF'
  It fires on CREATE, in two namespaces, for one image repository. That is why
  the cluster's own components are outside it: an Enforce policy with
  failurePolicy: Fail across every namespace turns a broken signature lookup
  into a cluster that cannot restart anything.

  Three limits worth naming before someone else finds them:
    - the pods already running are untouched. A policy that refuses new Pods
      does not evict old ones, signed or not.
    - verification happens at admission against whatever the tag points at that
      moment. mutateImage: true would pin the verified digest into the Pod spec
      and close that window; it is off here so that the image string keeps
      matching what git says.
    - the identity is "this workflow ran on main", not "this build is
      reproducible". A signed image from a workflow you rewrote yesterday is
      still signed by that workflow.
EOF
kubectl -n "$DEV_NAMESPACE" delete pod supply-chain-check --ignore-not-found >/dev/null
echo
log "done. The refusing Pod and the accepted one differed by one thing: a signature."
