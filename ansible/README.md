# 9Router — Ansible deployment

Deploys 9Router and its Headroom sidecar as Docker containers using the
`community.docker` container modules directly. No `docker-compose.yml` is copied
to the target and nothing shells out to `docker compose` — Ansible owns the
container, network and image state.

```
ansible/
├── site.yml                        the playbook
├── ansible.cfg
├── requirements.yml                collection dependencies
├── inventory/hosts.yml             example inventory
├── group_vars/ninerouter/
│   ├── vars.yml                    non-secret settings
│   └── vault.yml.example           template for the encrypted secrets
└── roles/
    ├── docker_engine/              installs Docker CE (skipped if already present)
    └── ninerouter/                 the deployment itself
```

## Quick start

```bash
cd ansible
ansible-galaxy collection install -r requirements.yml

# Point the inventory at your host
$EDITOR inventory/hosts.yml

# Create the encrypted secrets
cp group_vars/ninerouter/vault.yml.example group_vars/ninerouter/vault.yml
$EDITOR group_vars/ninerouter/vault.yml     # openssl rand -hex 32
ansible-vault encrypt group_vars/ninerouter/vault.yml

ansible-playbook site.yml --ask-vault-pass
```

The play ends by printing the address it verified as healthy.

**Then enable the sidecar in the dashboard** — `HEADROOM_URL` only tells 9Router
where Headroom is. Go to **Endpoint → Token Saver → Headroom**, confirm the URL
is `http://headroom:8787`, recheck status, enable. Until you do, the container
runs but nothing routes through it.

## What the role does

1. Refuses to run if the secrets are empty or still at upstream's placeholders.
2. Refuses a relative `ninerouter_data_path`.
3. Creates the data directory owned by uid/gid 1000.
4. Pulls both images (`docker_image_pull`).
5. Creates a user-defined network, which is what gives 9Router DNS for the
   `headroom` name.
6. Starts `headroom` and **waits for its built-in `/readyz` healthcheck** before
   continuing, because 9Router reads the Headroom status at boot.
7. Starts `9router` with a Node `fetch` healthcheck and waits for healthy.

Idempotent — a second run reports `changed=0`. The container tasks use
`no_log: true` because the environment carries `JWT_SECRET` and
`INITIAL_PASSWORD`.

## Common operations

```bash
# Upgrade to a new image
ansible-playbook site.yml --ask-vault-pass -e ninerouter_image_tag=0.5.55

# Re-pull floating tags and recreate if the image moved
ansible-playbook site.yml --ask-vault-pass --tags ninerouter

# Validate config without touching the host
ansible-playbook site.yml --ask-vault-pass --tags ninerouter_validate

# Stop and remove the containers (the data directory is left alone)
ansible-playbook site.yml --ask-vault-pass -e ninerouter_state=absent

# Check mode
ansible-playbook site.yml --ask-vault-pass --check --diff
```

## Variables worth setting

Full list with comments in `roles/ninerouter/defaults/main.yml`.

| Variable | Default | Notes |
|---|---|---|
| `ninerouter_image_tag` | `latest` | Bare SemVer, **no leading `v`** — `0.5.55` |
| `ninerouter_data_path` | `/var/lib/9router` | Must be absolute; holds the SQLite DB |
| `ninerouter_bind_addr` | `127.0.0.1` | `0.0.0.0` only behind a TLS proxy |
| `ninerouter_host_port` | `20128` | Container port is always 20128 |
| `ninerouter_headroom_publish` | `true` | `false` keeps the sidecar off the host entirely |
| `ninerouter_auth_cookie_secure` | `false` | Set `true` when served over HTTPS |
| `ninerouter_docker_host` | `unix:///var/run/docker.sock` | See below |
| `ninerouter_extra_env` | `{}` | Merged last; overrides anything above |
| `ninerouter_state` | `started` | `absent` tears the containers down |
| `ninerouter_health_timeout` | `180` | Seconds to wait for healthy |

`ninerouter_extra_env` values are cast to strings for you, but a YAML boolean
becomes `"True"`/`"False"` — which the app does not read as a boolean. Write
booleans as lowercase strings there: `ENABLE_REQUEST_LOGS: "true"`.

### Non-standard Docker sockets

`ninerouter_docker_host` defaults to the usual root daemon. Override for:

- rootless Docker — `unix:///run/user/1000/docker.sock`
- Docker Desktop — `unix://{{ ansible_env.HOME }}/.docker/run/docker.sock`

### Pinned by the role

`DATA_DIR`, `PORT`, `HOSTNAME` and `HEADROOM_URL` describe the container's own
layout and are not exposed as variables. `DATA_DIR` in particular must stay
`/app/data` — the bind-mount target — or the database lands in the container's
writable layer and disappears on the next recreate. Set `ninerouter_data_path`
to change where the data lives *on the host*.

`BASE_URL` is 9Router's own sync job calling back into itself, so it stays at
the container-internal address regardless of the published host port.

## Requirements

- **Control node:** ansible-core ≥ 2.15, collections from `requirements.yml`.
- **Target:** SSH + sudo; Debian/Ubuntu or RHEL family if you want
  `docker_engine` to install Docker. Set `docker_engine_install=false` if Docker
  is managed elsewhere — the role also auto-skips installation when the daemon
  already answers.
- The `community.docker` modules run **on the target** and need `python3-requests`
  there. `docker_engine` installs it on Debian/RHEL hosts.

## Relation to the compose deployment

`../docker-compose/` deploys the same two containers with the same settings for
single-host use. This role is the multi-host / fleet path and is the one that
owns state; do not point both at the same host.
