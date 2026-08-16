# 9Router — Docker Compose deployment

Runs 9Router plus its `headroom` sidecar on a single host.

| Service | Image | Container port | Role |
|---|---|---|---|
| `9router` | `decolua/9router` | 20128 | The router UI + API |
| `headroom` | `ghcr.io/chopratejas/headroom` | 8787 | Reached by 9Router as `http://headroom:8787` |

## Quick start

```bash
cd docker-compose
cp .env.example .env

# Fill in the required secrets
sed -i '' "s|^JWT_SECRET=.*|JWT_SECRET=$(openssl rand -hex 32)|"      .env
sed -i '' "s|^API_KEY_SECRET=.*|API_KEY_SECRET=$(openssl rand -hex 32)|" .env
sed -i '' "s|^MACHINE_ID_SALT=.*|MACHINE_ID_SALT=$(openssl rand -hex 16)|" .env
# ...then set INITIAL_PASSWORD by hand.

docker compose up -d
docker compose ps
```

On Linux, drop the `''` after `-i`.

Open <http://127.0.0.1:20128> and log in with `INITIAL_PASSWORD`. Change the
password in the UI right after the first login.

## Enabling Headroom (required — it is not automatic)

Setting `HEADROOM_URL` only tells 9Router *where* Headroom is. You must still
turn it on in the dashboard:

> **Endpoint → Token Saver → Headroom** → confirm the URL is
> `http://headroom:8787` → *Recheck status* → enable.

Until you do, the `headroom` container runs but nothing routes through it.

## Everyday commands

```bash
docker compose logs -f 9router      # follow logs
docker compose ps                   # health status
docker compose pull && docker compose up -d   # upgrade
docker compose down                 # stop (data directory is untouched)
```

## Configuration notes

**Pinned in `docker-compose.yml`, not in `.env`.** `DATA_DIR`, `PORT`,
`HOSTNAME`, `NODE_ENV` and `HEADROOM_URL` describe the container's own layout.
Compose's `environment:` block wins over `env_file:`, so setting them in `.env`
does nothing. In particular `DATA_DIR` is `/app/data`, the *container-side*
mount point — pointing it elsewhere would write the database into the
container's ephemeral layer and lose it on the next `up`. To change **where the
data lives on the host**, set `DATA_PATH` instead.

**Ports bind to loopback by default.** `BIND_ADDR=127.0.0.1` keeps the instance
off the network. It holds provider API keys and is not meant to face the
internet directly.

**`headroom` is an internal dependency.** 9Router talks to it over the Compose
network. Its published port exists only for debugging and can be dropped from
`docker-compose.yml` entirely.

**`BASE_URL` vs `NEXT_PUBLIC_BASE_URL`.** `BASE_URL` is used by 9Router's own
sync job calling back into itself, so it must stay `http://127.0.0.1:20128` —
the container-internal address, regardless of which host port you published.
`NEXT_PUBLIC_BASE_URL` is the browser-facing URL and should be the address users
actually type.

**Image tags.** `NINEROUTER_TAG` / `HEADROOM_TAG` default to `latest`. Pin them
in production so a `docker compose pull` cannot swap the running version out
from under you. 9Router tags are bare SemVer with **no leading `v`** —
`NINEROUTER_TAG=0.5.55`, not `v0.5.55`. Both images are multi-arch
(`linux/amd64` + `linux/arm64`).

## Behind a reverse proxy

Terminate TLS in front of 9Router (Caddy, nginx, Traefik) rather than exposing
port 20128. Then in `.env`:

```
AUTH_COOKIE_SECURE=true
NEXT_PUBLIC_BASE_URL=https://9router.example.com
```

Leave `BIND_ADDR=127.0.0.1` if the proxy runs on the same host.

## Data and backup

Everything lives in the host directory set by `DATA_PATH` (default `./data`),
bind-mounted at `/app/data`:

```text
$DATA_PATH/db/data.sqlite     main SQLite database
$DATA_PATH/db/backups/        the app's own automatic backups
```

Set `DATA_PATH` to an absolute path in production — `/var/lib/9router`,
`/srv/9router/data`, a mounted disk. Relative paths resolve against this
directory, so `docker compose` run from elsewhere still lands in the right place.

The container's entrypoint runs `chown -R node:node /app/data` as root before
dropping to the `node` user, so **the directory changes owner to uid/gid 1000 on
the host**. Create it yourself first if that matters to you.

Stop the app before archiving. The database runs in WAL mode, so copying a live
`data.sqlite` + `-wal` + `-shm` can capture a torn state that restores badly.

```bash
# Back up
docker compose stop 9router
sudo tar czf 9router-data-$(date +%F).tar.gz -C "${DATA_PATH:-./data}" .
docker compose start 9router

# Restore
docker compose down
sudo tar xzf 9router-data-2026-08-16.tar.gz -C "${DATA_PATH:-./data}"
docker compose up -d
```

Because it is a plain directory, `rsync`, snapshots, and your existing host
backup tooling work on it directly — no `docker run --rm -v ...` dance.

Neither `docker compose down` nor `docker compose down -v` touches this
directory — with a bind mount, deleting the data is always an explicit `rm` on
the host. That is the main practical gain over the named volume this replaced,
where a stray `down -v` wiped every configured provider and key.

## Troubleshooting

- **`unhealthy` in `docker compose ps`** — the healthcheck calls `/` inside the
  container with Node's `fetch`. Check `docker compose logs 9router`; a missing
  `JWT_SECRET` is the usual cause of a boot failure.
- **Port already in use** — change `HOST_PORT` in `.env`. The container port
  stays 20128 either way.
- **Data directory stays empty on macOS/Windows while the app looks healthy** —
  Docker Desktop only bind-mounts paths on its file-sharing list. Point
  `DATA_PATH` at something outside it and Desktop silently creates the directory
  *inside its VM* instead: the container starts, reports healthy, migrates the
  DB — and nothing appears on your host. `$HOME` is shared by default; add other
  paths under Docker Desktop → Settings → Resources → File sharing.
- **`SQLITE_CANTOPEN` / permission denied on the data directory** — the
  entrypoint's `chown` is silenced (`2>/dev/null`) and fails quietly on some
  filesystems (NFS, rootless Docker with user namespaces). Fix it on the host:
  `sudo chown -R 1000:1000 "$DATA_PATH"`.
- **Upstream provider calls time out** — set `HTTPS_PROXY` in `.env`. Remember
  `127.0.0.1` there means inside the container; use `host.docker.internal` to
  reach a proxy on the host.
