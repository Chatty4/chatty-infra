#!/usr/bin/env bash
# Deploys the latest code on the server (Linux with Docker). Pulls the repos next to chatty-infra,
# rebuilds and replaces only what changed, and waits until it's healthy. Data in the Docker
# volumes is kept; migrations run when the chat and core containers start.
#
#   bash deploy.sh              what changed in the pull
#   bash deploy.sh chat web     these, changed or not: infra, core, chat, web
#   bash deploy.sh all          everything
#
# Uses docker-compose.yml plus the server's docker-compose.prod.yml (web, Caddy and the production
# settings; not in git). The labeler is never deployed: it runs on a laptop (README, Deploy).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE="$(dirname "$ROOT")"
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

deploy_infra() {
  step "infra: recreate what the compose files or .env changed"
  docker compose up -d "${WAIT[@]}"
}

deploy_core() {
  step "core: rebuild and replace"
  docker compose up -d --build "${WAIT[@]}" core
}

deploy_chat() {
  step "chat, relay and push worker: rebuild and replace (one image, so always together)"
  docker compose up -d --build "${WAIT[@]}" chat relay push-worker
  echo "migration: $(docker compose exec -T chat alembic current 2>/dev/null | tail -n 1)"
}

deploy_web() {
  step "web: rebuild and replace (Caddy keeps serving and forwards to the new container)"
  docker compose up -d --build "${WAIT[@]}" web
  # The served files, not the source: proves the new build is the one Nginx sends.
  docker compose exec -T web wget -q -O /dev/null http://127.0.0.1/ || fail "web doesn't answer"
  echo "ok  web"
}

main() {
  cd "$ROOT"
  if [[ -f docker-compose.prod.yml ]]; then
    export COMPOSE_FILE="docker-compose.yml:docker-compose.prod.yml"
  else
    echo "No docker-compose.prod.yml: deploying with docker-compose.yml only."
  fi

  local targets=("$@") changed=() repo target
  if [[ "${targets[*]:-}" == "all" ]]; then targets=(infra core chat web); fi
  for target in "${targets[@]}"; do
    [[ "$target" =~ ^(infra|core|chat|web)$ ]] || fail "unknown target: $target (infra, core, chat, web, all)"
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
