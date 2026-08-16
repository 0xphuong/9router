# ninerouter

Helm chart for 9Router and its Headroom token-saver sidecar.

| Workload | Kind | Why |
|---|---|---|
| 9Router | **StatefulSet** | Keeps all state in a local SQLite database; needs a stable identity and its own volume |
| Headroom | **Deployment** | Stateless proxy; any replica serves any request |

## Why the chart is called `ninerouter`

Kubernetes validates Service names as **RFC 1035 labels**, which must start with
a letter. A Service named `9router` is rejected by the API server outright. The
chart, its resources and its labels therefore use `ninerouter` — matching the
Ansible role name. Anything you pass to `nameOverride` / `fullnameOverride` must
also start with a letter.

## Install

The chart will not invent a signing key, so give it secrets one of two ways.

**Existing Secret (recommended):**

```bash
kubectl create secret generic ninerouter-auth \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=INITIAL_PASSWORD='choose-one' \
  --from-literal=API_KEY_SECRET="$(openssl rand -hex 32)" \
  --from-literal=MACHINE_ID_SALT="$(openssl rand -hex 16)"

helm install ninerouter ./helm/ninerouter \
  --set auth.existingSecret=ninerouter-auth
```

**Chart-managed Secret:**

```bash
helm install ninerouter ./helm/ninerouter \
  --set auth.jwtSecret="$(openssl rand -hex 32)" \
  --set auth.initialPassword='choose-one' \
  --set auth.apiKeySecret="$(openssl rand -hex 32)" \
  --set auth.machineIdSalt="$(openssl rand -hex 16)"
```

Rendering fails with an explanation if neither is supplied. A generated key is
deliberately not offered: it would rotate on every `helm upgrade` and log every
user out.

Then **enable Headroom in the dashboard** — `HEADROOM_URL` only tells 9Router
where it is. Go to **Endpoint → Token Saver → Headroom**, confirm the URL shown
in `helm status`, recheck, enable.

## Values

Full list in `values.yaml`. The ones that matter:

| Key | Default | Notes |
|---|---|---|
| `ninerouter.image.tag` | `.Chart.AppVersion` (`0.5.55`) | Bare SemVer, no leading `v` |
| `ninerouter.replicaCount` | `1` | **Must stay 1** — see below |
| `ninerouter.persistence.enabled` | `true` | `false` uses emptyDir and loses the database |
| `ninerouter.persistence.size` | `8Gi` | |
| `ninerouter.persistence.storageClassName` | `""` | `""` = cluster default, `"-"` = no dynamic provisioning |
| `ninerouter.persistence.existingClaim` | `""` | Bypasses the volumeClaimTemplate |
| `headroom.enabled` | `true` | `false` removes the sidecar and `HEADROOM_URL` |
| `auth.existingSecret` | `""` | Needs keys `JWT_SECRET`, `INITIAL_PASSWORD`, `API_KEY_SECRET`, `MACHINE_ID_SALT` |
| `config.authCookieSecure` | `false` | Set `true` when serving over HTTPS |
| `ingress.enabled` | `false` | |
| `networkPolicy.enabled` | `false` | Restricts Headroom to 9Router pods only |
| `extraEnv` | `{}` | Merged last; values must be strings |

### `replicaCount` must be 1

9Router's state is a SQLite file on a ReadWriteOnce volume. With a StatefulSet,
each replica gets its **own** PersistentVolumeClaim — so a second replica would
come up with a second, empty database rather than sharing the first. Providers
and keys configured on one pod would be invisible on the other, and which one
you hit would depend on Service load-balancing. The chart refuses to render
above 1 rather than let that happen quietly.

### Security context

The image entrypoint runs as **root** to `chown -R node:node /app/data`, then
drops to uid 1000 with `su-exec`. So:

- **Do not set `runAsNonRoot: true` or `runAsUser`** on the 9Router pod. The
  chown fails silently (the entrypoint redirects its stderr to `/dev/null`) and
  the app cannot open its database.
- `fsGroup: 1000` is what actually makes the mounted volume writable.
- Capabilities are dropped to `ALL` and only `CHOWN`, `DAC_OVERRIDE`, `SETUID`
  and `SETGID` are added back — the minimum the entrypoint needs.
  `allowPrivilegeEscalation: false` is safe here because `su-exec` drops
  privileges rather than gaining them.

This set is verified: under exactly these capabilities plus `no-new-privileges`,
the main process runs as uid 1000 and the database initializes normally.

### Pinned by the chart

`DATA_DIR`, `PORT`, `HOSTNAME` and `HEADROOM_URL` describe the container's own
layout and are not exposed as values. `DATA_DIR` must stay `/app/data`, the
volume mount path, or the database lands on the pod's ephemeral filesystem and
is lost on the next restart. `HEADROOM_URL` is derived from the Headroom
Service name so the two cannot drift apart.

`config.baseUrl` is 9Router's own sync job calling back into itself, so it stays
at the pod-internal `http://127.0.0.1:20128` regardless of the Service port.

## Operations

```bash
helm status ninerouter                                    # includes the login instructions
helm test ninerouter                                      # in-cluster connectivity check
helm upgrade ninerouter ./helm/ninerouter --reuse-values --set ninerouter.image.tag=0.5.55
kubectl rollout status statefulset/ninerouter
```

Access without an ingress:

```bash
kubectl port-forward svc/ninerouter 20128:20128
```

### Data

The volume comes from the StatefulSet's `volumeClaimTemplate`, so it is created
by the StatefulSet controller rather than by Helm — **`helm uninstall` leaves the
PVC behind.** That is deliberate: reinstalling the release reattaches the
existing data. To actually delete the data:

```bash
kubectl delete pvc data-ninerouter-0
```

Back up by snapshotting the PVC, or by copying the database out with the app
stopped — SQLite runs in WAL mode, so copying a live `data.sqlite` plus its
`-wal`/`-shm` files can capture a torn state.

## Relation to the other deployments

`../../docker-compose/` and `../../ansible/` deploy the same two containers
outside Kubernetes. Settings, guardrails and pinned values are kept consistent
across all three.
