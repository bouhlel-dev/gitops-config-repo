# Opening Argo CD, Grafana and Prometheus in a browser

Runbook for the local `kind` cluster: how to launch the UIs, what to log in with,
and what to show. Nothing here is a secret — both admin passwords are generated
inside the cluster and are read from a Secret each time, exactly as
`scripts/bootstrap.sh` does at the end of a bootstrap. **Do not paste the values
into this file or into either repository.**

## A. Open it now (if the forwards are already running)

```bash
cd config-repo
source scripts/env.sh

# Argo CD admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo

# Grafana admin password
kubectl -n monitoring get secret kube-prometheus-stack-grafana -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

| What | URL | Login |
|---|---|---|
| Argo CD | `https://127.0.0.1:8089` — **https**, not http | `admin` + first password |
| Grafana | `http://127.0.0.1:3002` | `admin` + second password |
| Prometheus | `http://127.0.0.1:9091` | none |
| The app itself | `http://gitops-demo.local`, `http://gitops-demo-prod.local` | none |

Three things that look like breakage and are not:

- **Argo CD shows a certificate warning.** The server self-signs. Advanced →
  continue.
- **`gitops-demo.local` does not resolve.** Add two lines to
  `C:\Windows\System32\drivers\etc\hosts` **as Administrator** (the README's last
  bootstrap step says the same):

  ```
  127.0.0.1  gitops-demo.local gitops-demo-prod.local
  ```

  Without them only `curl -H "Host: gitops-demo.local" http://127.0.0.1/` works,
  which is how `scripts/loadgen.py` reaches the service.
- **Grafana panels are flat or empty.** The metrics only exist while traffic
  flows, and Prometheus keeps its TSDB in an `emptyDir`, so a Docker Desktop
  restart also erases the history. Start the load generator (section B).

## B. Relaunch from scratch

Four terminals. `source scripts/env.sh` first in each — it puts the pinned
`kubectl` on `PATH`.

```bash
cd config-repo
source scripts/env.sh

kubectl -n argocd port-forward svc/argocd-server 8089:80                       # terminal 1
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3002:80   # terminal 2
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9091:9090  # terminal 3
python scripts/loadgen.py --target all --rate 20 --duration 1800               # terminal 4
```

Each `port-forward` dies with its shell, so keep them in their own windows.

`../README.md` and `DEMO.md` document ports **8080 / 3000 / 9090**. On this
laptop 8080 is held by another process and 3000 by the portfolio dev server, so
this file uses 8089 / 3002 / 9091. Free those ports and use the documented
numbers instead — they are what the viva notes say to type.

## C. What to click, in the order that tells the story

1. **Argo CD → Applications → `gitops-demo-dev`.** The resource tree:
   Application → Rollout → AnalysisTemplate → the canary and stable ReplicaSets →
   pods. Point at `SYNC STATUS Synced to main (<sha>)`: that sha *is* the release.
2. **Same page → History and rollback.** The revision list is the release trail;
   every row is one merged promotion PR.
3. **Grafana → Dashboards → "GitOps canary — quality gate as Prometheus sees it"**
   (`http://127.0.0.1:3002/d/gitops-canary/f187a7f`): traffic split by version,
   success rate with the 0.99 line, p95 with the 0.5 s line. Those two lines are
   exactly what the `AnalysisTemplate` asserts.
4. **Prometheus → Graph.** Paste the gate query from
   `apps/gitops-demo/base/analysistemplate.yaml` to show the check is plain
   PromQL, not a black box.
5. **GitHub.** app-repo → Actions (lint, test, build, scan, sign, publish), then
   config-repo → the closed `release: gitops-demo <sha>` pull request. That pair
   is the GitOps claim on one screen.
6. **A live canary to narrate over the top of it:**

   ```bash
   bash scripts/demo-good-release.sh   # ~12 min, ends at 100% in both environments
   bash scripts/demo-bad-release.sh    # ~15 min, ends with the abort and the rollback
   ```

## D. Known fragility

- **The canary dashboard is not in git.** It lives in Grafana's SQLite database,
  which is an `emptyDir`: deleting or restarting the Grafana pod loses it, and
  re-importing means posting the JSON again. Committing it as a ConfigMap that
  the dashboard sidecar loads would make it survive, like every other artifact
  in this project.
- **Grafana's password can drift from the Secret.** The DB keeps whatever the UI
  was last given, and that outranks `GF_SECURITY_ADMIN_PASSWORD` on later boots.
  If the printed password is refused:

  ```bash
  kubectl -n monitoring delete pod -l app.kubernetes.io/name=grafana
  ```

  The fresh database initializes from the Secret, so the documented credential
  is correct again. (README → Troubleshooting carries the same note.)
- **Argo CD tokens expire after 24 h.** If a scripted call starts returning
  401, log in again rather than debugging RBAC:

  ```bash
  PW=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d)
  curl -sk -X POST -H 'Content-Type: application/json' \
    -d "{\"username\":\"admin\",\"password\":\"$PW\"}" \
    https://127.0.0.1:8089/api/v1/session | head -c 60
  ```

## E. Verify the whole thing is up

```bash
cd config-repo
source scripts/env.sh

curl -sk -o /dev/null -w "argocd:%{http_code}\n" https://127.0.0.1:8089/                       # 200 or 302
curl -s  -o /dev/null -w "grafana:%{http_code}\n" http://127.0.0.1:3002/api/health              # 200
curl -s  -o /dev/null -w "prometheus:%{http_code}\n" http://127.0.0.1:9091/-/ready              # 200
curl -s -H "Host: gitops-demo-prod.local" http://127.0.0.1/health                               # {"status":"ok","version":"<sha>",...}
kubectl argo rollouts get rollout gitops-demo -n gitops-demo-dev                                # ✔ Healthy
kubectl argo rollouts get rollout gitops-demo -n gitops-demo-prod                               # ✔ Healthy
```
