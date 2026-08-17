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
Ansible role name.

**This applies to the release name too.** Resource names are built as
`<release>-<chart>`, so installing under a release called `9router` produces
`9router-ninerouter` and the same rejection:

```
Service "9router-ninerouter" is invalid: metadata.name: Invalid value:
a DNS-1035 label must ... start with an alphabetic character
```

The chart checks this before rendering and fails with the fix rather than
letting the API server reject it. Either use a release name that starts with a
letter:

```bash
helm install ninerouter ./helm/ninerouter
```

or keep the release name and override the resource names:

```bash
helm install 9router ./helm/ninerouter --set fullnameOverride=ninerouter
```

The same applies to anything you pass to `nameOverride` / `fullnameOverride`.
With helmfile, the release `name:` is what matters:

```yaml
releases:
  - name: 9router            # fine, as long as...
    chart: ./ninerouter
    values:
      - fullnameOverride: ninerouter   # ...this is set
```

## Install

`values.yaml` ships **sample** secrets so the chart installs out of the box:

```bash
helm install ninerouter ./helm/ninerouter
```

> **The samples are committed to this repository, so they are public.** Anyone
> who can read the chart can forge a session token against an instance still
> running them. The chart prints a warning after install until you replace them.
> Do that before the instance is reachable by anyone but you.

Replace them one of three ways.

**1. `--set` on the command line** — not in git, but it does land in your shell
history and in `helm get values`:

```bash
helm upgrade --install ninerouter ./helm/ninerouter \
  --set auth.jwtSecret="$(openssl rand -hex 32)" \
  --set auth.initialPassword='choose-one' \
  --set auth.apiKeySecret="$(openssl rand -hex 32)" \
  --set auth.machineIdSalt="$(openssl rand -hex 16)"
```

**2. An existing Secret** — created out of band, so the values never pass
through Helm at all:

```bash
kubectl create secret generic ninerouter-auth \
  --from-literal=JWT_SECRET="$(openssl rand -hex 32)" \
  --from-literal=INITIAL_PASSWORD='choose-one' \
  --from-literal=API_KEY_SECRET="$(openssl rand -hex 32)" \
  --from-literal=MACHINE_ID_SALT="$(openssl rand -hex 16)"

helm install ninerouter ./helm/ninerouter \
  --set auth.existingSecret=ninerouter-auth
```

`auth.existingSecret` overrides the sample values entirely — no Secret is
rendered and the warning goes away.

**3. helm-secrets** — encrypted at rest in git. See below.

The chart will not generate a key for you: a generated one would rotate on every
`helm upgrade` and log every user out. It does still fail rendering if you blank
the values out without setting `auth.existingSecret`.

### Moving to helm-secrets

`secrets.yaml.example` is ready for this.

```bash
helm plugin install https://github.com/jkroepke/helm-secrets

cd helm/ninerouter
cp secrets.yaml.example secrets.yaml
$EDITOR secrets.yaml                 # fill in real values
sops --encrypt --in-place secrets.yaml

helm secrets upgrade --install ninerouter . -f secrets.yaml
```

`secrets.yaml` is gitignored so a decrypted copy cannot be committed by
accident; commit the SOPS-encrypted form under a different name if you want it
in git. Values from that file override the samples, which also silences the
warning.

### Rotating

Changing `JWT_SECRET` invalidates every existing session — users log in again.
`INITIAL_PASSWORD` only seeds the first login; once you have changed the
password in the UI, changing this value does nothing.

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
| `ninerouter.persistence.mode` | `dynamic` | `dynamic`, `manual` or `existing` — see below |
| `ninerouter.persistence.size` | `8Gi` | |
| `ninerouter.persistence.storageClassName` | `""` | `dynamic` mode: `""` = cluster default, `"-"` = none |
| `ninerouter.persistence.existingClaim` | `""` | `existing` mode |
| `ninerouter.persistence.manual.path` | `/mnt/data/ninerouter` | `manual` mode: path on the node |
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

## Storage

Three modes, selected with `ninerouter.persistence.mode`.

### `dynamic` (default)

The StatefulSet's `volumeClaimTemplate` asks a StorageClass for a volume.

```bash
helm install ninerouter ./helm/ninerouter \
  --set auth.existingSecret=ninerouter-auth \
  --set ninerouter.persistence.storageClassName=fast-ssd \
  --set ninerouter.persistence.size=20Gi
```

### `manual` — a PV at a path you choose

For clusters with no dynamic provisioner, or when the database must live on a
known disk. The chart creates **both** the PersistentVolume and the
PersistentVolumeClaim and binds them to each other exclusively — `claimRef` on
the PV, `volumeName` on the PVC — so no other claim in the cluster can take the
volume.

```bash
# The recommended form: a local volume pinned to one node.
helm install ninerouter ./helm/ninerouter \
  --set auth.existingSecret=ninerouter-auth \
  --set ninerouter.persistence.mode=manual \
  --set ninerouter.persistence.manual.type=local \
  --set ninerouter.persistence.manual.path=/mnt/disks/ninerouter \
  --set ninerouter.persistence.manual.nodeName=worker-01
```

**Create the directory on that node first** — a `local` volume will not create
it:

```bash
ssh worker-01 'sudo mkdir -p /mnt/disks/ninerouter'
```

Ownership is handled for you: the image entrypoint runs as root and chowns
`/app/data` to uid 1000 before dropping privileges.

`local` vs `hostPath`:

| | `local` | `hostPath` |
|---|---|---|
| Node affinity | **Required** — the API server rejects a local PV without it | Optional |
| Creates the directory | No | Yes, with `hostPathType: DirectoryOrCreate` |
| Multi-node safe | Yes, the scheduler keeps the pod with its data | **No** — see below |

The chart refuses to render a `local` PV without `nodeName` or `nodeAffinity`,
because the API server would reject it anyway.

`hostPath` without `nodeName` is accepted but dangerous: any node satisfies the
volume, so a rescheduled pod comes up against an empty directory on a different
node and looks like it lost its data. The chart prints a warning for that
combination. It is fine on a single-node cluster.

Other knobs:

| Key | Default | Notes |
|---|---|---|
| `manual.type` | `local` | or `hostPath` |
| `manual.nodeName` | `""` | Sets affinity on `kubernetes.io/hostname` |
| `manual.nodeAffinity` | `{}` | Full override, used verbatim instead of `nodeName` |
| `manual.storageClassName` | `""` | PV and PVC must agree; `""` keeps the default provisioner out |
| `manual.reclaimPolicy` | `Retain` | `Delete` would let the cluster wipe the directory |
| `manual.hostPathType` | `DirectoryOrCreate` | `hostPath` only |
| `manual.createPV` | `true` | `false` creates only the PVC, for a PV you made yourself |
| `manual.keepOnUninstall` | `true` | Annotates PV and PVC with `helm.sh/resource-policy: keep` |

`keepOnUninstall` matters more than it looks. Unlike a `volumeClaimTemplate`
PVC — which Helm never owned and therefore never deletes — a `manual` PV and PVC
*are* chart resources, so `helm uninstall` would remove them. `Retain` keeps the
bytes on disk either way, but without the annotation a reinstall would find a
released volume it cannot rebind. Leaving this on means a reinstall picks the
data straight back up.

### `existing` — a PVC you already made

```bash
helm install ninerouter ./helm/ninerouter \
  --set auth.existingSecret=ninerouter-auth \
  --set ninerouter.persistence.mode=existing \
  --set ninerouter.persistence.existingClaim=my-pvc
```

The chart creates no storage objects and mounts that claim directly.

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

In `dynamic` mode the volume comes from the StatefulSet's `volumeClaimTemplate`,
so it is created by the StatefulSet controller rather than by Helm — **`helm
uninstall` leaves the PVC behind.** That is deliberate: reinstalling the release
reattaches the existing data. To actually delete it:

```bash
kubectl delete pvc data-ninerouter-0        # dynamic mode
kubectl delete pvc ninerouter-data          # manual mode
kubectl delete pv <namespace>-ninerouter-data
```

In `manual` mode the data also remains in the directory on the node after the PV
is gone; remove it there if you want it gone for good.

Back up by snapshotting the PVC, or by copying the database out with the app
stopped — SQLite runs in WAL mode, so copying a live `data.sqlite` plus its
`-wal`/`-shm` files can capture a torn state.

## Relation to the other deployments

`../../docker-compose/` and `../../ansible/` deploy the same two containers
outside Kubernetes. Settings, guardrails and pinned values are kept consistent
across all three.
