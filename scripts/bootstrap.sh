#!/usr/bin/env bash
# One-command cluster bootstrap for the GitOps demo.
#
#   scripts/bootstrap.sh                    create the cluster and install everything
#   scripts/bootstrap.sh --supply-chain     the above, plus Kyverno and the
#                                           ImageValidatingPolicy that refuses an
#                                           unsigned image
#   scripts/bootstrap.sh --status           report what is running, install nothing
#   scripts/bootstrap.sh --destroy          delete the kind cluster
#
# Re-runnable by design: each phase checks for its own end state, so a failed
# run is repaired by running the script again, not by undoing anything. The
# cluster is the only thing this script creates; both repositories, the GHCR
# image and the pinned tools in .tools are left alone.
#
# Install order is the dependency chain, not a preference:
#   kind -> ingress-nginx -> kube-prometheus-stack -> Argo CD -> Argo Rollouts
#   -> the two Applications
# The Applications come last because the first sync needs the Rollouts CRDs to
# exist (or it fails on "no matches for kind Rollout") and Prometheus to be
# scraping (or the canary analysis has nothing to read).
#
# Trade-off to be aware of: the four infrastructure pieces are installed by this
# script, not by Argo CD. Argo CD cannot manage the things it needs in order to
# exist, so the first install is out of band. The consequence is that a
# hand-run `helm upgrade` is never reverted -- selfHeal only covers what is in
# git, which is everything under apps/gitops-demo/.

set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")"
# shellcheck source=./env.sh
source ./env.sh

# 1 when the optional signature-enforcement component should be installed too.
SUPPLY_CHAIN=0

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m~~~\033[0m %s\n' "$*"; }
die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$CACHE_DIR"

# fetch NAME URL EXPECTED_SHA256 -> $CACHE_DIR/NAME, cache-first, checksum
# enforced even on a cached file.
fetch() {
  local name="$1" url="$2" want="$3" got
  # Separate statement: inside one `local`, a later assignment sees the names
  # declared but not yet assigned, so "$CACHE_DIR/$name" trips set -u.
  local dest="$CACHE_DIR/$name"
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

# wait_namespace NS: every pod in NS Ready. Waits for pods to appear first,
# because kubectl wait on an empty list is an error rather than a no-op. The
# 15 minutes is for a cold cluster on a slow link: a pod sitting in
# ContainerCreating is downloading, not broken, and dying at ten minutes would
# turn a working bootstrap into a false alarm.
wait_namespace() {
  local ns="$1" seen=0 i
  for i in $(seq 1 60); do
    seen="$(kubectl -n "$ns" get pods --no-headers 2>/dev/null | wc -l)"
    [ "$seen" -gt 0 ] && break
    sleep 2
  done
  [ "$seen" -gt 0 ] || die "no pods ever appeared in $ns"
  kubectl -n "$ns" wait --for=condition=Ready pod --all --timeout=900s >/dev/null \
    || die "pods in $ns are not Ready -- look with: kubectl -n $ns get pods"
  log "$ns ready"
}

create_namespace() { # idempotent, and keeps the script the owner of namespaces
  kubectl create namespace "$1" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

# --------------------------------------------------------------------- phases --

phase_preflight() {
  command -v docker >/dev/null 2>&1 || die "docker not on PATH"
  docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop, wait for the engine to come up, then run this script again."
  for tool in kind kubectl helm kustomize; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool not found -- run scripts/install-tools.sh, then source scripts/env.sh"
  done
}

phase_cluster() {
  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    log "cluster $CLUSTER_NAME exists"
  else
    log "creating kind cluster $CLUSTER_NAME ($KIND_NODE_IMAGE)"
    kind create cluster --name "$CLUSTER_NAME" \
      --image "$KIND_NODE_IMAGE" \
      --config "$BOOTSTRAP_DIR/kind/gitops.yaml" \
      --wait 5m \
      || die "kind could not create the cluster. If the message above mentions port 80 or 443, something on Windows already owns it: change hostPort in bootstrap/kind/gitops.yaml and the nodePorts in bootstrap/helm/ingress-nginx.yaml together (e.g. 8080/8443 and keep the same nodePorts)."
  fi
  kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null
  kubectl get nodes
}

phase_prepull() {
  # Why this exists at all: on a slow link, containerd inside the node can sit on
  # one pull for ten minutes without failing. kubelet never reports an error, but
  # the Deployment blows through its progressDeadlineSeconds, and `helm --wait`
  # then calls the install Failed while the only thing happening is a download.
  # Pulling on the host and sideloading with `kind load` turns that into
  # deterministic local copies -- and a re-created cluster starts in seconds.
  #
  # Every failure in here is a warning, not a stop, because the node can always
  # fetch an image itself: slower, but certain. `kind load` in particular fails
  # with "content digest not found" while the same image is mid-pull inside the
  # node -- a lock in containerd's content store, not a broken image.
  if [ "${SKIP_PREPULL:-0}" = "1" ]; then
    warn "SKIP_PREPULL=1 -- the node will fetch each image itself"
    return
  fi
  prepull_list "$INFRA_IMAGES"
  if [ "$SUPPLY_CHAIN" = 1 ]; then
    prepull_list "$SUPPLY_CHAIN_IMAGES"
  fi
}

prepull_list() {
  local node="$CLUSTER_NAME-control-plane" image present
  present="$(docker exec "$node" ctr -n k8s.io images ls -q 2>/dev/null || true)"
  for image in $1; do
    if printf '%s\n' "$present" | grep -qxF "$image"; then
      log "in node   $image"
      continue
    fi
    log "host pull $image"
    docker pull --quiet "$image" >/dev/null 2>&1 \
      || { warn "host pull failed for $image -- the node will fetch it"; continue; }
    log "kind load $image"
    kind load docker-image "$image" --name "$CLUSTER_NAME" >/dev/null 2>&1 \
      || warn "could not sideload $image -- the node will fetch it"
  done
}

# helm_install <release> <chart> <repo> <version> <namespace> <values> <timeout>
# helm --wait is the part a slow download breaks: it fails on the workload's
# progressDeadlineSeconds while the pull is still running, so the release reads
# as failed and the cluster is fine. Three attempts, then pod readiness decides
# -- it is the thing we actually care about, and it keeps working after helm has
# given up. Deliberately not --atomic: rolling back would delete the pods
# mid-pull and throw away the bandwidth the attempt already spent.
helm_install() {
  local release="$1" chart="$2" repo="$3" version="$4" namespace="$5" values="$6" timeout="$7"
  local attempt
  # --repo only applies to an http chart index. Kyverno publishes as an OCI
  # artifact, whose ref already names the registry, so passing --repo there is
  # an error rather than a no-op.
  local repo_flag=()
  [ -z "$repo" ] || repo_flag=(--repo "$repo")
  for attempt in 1 2 3; do
    if helm upgrade --install "$release" "$chart" \
      "${repo_flag[@]}" --version "$version" \
      --namespace "$namespace" --create-namespace \
      --values "$values" --wait --timeout "$timeout"; then
      return 0
    fi
    warn "$release not Ready inside $timeout (attempt $attempt): if pods are still ContainerCreating that is the download, not the chart"
  done
  wait_namespace "$namespace"
  log "$release is Ready, whatever helm --wait made of the downloads"
}

phase_ingress() {
  log "ingress-nginx $INGRESS_NGINX_CHART_VERSION"
  helm_install "$INGRESS_RELEASE" ingress-nginx \
    https://kubernetes.github.io/ingress-nginx \
    "$INGRESS_NGINX_CHART_VERSION" "$INGRESS_NAMESPACE" \
    "$HELM_VALUES_DIR/ingress-nginx.yaml" 10m
}

phase_monitoring() {
  # The heavy phase: this chart installs the prometheus-operator CRDs and then
  # the operator, Prometheus, kube-state-metrics and Grafana. Waiting matters
  # twice over -- the ServiceMonitor CRD has to exist before Argo CD can sync
  # one, and a canary that starts before Prometheus is serving scrapes has
  # nothing to analyse.
  log "kube-prometheus-stack $KUBE_PROMETHEUS_STACK_CHART_VERSION"
  helm_install "$MONITORING_RELEASE" kube-prometheus-stack \
    https://prometheus-community.github.io/helm-charts \
    "$KUBE_PROMETHEUS_STACK_CHART_VERSION" "$MONITORING_NAMESPACE" \
    "$HELM_VALUES_DIR/kube-prometheus-stack.yaml" 20m
}

phase_argocd() {
  fetch argocd-install.yaml \
    "https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml" \
    "$ARGOCD_INSTALL_SHA256"
  create_namespace "$ARGOCD_NAMESPACE"
  # --server-side because install.yaml carries CRDs whose full schema blows past
  # the 24 KB annotation limit that a client-side apply records in
  # last-applied-configuration. The -n is not decoration: most objects in the
  # manifest declare no namespace, and Argo CD's RBAC assumes they live here.
  kubectl -n "$ARGOCD_NAMESPACE" apply --server-side \
    -f "$CACHE_DIR/argocd-install.yaml" >/dev/null
  wait_namespace "$ARGOCD_NAMESPACE"

  # Argo CD reconciles every 180s by default, so a git push would be followed by
  # three minutes of nothing on screen. 20s keeps a live demo watchable; the
  # cost is more API queries, which on one cluster and two apps is noise.
  #
  # Both ConfigMaps, because the docs and the manifest disagree: Argo CD's own
  # install.yaml wires the controller's ARGOCD_RECONCILIATION_TIMEOUT from
  # argocd-cm (optional), while timeout.reconciliation is documented as a key of
  # argocd-cmd-params-cm. Patching only the second one produced a measured
  # 5-minute commit-to-deploy delay -- the key was set, the env was never read,
  # and the controller quietly kept its default.
  log "reconciliation interval -> 20s"
  local cm
  for cm in argocd-cm argocd-cmd-params-cm; do
    kubectl -n "$ARGOCD_NAMESPACE" patch configmap "$cm" \
      --type merge -p '{"data":{"timeout.reconciliation":"20s"}}' >/dev/null
  done
  kubectl -n "$ARGOCD_NAMESPACE" rollout restart \
    statefulset/argocd-application-controller >/dev/null
  kubectl -n "$ARGOCD_NAMESPACE" rollout status \
    statefulset/argocd-application-controller --timeout=300s >/dev/null
  # Print what the controller actually starts with, so a future Argo CD that
  # moves the key again shows up here instead of as an unexplained lag. Neither
  # the StatefulSet nor the Pod spec carries the resolved value -- both keep the
  # configMapKeyRef -- so the only honest read is the running process itself.
  local effective
  effective="$(kubectl -n "$ARGOCD_NAMESPACE" exec "statefulset/argocd-application-controller" \
    -- cat /proc/1/environ 2>/dev/null | tr '\0' '\n' |
    awk -F= '/^ARGOCD_RECONCILIATION_TIMEOUT=/{print $2}')"
  if [ "$effective" = "20s" ]; then
    log "controller ARGOCD_RECONCILIATION_TIMEOUT=$effective"
  else
    warn "controller ARGOCD_RECONCILIATION_TIMEOUT=${effective:-<unset>}: the interval is still whatever the binary defaults to (180s)"
  fi
}

phase_rollouts() {
  fetch argo-rollouts-install.yaml \
    "https://github.com/argoproj/argo-rollouts/releases/download/${ARGO_ROLLOUTS_VERSION}/install.yaml" \
    "$ARGO_ROLLOUTS_INSTALL_SHA256"
  # Its own namespace, not argocd's: the manifest's ClusterRoleBinding binds the
  # ClusterRole to ServiceAccount argo-rollouts/argo-rollouts by name. Applied
  # into another namespace, the service account lands there, the binding keeps
  # pointing at a namespace where nothing exists, and the controller runs with
  # no permissions -- Rollouts are created, never reconciled, no error anywhere.
  create_namespace "$ROLLOUTS_NAMESPACE"
  kubectl -n "$ROLLOUTS_NAMESPACE" apply --server-side \
    -f "$CACHE_DIR/argo-rollouts-install.yaml" >/dev/null
  # An apply returns before the API server has finished building its rest
  # mapper for the new types, and a sync in that window fails on "no matches
  # for kind Rollout". Wait on the CRDs themselves instead of guessing a sleep.
  for crd in rollouts.argoproj.io analysisruns.argoproj.io analysistemplates.argoproj.io; do
    kubectl wait --for=condition=Established --timeout=120s "crd/$crd" >/dev/null \
      || die "$crd never became Established"
  done
  wait_namespace "$ROLLOUTS_NAMESPACE"
}

phase_applications() {
  log "Applications -> Argo CD starts watching both overlays"
  kubectl -n "$ARGOCD_NAMESPACE" apply -f "$APPLICATIONS_DIR" >/dev/null
}

phase_kyverno() {
  # The admission webhook is the only Kyverno component this project needs: it
  # is the thing that reads the cosign signature at CREATE time. The background,
  # cleanup and reports controllers scan existing objects and write PolicyReports
  # -- useful in a real cluster, four more deployments on a one-node kind cluster
  # that is already carrying Prometheus.
  log "kyverno $KYVERNO_CHART_VERSION (admission controller only)"
  create_namespace "$KYVERNO_NAMESPACE"
  # A run interrupted during an upgrade leaves the release at pending-upgrade,
  # and helm refuses to upgrade a release it still believes is mid-upgrade -- the
  # next attempt dies with "another operation is in progress" rather than with
  # anything about the real problem. The first time this happened, the upgrade was
  # the chart's post-upgrade kyverno-cli Job spending the whole 10m --timeout
  # stuck in ContainerCreating on an image no pre-pull list covered.
  local status
  status="$(helm -n "$KYVERNO_NAMESPACE" list -f "^$KYVERNO_RELEASE\$" -o json 2>/dev/null \
            | grep -o '"status": *"[^"]*"' | cut -d'"' -f4)"
  case "$status" in
    pending-*)
      warn "$KYVERNO_RELEASE is $status from an earlier run -- rolling back to the last deployed revision"
      helm -n "$KYVERNO_NAMESPACE" rollback "$KYVERNO_RELEASE" >/dev/null 2>&1 \
        || die "could not roll back a $KYVERNO_RELEASE left $status: helm -n $KYVERNO_NAMESPACE history $KYVERNO_RELEASE"
      ;;
  esac
  helm_install "$KYVERNO_RELEASE" "oci://ghcr.io/kyverno/charts/kyverno" "" \
    "$KYVERNO_CHART_VERSION" "$KYVERNO_NAMESPACE" \
    "$HELM_VALUES_DIR/kyverno.yaml" 10m
  # The webhook is a cluster-scoped admission hook: an apply that lands before
  # the Service has endpoints makes every matching CREATE fail with
  # "failed calling webhook". Wait for the endpoint, not just the pod.
  # kubernetes.io/service-name is put on every EndpointSlice by the endpoints
  # controller itself, so it does not depend on which labels the chart happens
  # to set this release. The Service is <release>-svc, not <release>-
  # admission-controller: the chart names the Deployment after the component and
  # the Service after the release, which is how this check failed its first run.
  local i
  for i in $(seq 1 90); do
    if kubectl -n "$KYVERNO_NAMESPACE" get endpointslices \
        -l "kubernetes.io/service-name=$KYVERNO_RELEASE-svc" \
        -o jsonpath='{.items[*].endpoints[*].addresses[*]}' 2>/dev/null | grep -q .; then
      log "kyverno webhook has an endpoint"
      return
    fi
    sleep 2
  done
  die "kyverno-svc never got an endpoint: kubectl -n $KYVERNO_NAMESPACE get pods,svc,endpointslices"
}

phase_policy() {
  log "ImageValidatingPolicy -> an unsigned gitops-demo image cannot be scheduled"
  kubectl apply -f "$KYVERNO_POLICY_DIR" >/dev/null
  # Kyverno registers the admission webhook itself, once it has its certificate,
  # and the policy reports that it happened: status.conditionStatus.ready is true
  # only after the WebhookConfigured condition does. That is the difference
  # between "policy applied" and "policy firing", so wait on it rather than on a
  # sleep -- an apply that lands before the webhook exists admits everything.
  local i
  for i in $(seq 1 60); do
    if [ "$(kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
            -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = "true" ]; then
      break
    fi
    sleep 2
  done
  kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
    -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null | grep -qx true \
    || die "the policy never became ready: kubectl -n $KYVERNO_NAMESPACE logs deploy/kyverno-admission-controller"
  # Belt and braces, and the name is the useful part: this policy's webhook is
  # ivpol.validate.kyverno.svc-fail, registered inside the *resource* validating
  # configuration next to the one protecting Kyverno's own generation labels.
  # `kubectl get validatingwebhookconfigurations kyverno` finds nothing at all.
  kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].name}' 2>/dev/null | grep -q ivpol.validate \
    || die "the ivpol webhook is not in kyverno-resource-validating-webhook-cfg: kubectl -n $KYVERNO_NAMESPACE logs deploy/kyverno-admission-controller"
  kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
    -o jsonpath='{.metadata.name} ready={.status.conditionStatus.ready} deny_on={.spec.validationActions}{"\n"}' \
    2>/dev/null || true
}

app_state() {
  kubectl -n "$ARGOCD_NAMESPACE" get application "$1" \
    -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null || echo "Pending"
}

wait_application() {
  local name="$1" state="" i
  for i in $(seq 1 60); do
    state="$(app_state "$name")"
    case "$state" in
      Synced/Healthy|Synced/Degraded|OutOfSync/*Degraded*) break ;;
    esac
    sleep 3
  done
  printf '%s %s\n' "$name" "$state"
}

phase_report() {
  log "waiting for the first sync"
  local app
  for app in gitops-demo-dev gitops-demo-prod; do
    state_line="$(wait_application "$app")"
    printf '   %s\n' "$state_line"
    case "$state_line" in
      *Synced/Healthy*) ;;
      *) warn "$app is not Synced/Healthy yet. In the Argo CD UI it shows which resource is missing; kubectl -n $ARGOCD_NAMESPACE get application $app -o yaml ends in .status.conditions." ;;
    esac
  done

  echo
  log "what is running"
  # no `head` here: with pipefail, the pipe closing early kills awk and fails a
  # run that actually succeeded.
  kubectl get pods -A --no-headers | awk '{printf "  %-18s %s\n", $1, $2}' | sort
  echo
  log "Argo CD UI"
  # Both passwords are read from Secrets the clusters generated themselves.
  # They are looked up defensively because this report runs the moment the last
  # pod is Ready, and the server may not have written its secret yet -- a
  # missing secret must not abort a bootstrap that worked, so a command to run
  # later is printed instead of a value.
  local argo_password grafana_service grafana_password
  argo_password="$(kubectl -n "$ARGOCD_NAMESPACE" get secret argocd-initial-admin-secret \
    -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  [ -n "$argo_password" ] || argo_password="(not generated yet: kubectl -n $ARGOCD_NAMESPACE get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)"
  echo "  1. kubectl -n $ARGOCD_NAMESPACE port-forward svc/argocd-server 8080:80"
  echo "  2. admin / $argo_password"
  echo "     (generated in the cluster, never stored in git)"
  echo
  log "Grafana"
  grafana_service="$(kubectl -n "$MONITORING_NAMESPACE" get svc -l app.kubernetes.io/name=grafana \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  grafana_password=""
  if [ -n "$grafana_service" ]; then
    grafana_password="$(kubectl -n "$MONITORING_NAMESPACE" get secret "$grafana_service" \
      -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)"
  fi
  echo "  kubectl -n $MONITORING_NAMESPACE port-forward svc/${grafana_service:-grafana} 3000:80"
  [ -n "$grafana_password" ] || grafana_password="(not generated yet: kubectl -n $MONITORING_NAMESPACE get secret ${grafana_service:-<grafana>} -o jsonpath='{.data.admin-password}' | base64 -d)"
  echo "  admin / $grafana_password"
  echo
  log "app URLs (add these to C:\\Windows\\System32\\drivers\\etc\\hosts first, as Administrator)"
  echo "  127.0.0.1  gitops-demo.local gitops-demo-prod.local"
  echo "  http://gitops-demo.local/health       dev"
  echo "  http://gitops-demo-prod.local/health  prod"
  echo "  without editing hosts: curl -H 'Host: gitops-demo.local' http://127.0.0.1/health"
  echo
  log "done"
}

# ------------------------------------------------------------------ dispatcher --

case "${1:-}" in
  --status)
    phase_preflight
    kind get clusters
    kubectl config current-context 2>/dev/null || die "no kube context yet -- run scripts/bootstrap.sh"
    kubectl get nodes
    helm list --all-namespaces
    kubectl -n "$ARGOCD_NAMESPACE" get application 2>/dev/null || true
    kubectl get pods -A --no-headers | awk '{print $1, $2, $3, $4}' | sort
    exit 0
    ;;
  --destroy)
    log "deleting kind cluster $CLUSTER_NAME"
    kind delete cluster --name "$CLUSTER_NAME"
    log "cluster gone. Nothing else was touched: the repos, the GHCR image and .tools are untouched."
    exit 0
    ;;
  --supply-chain)
    SUPPLY_CHAIN=1
    shift
    [ "${1:-}" = "" ] || die "usage: scripts/bootstrap.sh [--status|--destroy|--supply-chain]"
    ;;
  "") ;;
  *) die "usage: scripts/bootstrap.sh [--status|--destroy|--supply-chain]" ;;
esac

phase_preflight
phase_cluster
phase_prepull
phase_ingress
phase_monitoring
phase_argocd
phase_rollouts
phase_applications
if [ "$SUPPLY_CHAIN" = 1 ]; then
  phase_kyverno
  phase_policy
fi
phase_report
