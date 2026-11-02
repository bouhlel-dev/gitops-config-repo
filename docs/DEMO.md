# Demo walkthrough

Four scripted scenarios, each one a real release or a real tamper, run against
the cluster `bootstrap.sh` built. Every block of output below was captured on
this machine, not written by hand — the commands that produced it are printed
above each block.

Read the *what you point at* line in each step before you speak: the demo fails
not when the pipeline breaks but when the audience cannot see the thing that
just happened.

---

## Before the demos: three checks

```bash
cd config-repo
source scripts/env.sh
bash scripts/bootstrap.sh --status
```

Expected, with the ages whatever they are:

```
==> cluster gitops exists
NAME                   STATUS   ROLES           AGE    VERSION
gitops-control-plane   Ready    control-plane   4h5m   v1.34.11
```

Then confirm the two Applications and the two entrypoints:

```bash
kubectl -n argocd get application
curl -s -H 'Host: gitops-demo.local'      http://127.0.0.1/health
curl -s -H 'Host: gitops-demo-prod.local' http://127.0.0.1/health
```

```
NAME               HEALTH        SYNC
gitops-demo-dev    Healthy       Synced
gitops-demo-prod   Healthy       Synced
{"status":"ok","version":"0.1.0","environment":"dev"}
{"status":"ok","version":"0.1.0","environment":"prod"}
```

`/health` is the one endpoint that answers even when the app is sick. That is
deliberate: a readiness probe that fails on an injected fault takes the canary
out of the Service endpoints, which starves the analysis of exactly the traffic
that would prove the version bad.

Open the dashboards you will switch to while the scripts run:

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80        # admin pw: argocd admin initial-password -n argocd
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

The Argo Rollouts dashboard is not installed — it is a fourth Deployment on a
one-node cluster, and `kubectl argo rollouts get --watch` prints the same state
machine in a terminal, which is faster to read on a projector.

---

## Scenario 1 — a release nothing objects to

```bash
bash scripts/demo-good-release.sh
```

The change is a line in `RELEASES.md`: no behaviour, so nothing in the diff
competes with the pipeline for attention. Twenty requests per second are offered
to both environments for the whole run, because a canary Prometheus has never
seen returns an empty result and the gate reads an empty result as a failure.

What the script prints, and what each part means:

```
[1] what is live right now
  gitops-demo-dev    ghcr.io/bouhlel-dev/gitops-demo:61627bf
  gitops-demo-prod   ghcr.io/bouhlel-dev/gitops-demo:61627bf
==> note the tag: it is a commit from app-repo, not a build number

[2] generating the traffic the canary will be measured on
==> traffic -> all: 20 rps for 1200s (pid 12650)
  a sample request through the ingress:
    {"service":"gitops-demo","version":"61627bf","environment":"dev", … }

[3] a change worth reviewing, and nothing else
==> pushed 0542eb1 to bouhlel-dev/gitops-app-repo

[4] CI: lint, test, build, scan, publish, promote
==> CI run 41523662335
==> CI green: ghcr.io/bouhlel-dev/gitops-demo:0542eb1 published,
    promotion merged into bouhlel-dev/gitops-config-repo

[5] Argo CD picks it up (reconciles every 20s)

[6] canary at 10%, paused for a human -- in both environments
==> gitops-demo-dev is serving 10% of traffic (Paused)
  one pod of ten carries the new version:
    NEW gitops-demo-f4668d66d-rwbwc
    old gitops-demo-f95f867d7-554wc
    … nine more old
==> promoted (the human decision in gitops-demo-dev)
==> gitops-demo-prod is serving 10% of traffic (Paused)
  two pods of twenty carry it there:
    NEW gitops-demo-7b579b9d75-stn9k
    NEW gitops-demo-7b579b9d75-v7skh
    … twenty old
==> promoted (the human decision in gitops-demo-prod)

[7] 30% -> 60% -> 100%, each gate measured
==>   weight=10% phase=Progressing
==>   weight=30% phase=Paused
==>   weight=60% phase=Paused
==>   weight=0% phase=Missing
==>   weight=60% phase=Progressing
==>   weight=100% phase=Paused
==>   weight=0% phase=Healthy

[8] every pod in both environments runs the new image
  gitops-demo-dev    10 of 10 pods on :0542eb1
  gitops-demo-prod   20 of 40 pods on :0542eb1
  gitops-demo-69f5cccdd6-4-4                     Failed
  gitops-demo-f4668d66d-8-10                     Successful
  gitops-demo-f4668d66d-8-4                      Successful
  gitops-demo-f4668d66d-8-7                      Successful
  gitops-demo-f95f867d7-7-10                     Successful
  gitops-demo-f95f867d7-7-7                      Successful

==> good release delivered in 729s: commit -> image -> PR -> sync -> canary -> 100%
==> release 0542eb1 is live in both namespaces, and no one typed kubectl apply
```

Step 1 prints the image each namespace is running, read from the Rollout's own pod
template rather than from a pod name — names carry the pod-template hash, which
changes even when the tag does not.

Step 6 is two pauses, not one. The indefinite `pause: {}` is defined once, in
`base/rollout.yaml`, so dev and prod both stop at 10 % and both need a person:
one pod of ten in dev, two of twenty in prod. The script answers both, which is
the whole of the human's role in this pipeline.

The `weight=0% phase=Missing` line in the middle of step 7 is real output, not a
typo: the watch loop reads `status.canary.currentStepWeight` and `status.phase`
every couple of seconds, and one of those reads came back empty between the 60 %
soak and the 60 % gate. The next sample showed 60 % Progressing. It is the shape
of a live cluster — a controller write landing while you are reading — and the
line that matters is the last one, `phase=Healthy`.

The `weight=0%` on the final line is not a regression: at 100 % the canary is no
longer a canary, so the controller reports the *stable* ReplicaSet, which carries
no weight. `phase=Healthy` is the answer.

"20 of 40" in prod is the retired ReplicaSet still winding down while dev has
already finished; the pods are scaled away a moment later, and the count is a
snapshot of the walk, not a stuck release. `gitops-demo-69f5cccdd6-4-4 Failed` is
scenario 2's abort, still in the namespace's history — `kubectl get analysisruns`
lists every run this cluster has ever made, which is exactly what the DORA script
counts.

**Point at:** the tag. `0542eb1` is a commit in app-repo, it is the image name in
GHCR, and it is the only line CI changed in config-repo. Same seven characters
in all three places, which is the whole traceability argument in one glance. And
with `--supply-chain` installed, thirty new pods each went through the image
webhook on their way in, at a measured five seconds for the first one
(`docs/SUPPLY_CHAIN.md`). The canary walked to 100 % anyway: that is the evidence
the two controls coexist rather than fighting over every release.

---

## Scenario 2 — the release that must fail

```bash
bash scripts/demo-bad-release.sh
```

This is the centre of the project. The fault is one line in `app/main.py`: a
600 ms `sleep` on 25% of `/api/items` calls. It is not a crash, it returns 200,
and it does nothing wrong that a static check can see.

```
[1] the one-line change CI cannot see
 app/main.py | 2 +-
 1 file changed, 1 insertion(+), 1 deletion(-)

[2] the checks CI runs, run locally first -- all green, as CI will report
==> ruff + pytest pass on the faulty code (of course they do)

[3] ship it
==> CI run 41480519877
==> CI green: ghcr.io/bouhlel-dev/gitops-demo:9a0526d published,
    promotion merged into bouhlel-dev/gitops-config-repo
```

Ruff passes. Twenty-eight pytest tests pass — none of them measures a duration.
The build succeeds, Trivy reports nothing, the image is published, the promotion
PR merges. Every gate that existed before deployment approved this release.

```
[5] the canary reaches 10% and waits for a decision
==> gitops-demo-dev is serving 10% of traffic (Paused)
    the dashboard at this moment looks fine: 10% of traffic, no errors.

[6] the analysis runs, and says no
==>   weight=10% phase=Progressing
==>   weight=30% phase=Paused
==>   weight=0% phase=Degraded
```

The abort happens *after* the weight moves to 30%, which is where the first
sample of the p95 lands. The full verdict, read off the AnalysisRun:

```
==> AnalysisRun gitops-demo-69f5cccdd6-4-4:
  success-rate   phase=Successful measured=1 failed=0
      values: [1]
  p95-latency    phase=Failed    measured=1 failed=0
      values: [0.8861961691205639]
  the two pod-template hashes the split was between:
    {"canary":{"podTemplateHash":"69f5cccdd6","serviceName":"gitops-demo-canary","weight":0},
     "stable":{"podTemplateHash":"5888c96b87","serviceName":"gitops-demo-stable","weight":100}}
```

Two things to say out loud here:

- **The success rate stayed at 1.00.** A pipeline with only an error-rate gate
  would have promoted this release at every step. The metric that caught it is
  the one nobody looks at when the dashboard says "no errors".
- **`measured=1`** — `failureLimit: 0` means the run ends on the first failed
  sample, so the fault cost one measurement, not four. That is why the restore
  clock below reads 0 s.

```
[7] what the cluster did with no help
  NAME                     DESIRED   READY    IMAGE
  gitops-demo-5888c96b87   10        10       c4b0700
  gitops-demo-69f5cccdd6   3         3        9a0526d
  traffic back on the old version: canary weight 0%, phase Degraded
==> detection took 277s from the push, and no human touched the cluster
```

Read the ReplicaSet table carefully: the stable set never left 10/10, because
`maxUnavailable: 0` and the canary is additive. There was no outage to restore
from — the service was whole at the moment the gate failed.

The faulty pods are still *running* at this point, with `READY 3/3`. Aborting
removes them from traffic; it does not delete them. What deletes them is the
next sync of the corrected commit.

```
[8] the fix is a commit
==> pushed revert dda102f
==> CI green: ghcr.io/bouhlel-dev/gitops-demo:dda102f published, promotion merged
==> healthy again after 864s end to end
```

`git revert`, then the same pipeline again. No `kubectl rollout undo`, and no
Argo CD rollback button — those would both leave git pointing at the broken
image, and the next reconciliation would put the fault back.

**Point at:** the `values:` lines. One number, 0.886 s, against a threshold of
0.5 s, is the entire automated decision. Everything else in the chain was green.

---

## Scenario 3 — drift, and the thing that puts it back

```bash
bash scripts/demo-drift.sh          # or: bash scripts/demo-drift.sh prod
```

```
[1] the value as git says it should be
  gitops-demo-dev/gitops-demo-config APP_ENV=dev

[2] one legal kubectl patch, no git involved
  APP_ENV is now tampered-by-hand
  kubectl accepted it. Nothing warned. The pods kept running.

[3] waiting for Argo CD to notice (it reconciles every 20s)
  +  0s  APP_ENV=tampered-by-hand   app=OutOfSync
  +  3s  APP_ENV=dev                app=Synced

[4] what just happened, in the cluster's own words
  reverted after 3s -- one reconciliation cycle
  the Application's own record of the sync that fixed it:
    d95cfe6df4aa5fa670273696b0d40d4c6ec9975c 2026-11-02T17:19:47Z
  events on the Application, newest last:
    3s    Normal   ResourceUpdated      application/gitops-demo-dev   Updated sync status: Synced -> OutOfSync
    2s    Normal   OperationCompleted   application/gitops-demo-dev   Partial sync operation to d95cfe6df4aa5fa670273696b0d40d4c6ec9975c succeeded
    2s    Normal   ResourceUpdated      application/gitops-demo-dev   Updated sync status: OutOfSync -> Synced
```

The three events are the proof: the Application *observed* the drift
(`Synced -> OutOfSync`), *acted* without being asked
(`OperationCompleted`), and *landed on the commit in git* (the revision is a
config-repo SHA, not a local override).

The script polls every 2 s, so the honest reading of "3 s" is *the second
sample*, not a millisecond-accurate latency; the upper bound is one 20-second
reconciliation cycle. Say it that way and the number stops being a claim.

```
[5] the limit, which is worth stating out loud
```

The script prints the boundary rather than skipping it: selfHeal reverts what
Argo CD owns. A ConfigMap created by hand in the same namespace, a
`helm upgrade` against ingress-nginx, or anything in a namespace the Application
does not select all survive forever. `apps/gitops-demo/` is the whole protected
area.

---

## Scenario 4 — an image nobody signed cannot start

```bash
bash scripts/bootstrap.sh --supply-chain   # once, before the demo
bash scripts/demo-supply-chain.sh
```

Prerequisite that matters for a live run: at least one release published *after*
CI began signing, so there is a signed tag and an older unsigned one both
pullable. The script picks them out of the cluster rather than hard-coding them.

<!-- FILL: captured output of scripts/demo-supply-chain.sh goes here, with the
     real webhook denial message. -->

```
[1] what signed the image, and with what
  signed image:   ghcr.io/bouhlel-dev/gitops-demo:3aae81c
  unsigned image: ghcr.io/bouhlel-dev/gitops-demo:dda102f
  cosign:         v3.1.4

[2] the signature is readable from here, and it is tied to one identity
  signature valid for "docker-manifest-digest":"sha256:03a3a9bb854d6837a7296d88b1d05642cca8898f9bb661a9fbafe312bb681bb2"
  wrong subject: Error: no matching attestations: failed to verify certificate identity: no matching CertificateIdentity found, last error: expected SAN value to match regex "^https://github.com/bouhlel-dev/gitops-app-repo/[.]github/workflows/ci[.]yml@refs/heads/some-other-branch$", got "https://github.com/bouhlel-dev/gitops-app-repo/.github/workflows/ci.yml@refs/heads/main"

[3] and the older tag carries nothing to verify
  ghcr.io/bouhlel-dev/gitops-demo:dda102f: Error: no signatures found

[4] ask the cluster for a Pod on the unsigned image
  Error from server: error when creating ".../cache/supply-chain-pod.yaml.in": admission webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-gitops-demo-signature" denied the request: Policy verify-gitops-demo-signature failed: the image is not signed by the gitops-app-repo main-branch pipeline
  (that error came from the admission webhook, before kubelet was involved)

[5] ask for the same Pod on the signed image
pod/supply-chain-check condition met
  admitted and running: Running on ghcr.io/bouhlel-dev/gitops-demo:3aae81c

==> done. The refusing Pod and the accepted one differed by one thing: a signature.
```

Steps [4] and [5] apply the *same* manifest, and the only line that differs
between them is the image tag. The capture is verbatim except that the absolute
Windows path to the script's scratch manifest is elided.

Step [2] is the one to talk through slowly: cosign
verifies on a match and prints the digest, never the identity, so the script
immediately asks for a deliberately wrong ref — `some-other-branch` — and the
complaint names the subject the certificate really carries. That is the proof the
check is an identity check and not a "does a signature exist" check: a signature
from any other workflow, branch or repository fails here exactly as it fails in
the cluster.

Step [1] is worth a sentence too. Both tags are real releases of the same
service; `dda102f` predates CI starting to sign, `3aae81c` was signed by the
main-branch workflow with no key involved — the runner's OIDC token bought a
short-lived Fulcio certificate, and the signature is attached to the image
digest, not the tag.

---

## Reading the state yourself

Five commands worth knowing when a script is not doing the talking.

```bash
# the canary as a state machine, updated every 2s
kubectl argo rollouts get rollout gitops-demo -n gitops-demo-dev --watch 2s

# what the gates actually measured, as the controller stored it
kubectl -n gitops-demo-dev get analysisrun -o jsonpath=\
'{range .items[*]}{.metadata.name}{"  "}{.status.phase}{"\n"}{end}'

# which pods are behind each Service right now
kubectl -n gitops-demo-dev get endpoints gitops-demo-canary gitops-demo-stable

# is Prometheus seeing the app at all
curl -sG 'http://127.0.0.1:9090/api/v1/query' \
  --data-urlencode 'query=sum(rate(http_requests_total{namespace="gitops-demo-dev"}[1m]))'

# the four DORA keys, from git and from AnalysisRuns
python scripts/dora.py --days 1
```

The Prometheus query is the first thing to run when an AnalysisRun fails with an
empty value: if it returns an empty `result`, there is no traffic, and the abort
is the design working, not the app being broken.

`dora.py` on the window that contains every run in this project:

```
DORA  bouhlel-dev/gitops-app-repo + bouhlel-dev/gitops-config-repo  last 1 day(s)
sample: 8 release(s), 11 analysis run(s)

Deployment frequency
  8 deployment(s), 8.0/day
  median gap between releases: 22m 42s

Lead time for changes  (commit authored -> release PR merged)
  median 82s  p90 1m 30s  max 1m 33s
    PR #1   59f472e  authored 12:51:34  merged 12:52:55  81s
    PR #2   370b136  authored 15:49:10  merged 15:50:31  81s
    PR #3   c4b0700  authored 16:11:56  merged 16:13:13  77s
    PR #4   9a0526d  authored 16:20:35  merged 16:22:03  88s
    PR #5   dda102f  authored 16:25:07  merged 16:26:30  83s
    PR #6   3aae81c  authored 16:47:02  merged 16:48:24  82s
    PR #7   61627bf  authored 20:27:09  merged 20:28:39  1m 30s
    PR #8   0542eb1  authored 20:55:36  merged 20:57:09  1m 33s
  plus at most 20s before Argo CD reconciles the merged commit

Change failure rate  (canaries the quality gate rejected)
  1 of 11  (9%)  {'Failed': 1, 'Successful': 10}

Time to restore
  gate decides: 0s (ended on its first measurement; stable pods never left service, maxUnavailable: 0)
    gitops-demo-dev/gitops-demo-69f5cccdd6-4-4: Metric "p95-latency" assessed Failed due to failed (1) > failureLimit (0)
  corrected release: 4h 14m (abort -> gitops-demo-dev/gitops-demo-f95f867d7-7-10 done, i.e. back at 100%)
      (over 30 minutes: Rollouts had pruned the nearer runs -- `kubectl get analysisruns` before quoting this)
```

Three caveats to say when presenting these, before anyone asks:

- **The denominator moves.** Argo Rollouts keeps AnalysisRuns only for the
  retained revisions, so the count drops as releases pile up. "1 of 11" is a
  snapshot of the window, not a permanent ledger; the durable record is the
  commit log plus the `Failed` run captured above.
- **`0s` is a real reading, not a missing measurement.** `startedAt` and
  `completedAt` are equal on a run that fails its first sample. The service was
  never incomplete because the canary was additive and `maxUnavailable: 0`, so
  the only restore cost that is not automatic is the human one: deciding on a
  revert and pushing it. Scenario 2's own clock is the number to quote, because
  the same run produced both ends of it — `277 s` from pushing the fault to the
  abort, `864 s` from the start of the script to both apps `Healthy` on the
  revert. Everything between those two is the fix's own canary walk.
- **The 4 h 14 m is wrong, and the script says so.** Four hours is not how long
  the restore took; it is what `dora.py` can still *see*. It defines "corrected
  release" as the next `Successful` run belonging to a different pod-template hash
  after the abort. The revert (`dda102f`) finished that walk 9 m 48 s after the
  abort, and when its runs were still retained the script printed exactly that.
  Rollouts has since pruned them with the revision, so the first surviving
  `Successful` run belongs to PR #7 — a release made four hours later, for an
  unrelated reason:

  ```
  $ kubectl get analysisruns --all-namespaces -o custom-columns=\
  NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,STARTED:.status.startedAt,FINISHED:.status.completedAt
  NS                 NAME                          PHASE        STARTED                FINISHED
  gitops-demo-dev    gitops-demo-69f5cccdd6-4-4    Failed       2026-11-02T16:24:58Z   2026-11-02T16:24:58Z
  gitops-demo-dev    gitops-demo-f4668d66d-8-10    Successful   2026-11-02T21:05:14Z   2026-11-02T21:05:59Z
  gitops-demo-dev    gitops-demo-f95f867d7-7-10    Successful   2026-11-02T20:38:18Z   2026-11-02T20:39:03Z
  ```

  Nothing in that list carries the revert's hash, so the pairing is a retention
  artifact. The finding is the general one: **a metric derived from garbage-
  collected cluster objects has an expiry date.** `dora.py` prints the run name it
  paired, and warns when the gap exceeds half an hour, so a wrong restore number
  cannot leave the terminal unnoticed -- the line under it in the capture above is
  the script disagreeing with its own output.

---

## If a step stalls

| You see | It means | Do |
|---|---|---|
| `==> timed out ... waiting for the new tag to reach the Rollout specs` | CI merged the PR but Argo CD has not acted | `kubectl -n argocd get application gitops-demo-dev -o jsonpath='{.status.operationState}'`; then check `ARGOCD_RECONCILIATION_TIMEOUT` is 20 in `/proc/1/environ` of the application-controller pod |
| AnalysisRun `Failed` with an empty value list, on the *good* release | no traffic was offered | run `python scripts/loadgen.py all 20 1200` and re-promote |
| Rollout stuck `Paused` at 10% | that is the manual gate, working | `kubectl argo rollouts promote gitops-demo -n gitops-demo-dev` |
| `Unable to connect to the server: TLS handshake timeout` | the single API server is saturated | wait and retry; `docker info --format '{{.MemTotal}}'` to check the VM |
| CI red at `Promote the tag into config-repo`, exit 128 | the PAT lost its scope or the checkout lost its `token:` | `gh secret set CONFIG_REPO_TOKEN --repo bouhlel-dev/gitops-app-repo` |

The demo is long — 12 minutes for a good release (measured: 729 s), 15 for the bad
one (864 s) because it ships the fault *and* the fix — so start the load generator
first, and start `--watch` terminals before you start the script. Nothing in either
demo needs you to type during the waits, which is the point.
