#!/usr/bin/env bash
# The parts test-flow.sh stubs, with the real images: the exact PHP snapshot call
# under the box's container limits, and mongodump --quiet --config, then a restore.
# Throwaway containers only. Writes the dump to $1 for test-flow.sh.
set -uo pipefail
OUT=${1:?usage: test-real-parts.sh <archive-path>}
A=t-box-php
B=t-box-src
clean() { docker rm -f -v "$A" "$B" >/dev/null 2>&1; }
trap clean EXIT
clean

echo "== PHP snapshot, exact call, as www-data with all capabilities dropped"
docker run -d --name "$A" --entrypoint sleep --cap-drop ALL --security-opt no-new-privileges:true clinicdemo-web:local 300 >/dev/null
docker exec -u www-data "$A" php -r '
  @mkdir("/tmp/wp", 0755, true);
  $d = new SQLite3("/tmp/wp/.ht.sqlite");
  $d->exec("create table t(a text)");
  for ($i = 0; $i < 5000; $i++) { $d->exec("insert into t values (\"row\")"); }' </dev/null
docker exec -u www-data "$A" php -r '
  $s = new SQLite3("/tmp/wp/.ht.sqlite", SQLITE3_OPEN_READONLY);
  $d = new SQLite3("/tmp/box-backup.sqlite");
  exit($s->backup($d) ? 0 : 1);' </dev/null
echo "   backup call exit=$?"
docker exec -u www-data "$A" php -r '
  $d = new SQLite3("/tmp/box-backup.sqlite");
  echo "   rows in the copy: ", $d->querySingle("select count(*) from t"), ", check: ", $d->querySingle("pragma integrity_check"), PHP_EOL;' </dev/null

echo "== mongodump --quiet --config"
docker run -d --name "$B" mongo:7 >/dev/null
for i in $(seq 1 30); do docker exec "$B" mongosh --quiet --eval 1 >/dev/null 2>&1 && break; sleep 1; done
docker exec "$B" mongosh --quiet kehilapp_demo --eval '
  db.messages.insertMany(Array.from({length: 240}, (_, i) => ({n: i, text: "message " + i})));
  db.users.insertMany(Array.from({length: 70}, (_, i) => ({n: i})));' >/dev/null
docker exec "$B" sh -c 'printf "uri: \"%s\"\n" "mongodb://127.0.0.1:27017" > /tmp/dump.yaml'
out=$(docker exec "$B" mongodump --quiet --config=/tmp/dump.yaml --db=kehilapp_demo --archive=/tmp/k.gz --gzip 2>&1)
echo "   dump exit=$? output chars=${#out}"
docker cp "$B:/tmp/k.gz" "$OUT" >/dev/null
echo "   archive bytes: $(wc -c < "$OUT")"
