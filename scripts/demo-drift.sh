#!/usr/bin/env bash
# Demo 3 -- drift, and the thing that puts it back.
#
#   scripts/demo-drift.sh              tamper with dev
#   scripts/demo-drift.sh prod         tamper with prod
#
# Someone runs one kubectl patch. It is a legal edit, the API server accepts it,
# no webhook objects, and the running pods do not care. Ten seconds later Argo CD
# notices the live tree no longer matches git and reverts it. That is the second
# half of the GitOps claim: not "deploys come from git" but "git stays true".
#
# What this demo deliberately does NOT cover, because it is a real limit worth
# stating out loud: selfHeal only reverts resources Argo CD owns. A hand-run
# `helm upgrade` against ingress-nginx or kube-prometheus-stack is invisible
# here -- those releases were installed out of band by bootstrap.sh and are not
# under git at all. Same for a resource created in a namespace Argo CD does not
# watch, and for anything the Application does not select.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./demo-lib.sh
source ./demo-lib.sh

env_name="${1:-dev}"
case "$env_name" in
  dev) namespace="$DEV_NAMESPACE"; app="$DEV_APP" ;;
  prod) namespace="$PROD_NAMESPACE"; app="$PROD_APP" ;;
  *) die "usage: scripts/demo-drift.sh [dev|prod]" ;;
esac

configmap=gitops-demo-config
tampered=tampered-by-hand
require_demo_tools

step 1 "the value as git says it should be"
before="$(kubectl -n "$namespace" get configmap "$configmap" -o jsonpath='{.data.APP_ENV}')"
printf '  %s/%s APP_ENV=%s\n' "$namespace" "$configmap" "$before"
printf '  which is what apps/gitops-demo/overlays/%s/kustomization.yaml writes\n\n' "$env_name"

step 2 "one legal kubectl patch, no git involved"
kubectl -n "$namespace" patch configmap "$configmap" --type merge \
  -p "{\"data\":{\"APP_ENV\":\"$tampered\"}}" >/dev/null
patched_at=$SECONDS
printf '  APP_ENV is now %s\n' "$(kubectl -n "$namespace" get configmap "$configmap" -o jsonpath='{.data.APP_ENV}')"
printf '  kubectl accepted it. Nothing warned. The pods kept running.\n'

step 3 "waiting for Argo CD to notice (it reconciles every 20s)"
reverted_at=""
while true; do
  now="$(kubectl -n "$namespace" get configmap "$configmap" -o jsonpath='{.data.APP_ENV}' 2>/dev/null || echo gone)"
  state="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$app" \
    -o jsonpath='{.status.sync.status}' 2>/dev/null || echo '?')"
  printf '  +%3ds  APP_ENV=%-18s app=%s\r' "$((SECONDS - patched_at))" "$now" "$state"
  if [ "$now" = "$before" ]; then
    reverted_at=$SECONDS
    echo
    break
  fi
  [ "$((SECONDS - patched_at))" -lt 180 ] || {
    echo
    die "Argo CD did not revert within 180s. Look at kubectl -n $ARGOCD_NAMESPACE get application $app -o yaml and check selfHeal is still true."
  }
  sleep 2
done

step 4 "what just happened, in the cluster's own words"
printf '  reverted after %ss -- one reconciliation cycle\n' "$((reverted_at - patched_at))"
printf '  APP_ENV=%s  (matches %s again)\n' \
  "$(kubectl -n "$namespace" get configmap "$configmap" -o jsonpath='{.data.APP_ENV}')" \
  "apps/gitops-demo/overlays/$env_name/kustomization.yaml"
echo
echo "  the Application's own record of the sync that fixed it:"
kubectl -n "$ARGOCD_NAMESPACE" get application "$app" \
  -o 'jsonpath={.status.operationState.syncResult.revision} {.status.operationState.finishedAt}{"\n"}' 2>/dev/null |
  sed 's/^/    /'
echo "  events on the Application, newest last:"
kubectl -n "$ARGOCD_NAMESPACE" get events --field-selector "involvedObject.name=$app" \
  --sort-by=.lastTimestamp --no-headers 2>/dev/null | tail -n 3 | sed 's/^/    /'

step 5 "the limit, which is worth stating out loud"
echo "  selfHeal reverts resources Argo CD recognises as its own. Create one it"
echo "  has never seen and it survives forever:"
echo "    kubectl -n $namespace create configmap rogue --from-literal=note=untracked"
echo "    kubectl -n $namespace get configmap rogue -o jsonpath='{.data.note}'"
echo "  prune removes things that were in git and left git; it does not sweep the"
echo "  namespace. Same story for a hand-run helm upgrade against ingress-nginx or"
echo "  kube-prometheus-stack -- those were installed out of band and are not in"
echo "  the Application's tree at all. The guarantee covers apps/gitops-demo/."
echo
log "drift detected and reverted in $((reverted_at - patched_at))s, by reconciliation alone, with no human in the loop"
