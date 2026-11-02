#!/usr/bin/env bash
# Demo 2 -- a bad release, caught and rolled back by itself.
#
#   scripts/demo-bad-release.sh              ship it, watch it abort, revert it
#   scripts/demo-bad-release.sh --no-restore stop after the abort and leave the
#                                faulty version in git, for a second run of the
#                                rollback by hand
#
# The fault is one character-long: EXTRA_LATENCY_MS in app/main.py goes from 0.0
# to 600.0. It is chosen because everything upstream of the cluster approves it.
# Ruff formats it happily, the test suite never measures a duration, Trivy has no
# opinion about application latency, the image builds, the scan is clean, CI
# pushes it and the promotion PR merges. The p95 of the canary is the first thing
# in the chain that disagrees -- which is the argument for the whole project.
#
# Success rate stays at 100% throughout: a slow release is not an erroring one,
# so the abort is caused by the second metric in the AnalysisTemplate. Both
# metrics earn their place here, one per kind of failure.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./demo-lib.sh
source ./demo-lib.sh

restore=1
[ "${1:-}" = "--no-restore" ] && restore=0

file=app/main.py
started=$SECONDS
trap cleanup EXIT

require_demo_tools
app_repo_ready

bad_tag=""
step 1 "the one-line change CI cannot see"
# Anchored sed: if the hook ever moves or someone rewrites the default, the
# substitution changes nothing and the demo stops rather than shipping a good
# release and calling it bad.
sed -i 's/^EXTRA_LATENCY_MS = 0.0$/EXTRA_LATENCY_MS = 600.0/' "$APP_REPO_DIR/$file"
grep -q '^EXTRA_LATENCY_MS = 600.0$' "$APP_REPO_DIR/$file" ||
  die "the latency hook is not where demo-bad-release.sh expects it in $APP_REPO_DIR/$file"
git -C "$APP_REPO_DIR" --no-pager diff --stat

step 2 "the checks CI runs, run locally first -- all green, as CI will report"
if [ -x "$APP_REPO_DIR/.venv/Scripts/python.exe" ]; then
  (
    cd "$APP_REPO_DIR" &&
      .venv/Scripts/python.exe -m ruff check app tests >/dev/null &&
      .venv/Scripts/python.exe -m ruff format --check app tests >/dev/null &&
      .venv/Scripts/python.exe -m pytest -q >/dev/null
  ) && log "ruff + pytest pass on the faulty code (of course they do)"
else
  warn "no .venv in app-repo -- skipping the local reproduction of CI's checks"
fi

step 3 "ship it"
app_repo_release "make /api/items 600ms slower for a quarter of requests"
bad_tag="${HEAD_SHA:0:$IMAGE_TAG_LEN}"
loadgen_start all 20 1800
wait_ci

step 4 "Argo CD deploys it, because deploying is what it is told to do"
until_or_timeout "$SYNC_TIMEOUT" ":$bad_tag to reach the Rollout specs" \
  rollout_image_is "$DEV_NAMESPACE" "$bad_tag"
log "both namespaces now consider the faulty image the desired state"
ui_hint "$DEV_NAMESPACE"

step 5 "the canary reaches 10% and waits for a decision"
wait_weight "$DEV_NAMESPACE" 10
echo "  the dashboard at this moment looks fine: 10% of traffic, no errors."
promote "$DEV_NAMESPACE"

step 6 "the analysis runs, and says no"
# 30% -> 30s soak -> 4 samples at 15s -> same again at 60%: roughly four minutes
# before the gate has measured enough to disagree.
watch_canary "$DEV_NAMESPACE"
aborted_at=$SECONDS
echo
log "phase=$(rollout_phase "$DEV_NAMESPACE")  reason=$(abort_reason "$DEV_NAMESPACE")"
run="$(latest_analysis_run "$DEV_NAMESPACE")"
log "AnalysisRun $run:"
analysis_detail "$DEV_NAMESPACE" "$run"
printf '  the run'"'"'s own verdict: %s\n' "$(analysis_message "$DEV_NAMESPACE" "$run")"
echo "  the two pod-template hashes the split was between:"
kubectl -n "$DEV_NAMESPACE" get rollout "$ROLLOUT_NAME" \
  -o 'jsonpath={.status.canary.weights}{"\n"}' | sed 's/^/    /'

step 7 "what the cluster did with no help"
# .status.stableScaleSelector does not exist in Rollouts 1.10; the honest
# evidence is the ReplicaSet table and which pods are left standing.
kubectl -n "$DEV_NAMESPACE" get replicasets -l app="$ROLLOUT_NAME" \
  -o custom-columns=NAME:.metadata.name,DESIRED:.spec.replicas,READY:.status.readyReplicas,IMAGE:.spec.template.spec.containers[0].image |
  sed 's|ghcr.io/bouhlel-dev/gitops-demo:||' | sed 's/^/  /'
printf '  traffic back on the old version: canary weight %s%%, phase %s\n' \
  "$(canary_weight "$DEV_NAMESPACE")" "$(rollout_phase "$DEV_NAMESPACE")"
echo "  AnalysisRuns this release produced:"
analysis_runs "$DEV_NAMESPACE"
echo
log "detection took $((aborted_at - started))s from the push, and no human touched the cluster"

if [ "$restore" = 1 ]; then
  step 8 "the fix is a commit"
  git -C "$APP_REPO_DIR" revert --no-edit HEAD >/dev/null
  HEAD_SHA="$(git -C "$APP_REPO_DIR" rev-parse HEAD)"
  git -C "$APP_REPO_DIR" push origin main >/dev/null
  log "pushed revert ${HEAD_SHA:0:$IMAGE_TAG_LEN}"
  wait_ci
  until_or_timeout "$SYNC_TIMEOUT" ":${HEAD_SHA:0:$IMAGE_TAG_LEN} to reach the Rollout specs" \
    rollout_image_is "$DEV_NAMESPACE" "${HEAD_SHA:0:$IMAGE_TAG_LEN}"
  wait_weight "$DEV_NAMESPACE" 10
  promote "$DEV_NAMESPACE"
  watch_canary "$DEV_NAMESPACE"
  until_or_timeout "$SYNC_TIMEOUT" "$DEV_APP to settle" app_healthy "$DEV_APP"
  log "healthy again after $((SECONDS - started))s end to end"
else
  step 8 "left faulty on purpose (--no-restore)"
  echo "  revert it yourself with:"
  echo "    git -C \"$APP_REPO_DIR\" revert --no-edit HEAD && git -C \"$APP_REPO_DIR\" push origin main"
fi

loadgen_stop
echo
echo "  for the record, the numbers this demo produced:"
echo "    python scripts/dora.py --days 1"
