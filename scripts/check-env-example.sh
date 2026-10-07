#!/usr/bin/env bash
# Checks that .env.example and docker-compose.yml use the same variables.
# Every ${VAR} in the compose file must be listed in .env.example, and every variable in
# .env.example must be used by the compose file. $${VAR} is resolved inside the container, so it is skipped.
#
# Run from the repo root: bash scripts/check-env-example.sh
set -euo pipefail

compose_file="${1:-docker-compose.yml}"
env_file="${2:-.env.example}"

compose_vars="$(grep -oE '(^|[^$])\$\{[A-Za-z_][A-Za-z0-9_]*' "$compose_file" \
  | grep -oE '[A-Za-z_][A-Za-z0-9_]*$' | sort -u)"
env_vars="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*=' "$env_file" | tr -d '=' | sort -u)"

missing="$(comm -23 <(echo "$compose_vars") <(echo "$env_vars"))"
unused="$(comm -13 <(echo "$compose_vars") <(echo "$env_vars"))"

status=0
if [[ -n "$missing" ]]; then
  echo "Used in $compose_file but missing from $env_file:"
  sed 's/^/  - /' <<< "$missing"
  status=1
fi
if [[ -n "$unused" ]]; then
  echo "Listed in $env_file but not used in $compose_file:"
  sed 's/^/  - /' <<< "$unused"
  status=1
fi

if [[ $status -eq 0 ]]; then
  echo "$env_file and $compose_file use the same $(wc -l <<< "$compose_vars") variables."
fi
exit $status
