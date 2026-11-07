# Supply chain: Cosign signs, Kyverno refuses

The bonus phase of the project. Two halves that only make sense together: CI
signs each image it publishes with the identity GitHub gave it for that run, and
the cluster refuses to start an image that carries no such signature.

Everything here is optional and stays behind a flag —
`bash scripts/bootstrap.sh --supply-chain` — because an admission policy with
`failurePolicy: Fail` is the one component in this project that can stop the
cluster from scheduling pods.

## What this proves, and what it does not

**Proves:** a `Pod` asking for `ghcr.io/bouhlel-dev/gitops-demo*` in
`gitops-demo-dev` or `gitops-demo-prod` is admitted only if the registry holds a
cosign signature whose certificate was issued to *this repository's `ci.yml`,
running on `main`*. An unsigned tag — one published before CI started signing,
still pullable, still the exact same application code — is refused before the
kubelet is involved.

**Does not prove:** that the build was honest. Anyone with write access to
app-repo can commit a workflow that signs something else, and GitHub will issue
the certificate for it. The identity is "this workflow ran on main", not "this
image contains what the commit says". Provenance beyond that identity is what
SLSA attestations and a build you do not control are for, and neither is here.

Saying the second part out loud is the point of the exercise: a signature is a
statement about *who*, and a supply-chain policy that only answers *who* covers
one third of the problem.

## Keyless: nobody holds a key

`app-repo/.github/workflows/ci.yml` gets `permissions: id-token: write`. For one
run, GitHub's OIDC provider issues the runner a token binding it to
`repo:bouhlel-dev/gitops-app-repo:ref:refs/heads/main` plus the workflow file.
cosign trades that token to Fulcio for a short-lived code-signing certificate
whose **subject** is:

```
https://github.com/bouhlel-dev/gitops-app-repo/.github/workflows/ci.yml@refs/heads/main
```

and signs the image digest with an ephemeral key that exists only for the
seconds of that step.

The consequence is worth stating as a design result rather than a detail: **there
is no signing key to rotate, leak, or store in a secret.** The whole trust
question collapses into "can you make GitHub issue an OIDC token for that
ref", which is the same question as "can you push to main". Keyless is not
weaker than a key in a secret; it moves the boundary from a file to a permission.

## The three places the same string must agree

| Where | What it holds | If it drifts |
|---|---|---|
| `app-repo` `ci.yml`, "Verify the signature the way the cluster will" | issuer + `--certificate-identity-regexp` for that subject | build stays green, pods stop scheduling |
| `bootstrap/kyverno/verify-gitops-demo-signature.yaml` | `attestors[].cosign.keyless.identities[].subject`, same subject | unsigned pods admitted, signed pods refused |
| `scripts/demo-supply-chain.sh` | builds the regexp from `APP_REPO_SLUG` | the demo reports a false pass |

The CI step is deliberately a *verify* and not just a *sign*. A signature GHCR
will not serve is indistinguishable, at admission time, from no signature at
all — so the pipeline reads its own work back with the same two strings the
cluster will use, and fails the build rather than shipping a release no pod can
start.

Sign the **digest**, never the tag:

```bash
digest="$(docker inspect --format '{{index .RepoDigests 0}}' "${IMAGE}:${GIT_SHA}")"
cosign sign --yes "${digest}"
```

A tag can be re-pointed at a different image after signing, and the signature
would then describe whatever the name happens to mean that week. That step is
also why it cannot move earlier in the workflow: `RepoDigests` is only populated
by the push above it.

## What is pinned

`versions.env` carries the versions for this phase exactly like every other:

| Pin | Value |
|---|---|
| `COSIGN_VERSION` | `v3.1.4` |
| `COSIGN_SHA256` / `COSIGN_SHA256_LINUX` | the Windows binary for the laptop, the Linux one CI downloads on `ubuntu-24.04` |
| `KYVERNO_CHART_VERSION` | `3.9.2` (OCI only — `oci://ghcr.io/kyverno/charts/kyverno`; the `charts.kyverno.io` HTTP endpoint no longer resolves) |
| `KYVERNO_APP_VERSION` | `v1.19.2` |
| `SUPPLY_CHAIN_IMAGES` | `reg.kyverno.io/kyverno/kyvernopre:v1.19.2`, `reg.kyverno.io/kyverno/kyverno:v1.19.2`, `reg.kyverno.io/kyverno/kyverno-cli:v1.19.2` — the init container, the webhook, and the `post-upgrade` hook Job that only a *re-run* of the bootstrap ever meets |

The chart version is load-bearing in a way the other pins are not. Kyverno 1.10
bootstraps keyless verification from the retired legacy TUF mirror
(`sigstore-tuf-root.storage.googleapis.com`); that mirror now serves a
`timestamp.json` whose key no longer validates, so a denying policy on 1.10
denies **every** Pod in the matched namespaces, signed or not, with
`invalid key` in the webhook log. 1.19 ships the current Sigstore trust bundle.
The failure is silent from outside: the policy applies, the webhook runs, the
denials look like the control working.

`bootstrap/helm/kyverno.yaml` turns off the background controller, the cleanup
controller, the reports controller, admission reports, policy reports and
background scans. Kyverno's default install is four Deployments; the admission
webhook is the only one this project uses, and a one-node cluster is already
carrying thirty app pods plus Prometheus. It also turns off `webhooksCleanup`,
whose replacement in 3.9.2 (`ghcr.io/kyverno/readiness-checker`) defaults to
`latest` and publishes only commit-SHA tags — there is no pin to write, so the
hook is disabled and the documented teardown is `kind delete cluster`.

## Rotating a pin

A digest pin does not move when the thing it names is fixed upstream, and that
is the whole point: `python:3.12-slim-bookworm@sha256:e697c818…` was a real,
immutable image that simply grew HIGH-severity findings inside it. So a pin is a
snapshot with a shelf life, and the Trivy gate is what tells you it expired.

It did, on 2026-11-07. CI run 42392543589 (app-repo `8e39902`) died in the scan
step after 62 s:

```
ghcr.io/bouhlel-dev/gitops-demo:8e39902 (debian 12.15)
Total: 2 (HIGH: 2, CRITICAL: 0)
│ apt           │ CVE-2026-109518 │ HIGH │ fixed │ 2.6.1 │ 2.6.2 │
│ libapt-pkg6.0 │                 │      │       │       │       │
```

Two findings, one CVE: `apt` and the library it is built on, both fixed in
2.6.2. Nothing was published, no promotion PR was opened, and the cluster never
saw a diff. That is the gate failing closed, which is the only moment its design
gets tested.

The fix is a new digest. Not a relaxed flag: `--ignore-unfixed` was already on
and stays on, and dropping a severity or adding a `.trivyignore` would have
bought a green run at the cost of the control itself.

```bash
# 1. what the tag points at now, read from the registry manifest: no download,
#    no re-hash, so the digest you write is the one Docker would resolve anyway
docker buildx imagetools inspect python:3.12-slim-bookworm \
  --format '{{json .Manifest.Digest}}'

# 2. write it in both places, which is what "pinned" costs:
#      config-repo/versions.env  PYTHON_BASE_IMAGE=   <- CI builds with this
#      app-repo/Dockerfile       ARG PYTHON_BASE_IMAGE= <- a standalone local build

# 3. prove the new digest carries the fix before spending a CI run on it
MSYS_NO_PATHCONV=1 docker run --rm --entrypoint /bin/sh \
  python:3.12-slim-bookworm@<new-digest> \
  -c "dpkg-query -W -f='\${Package} \${Version}\n' apt libapt-pkg6.0"
```

Step 3 is the entire verification: `apt 2.6.2` and `libapt-pkg6.0 2.6.2` back
means the scan has nothing left to block on. `MSYS_NO_PATHCONV=1` is Git Bash's
problem, not the image's: it rewrites `/bin/sh` into a Windows path on the way to
the daemon, the same argv mangling that breaks cosign's regex above.

This rotation landed as config-repo `efc40cd` plus app-repo `4820596`, and CI run
42393126754 was green in 80 s — which is also a fair statement of what the
control costs.

What this does not rotate: the chart and tool pins in the same file. Those are
upstream-release decisions rather than security patches, and `bootstrap.sh`
pulls them by digest too, so a stale one shows up as a missing feature, not a
CVE.

## Installing it

```bash
bash scripts/bootstrap.sh --supply-chain
```

Two phases after the normal ones: `phase_kyverno` (helm install, then wait for
the admission Service to have an endpoint) and `phase_policy` (apply the
ImageValidatingPolicy, then wait for its `ready` condition *and* for the
`ivpol.validate` webhook to be registered — Kyverno does that itself once it has
its certificate, so "policy applied" and "policy firing" are different states).

`phase_kyverno` uses `helm upgrade --install`, which means the first run takes the
install path and every later run takes the upgrade path — and the chart's upgrade
path has a `post-upgrade` hook Job running `kyverno-cli` that the install path
never meets. That Job is why `kyverno-cli` is in the pre-pull list, and why the
phase rolls back a release left `pending-upgrade` by an interrupted run before it
tries to upgrade it again.

Verify:

```bash
kubectl -n kyverno get deploy,po                        # one admission controller, ready
kubectl -n kyverno get endpointslices \
  -l kubernetes.io/service-name=kyverno-svc             # the webhook has a backend
kubectl get validatingwebhookconfigurations \
  kyverno-resource-validating-webhook-cfg \
  -o jsonpath='{.webhooks[*].name}{"\n"}'               # the image check is registered here
kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
  -o jsonpath='{.status.conditionStatus.ready}{"\n"}'
kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
  -o jsonpath='{.spec.validationActions} {.spec.failurePolicy}{"\n"}'
```

Measured on this cluster:

```
$ kubectl -n kyverno get deploy,po
NAME                                           READY   UP-TO-DATE   AVAILABLE   AGE
deployment.apps/kyverno-admission-controller   1/1     1            1           41m
NAME                                                READY   STATUS    RESTARTS   AGE
pod/kyverno-admission-controller-66c446787c-fckrn   1/1     Running   0          41m

$ kubectl -n kyverno get endpointslices -l kubernetes.io/service-name=kyverno-svc
NAME                ADDRESSTYPE   PORTS   ENDPOINTS      AGE
kyverno-svc-scqrv   IPv4          9443    10.244.0.191   41m

$ kubectl get validatingwebhookconfigurations kyverno-resource-validating-webhook-cfg \
    -o jsonpath='{.webhooks[*].name}'
ivpol.validate.kyverno.svc-fail-finegrained-verify-gitops-demo-signature protect-generation-labels.kyverno.svc

$ kubectl get imagevalidatingpolicy verify-gitops-demo-signature -o jsonpath='{.status.conditionStatus.ready}'
true

$ kubectl get imagevalidatingpolicy verify-gitops-demo-signature -o jsonpath='{.spec.validationActions} {.spec.failurePolicy}'
["Deny"] Fail
```

Three names are worth getting right, and each cost a debugging cycle. The
Deployment is `<release>-admission-controller` but the Service is `kyverno-svc`,
so waiting on the Deployment name never finds an endpoint. The webhook that
intercepts Pod creation is `kyverno-resource-validating-webhook-cfg`, not a
`kyverno`-named one, so `kubectl get validatingwebhookconfigurations kyverno` is
a clean "not found" next to a webhook that is firing. And the last two commands
have to name the kind: `kubectl get clusterpolicy` still works against 1.19 and
returns nothing for a policy that is enforcing, because the policy is a different
API now.

Measured, on a cluster that already exists and already has every image in the
node: **7 m 3 s** for the whole of `bootstrap.sh --supply-chain`, exit 0 — and
the link was bad enough during that run that the 6.6 MB prometheus-community
chart index timed out on two of the three helm attempts, the third succeeded, and
the phase printed a warning claiming a slow pod download that was not what was
happening. The Kyverno-specific part is two helm round-trips plus the
`post-upgrade` migration Job, which takes **32 s** once `kyverno-cli` is in the
node and **8 m 8 s** when the node has to pull it — the difference between an
image in `SUPPLY_CHAIN_IMAGES` and one that is not.

## Why this is not a `ClusterPolicy`

The first version of this control was a `kyverno.io/v1 ClusterPolicy` with a
`verifyImages` rule, which is the shape nearly every write-up of "Kyverno +
cosign" still uses. It applied cleanly, Kyverno registered it, and it denied
**every** pod — including the one asking for the image `cosign verify` had
accepted in the same second, with
`.attestors[0].entries[0].keyless: no signatures found`.

The signature was not missing. It was somewhere the policy could not look:

```
$ curl -s -H "Authorization: Bearer $TOKEN" \
    https://ghcr.io/v2/bouhlel-dev/gitops-demo/tags/list
{"name":"bouhlel-dev/gitops-demo","tags":["1f54f63","370b136","3aae81c","dda102f", … ,
 "sha256-03a3a9bb854d6837a7296d88b1d05642cca8898f9bb661a9fbafe312bb681bb2"]}
```

cosign v3 publishes a signature as an **OCI 1.1 referrer** of the image manifest.
GHCR does not implement the Referrers API — `GET /v2/…/referrers/sha256:03a3a9bb…`
answers `MANIFEST_UNKNOWN` — so cosign emulates it by writing the signature as a
*tag in the same repository*, named after the digest it signs. That is the
`sha256-03a3a9bb…` entry above, sitting next to the release tags.

The pre-v3 convention was a *nested repository* holding tag `latest`:
`bouhlel-dev/gitops-demo/sha256-03a3a9bb….sig:latest`, which does not exist here
at all. `verifyImages` uses the vendored cosign library and looks in the old
place; `ImageValidatingPolicy` uses sigstore-go, follows the fallback tag, and
verifies. Kyverno's issue #16678 documents the same split from the outside
("the cosign CLI discovers the fallback-tag bundle on the same registry;
Kyverno's embedded call does not"), and upstream deprecates `kyverno.io/v1`
policies regardless — the chart's own install notes say so, in the run that
installed the release this cluster is using:

```
⚠️  WARNING: The legacy kyverno.io policy types are deprecated and will be
    removed in a future release. Migrate to their policies.kyverno.io
    replacements:
```

Two things make this worth writing down rather than fixing silently:

- **Nothing in the symptom points at the cause.** The registry had the
  signature, the certificate was valid, the CLI agreed. A control that denies
  everything *looks* like a control that works, which is the worst failure an
  admission policy can have.
- **A version pin is a format contract.** `COSIGN_VERSION` in CI and
  `KYVERNO_CHART_VERSION` in the cluster are the two ends of how a signature is
  laid out in a registry. Moving one alone broke the other, and the only honest
  lesson is that the pairing has to be tested end to end — which is exactly what
  `demo-supply-chain.sh` does, and what no amount of `helm lint` would have.

## The policy

```yaml
apiVersion: policies.kyverno.io/v1beta1
kind: ImageValidatingPolicy
spec:
  failurePolicy: Fail
  validationActions: [Deny]
  webhookConfiguration: {timeoutSeconds: 30}
  matchConstraints:
    resourceRules: [{apiGroups: [""], operations: [CREATE], resources: [pods]}]
    namespaceSelector: {matchExpressions: [{key: kubernetes.io/metadata.name,
                  operator: In, values: [gitops-demo-dev, gitops-demo-prod]}]}
  matchImageReferences: [{glob: "ghcr.io/bouhlel-dev/gitops-demo*"}]
  attestors: [{name: pipeline, cosign: {keyless: {identities: [{issuer: …, subject: …}]},
              ctlog: {url: https://rekor.sigstore.dev}}}]
  validationConfigurations: {verifyDigest: false, mutateDigest: false}
  validations: [{expression: >-
      images.containers.map(image, verifyImageSignatures(image, [attestors.pipeline])).all(e, e > 0)}]
```

Six choices, each with a cost:

- **`Deny`, not `Audit`.** Audit produces a report and lets the pod run, which is
  a compliance dashboard, not a control. The cost of Deny is that a broken
  signature lookup stops deployments.
- **`failurePolicy: Fail`** means an unreachable Kyverno blocks admission rather
  than waving everything through. That is the safe direction and the dangerous
  one at the same time: with `Ignore`, the policy is only as strong as the
  webhook's uptime, and every outage is a hole. Kyverno's own sample policy ships
  `Ignore`; a control meant to stop an image cannot.
- **Two namespaces, CREATE only.** A Deny + Fail policy across every namespace
  turns one bad signature lookup into a cluster that cannot restart its own
  control plane — including Kyverno itself. The scope is the trade-off, and it is
  a real one: a Pod in another namespace is unchecked. `pods` is what the rule
  names; Kyverno autogenerates the same rule for Deployment, ReplicaSet,
  StatefulSet, DaemonSet, Job and CronJob, so the ReplicaSet is refused before it
  can make a single pod.
- **`timeoutSeconds: 30`** (the maximum; the default is 10). Verifying means
  resolving the tag to a digest, pulling the signature artifact from GHCR and
  checking the Rekor entry. On a cold cache that routinely exceeds 10 s, and with
  `Fail` a timeout denies a pod asking for an image that verifies fine.
- **`verifyDigest: false`** because the promotion in config-repo writes a tag.
  Left at its default of `true`, the policy demands an image that already names a
  digest and denies every pod in the project with
  `image ghcr.io/…:3aae81c does not have a digest`.
- **`matchImageReferences` scoped to one repository.** An image the policy does
  not name is skipped rather than failed, which is what lets a debug pod run
  `busybox` in the same namespace.

`mutateDigest: false` is the one that costs the strongest form of the guarantee.
With `true`, Kyverno pins the verified *digest* into the pod spec, so the tag
cannot be re-resolved later by kubelet. With `false`, verification happens at
admission against whatever the tag points at that moment. It stays `false` here
so the running pod's image string keeps matching what git says — the property
every other part of this project depends on. A real cluster would set `true` and
accept that `kubectl get pod -o jsonpath=…image` no longer echoes the manifest
in the repo. The default for this field is `true`, so the line in the policy is
load-bearing: delete it and the pods that come up read `ghcr.io/…@sha256:…`
instead of `ghcr.io/…:3aae81c`, which breaks every check in this project that
counts pods by image tag — including step 8 of `scripts/demo-good-release.sh`,
which would report zero pods on the new release in both namespaces while the
release was running perfectly.

## The demo

```bash
bash scripts/demo-supply-chain.sh
```

It resolves both images from the cluster rather than hard-coding them: the tag
the dev Rollout currently wants (signed), and a different tag already present
among the dev ReplicaSets (published before CI signed anything). Captured run:

```
[1] what signed the image, and with what
  signed image:   ghcr.io/bouhlel-dev/gitops-demo:3aae81c
  unsigned image: ghcr.io/bouhlel-dev/gitops-demo:dda102f
  cosign:         v3.1.4

[2] the signature is readable from here, and it is tied to one identity
  signature valid for "docker-manifest-digest":"sha256:03a3a9bb854d…1bb2"
  wrong subject: Error: no matching attestations: failed to verify certificate
    identity: … expected SAN value to match regex
    "^https://github.com/bouhlel-dev/gitops-app-repo/[.]github/workflows/ci[.]yml@refs/heads/some-other-branch$",
    got "https://github.com/bouhlel-dev/gitops-app-repo/.github/workflows/ci.yml@refs/heads/main"

[3] and the older tag carries nothing to verify
  ghcr.io/bouhlel-dev/gitops-demo:dda102f: Error: no signatures found

[4] ask the cluster for a Pod on the unsigned image
  Error from server: error when creating "…/supply-chain-pod.yaml.in": admission
  webhook "ivpol.validate.kyverno.svc-fail-finegrained-verify-gitops-demo-signature"
  denied the request: Policy verify-gitops-demo-signature failed: the image is not
  signed by the gitops-app-repo main-branch pipeline
  (that error came from the admission webhook, before kubelet was involved)

[5] ask for the same Pod on the signed image
  pod/supply-chain-check condition met
  admitted and running: Running on ghcr.io/bouhlel-dev/gitops-demo:3aae81c
```

Steps 4 and 5 are the demo. One manifest, applied twice, differing only in the
image string: the first is refused by the webhook, the second is admitted and
reaches `Ready`. Step 2's second half is the identity check doing its job — ask
for a subject from another branch and the complaint names the subject the
certificate really carries. Step 3 shows the unsigned tag is not a fiction: it is
in the registry, it pulls, and it carries nothing to verify.

## What this catches, in time order

| Attack | Stopped here? |
|---|---|
| `docker push` a hand-built image to GHCR under the same repo | yes — nothing signed it |
| A Pod spec asking for `gitops-demo:latest` or an old unsigned SHA | yes — no signature to verify |
| An unsigned image *already running* | no — policies do not evict; `kubectl delete pod` and it stays deleted |
| `kubectl set image pod/… app=<unsigned tag>` on a running Pod | no — the policy matches CREATE, and a container image is one of the few fields Kubernetes lets you change on an existing Pod. Measured, not theorised: the swap above was accepted by the API server in a namespace the policy enforces in |
| CI signing an image built from a workflow someone rewrote last week | no — valid signature, valid identity, dishonest build |
| Re-pointing a tag after signing | `mutateDigest: false` leaves that window open; pinning the digest closes it |
| Anything outside the two namespaces | no — out of scope by design |

## Failure modes found while building this

| Symptom | Cause | Fix |
|---|---|---|
| `helm repo add kyverno https://charts.kyverno.io` → `no such host` | the chart is OCI-only now | `helm install oci://ghcr.io/kyverno/charts/kyverno`, and `helm_install` passes `--repo` only when a repo argument is given |
| Every Pod in the two namespaces denied, signed images included, webhook log full of `initializing tuf: invalid key` | Kyverno 1.10 still bootstraps keyless trust from the retired legacy TUF mirror | move to chart 3.9.2 / app v1.19.2, which uses the current Sigstore trust bundle — this is why the chart pin is a security pin, not a cosmetic one |
| Every Pod in the two namespaces denied, signed images included, `.attestors[0].entries[0].keyless: no signatures found` | cosign v3 publishes the signature as an OCI 1.1 referrer, which GHCR does not implement, so it lands as a *tag in the same repository*; the legacy `verifyImages` rule looks in the pre-v3 nested `.sig` repository | use `policies.kyverno.io/v1beta1 ImageValidatingPolicy`, whose sigstore-go path follows the fallback tag — see "Why this is not a ClusterPolicy" above |
| Every Pod denied with `image ghcr.io/…:3aae81c does not have a digest` | `validationConfigurations.verifyDigest` defaults to `true`, which requires the image to already name a digest | set it to `false` so the verifier resolves the tag itself |
| One Pod denied with `failed calling webhook … context deadline exceeded`, the next one admitted | the policy's webhook budget is 10 s by default and a cold signature lookup (GHCR + Rekor) can exceed it | `webhookConfiguration.timeoutSeconds: 30`, the maximum |
| `helm upgrade` → `cannot overwrite table with non table for kyverno.webhooksCleanup.image` | in 3.9.2 that value became a map (`registry`/`repository`/`tag`), so the old string-valued override collides with it | drop the override; and since the new default is `readiness-checker:latest` with only commit-SHA tags published, disable `webhooksCleanup` outright |
| The *second* `bootstrap.sh --supply-chain` hangs for the full 10 m helm timeout, then the release is `pending-upgrade` and every later run says `another operation is in progress` | `helm upgrade --install` makes the first run an *install* and every later run an *upgrade*, and chart 3.9.2 registers a `post-upgrade` hook Job that runs `kyverno-cli` — a third image nothing pre-pulled, so the hook Pod sits in `ContainerCreating` pulling from a slow registry. A re-run exercises paths a first run never touches | `kyverno-cli` is now in `SUPPLY_CHAIN_IMAGES`, and `phase_kyverno` rolls a release left `pending-*` back before upgrading it |
| `strict decoding error: unknown field "…keyless.subjects"`, `"…mutateImage"` | the `kyverno.io/v1` CRD has a singular `subject` string and calls the digest field `mutateDigest` — both names belong to newer APIs | `kubectl explain` the CRD actually installed before writing the policy; the v1beta1 API really does use `identities` and `validationConfigurations.mutateDigest` |
| Policy apply refused with `Either Rekor URL or roots are required` | a keyless attestor with no transparency log and no roots has nothing to anchor the Fulcio certificate | `ctlog.url: https://rekor.sigstore.dev` in the attestor |
| Four Deployments in `kyverno` after setting `backgroundController.enable=false` | the key is `enabled`, and an unknown values key is silently ignored by Helm | fixed in `bootstrap/helm/kyverno.yaml` |
| `bootstrap.sh --supply-chain` dies with "kyverno-admission-controller never got an endpoint" while Kyverno is healthy | the Deployment is `<release>-admission-controller`, the Service is `kyverno-svc` | select EndpointSlices by `kubernetes.io/service-name=kyverno-svc` |
| Local `cosign verify` reports `expected SAN value to match regex "^…repo//.github/workflows/ci/.yml@…"` against a certificate that is correct | Git Bash rewrites every backslash in an argv entry into a forward slash on the way to `cosign.exe`, so `\.` arrives as `/.` | write the dots as `[.]` — same regex to Go, no backslash to mangle, and no `MSYS_NO_PATHCONV` needed |
| The rollout stalls mid-canary right after `--supply-chain` | the policy denies at admission, and the tag being rolled out predates signing | run the phase only when the next release is signed — the reason it is a flag |
| `cosign verify` succeeds but names no identity | on a match cosign echoes the image digest and reference, never the certificate subject | the exit code *is* the identity check; ask for a deliberately wrong subject and read the complaint |

## Verify it yourself

```bash
# 1. CI signed the release the cluster is running
gh run view --repo bouhlel-dev/gitops-app-repo --log \
  | grep -E "Pushing signature|signature valid for"

# 2. the workstation can read that signature
cosign verify \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/bouhlel-dev/gitops-app-repo/[.]github/workflows/ci[.]yml@refs/heads/main$' \
  ghcr.io/bouhlel-dev/gitops-demo:<the tag in the dev Rollout>

# 3. the policy is in force
kubectl get imagevalidatingpolicy verify-gitops-demo-signature \
  -o jsonpath='ready={.status.conditionStatus.ready} actions={.spec.validationActions}{"\n"}'

# 4. an unsigned pod cannot start
bash scripts/demo-supply-chain.sh
```

Step 2 needs the pinned `cosign.exe` in `../.tools/bin` — `install-tools.sh`
downloads it with the rest of the toolchain. It is a 191 MB binary whose only
job is these two commands, which is the honest cost of verifying locally instead
of from a container.
