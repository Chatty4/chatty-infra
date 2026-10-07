# chatty-infra
Docker compose setup, API contracts and event docs for running Chatty locally.

## Getting started

You need Git, Docker Desktop and, for local virtualenvs, Python 3.14.

1. Make an empty folder and clone this repo into it:

   ```bash
   git clone https://github.com/Chatty4/chatty-infra.git C:\chatty\chatty-infra
   ```

2. Run `setup.bat`. It clones the other repos next to this one on `dev`, creates every `.env` from its
   `.env.example` with matching secrets, creates `chatty.code-workspace`, and can set up the virtualenvs
   and start the stack. It is safe to run again: it never overwrites a value you set and never touches a
   repo with uncommitted changes.

```text
C:\chatty\
  chatty-infra\    this repo: docker-compose.yml, docs, scripts
  chatty-core\     Django service
  chatty-chat\     FastAPI service
  chatty-web\      React app
  .github\         PR templates and the shared CI workflow
  chatty.code-workspace
```

## Scripts

Double-click `chatty.bat` for a menu with all of them. Each one also works on its own: double-clicked it
asks, and with arguments it runs without questions (see the top of each file).

| Script | What it does | Without questions |
|---|---|---|
| `setup.bat` | Clone the repos, create `.env` files, virtualenvs | `setup.bat --yes` |
| `start.bat` | Start everything, infra only, or chosen services; waits for health checks | `start.bat all`, `start.bat infra`, `start.bat apps --build` |
| `stop.bat` | Stop containers, or remove them; data is always kept | `stop.bat all`, `stop.bat apps`, `stop.bat down` |
| `restart.bat` | Restart, recreate (compose or `.env` changes) or rebuild (`requirements.txt` changes) | `restart.bat core`, `restart.bat chat --build` |
| `migrate.bat` | Status, apply, make, check and roll back migrations for core and chat | `migrate.bat all status`, `migrate.bat chat apply` |
| `logs.bat` | Follow logs, last lines, or errors only | `logs.bat core`, `logs.bat chat --errors` |
| `status.bat` | Containers, app health and the branch of every repo; can refresh every 5 seconds | `status.bat --once` |
| `test.bat` | The CI checks inside the containers: ruff, pre-test checks, pytest; or fix lint | `test.bat all`, `test.bat chat tests` |
| `shell.bat` | Django shell, bash, psql, redis-cli, MinIO console | `shell.bat psql-core`, `shell.bat redis` |
| `reset-db.bat` | Wipe `core_db`, `chat_db` or every volume; backs up to `backups\` first | always asks |

`migrate.bat` won't migrate `core_db` before chatty-core has its custom User model, as chatty-core's
`CLAUDE.md` asks. Set `NO_COLOR=1` to turn off colors.

## Services and ports

| Service | Address | |
|---|---|---|
| `core` | <http://127.0.0.1:8000> | chatty-core API, `/health` |
| `chat` | <http://127.0.0.1:8001> | chatty-chat API, `/health` |
| `core-db` | `127.0.0.1:5432` | Postgres, `core_db` |
| `chat-db` | `127.0.0.1:5433` | Postgres, `chat_db` |
| `redis` | `127.0.0.1:6379` | Redis |
| `minio` | <http://127.0.0.1:9001> | MinIO console, API on 9000 |
| `kafka` | `127.0.0.1:9092` | Kafka |

Ports come from `.env.example`; override them in `.env`. Use `127.0.0.1`, not `localhost`: Docker
publishes the ports on IPv4 only, and Windows tries `localhost` as IPv6 first.

Without the scripts, the same with plain compose: `docker compose up -d --wait`, `docker compose stop`.

## Contracts

The API contracts, events and decisions shared by chatty-core and chatty-chat live in `docs/`. Change
them here first, in their own PR, before changing a service.
