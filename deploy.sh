#!/usr/bin/env bash
# Deploys the latest code on the server (Linux with Docker). Pulls the repos next to chatty-infra,
# rebuilds and replaces only what changed, then checks that everything answers. Data in the Docker
# volumes is kept; migrations run when the chat and core containers start.
#
#   bash deploy.sh              what changed in the pull
#   bash deploy.sh chat web     these, changed or not: infra, core, chat, web
#   bash deploy.sh all          everything
#
# The web container's settings come from deploy.env next to this file (copy deploy.env.example).
# The labeler is never deployed: it runs on a laptop against the server (README, Deploy).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$ROOT")"
NETWORK="chatty_default" # compose's `name: chatty`
WAIT=(--wait --wait-timeout 180)

step() { printf '\n== %s\n' "$*"; }
fail() {
  printf 'deploy: %s\n' "$*" >&2
  exit 1
}

# Pulls one repo and prints its name if new commits came in. Refuses a clone with local changes.
pull() {
  local repo="$1" dir="$WORKSPACE/$1" before
  [[ -d "$dir/.git" ]] || fail "$dir is not a clone"
  [[ -z "$(git -C "$dir" status --porcelain --untracked-files=no)" ]] ||
    fail "$repo has local changes: commit, stash or discard them first"
  before="$(git -C "$dir" rev-parse HEAD)"
  git -C "$dir" pull --ff-only --quiet
  [[ "$(git -C "$dir" rev-parse HEAD)" == "$before" ]] || echo "$repo"
}

answers() {
  curl -fsS -o /dev/null --max-time 10 "$1" || fail "$1 doesn't answer"
  echo "ok  $1"
}

# A container's published address for a port, as a URL the server itself can call.
local_url() { echo "http://$(docker port "$1" "$2" | head -n 1 | sed 's/^0\.0\.0\.0/127.0.0.1/')"; }

deploy_infra() {
  step "infra: recreate what docker-compose.yml or .env changed"
  docker compose up -d "${WAIT[@]}"
}

deploy_core() {
  step "core: rebuild and replace"
  docker compose up -d --build "${WAIT[@]}" core
  answers "$(local_url chatty-core 8000)/health"
}

deploy_chat() {
  step "chat, relay and push worker: rebuild and replace (one image, so always together)"
  docker compose up -d --build "${WAIT[@]}" chat relay push-worker
  answers "$(local_url chatty-chat 8001)/health"
  echo "migration: $(docker exec chatty-chat alembic current 2>/dev/null | tail -n 1)"
}

deploy_web() {
  step "web: build the image, then replace the container"
  [[ -f "$ROOT/deploy.env" ]] || fail "missing deploy.env: copy deploy.env.example and fill it in"
  # shellcheck source=/dev/null
  source "$ROOT/deploy.env"
  : "${WEB_CONTAINER:?set in deploy.env}" "${WEB_PUBLISH:?set in deploy.env}"
  : "${MINIO_PUBLIC_URL:?set in deploy.env}"

  # Built before the old container goes: a failed build leaves the site running.
  docker build --quiet -t chatty-web:latest \
    --build-arg VITE_VAPID_PUBLIC_KEY="${VITE_VAPID_PUBLIC_KEY:-}" \
    --build-arg VITE_GIPHY_API_KEY="${VITE_GIPHY_API_KEY:-}" \
    "$WORKSPACE/chatty-web" >/dev/null
  docker rm -f "$WEB_CONTAINER" >/dev/null 2>&1 || true
  docker run -d --name "$WEB_CONTAINER" --restart unless-stopped --network "$NETWORK" \
    -p "$WEB_PUBLISH" -e MINIO_PUBLIC_URL="$MINIO_PUBLIC_URL" chatty-web:latest >/dev/null
  sleep 2 # Nginx fills in its config template at start
  answers "$(local_url "$WEB_CONTAINER" 80)/"
}

main() {
  cd "$ROOT"
  local targets=("$@") changed=() repo
  if [[ "${targets[*]:-}" == "all" ]]; then targets=(infra core chat web); fi
  for repo in "${targets[@]}"; do
    [[ "$repo" =~ ^(infra|core|chat|web)$ ]] || fail "unknown target: $repo (infra, core, chat, web, all)"
  done

  step "Pulling"
  for repo in chatty-infra chatty-core chatty-chat chatty-web; do
    if [[ -n "$(pull "$repo")" ]]; then
      changed+=("${repo#chatty-}")
      echo "new  $repo"
    else
      echo "     $repo"
    fi
  done

  if [[ ${#targets[@]} -eq 0 ]]; then targets=("${changed[@]}"); fi
  if [[ ${#targets[@]} -eq 0 ]]; then
    echo "Nothing new to deploy."
    return
  fi

  local target
  # infra first: the apps may need its new settings.
  for target in infra core chat web; do
    if [[ " ${targets[*]} " == *" $target "* ]]; then
      "deploy_$target"
    fi
  done

  step "Done"
  docker compose ps --format 'table {{.Name}}\t{{.Status}}'
}

# Inside a function and called last: bash reads the whole script first, so pulling a new
# deploy.sh in chatty-infra can't change the run that's already going.
main "$@"
