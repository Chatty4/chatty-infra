# chatty-infra
Docker compose setup, API contracts and event docs for running Chatty locally.

## Getting started

You need Git, Docker Desktop and, for local virtualenvs, Python 3.14.

1. Make an empty folder and clone this repo into it:

   ```bash
   git clone https://github.com/Chatty4/chatty-infra.git C:\chatty\chatty-infra
   ```

2. Run `setup.bat`. It clones the other repos next to this one on `dev`, creates every `.env` from its
   `.env.example` with matching secrets, creates the JWT key pair in `chatty-core/keys` once (new keys
   would log everyone out), creates `chatty.code-workspace`, can set up the virtualenvs and start the
   stack, and last creates the Kafka topic `chat.events` and the MinIO bucket `chatty` (it starts Kafka
   and MinIO for that). It is safe to run again: it never overwrites a value you set and never touches
   a repo with uncommitted changes.

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
| `setup.bat` | Clone the repos, create `.env` files, virtualenvs, the Kafka topic, the MinIO bucket | `setup.bat --yes` |
| `start.bat` | Start everything, infra only, or chosen services; waits for health checks | `start.bat all`, `start.bat infra`, `start.bat apps --build` |
| `stop.bat` | Stop containers, or remove them; data is always kept | `stop.bat all`, `stop.bat apps`, `stop.bat down` |
| `restart.bat` | Restart, recreate (compose or `.env` changes) or rebuild (`requirements.txt` changes) | `restart.bat core`, `restart.bat chat --build` |
| `migrate.bat` | Status, apply, make, check and roll back migrations for core and chat | `migrate.bat all status`, `migrate.bat chat apply` |
| `logs.bat` | Follow logs, last lines, or errors only | `logs.bat core`, `logs.bat chat --errors` |
| `status.bat` | Containers, app health and the branch of every repo; can refresh every 5 seconds | `status.bat --once` |
| `test.bat` | The CI checks inside the containers: ruff, pre-test checks, pytest; or fix lint | `test.bat all`, `test.bat chat tests` |
| `shell.bat` | Django shell, bash, psql, redis-cli, MinIO console | `shell.bat psql-core`, `shell.bat redis` |
| `reset-db.bat` | Wipe `core_db`, `chat_db` or every volume; backs up to `backups\` first. Every volume also deletes the Kafka topic and the MinIO bucket: they are created again if you start again, otherwise run `setup.bat` | always asks |

The core and chat containers apply pending migrations every time they start, so `migrate.bat` is for
everything else: status, new migrations, checks and rollbacks. Set `NO_COLOR=1` to turn off colors.

## Services and ports

| Service | Address | |
|---|---|---|
| `core` | <http://127.0.0.1:8000> | chatty-core API, `/health` |
| `chat` | <http://127.0.0.1:8001> | chatty-chat API, `/health` |
| `relay` | – | Outbox relay: sends `channel_events` to Kafka. No port; `logs.bat relay` |
| `core-db` | `127.0.0.1:5432` | Postgres, `core_db` |
| `chat-db` | `127.0.0.1:5433` | Postgres, `chat_db` |
| `redis` | `127.0.0.1:6379` | Redis |
| `minio` | <http://127.0.0.1:9001> | MinIO console, API on 9000 |
| `kafka` | `127.0.0.1:9092` | Kafka |

Ports come from `.env.example`; override them in `.env`. Use `127.0.0.1`, not `localhost`: Docker
publishes the ports on IPv4 only, and Windows tries `localhost` as IPv6 first.

Without the scripts, the same with plain compose: `docker compose up -d --wait`, `docker compose stop`.

## MinIO

All files are in one private bucket, `chatty`, separated by prefix (D-14 in `docs/decisions.md`):
`uploads/` (temporary, until `confirm`), `avatars/`, `team-icons/`, `attachments/`. `setup.bat`
creates it from the files in `minio/`, and it is safe to run again:

| File | What it sets |
|---|---|
| `minio/lifecycle.json` | objects in `uploads/` are deleted after 1 day |
| `minio/chatty-core.json` | policy of the `chatty-core` user: list the bucket, read, write and delete files |
| `minio/chatty-chat.json` | policy of the `chatty-chat` user: read `attachments/` only (D-02) |

- Each service uses its own user, never the root user. `setup.bat` puts a random secret for each in
  `.env` (`CORE_MINIO_SECRET_KEY`, `CHAT_MINIO_SECRET_KEY`) and sets it in MinIO every time it runs.
- For runs outside Docker, `setup.bat` also copies each secret to `MINIO_SECRET_KEY` in
  `chatty-core/.env` and `chatty-chat/.env`, overwriting it every time: `chatty-infra/.env` is the
  source, so the copies can't drift from MinIO.
- The bucket name `chatty` is fixed: it is also in the policy files.
- Services sign URLs with `MINIO_PUBLIC_URL` (`http://127.0.0.1:9000`), the address the browser
  reaches; chatty-core's own calls use `MINIO_INTERNAL_URL` (`http://minio:9000`) (D-16).
- CORS: MinIO allows every origin by default, so browser uploads from the web app work locally.
  Production sets `MINIO_API_CORS_ALLOW_ORIGIN` to the web app's origin.
- Changed a file in `minio/`? Run `setup.bat --yes` again.

## Contracts

The API contracts, events and decisions shared by chatty-core and chatty-chat live in `docs/`. Change
them here first, in their own PR, before changing a service.

## Postman

`postman/chatty.postman_collection.json` has a request for every built chatty-core and chatty-chat endpoint, and
`postman/chatty-local.postman_environment.json` points it at the local stack. Import both into Postman, or
run the collection with the Postman CLI.
