#!/usr/bin/env bash
# Tests post-reboot-check.sh without a reboot: curl and docker are stubs on PATH,
# the site files are fakes. Run: bash shared-proxy/box/test-post-reboot-check.sh
set -u
D=$(cd "$(dirname "$0")" && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/prc.XXXXXX")
pass=0; fail=0
ok() { if [ "$2" = "$3" ]; then echo "PASS $1"; pass=$((pass + 1)); else echo "FAIL $1: got [$2] want [$3]"; fail=$((fail + 1)); fi; }

mkdir -p "$T/bin" "$T/sites" "$T/state"
# curl stub: the answer for each URL comes from a state file.
cat > "$T/bin/curl" <<'EOF'
#!/usr/bin/env bash
S="$PRC_STATE"; url=""
for a in "$@"; do case "$a" in http*) url=$a ;; esac; done
case "$url" in
  */admin/) n=admin ;; */readyz) n=readyz ;; */health/ready) n=careerflow ;; *clinic*) n=clinic ;; *) n=home ;;
esac
# The second check (after the recovery step) reads <name>.after when it exists.
echo x >> "$S/$n.calls"
f="$S/$n"; [ "$(wc -l < "$S/$n.calls")" -gt 1 ] && [ -f "$S/$n.after" ] && f="$S/$n.after"
cat "$f"
EOF
# docker stub: "ps" answers nothing; every other call is a recovery step, logged.
cat > "$T/bin/docker" <<'EOF'
#!/usr/bin/env bash
[ "$1" = ps ] && exit 0
echo "$PWD $*" >> "$PRC_STATE/docker.log"
EOF
chmod +x "$T/bin/curl" "$T/bin/docker"

good() { # all services answer as they should
  rm -f "$T/state/"*
  echo 'x class="text-gray-800" x' > "$T/state/home"
  echo 'x root fix for this panel x' > "$T/state/admin"
  echo '{"db":"up"}' > "$T/state/readyz"
  printf 200 > "$T/state/clinic"
  echo '{"ready":true,"degraded":false,"components":{}}' > "$T/state/careerflow"
}
run() {
  : > "$T/state/docker.log"; rm -f "$T/state/"*.calls
  PATH="$T/bin:$PATH" PRC_STATE="$T/state" POST_REBOOT_SLEEP=0 POST_REBOOT_RETRY_SLEEP=0 \
    POST_REBOOT_LOG="$T/log" POST_REBOOT_SITE=https://k.example POST_REBOOT_SITES_DIR="$T/sites" \
    POST_REBOOT_CF_DIR="$T" bash "$D/post-reboot-check.sh" > "$T/out" 2>&1
  echo $?
}
cfup() { grep -c 'infra/docker-compose.prod.yml.*up -d' "$T/state/docker.log"; }

echo 'clinic.example {' > "$T/sites/clinicdemo.caddy"
printf '# a comment first\ncf.example {\n' > "$T/sites/careerflow-ai.caddy"

good; ok "all good: exit 0" "$(run)" 0
ok "all good: OK line" "$(grep -c ' OK kernel=' "$T/out")" 1
ok "all good: no recovery" "$(wc -l < "$T/state/docker.log" | tr -d ' ')" 0

good; echo '{"ready":true,"degraded":true}' > "$T/state/careerflow"
ok "careerflow degraded: exit 1" "$(run)" 1
ok "careerflow degraded: named in FAIL" "$(grep -c 'FAIL: careerflow kernel=' "$T/out")" 1
ok "careerflow degraded: its stack brought up" "$(cfup)" 1

good; : > "$T/state/careerflow"; echo '{"ready":true,"degraded":false}' > "$T/state/careerflow.after"
ok "careerflow down, back after up -d: exit 0" "$(run)" 0
ok "careerflow down, back: first failure logged" "$(grep -c 'first check failed: careerflow' "$T/out")" 1

good; echo 'nothing' > "$T/state/readyz"; echo '{"db":"up"}' > "$T/state/readyz.after"
ok "control - kehilapp db fails: exit 0 after recovery" "$(run)" 0
ok "control - kehilapp db fails: careerflow stack not touched" "$(cfup)" 0

mv "$T/sites/careerflow-ai.caddy" "$T/careerflow-ai.caddy.off"
good; : > "$T/state/careerflow"
ok "no careerflow site file: not checked, exit 0" "$(run)" 0
mv "$T/careerflow-ai.caddy.off" "$T/sites/careerflow-ai.caddy"

good; ok "control - unchanged state still passes" "$(run)" 0

echo "RESULT pass=$pass fail=$fail"
case "$T" in "${TMPDIR:-/tmp}"/prc.*) rm -r "$T" ;; esac
[ "$fail" = 0 ]
