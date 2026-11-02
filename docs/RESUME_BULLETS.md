# Résumé bullets — this project

Written so that every claim survives being asked "how did you measure that?".
Numbers are from real runs on this cluster; the command that produces each one is
listed, so nothing here is a figure that cannot be re-derived in an interview.

## Long version (project block, 5 bullets)

**GitOps CI/CD pipeline with metric-driven canary analysis and automatic
rollback** — Kubernetes (kind, v1.34.11), Argo CD v3.5.6, Argo Rollouts v1.10.1,
ingress-nginx, Prometheus v0.94.2, Grafana, GitHub Actions, GHCR, Kustomize,
Trivy, Python/FastAPI.

- Designed and built a two-repository delivery chain — application code and CI on
  one side, declarative desired state and Argo CD `Application` objects on the
  other — so that the only path from a commit to a running pod is a merged commit
  in the configuration repo, and CI holds no cluster credentials at all.
- Implemented a progressive-delivery rollout (10 → 30 → 60 → 100 % with a manual
  approval at 10 %) gated by an `AnalysisTemplate` that queries Prometheus for the
  canary's own success rate and p95 latency: 4 samples per gate at 15 s intervals
  with `failureLimit: 0`, aborting and scaling the canary to zero automatically.
- Validated the gate with a regression that every pre-deployment stage approves:
  ruff clean, 28/28 tests passing, image built, Trivy HIGH/CRITICAL scan clean,
  published and promoted — with the canary's p95 the first component in the chain
  to reject it. Contrast case measured against a healthy canary at p95 4.75 ms
  versus the 500 ms threshold.
- Built the cluster from a single script (`bootstrap.sh`) with a re-runnable,
  phase-checked design: kind on Docker Desktop with `extraPortMappings` (no
  LoadBalancer implementation exists), a trimmed kube-prometheus-stack, Argo CD
  applied server-side, Rollouts CRDs waited on as `Established` before the first
  sync, and reconciliation tuned for live demonstration (measured drift reversion
  in 3 s via `selfHeal`).
- Pinned 12 tool and chart versions plus 10 infrastructure images with 12 sha256
  checksums in one `versions.env` consumed by both the local scripts and CI, and
  instrumented the four DORA keys from git history and `AnalysisRun` timestamps
  (`dora.py`) rather than from a dashboard screenshot.

## Short version (2 bullets, for a crowded page)

- Built a GitOps delivery chain (GitHub Actions → GHCR → Argo CD → Argo Rollouts)
  where a commit becomes a deployment only through a merged configuration-repo
  commit, and CI never touches the cluster.
- Gated canary promotion on Prometheus-measured success rate and p95 per pod-hash;
  demonstrated an automatic rollback for a latency regression that passed lint,
  28 tests, the image build and a Trivy HIGH/CRITICAL scan.

## One-line version (summary section of the CV)

Kubernetes delivery automation with Argo CD and metric-driven canary analysis —
including the failure cases, measured.

## Skills tags to pair with the block

`Kubernetes` `GitOps` `Argo CD` `Argo Rollouts` `GitHub Actions` `Prometheus /
Grafana` `Kustomize` `Helm` `container security (Trivy)` `FastAPI` `Docker`
`bash` `CI/CD` `progressive delivery` `observability` `software supply chain
(Cosign, Kyverno)` `DORA metrics`

## Interview-proofing: the follow-up question for each bullet, and the answer

**"You say the pipeline couldn't catch it — what would have?"**
Nothing upstream of deployment, by construction: the fault is a latency value in a
code default. The honest answers are longer soaks, synthetic transactions that hit
the slow path, error-budget-based promotion, or load-aware canary analysis — none
of which is a static check.

**"Why filter by pod-template hash *and* namespace?"**
Because dev and prod run in one cluster against one Prometheus, and an identical
pod template produces an identical hash. Hash alone would blend the two
environments' metrics.

**"What happens if Prometheus is down during a release?"**
The query returns an empty result, an empty result is a failed measurement, and
the rollout aborts. It fails shut. That is a deliberate choice: a canary nobody
measured is not a healthy canary.

**"Why did you leave a manual pause at 10 %?"**
`pause: {}` versus `pause: {duration: 30s}` is the human-in-the-loop decision. The
metrics gate still runs after it, so the demo shows that the gate catches a release
a human already approved.

**"What does selfHeal *not* protect you from?"**
Anything outside the Application's tree. The ingress controller and the monitoring
stack were installed out of band because Argo CD cannot manage the components it
needs in order to exist, so a hand-run `helm upgrade` there is never reverted. A
resource created by hand in the app namespace, never in git, is not pruned either.

**"Why not Helm for the app?"**
The dev/prod difference is a replica count and a hostname. Kustomize expresses
that as an overlay; a chart would add templating to describe a three-value diff.

**"Your canary is one pod. Is that enough traffic to measure?"**
Not always — which is why the load generator is part of the pipeline story, not a
prop: 20 rps per environment, roughly 34 000 requests behind a single release. A
canary with no requests returns no data and the gate fails the release for the
wrong reason.

**"What broke while building this?"**
Four things worth naming: `helm --wait` failing on `progressDeadlineSeconds`
during slow pulls rather than on anything wrong with the chart; Argo CD's install
manifest wiring `ARGOCD_RECONCILIATION_TIMEOUT` to a different ConfigMap than the
documentation implies (measured 5 m 21 s of dead time before the fix); selfHeal
fighting Argo Rollouts over rewritten Service selectors until
`ignoreDifferences` was added; and a `git push` from CI being answered with
`403 denied to github-actions[bot]` because the runner's `GIT_ASKPASS` outranks
everything unless the token is installed by the checkout step.

## Where each number came from

| Claim | Command |
|---|---|
| 28 tests, all green | `pytest -q` |
| p95 4.75 ms, success rate 1.00 | `kubectl -n gitops-demo-dev get analysisrun <name> -o json` |
| canary walk 4 m 34 s | timestamps in `kubectl -n gitops-demo-dev get analysisruns` |
| drift reverted in 3 s | `bash scripts/demo-drift.sh` |
| CI ~90 s warm | `gh run view <id>` |
| 12 version pins, 10 images | `grep -c _SHA256 versions.env` |
| ~34 000 requests per release | `scripts/loadgen.py` final summary |
