# Résumé bullets — this project

Written so that every claim survives being asked "how did you measure that?".
Numbers are from real runs on this cluster; the command that produces each one is
listed, so nothing here is a figure that cannot be re-derived in an interview.

## Long version (project block, 6 bullets)

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
- Pinned every tool, chart, image and install manifest in one `versions.env` —
  versions plus sha256 digests for both the laptop (Windows) and CI (Linux),
  consumed by the local scripts and the workflow alike — and instrumented the
  four DORA keys from git history and `AnalysisRun` timestamps (`dora.py`) rather
  than from a dashboard screenshot.
- Added an admission-time supply-chain control: CI signs each pushed **digest**
  keyless with cosign (Fulcio certificate issued from the runner's GitHub OIDC
  token, subject pinned to `repo:workflow-file:ref`, so no signing key exists to
  leak or rotate), reads the signature back with the same issuer + subject the
  cluster uses, and a Kyverno `ImageValidatingPolicy` in `Deny` mode with
  `failurePolicy: Fail` refuses any Pod in the two app namespaces whose image
  carries no such signature — demonstrated by applying one manifest twice, the
  unsigned tag denied at admission and the signed one reaching `Ready`.

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

**"Your signature proves who built the image. Suppose the build itself lied?"**
Then the signature is valid and the image is still whatever the workflow produced
— keyless answers *who*, not *what*. Closing that needs SLSA provenance or an
attested build pipeline plus a policy that reads the attestation, and here
`mutateDigest: false` leaves one more window open: verification runs against
whatever the tag resolves to at admission, so pinning the verified digest into
the pod spec is the stronger setting I deliberately did not take, because it
breaks the property that a running pod's image string matches what git says.

**"Why is the admission policy `Deny` with `failurePolicy: Fail`?"**
`Audit` writes a report and lets the pod run, which proves nothing. `Fail` is
the safe direction for a control, and the reason its match is two namespaces
instead of the cluster: with `Fail` and a dead webhook, a cluster-wide policy
prevents the control plane from rescheduling its own pods. The scope is the
trade-off, and it is a limitation as much as a feature — a pod outside those two
namespaces is unchecked. One more number belongs to that answer: the webhook
timeout is 30 s, the maximum, because verifying a tag means resolving it at GHCR
and then reading a Rekor entry, and on a cold cache that does not fit in the 10 s
default — a timed-out webhook is a denied pod for an image that verifies
perfectly.

**"What broke while building this?"**
Seven things worth naming: `helm --wait` failing on `progressDeadlineSeconds`
during slow pulls rather than on anything wrong with the chart; Argo CD's install
manifest wiring `ARGOCD_RECONCILIATION_TIMEOUT` to a different ConfigMap than the
documentation implies (measured 5 m 21 s of dead time before the fix); selfHeal
fighting Argo Rollouts over rewritten Service selectors until
`ignoreDifferences` was added; a `git push` from CI being answered with
`403 denied to github-actions[bot]` because the runner's `GIT_ASKPASS` outranks
everything unless the token is installed by the checkout step; and a Kyverno
readiness check that never passed because the chart names its Deployment
`kyverno-admission-controller` but its Service `kyverno-svc` — the endpoint
existed the whole time, the label selector was looking for a Service that does
not. The last two are the ones I would tell an interviewer about. Kyverno 1.10
denied every pod, signed images included, and its own log said `initializing tuf:
invalid key`: the version pinned for the chart still bootstrapped keyless trust
from a Sigstore root that has since been retired, so a stale pin was a silent
security failure rather than an old feature set. And after fixing that, the
policy still refused an image that `cosign verify` accepted on the same laptop —
cosign v3 publishes a signature as an OCI 1.1 referrer, GitHub's registry does
not implement the Referrers API, so cosign falls back to a tag named
`sha256-<digest>` in the same repository; the older `ClusterPolicy` API reads the
pre-v3 nested `.sig` repository and finds nothing, while the newer
`ImageValidatingPolicy` follows the fallback tag. Both symptoms looked like
signature problems; neither was a signature.

## Where each number came from

| Claim | Command |
|---|---|
| 28 tests, all green | `pytest -q` |
| p95 4.75 ms, success rate 1.00 | `kubectl -n gitops-demo-dev get analysisrun <name> -o json` |
| canary walk 4 m 34 s | timestamps in `kubectl -n gitops-demo-dev get analysisruns` |
| drift reverted in 3 s | `bash scripts/demo-drift.sh` |
| CI ~90 s warm | `gh run view <id>` |
| 14 tool digests, 13 pinned images | `grep -c _SHA256 versions.env`, `grep -cE '^  [a-z0-9.-]+/' versions.env` |
| ~34 000 requests per release | `scripts/loadgen.py` final summary |
| every published image is signed | `gh run view --repo bouhlel-dev/gitops-app-repo --log \| grep "Pushing signature"` |
| an unsigned image cannot be scheduled | `bash scripts/demo-supply-chain.sh` (one Pod manifest, applied twice) |
| the signature verifies against one identity | step 2 of `bash scripts/demo-supply-chain.sh` — cosign's exit code against the pinned issuer + subject regexp, and against a deliberately wrong ref |
| Kyverno installs in ~4 min including both image pulls | `bash scripts/bootstrap.sh --supply-chain` |
