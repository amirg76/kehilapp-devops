#!/usr/bin/env bash
# Deploys kehilapp on the shared box. Runs ON the box, from /opt/kehilapp, after
# `git pull`.
#
#   bash scripts/deploy-shared-box.sh build-57     # that build; see runbook 00
#   bash scripts/deploy-shared-box.sh rollback     # back to the last good tag
#
# Passing means the right app answered at the right address, not that something
# answered: on 2026-10-29 / served the admin panel with a 200, and a status check
# stayed green for 41 hours. Prints statuses only, never .env values.
set -euo pipefail
cd "$(dirname "$0")/.."

HOST=${DEPLOY_HOST:-kehilapp.letstalkanddesign.com}
C="docker compose -f docker-compose.prod.yml -f docker-compose.shared-box.yml --env-file .env"
PREV_FILE=.deploy-previous-tag
# Exists from `up` until the checks pass. While it is there, the tag in .env is not
# known good, so it must not become the rollback target.
MARK=.deploy-in-progress
ARG=${1:?usage: deploy-shared-box.sh <tag> | rollback}

env_value() { sed -n "s/^$1=//p" .env | tail -1 | tr -d "\r\"'"; }
REG=$(env_value REGISTRY)
BEFORE=$(env_value TAG)
[ -n "$REG" ] && [ -n "$BEFORE" ] || { echo "REGISTRY or TAG missing from .env"; exit 1; }

if [ "$ARG" = rollback ]; then
  [ -s "$PREV_FILE" ] || { echo "no previous tag recorded"; exit 1; }
  TAG=$(cat "$PREV_FILE")
else
  TAG=$ARG
fi
case "$TAG" in
  latest) echo "refusing 'latest': it cannot be rolled back to by name"; exit 1 ;;
  *[!A-Za-z0-9._-]*|'') echo "bad tag"; exit 1 ;;
esac
# A shell variable beats --env-file in compose. Exporting both makes every compose
# call below use these values, whatever the operator's session holds.
export TAG REGISTRY=$REG

echo "== tag: $BEFORE -> $TAG"
# Pull before touching .env: a tag that does not exist stops here, nothing changed.
# A tag already on the box needs no pull, and pre-* tags exist only here.
on_box=yes
for s in backend frontend admin; do
  docker image inspect "$REG/kehilapp-$s:$TAG" >/dev/null 2>&1 </dev/null || on_box=no
done
if [ "$on_box" = yes ]; then
  echo "== images already on the box"
else
  $C pull backend frontend admin proxy </dev/null
fi

# `latest` moves, so keep what is running under a name a rollback can reach.
if [ "$BEFORE" = latest ]; then
  BEFORE=pre-$(date -u +%Y%m%d-%H%M%S)
  for s in backend frontend admin; do
    id=$(docker inspect -f '{{.Image}}' "$($C ps -q "$s" </dev/null)" </dev/null)
    docker tag "$id" "$REG/kehilapp-$s:$BEFORE" </dev/null
  done
  echo "== running images kept as $BEFORE"
fi

if [ ! -e "$MARK" ] && [ "$TAG" != "$BEFORE" ]; then
  printf '%s\n' "$BEFORE" > "$PREV_FILE"
fi
: > "$MARK"
sed -i "s/^TAG=.*/TAG=$TAG/" .env
$C up -d </dev/null

echo "== waiting for health"
healthy=0
for _ in $(seq 1 24); do
  healthy=$($C ps --format '{{.Status}}' </dev/null | grep -c '(healthy)' || true)
  [ "$healthy" -ge 3 ] && break
  sleep 5
done
$C ps --format '{{.Service}} {{.Image}} {{.Status}}' </dev/null
[ "$healthy" -ge 3 ] || { echo "FAILED: only $healthy healthy. Undo: bash scripts/deploy-shared-box.sh rollback"; exit 1; }

fail=0
check() { # path, text the page must have, text it must not have
  local page assets a code
  page=$(curl -fsS -m 20 "https://$HOST$1") || { echo "FAILED $1: no answer"; fail=1; return 0; }
  if ! grep -q "$2" <<<"$page" || grep -q "$3" <<<"$page"; then
    echo "FAILED $1: wrong app at this address"; fail=1; return 0
  fi
  assets=$(grep -oE '(src|href)="/[^"]*assets/[^"]+"' <<<"$page" | cut -d'"' -f2 | sort -u || true)
  [ -n "$assets" ] || { echo "FAILED $1: no assets in the page"; fail=1; return 0; }
  for a in $assets; do
    code=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "https://$HOST$a" || true)
    [ "$code" = 200 ] || { echo "FAILED $a: $code"; fail=1; }
  done
  echo "checked $1, $(wc -w <<<"$assets") assets"
}
# Both apps say lang="he" dir="rtl". Only the admin panel has the comment, and only
# the resident app has this <html> class.
check / 'class="text-gray-800"' 'root fix for this panel'
check /admin/ 'root fix for this panel' 'class="text-gray-800"'

ready=$(curl -s -m 20 "https://$HOST/readyz" || true)
case "$ready" in *'"db":"up"'*) echo "checked readyz" ;; *) echo "FAILED readyz"; fail=1 ;; esac

if [ "$fail" != 0 ]; then
  echo "DEPLOY FAILED. Undo: bash scripts/deploy-shared-box.sh rollback"
  exit 1
fi
rm -f "$MARK"
echo "DEPLOY OK: $TAG (rollback target: $(cat "$PREV_FILE" 2>/dev/null || echo none))"
