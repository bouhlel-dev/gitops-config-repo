#!/usr/bin/env bash
# Demo 1 -- a good release, start to finish.
#
#   scripts/demo-good-release.sh
#
# What it proves: a commit is enough. Nothing here runs kubectl apply, and the
# only kubectl write is the one `promote` that stands in for the operator
# clicking "Promote" in the dashboard. The change itself is a line in a
# markdown file, deliberately: the release carries no behaviour, so every second
# you spend watching it is spent on the pipeline rather than on the diff.
#
# The load generator runs against both environments for the whole demo. That is
# not decoration -- prod syncs at the same moment as dev, its canary is analysed
# by the same AnalysisTemplate, and a canary Prometheus has never seen returns an
# empty result, which the gate reads as a failure. Traffic is what makes the
# measurement mean something.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./demo-lib.sh
source ./demo-lib.sh

started=$SECONDS
trap cleanup EXIT

require_demo_tools
app_repo_ready

step 1 "what is live right now"
for ns in "$DEV_NAMESPACE" "$PROD_NAMESPACE"; do
  printf '  %-18s %s\n' "$ns" \
    "$(kubectl -n "$ns" get rollout "$ROLLOUT_NAME" -o jsonpath='{.spec.template.spec.containers[0].image}')"
done
log "note the tag: it is a commit from app-repo, not a build number"

step 2 "generating the traffic the canary will be measured on"
loadgen_start all 20 1200
printf '  a sample request through the ingress:\n'
curl -sS -H 'Host: gitops-demo.local' http://127.0.0.1/ | sed 's/^/    /'
echo

step 3 "a change worth reviewing, and nothing else"
note="- $(date -u +%Y-%m-%dT%H:%M:%SZ) $(git -C "$APP_REPO_DIR" rev-parse --short HEAD): demo-good-release, no behaviour change"
printf '%s\n' "$note" >>"$APP_REPO_DIR/RELEASES.md"
app_repo_release "docs: record a release in RELEASES.md"

step 4 "CI: lint, test, build, scan, publish, promote"
log "this is the slow part. Watch it live with:"
log "  gh run watch --repo $APP_REPO_SLUG"
wait_ci

step 5 "Argo CD picks it up (reconciles every 20s)"
# Waiting on the Rollout's own spec, not on app health: as soon as CI's promotion
# lands the canary starts, and while it is at 10% the app is Progressing, not
# Healthy. Waiting for Healthy here would time out on a release that is working.
until_or_timeout "$SYNC_TIMEOUT" "the new tag to reach the Rollout specs" \
  rollout_image_is "$DEV_NAMESPACE" "${HEAD_SHA:0:$IMAGE_TAG_LEN}"
ui_hint "$DEV_NAMESPACE"

step 6 "canary at 10%, paused for a human"
# The pause has no timeout: the rollout waits here until someone promotes it,
# which is the only human decision in the whole pipeline.
wait_weight "$DEV_NAMESPACE" 10
printf '  one pod of ten carries the new version:\n'
kubectl -n "$DEV_NAMESPACE" get pods -l app="$ROLLOUT_NAME" \
  -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}' |
  awk -v tag=":${HEAD_SHA:0:$IMAGE_TAG_LEN}" '{if (index($2, tag)) print "    NEW " $1; else print "    old " $1}'
promote "$DEV_NAMESPACE"

step 7 "30% -> 60% -> 100%, each gate measured"
watch_canary "$DEV_NAMESPACE"
until_or_timeout "$SYNC_TIMEOUT" "$DEV_APP to settle" app_healthy "$DEV_APP"
until_or_timeout "$SYNC_TIMEOUT" "$PROD_APP to settle" app_healthy "$PROD_APP"

step 8 "every pod in both environments runs the new image"
for ns in "$DEV_NAMESPACE" "$PROD_NAMESPACE"; do
  # Count on the image field, not the pod name: names carry the pod-template
  # hash, so grepping a name for the tag matches nothing on a good release.
  printf '  %-18s %s of %s pods on :%s\n' "$ns" \
    "$(kubectl -n "$ns" get pods -o jsonpath='{range .items[*]}{.spec.containers[0].image}{"\n"}{end}' |
      grep -c ":${HEAD_SHA:0:$IMAGE_TAG_LEN}")" \
    "$(kubectl -n "$ns" get pods --no-headers | wc -l)" \
    "${HEAD_SHA:0:$IMAGE_TAG_LEN}"
done
analysis_runs "$DEV_NAMESPACE"

loadgen_stop
echo
log "good release delivered in $((SECONDS - started))s: commit -> image -> PR -> sync -> canary -> 100%"
log "release ${HEAD_SHA:0:$IMAGE_TAG_LEN} is live in both namespaces, and no one typed kubectl apply"
