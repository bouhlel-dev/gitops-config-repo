# config-repo — the desired state

This repository is the only way anything gets deployed. It holds the Kustomize
manifests for one FastAPI service, the Argo CD `Application` objects that watch
them, the scripts that build the cluster underneath, and the demos that prove
the whole chain works.

There is a second repository,
[gitops-app-repo](https://github.com/bouhlel-dev/gitops-app-repo), which holds
the application code and the CI that publishes its image. Neither repo can
deploy anything on its own: app-repo produces an image, this repo says what
should be running, and Argo CD is the only thing that touches the cluster.

```
app-repo commit -> CI: lint, test, build, scan, push, PR -> config-repo merge
                                                                   |
                                                       Argo CD syncs|
                                                                   v
                                        Rollout 10% -> 30% -> 60% -> 100%
                                             |          |
                                        Prometheus measures each step
                                             |
                                     bad -> abort and roll back
```

## Prerequisites

One machine, all free: **Docker Desktop**, **Git Bash** and **curl**. Nothing
needs admin rights except the cluster bootstrap's optional `hosts` entry. No
Make, no WSL, no package manager — every tool is a pinned binary downloaded into
`../.tools/bin`.

```bash
source scripts/env.sh          # puts the pinned toolchain on PATH for this shell
```

## One-command bootstrap

```bash
scripts/install-tools.sh       # kind, kubectl, helm, kustomize, gh, rollouts plugin, cosign
bash scripts/bootstrap.sh      # cluster + ingress + monitoring + Argo CD + Rollouts + apps
```

`bootstrap.sh` installs in dependency order — kind → ingress-nginx →
kube-prometheus-stack → Argo CD → Argo Rollouts → the two Applications — and is
safe to re-run: each phase checks its own end state, so a failed run is repaired
by running it again rather than by undoing anything. First run takes 15–25
minutes, almost all of it pulling images.

```bash
bash scripts/bootstrap.sh --status     # what is running, installs nothing
bash scripts/bootstrap.sh --destroy    # delete the kind cluster, touch nothing else
bash scripts/bootstrap.sh --supply-chain
```

`--supply-chain` is the bonus: it adds Kyverno's admission webhook and applies
the `ImageValidatingPolicy` that refuses a Pod whose image was not signed by
this pipeline. It is a flag and not the default because the policy denies at
admission, and applying it while an unsigned tag is the one being rolled out
stops that rollout mid-canary. See [docs/SUPPLY_CHAIN.md](docs/SUPPLY_CHAIN.md).

### Verify it worked

```bash
kubectl get nodes                                     # v1.34.11, Ready
kubectl -n argocd get application                     # both Synced/Healthy
curl -s -H 'Host: gitops-demo.local'      http://127.0.0.1/health   # dev
curl -s -H 'Host: gitops-demo-prod.local' http://127.0.0.1/health   # prod
kubectl -n gitops-demo-dev get pods -o jsonpath='{.items[*].spec.containers[0].image}'
```

UIs are port-forwards, not ingresses, so they need no credentials in git:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80   # admin + the secret it prints
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
```

[docs/argo-grafana-instructions.md](docs/argo-grafana-instructions.md) is the
browser runbook: where each password comes from, what to click to walk someone
through a release, and which ports to fall back to when 8080 and 3000 are taken.

## Layout

```
apps/gitops-demo/base/          the one copy of the truth: Rollout, Services,
                                Ingress, ServiceMonitor, AnalysisTemplate
apps/gitops-demo/overlays/dev/  10 replicas, host gitops-demo.local, APP_ENV=dev
apps/gitops-demo/overlays/prod/ 20 replicas, host gitops-demo-prod.local
bootstrap/kind/                 the kind cluster config (port mappings)
bootstrap/helm/                 values for ingress-nginx, the monitoring stack,
                                and Kyverno
bootstrap/argocd/applications/  the two Application objects
bootstrap/kyverno/              the ImageValidatingPolicy that refuses an unsigned image
scripts/bootstrap.sh            the one command
scripts/install-tools.sh        the pinned toolchain
scripts/loadgen.py              the traffic the analysis is measured on
scripts/dora.py                 the four DORA keys, from git and AnalysisRuns
scripts/demo-*.sh               the four demo scenarios
versions.env                    every version in the chain, pinned, with checksums
```

## How a release arrives

1. A commit lands on `app-repo` `main`.
2. CI lints and tests inside the image's own base image, builds it, scans it with
   Trivy, and **only then** pushes `ghcr.io/bouhlel-dev/gitops-demo:<git sha>`.
   `latest` is never pushed alone: the tag is the commit, so an image can always
   be traced back to the code that produced it.
3. CI signs the pushed digest with cosign, keyless, and reads the signature back
   with the same two strings the in-cluster policy checks. A signature the
   registry will not serve is a red build, not a release no pod can start.
4. CI runs `kustomize edit set image` on `apps/gitops-demo/base`, re-renders to
   check the tag really is in both overlays, opens a PR against this repo and
   squash-merges it. That merge is the deployment approval.
5. Argo CD notices the new commit, diffs it against the cluster, and syncs.
6. Argo Rollouts walks the new ReplicaSet 10 → 30 → 60 → 100, and Prometheus
   decides at three gates whether it is allowed to continue.

Nothing in CI ever runs `kubectl`. Nothing in this repo contains application
code. A rollback is a `git revert`, not a `kubectl rollout undo`.

## The canary, and what actually stops a bad release

`base/analysistemplate.yaml` asks Prometheus two questions about **the canary's
own pods only**, filtered by pod-template hash *and* namespace — dev and prod
share one Prometheus and an identical pod template produces an identical hash, so
the namespace filter is not optional:

| Gate | Query | Threshold |
|---|---|---|
| success rate | `rate(http_requests_total{...status!~"5.."}) / rate(http_requests_total{...})` | ≥ 0.99 |
| p95 latency | `histogram_quantile(0.95, ...)` | < 0.5 s |

Four samples at 15-second intervals per gate, `failureLimit: 0`, and an empty
result counts as a failure. Measured values from a real gate: p95 `[0.00475]`
(4.75 ms) and success rate `[1]`, both `Successful` — see `docs/DEMO.md` for how
to read them yourself.

Two consequences worth stating plainly:

- **An AnalysisTemplate with no traffic is a broken AnalysisTemplate.** No
  requests means no series means an empty result means an aborted release that
  was never given a chance. `scripts/loadgen.py` is part of the demo, not a
  prop.
- **The two gates catch different failures.** The faulty release in
  `demo-bad-release.sh` errors on nothing at all — its success rate stays at
  100% while its p95 doubles past the threshold. A pipeline with only a
  error-rate gate would have promoted it.

## Versions

Everything is pinned in [`versions.env`](versions.env) with the sha256 of each
downloaded artifact: the kind node image, Kubernetes, Helm 4, Kustomize, Argo CD,
Argo Rollouts, `gh`, Trivy, both chart versions and the ten infra images the
monitoring stack pulls. CI sources the same file, so a tool version is declared
once for the whole chain instead of drifting between a workflow and a script.

Checksums come from upstream release metadata rather than from re-downloading the
artifact, and Windows and Linux builds have separate digests (`FOO_SHA256` and
`FOO_SHA256_LINUX`) because CI runs on `ubuntu-24.04` while the laptop does not.

## Secrets

No plaintext secret exists in either repository.

| Secret | Where it lives |
|---|---|
| `CONFIG_REPO_TOKEN` (fine-grained PAT, Contents: RW + Pull requests: RW on this repo only) | GitHub Actions secrets of app-repo |
| GHCR push credential | the built-in `GITHUB_TOKEN`, via `packages: write` |
| Argo CD admin password | generated in-cluster as a Secret; printed by bootstrap, never committed |
| Grafana admin password | generated in-cluster; the values file deliberately sets no `adminPassword` |
| App credentials | none — the demo service authenticates nobody |

The PAT is scoped to one repository and two permissions. Rotating it is a
`gh secret set` and a delete in GitHub settings; nothing in git changes.

## The four demos

```bash
bash scripts/demo-good-release.sh    # a release nothing objects to: commit -> 100%
bash scripts/demo-bad-release.sh     # a 600 ms regression CI cannot see; the p95 aborts it
bash scripts/demo-drift.sh           # one kubectl patch, reverted by reconciliation
bash scripts/demo-supply-chain.sh    # an unsigned image cannot start; the signed one can
```

Each is a real release: they commit to app-repo and let the pipeline run. The
good one took 729 s (twelve minutes), the bad one 864 s end to end because it
ships the fault *and* the fix. `docs/DEMO.md` is the narrated walkthrough with the
output each step produces.

`demo-bad-release.sh` is the interesting one, and it is interesting because of
what does **not** happen: ruff says nothing, pytest passes (28 tests, none of
them measure a duration), Trivy finds nothing to flag, the image builds, the scan
is clean, CI publishes it and the promotion PR merges. Every gate in the classic
pipeline approves the regression. The first component in the chain that disagrees
is the p95 of one canary pod.

## Deliberate choices, and what they cost

- **Kustomize, not Helm**, for the app. The overlays are two files and a replica
  count; a Helm chart would add templating to express a diff of three values.
  The cost is no library of parameterised components, which this project does not need.
- **Infrastructure is installed out of band, not by Argo CD.** Argo CD cannot
  manage the components it needs in order to exist. The consequence is real:
  selfHeal reverts `apps/gitops-demo/` and nothing else, so a hand-run
  `helm upgrade` against ingress-nginx is never undone. `demo-drift.sh` says so out loud.
- **`ignoreDifferences` on `/spec/selector` of the two traffic Services.** Argo
  Rollouts rewrites those selectors to pin each Service to a pod-template hash —
  that is what makes the split real. Without the two entries selfHeal fights the
  controller every 20 seconds and quietly routes all traffic to all pods.
- **NodePort + `extraPortMappings` instead of a LoadBalancer.** kind on Docker
  Desktop has no LoadBalancer implementation, so `spec.type: LoadBalancer` parks
  at `<pending>` forever. The cost is that the demo depends on host ports 80/443
  being free; `bootstrap.sh` names the conflict and the two files to change when it happens.
- **10 replicas in dev, 20 in prod** so that 10% of traffic is exactly one pod.
  A two-replica dev environment cannot show a 10% canary at all. The cost is 30
  pods on a laptop, which is why the monitoring stack is trimmed.
- **A trimmed kube-prometheus-stack**: no Alertmanager, no node-exporter, no
  control-plane components. Prometheus, Grafana and kube-state-metrics only.
  Retention 2 days. The full stack exists to page someone at 3 a.m., which this
  project does not do.
- **Trivy blocks on HIGH and CRITICAL with `--ignore-unfixed`.** Without it a
  Debian patch that upstream has not released yet fails the build forever. The
  trade-off is real: a vulnerability with no fix ships, and the alternative is a
  pipeline that is red for reasons no one can act on.
- **20-second reconciliation** instead of 180. A demo where nothing visibly
  happens for three minutes is not a demo. The cost is more API queries, which on
  one cluster and two Applications is noise. Note that Argo CD's install manifest
  wires `ARGOCD_RECONCILIATION_TIMEOUT` from `argocd-cm`, while the documentation
  calls `timeout.reconciliation` a key of `argocd-cmd-params-cm` — `bootstrap.sh`
  patches both and then reads the value back from the running process.
- **Public repos and a public image.** A reviewer can clone and run it. The cost
  is that the GHCR image is readable by anyone, which for a demo with no secrets
  and no data is acceptable, and is exactly the reasoning a real team would have
  to write down.

## Limitations

- Single-node kind: no HA, no real ingress TLS, no topology spread. The canary
  split is HTTP-header/weight based (ingress-nginx annotations), not a mesh.
- Analysis uses *metric* thresholds only, no ingress/gateway-level request
  mirroring and no `mirrorPodCount` style A/B comparison.
- Both environments promote from the same image tag, so dev and prod move
  together. Giving each overlay its own `images:` block is the documented way to
  version them apart, and the trade-off is a longer release train.
- The demo service has no database, so this project says nothing about migration
  orchestration, which is where GitOps usually gets hard.
- CI signs every image it publishes, but **nothing checks that signature unless
  `bootstrap.sh --supply-chain` has run**, and even then only at admission in
  the two app namespaces, only on CREATE. A `kubectl set image` against a running
  pod — one of the few fields Kubernetes lets you change in place — reaches an
  unsigned tag unchecked; measured, not theorised. The transparency log is part
  of the check — Rekor is what makes "this certificate was issued for that
  identity on that date" verifiable rather than merely plausible — but there is
  no SBOM and no SLSA provenance, so the certificate says "this workflow, this
  ref", not "this build is reproducible". `docs/SUPPLY_CHAIN.md` states where
  that line is, and why the policy is not a `ClusterPolicy`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `kind could not create the cluster ... port 80` | Something on Windows owns 80/443. Change `hostPort` in `bootstrap/kind/gitops.yaml` **and** `nodePorts` in `bootstrap/helm/ingress-nginx.yaml` together. |
| `Progress deadline exceeded` on grafana during bootstrap | A slow image pull, not a broken chart. `bootstrap.sh` retries and then decides by pod readiness; re-running it finishes the job. |
| `ctr: content digest ... not found` from `kind load` | containerd holds a content lock while the node pulls the same image. Harmless: the phase warns and carries on. |
| App stuck `OutOfSync` with a diff on `/spec/selector` | The `ignoreDifferences` entries were removed. Rollouts owns those selectors. |
| AnalysisRun `Failed` with an empty value | No traffic. Run `scripts/loadgen.py` first. |
| Grafana rejects the admin password `bootstrap.sh` printed | The password is in the Secret, but Grafana's SQLite DB sits in an `emptyDir` and a password changed through the UI outranks `GF_SECURITY_ADMIN_PASSWORD` from then on. `kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana`: the fresh DB is initialized from the Secret, so the printed password is correct again. The sidecar dashboards come back from ConfigMaps; anything you built by hand in the UI is in that DB and is gone, which is the same argument for keeping dashboard JSON in git as for everything else here. |
| `Application ... unknown field "spec.syncPolicy.retry.backoff.maxSteps"` | Argo CD 3.x rejects unknown fields. The key is `retry.limit`, a sibling of `backoff`. |
| CI push `403 denied to github-actions[bot]` | The config-repo checkout lost its `token:` input, so Git fell back to the runner's `GIT_ASKPASS`, which vends the bot token. |
| `Unable to connect to the server: TLS handshake timeout` | The single API server is momentarily saturated (30 app pods plus watches). Retry; if persistent, `docker info --format '{{.MemTotal}}'` to check the VM has room. |
