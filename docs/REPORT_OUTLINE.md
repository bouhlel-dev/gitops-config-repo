# Report outline

Structure for the written submission. Each section says what it must *argue*, not
only what it must describe, because a report on a pipeline is judged on whether
the author can say why each piece is there.

Word counts are suggestions for a 12 000-word document; cut 5 before cutting 1, 2 or 7.

---

## 1. Abstract (150 words)

One paragraph, no citations. Claim only what section 6 measures: continuous
delivery from a commit to a Kubernetes cluster with an automatic rollback
decision made on observed metrics rather than on a human reading a dashboard.
State the environment honestly: single-node kind on a laptop, free tools, two
public repositories.

## 2. Introduction and problem statement (800)

- The failure mode being addressed: a deployment pipeline that gates on
  *artefact* properties — does it build, do tests pass, are there vulnerabilities
  — and then ships to production on the strength of those, without any check on
  the behaviour of the thing it just deployed.
- Why that gap exists: pre-deployment gates are cheap to evaluate and metrics
  need a live environment.
- The two claims under test: (i) git as the single source of truth is workable
  end-to-end on free tooling; (ii) a post-deployment metric gate can be made
  strict enough to catch a regression that every pre-deployment gate approves.
- Scope and non-goals, stated early: no multi-cluster, no real traffic, no
  secrets management beyond "not in git", no database.

## 3. Background (1 500)

Push versus pull deployment, and why a pull controller (Argo CD) changes the
failure model: the cluster converges toward git instead of being told once.
GitOps principles (declarative, versioned, automatically applied, continuously
verified) mapped onto which file in this project implements each. Progressive
delivery patterns: recreate, rolling, blue/green, canary, and where
analysis-driven promotion sits relative to a fixed bake time. Argo Rollouts'
canary model and why weight-based traffic needs an Ingress controller that
implements it. DORA: define the four keys and cite where each is computed from
in this project (`scripts/dora.py`), because a metric definition that does not
name its data source is a slogan.

## 4. Design and implementation (3 000)

Four subsections, each ending with the trade-off it accepted.

**4.1 Two repositories.** Why code and configuration have different review
cadences and different blast radii; what CI is allowed to write (a commit) and
what it is never allowed to write (a cluster object). Include the promotion
contract: `kustomize edit set image`, the render guard that greps the *rendered*
overlays for the tag, PR, squash merge.

**4.2 The pipeline.** Stage table with what each one can actually reject. Be
explicit that Trivy gates the push rather than the deploy, and that
`--ignore-unfixed` trades a permanently-red build for shipping a vulnerability
with no patch available.

**4.3 The cluster.** Bootstrap order and its dependency logic — the Applications
must be applied last because the first sync needs the Rollouts CRDs *Established*
and Prometheus already scraping. NodePort plus `extraPortMappings` because kind
has no LoadBalancer implementation; the trade-off against host-port ownership.

**4.4 Progressive delivery and the analysis.** The Rollout step list; why 10
replicas makes 10% exactly one pod; the two PromQL queries and why each is
filtered by pod-template hash *and* namespace; why an empty result is treated as
a failure; why `/metrics` is excluded from instrumentation; why the health probe
never fails on an injected fault (a probe that fails removes the canary from the
Service endpoints and starves the analysis of the traffic that would prove the
version bad).

Include the diagram from `docs/ARCHITECTURE.md` and the release sequence.

## 5. Evaluation method (800)

How the system was exercised rather than merely run: four scripted scenarios,
each a real release; load generation as a precondition of the measurement, not an
afterthought; what was measured and with which command. Say plainly that the
sample is small — one regression, one drift event, a handful of releases — so the
DORA figures illustrate the instrumentation, they do not establish rates.

## 6. Results (1 800)

Tables of measured values. Every number must be reproducible from a listed
command.

| Measurement | Result | Reproduce with |
|---|---|---|
| CI, commit → image published + promotion merged | ~90 s warm, ~4 min cold | `gh run view <id>` |
| Merged config-repo commit → Argo CD acts | 5 m 21 s with the wrong ConfigMap patched; seconds after the fix | `bootstrap.sh` report line |
| Full canary, promoted at 10% → Healthy at 100% | 4 m 34 s | `kubectl argo rollouts get rollout -w` |
| Gate samples per stage | 4 at 15 s, `failureLimit: 0` | `kubectl get analysisrun -o json` |
| p95 on a healthy canary | 0.00475 s against a 0.5 s threshold | `analysis_detail` in `demo-lib.sh` |
| Success rate on a healthy canary | 1.00 against a 0.99 threshold | same |
| Traffic behind one release | ~34 000 requests, 26 transport errors | `scripts/loadgen.py` summary |
| Hand-patched ConfigMap → reverted | 3 s | `scripts/demo-drift.sh` |
| Faulty release → abort | 277 s from push to abort. The gate's first p95 sample read 0.886 s against the 0.5 s threshold and `failureLimit: 0` ended the run on the spot; the success rate stayed at 1.00 all the way through, because the fault was latency and not errors | `bash scripts/demo-bad-release.sh` |
| Faulty release → healthy again | 9 m 48 s from the abort to the corrected release finishing its canary at 100%; 864 s from pushing the revert to both apps Healthy | `python scripts/dora.py --days 1` |
| DORA, this window | 5 releases, lead time median 81 s, 1 of 12 analysis runs Failed, gap between releases median 8 m 50 s | `python scripts/dora.py --days 1` |

The centre of gravity of this section is the bad release: ruff passes, pytest
passes (28 tests, none measures a duration), the build succeeds, Trivy reports
nothing, CI publishes, the promotion PR merges — and the first component in the
chain that objects is the p95 of one canary pod. That single row is the argument
for the entire design.

## 7. Discussion (1 200)

- **What the gate cannot see.** Metrics are lagging indicators over a 1-minute
  window: a regression that appears only in a rare code path, under a payload
  size the load generator does not produce, or after the analysis window closes,
  is not caught by anything here. Say what would catch it (longer soak, synthetic
  canary transactions, log-based signals, error-budget policies).
- **Failing shut is not free.** An AnalysisTemplate with no traffic aborts every
  release. The design chose "no signal means no promotion"; the alternative (no
  signal means proceed) is worse, but the consequence — that a Prometheus outage
  blocks deployments — has to be a deliberate decision, not a surprise.
- **Two gates, two failure kinds.** A success-rate gate alone would have promoted
  the latency regression in section 6. Argue the general point: a gate measures
  exactly what it measures.
- **selfHeal's scope is the boundary of git's authority.** Infrastructure
  installed out of band is invisible to it. Discuss the GitOps purity alternative
  (Argo CD Application-of-Applications, or managing the Helm releases through
  Argo CD with `syncWave`s) and why it was not done here: Argo CD cannot
  reconcile the components it needs to exist, and bootstrapping that is a
  separate problem.
- **Human-in-the-loop at 10%.** One manual pause is left deliberately. The
  trade-off: `pause: {duration: 30s}` would make the pipeline fully unattended,
  and the demo would be less able to show *why* a gate is worth waiting for.
- **Security posture.** No secret is in either repository; the promotion
  credential is a single-repository fine-grained PAT; CI never holds cluster
  credentials at all — which is the real security argument for the pull model,
  independent of GitOps purity.

## 8. Limitations (600)

Short, factual, no hedging: single node; laptop-class resources that caused real
flakiness (etcd request timeouts, progress-deadline failures during pulls, one
API-server TLS handshake timeout under 30 pods plus watches); both overlays
promote from the same tag so dev and prod move together; no TLS; no policy
engine before the optional Cosign/Kyverno step; a demo service with no state, so
nothing here exercises migrations.

## 9. Conclusion (400)

Restate the two claims and answer each with the evidence. The second one is the
interesting result: the pipeline was not made smarter, a check was added after
deployment where the behaviour is observable, and that check caught what every
earlier stage approved.

## 10. References

Argo CD and Argo Rollouts documentation, the GitOps working definition, the four
keys, ingress-nginx canary annotations, Cosign/Sigstore, Kyverno. Pin versions
cited from `versions.env` rather than from a moving doc.

## Appendix A — Reproduction

`scripts/install-tools.sh`, `bash scripts/bootstrap.sh`, the three demo scripts,
exact verify commands, expected output, and the four things that go wrong on a
fresh machine (host ports taken, slow pulls, the reconciliation ConfigMap, PAT
scope).

## Appendix B — Everything pinned

`versions.env` in full with the checksum policy explained: Windows and Linux
digests for the same tool, digests taken from upstream release metadata rather
than from a re-download.

## Appendix C — Artifacts

Two commit pairs: the faulty release (`ac68d20`) and the automatic abort; the
drift patch and its reversion. `git log` plus the corresponding AnalysisRun JSON.
