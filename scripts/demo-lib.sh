#!/usr/bin/env bash
# Shared helpers for the three demo scripts. Sourced, never executed.
#
# Rule the demos obey: a release only ever arrives through git. Each one commits
# to app-repo, lets CI build, scan, publish and merge the promotion PR, and then
# watches Argo CD and Argo Rollouts do the deploying. None of them runs kubectl
# apply against the app. The single exception is demo-drift.sh, whose whole
# subject is a hand-run kubectl patch.
#
# Helpers that wait return by exiting rather than by status, because the caller
# runs under set -e and a silent false would look like a broken script instead
# of a timed-out demo.

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./env.sh
source ./env.sh

APP_REPO_DIR="${APP_REPO_DIR:-$WORKSPACE_ROOT/app-repo}"
# Slugs, not remotes, because `gh` addresses a repo by slug and the local clone
# may call its remote anything at all.
APP_REPO_SLUG="${APP_REPO_SLUG:-bouhlel-dev/gitops-app-repo}"
CONFIG_REPO_SLUG="${CONFIG_REPO_SLUG:-bouhlel-dev/gitops-config-repo}"

ROLLOUT_NAME=gitops-demo
DEV_APP=gitops-demo-dev
PROD_APP=gitops-demo-prod
IMAGE_TAG_LEN=7
# The image is named after the app, not after the repo holding its code, so it
# cannot be derived from APP_REPO_SLUG. It is the same value CI builds with.
IMAGE="ghcr.io/bouhlel-dev/gitops-demo"

# How long each stage may take before the demo calls it a failure. CI is the
# slow one: a buildx layer cache miss plus a Trivy scan is minutes, not seconds.
CI_TIMEOUT="${CI_TIMEOUT:-1500}"
SYNC_TIMEOUT="${SYNC_TIMEOUT:-300}"
CANARY_TIMEOUT="${CANARY_TIMEOUT:-900}"

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m~~~\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
step() { printf '\n\033[1;32m[%s]\033[0m %s\n' "$1" "$2"; }

# until_or_timeout TIMEOUT DESC COMMAND...
until_or_timeout() {
  local timeout="$1" desc="$2" deadline=$((SECONDS + $1))
  shift 2
  while true; do
    if "$@"; then
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "timed out after ${timeout}s waiting for $desc"
    sleep 5
  done
}

require_demo_tools() {
  for tool in gh python; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found -- run scripts/install-tools.sh and source scripts/env.sh"
  done
  [ -d "$APP_REPO_DIR/.git" ] || die "no app-repo clone at $APP_REPO_DIR (override with APP_REPO_DIR)"
  gh auth status >/dev/null 2>&1 || die "gh is not authenticated -- run: gh auth login"
  kubectl get ns "$DEV_NAMESPACE" >/dev/null 2>&1 ||
    die "namespace $DEV_NAMESPACE is missing -- run scripts/bootstrap.sh first"
}

# -------------------------------------------------------------------- git side --

HEAD_SHA=""

app_repo_ready() {
  # Starting from a dirty tree would commit whatever the last experiment left
  # behind, so the demo refuses rather than shipping someone's scratch file.
  git -C "$APP_REPO_DIR" checkout main >/dev/null 2>&1
  git -C "$APP_REPO_DIR" pull --ff-only origin main >/dev/null ||
    die "app-repo main is not fast-forwardable -- reconcile $APP_REPO_DIR with origin/main first"
  [ -z "$(git -C "$APP_REPO_DIR" status --porcelain)" ] ||
    die "app-repo has uncommitted changes -- commit or stash them in $APP_REPO_DIR first"
  log "app-repo clean at $(git -C "$APP_REPO_DIR" rev-parse --short HEAD)"
}

app_repo_release() { # app_repo_release MESSAGE  (tree must already be modified)
  git -C "$APP_REPO_DIR" add -A
  git -C "$APP_REPO_DIR" commit -m "$1" >/dev/null
  git -C "$APP_REPO_DIR" push origin main >/dev/null
  HEAD_SHA="$(git -C "$APP_REPO_DIR" rev-parse HEAD)"
  log "pushed ${HEAD_SHA:0:$IMAGE_TAG_LEN} to $APP_REPO_SLUG"
}

ci_run_exists() {
  [ -n "$(gh run list --repo "$APP_REPO_SLUG" --commit "$1" --json databaseId \
    --jq '.[0].databaseId // empty' 2>/dev/null)" ]
}

wait_ci() {
  local run_id
  until_or_timeout "$CI_TIMEOUT" "a CI run for ${HEAD_SHA:0:$IMAGE_TAG_LEN}" ci_run_exists "$HEAD_SHA"
  run_id="$(gh run list --repo "$APP_REPO_SLUG" --commit "$HEAD_SHA" --json databaseId --jq '.[0].databaseId')"
  log "CI run $run_id"
  until_or_timeout "$CI_TIMEOUT" "CI to go green" ci_is_green "$run_id"
  echo
  log "CI green: ${IMAGE}:${HEAD_SHA:0:$IMAGE_TAG_LEN} published, promotion merged into $CONFIG_REPO_SLUG"
}

ci_is_green() {
  local state conclusion
  state="$(gh run view "$1" --repo "$APP_REPO_SLUG" --json status,conclusion \
    --jq '.status + "/" + .conclusion' 2>/dev/null || echo 'queued/')"
  conclusion="${state##*/}"
  printf '  run %s\r' "$state"
  case "$conclusion" in
    success) return 0 ;;
    # A red pipeline is not a slow pipeline. Waiting out the timeout on a run
    # GitHub has already called a failure costs the demo ten minutes and reports
    # "timed out" instead of the step that broke.
    failure | cancelled | timed_out)
      echo
      die "CI failed on run $1. See: gh run view $1 --repo $APP_REPO_SLUG --log-failed"
      ;;
  esac
  return 1
}

# The end state that matters is the manifest, not the git pointer: the Rollout
# must ask for the image this commit produced.
rollout_image_is() { # rollout_image_is NAMESPACE TAG
  [ "$(kubectl -n "$1" get rollout "$ROLLOUT_NAME" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)" = "$IMAGE:$2" ]
}

wait_deployed() { # wait_deployed APPLICATION NAMESPACE TAG
  until_or_timeout "$SYNC_TIMEOUT" "$2 to ask for image :$3" rollout_image_is "$2" "$3"
  until_or_timeout "$SYNC_TIMEOUT" "$1 to be Synced/Healthy" app_healthy "$1"
  echo
  log "$1 Synced/Healthy, $2 serves ${IMAGE##*/}:$3"
}

app_healthy() {
  local state
  state="$(kubectl -n "$ARGOCD_NAMESPACE" get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo Pending/Pending)"
  printf '  %s -> %s\r' "$1" "$state"
  [ "$state" = Synced/Healthy ]
}

# ---------------------------------------------------------------- rollout side --

rollout_phase() {
  kubectl -n "$1" get rollout "$ROLLOUT_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo Missing
}

canary_weight() {
  # Not .status.canary.currentWeight: that key does not exist in Rollouts 1.10,
  # which reports the live split as .status.canary.weights.canary.weight. Reading
  # the wrong path means waiting forever on an empty string.
  kubectl -n "$1" get rollout "$ROLLOUT_NAME" \
    -o 'jsonpath={.status.canary.weights.canary.weight}' 2>/dev/null || echo 0
}

abort_reason() {
  # Not a "RolloutAborted" condition: that type is not what Rollouts 1.10
  # writes. An aborted rollout is a Degraded one, and this is the string that
  # names the metric that failed -- printed empty the first time the demo read
  # a path that does not exist.
  kubectl -n "$1" get rollout "$ROLLOUT_NAME" \
    -o 'jsonpath={.status.conditions[?(@.type=="Degraded")].reason}{" :: "}{.status.conditions[?(@.type=="Degraded")].message}' 2>/dev/null || true
}

analysis_message() { # AnalysisRun NAMESPACE RUN -- the controller's own sentence
  kubectl -n "$1" get analysisrun "$2" -o 'jsonpath={.status.message}' 2>/dev/null || true
}

promote() { # answer the manual pause at 10% weight
  kubectl argo rollouts promote "$ROLLOUT_NAME" -n "$1" >/dev/null ||
    die "promote failed -- is the rollout at its pause step? kubectl argo rollouts get $ROLLOUT_NAME -n $1"
  log "promoted (the human decision in $1)"
}

watch_canary() { # print each weight change once, stop when the rollout settles
  local ns="$1" seen="" weight phase deadline=$((SECONDS + CANARY_TIMEOUT))
  while true; do
    weight="$(canary_weight "$ns")"
    phase="$(rollout_phase "$ns")"
    if [ "$weight" != "$seen" ]; then
      log "  weight=${weight}% phase=$phase"
      seen="$weight"
    fi
    case "$phase" in
      Healthy | Degraded | Error) return 0 ;;
    esac
    [ "$SECONDS" -lt "$deadline" ] ||
      die "$ns stayed in phase=$phase at ${weight}% for ${CANARY_TIMEOUT}s -- kubectl -n $ns get rollout $ROLLOUT_NAME -o yaml ends in .status"
    sleep 5
  done
}

rollout_healthy() { [ "$(rollout_phase "$1")" = Healthy ]; }

at_weight() { [ "$(canary_weight "$1")" = "$2" ]; }

# A pause step leaves the Rollout in phase=Progressing forever, so "reach this
# weight" is the signal that the rollout has arrived where the demo wants to
# look at it -- phase alone cannot tell a pause from a slow rollout.
wait_weight() { # wait_weight NAMESPACE WEIGHT
  until_or_timeout "$CANARY_TIMEOUT" "$1 to reach $2% of traffic" at_weight "$1" "$2"
  echo
  log "$1 is serving $2% of traffic ($(rollout_phase "$1"))"
}

analysis_runs() {
  kubectl -n "$1" get analysisruns --no-headers 2>/dev/null | awk '{printf "  %-46s %s\n", $1, $2}'
}

analysis_detail() { # analysis_detail NAMESPACE ANALYSISRUN
  kubectl -n "$1" get analysisrun "$2" -o json | python -c '
import json
import sys

run = json.load(sys.stdin)
for metric in run.get("status", {}).get("metricResults", []):
    # Rollouts 1.10 records each probe under "measurements"; older builds called
    # the same list "samples". Read whichever is there, or the demo silently
    # prints an empty table for an AnalysisRun that measured four times.
    readings = metric.get("measurements") or metric.get("samples") or []
    values = " ".join(
        "%s" % (m.get("value", "-"),) for m in readings[-4:]
    )
    print("  %-14s phase=%-9s measured=%s failed=%s"
          % (metric.get("name", "?"), metric.get("phase", "?"),
             metric.get("count", 0), metric.get("failedCount", 0)))
    print("      values: %s" % (values or "-"))
    query = (metric.get("metadata") or {}).get("ResolvedPrometheusQuery", "")
    if query:
        print("      query:  %s" % " ".join(query.split()))
'
}

# Newest by creation time, not by name: AnalysisRuns are named
# <rollout>-<hash>-<step>-<index>, so "...-2-10" sorts before "...-2-4" and the
# last item alphabetically is the second gate, not the one that just failed.
latest_analysis_run() {
  kubectl -n "$1" get analysisruns --sort-by=.metadata.creationTimestamp \
    -o 'jsonpath={.items[-1:].metadata.name}' 2>/dev/null || true
}

# --------------------------------------------------------------------- traffic --

loadgen_start() { # loadgen_start dev|prod|all RATE DURATION
  LOADGEN_LOG="$(mktemp)"
  python loadgen.py --target "$1" --rate "$2" --duration "$3" >"$LOADGEN_LOG" 2>&1 &
  LOADGEN_PID=$!
  log "traffic -> $1: $2 rps for $3s (pid $LOADGEN_PID)"
}

loadgen_stop() {
  [ -n "${LOADGEN_PID:-}" ] || return 0
  kill "$LOADGEN_PID" 2>/dev/null || true
  wait "$LOADGEN_PID" 2>/dev/null || true
  echo "  loadgen, last lines:"
  tail -n 6 "$LOADGEN_LOG" | sed 's/^/    /'
  rm -f "$LOADGEN_LOG"
  LOADGEN_PID=""
}

cleanup() { loadgen_stop; }

ui_hint() {
  echo
  echo "  in another terminal:  kubectl argo rollouts get $ROLLOUT_NAME -n $1 --watch 2s"
  echo "  Argo CD UI:           kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:80"
}
