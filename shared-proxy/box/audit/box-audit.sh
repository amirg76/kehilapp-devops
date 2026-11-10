#!/usr/bin/env bash
# Daily read-only audit of the shared box. No AI, and nothing on the box is changed.
# It takes a snapshot of what matters (packages, containers, open ports, firewall,
# users, SSH keys and settings, config file hashes, secret file modes, timers,
# SSH logins, disk, memory, certificates, HTTP errors), compares it with the last
# snapshot, and sends one Telegram message through box-alert.sh. Every day, also
# when nothing changed: silence is the alarm.
#
#   box-audit.sh run                          on the box, from box-audit.service
#   box-audit.sh collect > snapshot.tsv       the snapshot alone
#   box-audit.sh compare OLD NEW [KNOWN_IPS]  the report alone (used by the tests)
#
# A snapshot line is: section <TAB> key <TAB> value. It holds names, versions,
# hashes, fingerprints, modes and counts. Never a secret value and never raw log
# text: whoever reads the report later (a person, or an AI in level 3) must not
# meet text that someone on the internet wrote.
set -uo pipefail
STATE=${BOX_AUDIT_STATE:-/var/lib/box-audit}
OPS=${BOX_OPS:-/opt/box-ops}
KEEP=${BOX_AUDIT_KEEP:-30}                 # snapshots and reports kept
DISK_MAX=${BOX_AUDIT_DISK_MAX:-80}         # % used on /
MEM_MIN=${BOX_AUDIT_MEM_MIN:-10}           # % memory available
CERT_MIN=${BOX_AUDIT_CERT_MIN:-14}         # days left; Caddy renews at about 30
HTTP5XX_MAX=${BOX_AUDIT_5XX_MAX:-20}       # 5xx answers in 24 hours
MAX_LINES=${BOX_AUDIT_MAX_LINES:-25}       # lines in the Telegram message
CADDY=${BOX_AUDIT_CADDY:-shared-proxy-caddy-1}
SITES=${BOX_AUDIT_SITES:-/opt/shared-proxy/sites}

emit() { printf '%s\t%s\t%s\n' "$1" "$2" "$3"; }

# A reader that fails marks its section "unavailable" and prints nothing else.
# An empty section would read as "everything was removed" and bury real alerts.
section() { # name, reader function
  local out
  if out=$("$2"); then
    [ -z "$out" ] || printf '%s\n' "$out"
    emit "$1" _status ok
  else
    emit "$1" _status unavailable
  fi
}

c_pkg() {
  dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' \
    | awk -F'\t' '$1 ~ /^ii/ {print "pkg\t" $2 "\t" $3}'
}

c_kernel() {
  local k
  k=$(uname -r) || return 1
  emit kernel running "$k"
  if [ -e /var/run/reboot-required ]; then emit kernel reboot_required yes; else emit kernel reboot_required no; fi
}

c_ctr() {
  local ids
  ids=$(docker ps -aq) || return 1
  [ -n "$ids" ] || return 0
  # shellcheck disable=SC2086
  docker inspect --format '{{.Name}}{{"\t"}}{{.Config.Image}}{{"\t"}}{{.Image}}{{"\t"}}{{.State.Status}}{{"\t"}}{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}{{"\t"}}{{.RestartCount}}' $ids \
    | awk -F'\t' '{n = substr($1, 2)
        print "ctr_image\t" n "\t" $2 " " substr($3, 8, 12)
        print "ctr_state\t" n "\t" $4 "/" $5
        print "ctr_restarts\t" n "\t" $6}'
}

c_port() {
  ss -Htuln | awk '{print "port\t" $1 " " $5 "\tlistening"}'
}

c_pub() {
  docker ps --format '{{.Names}}{{"\t"}}{{.Ports}}' | awk -F'\t' '$2 ~ /->/ {print "pub\t" $1 "\t" $2}'
}

c_ufw() {
  local out
  out=$(sudo -n ufw status verbose) || return 1
  printf '%s\n' "$out" | awk '/^Status:/ {print "ufw\tstatus\t" $2; next}
    NF && !/^To / && !/^--/ {gsub(/  +/, " "); print "ufw\t" $0 "\tpresent"}'
}

c_user() {
  getent passwd | awk -F: '$7 !~ /(nologin|false|sync)$/ || $3 == 0 {print "user\t" $1 "\tuid=" $3 " shell=" $7}'
}

c_key() {
  local f u files
  sudo -n true || return 1
  # find runs as root: home folders are 750 on Ubuntu 24.04, so a glob run as
  # deploy would not see other users' keys and would skip them in silence.
  files=$(sudo -n find /root /home -maxdepth 3 -path '*/.ssh/authorized_keys*' -type f -size +0) || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case $f in /root/*) u=root ;; *) u=${f#/home/}; u=${u%%/*} ;; esac
    # Bits, fingerprint and type only; the comment is free text.
    sudo -n ssh-keygen -lf "$f" | awk -v u="$u" '{print "key\t" u " " $2 "\t" $1 " " $NF}' || return 1
  done <<<"$files"
}

c_sshd() { # a setting given more than once (port) keeps all its values on one line
  sudo -n sshd -T | awk '$1 ~ /^(passwordauthentication|permitrootlogin|kbdinteractiveauthentication|pubkeyauthentication|x11forwarding|maxauthtries|allowusers|allowtcpforwarding|port)$/ {
    k = $1; $1 = ""; sub(/^ /, ""); v[k] = (k in v) ? v[k] "," $0 : $0}
    END {for (k in v) print "sshd\t" k "\t" v[k]}'
}

c_file() {
  sudo -n true || return 1
  { sudo -n find /etc/ssh/sshd_config.d /etc/sudoers.d /etc/sysctl.d /etc/cron.d /var/spool/cron/crontabs \
      "$SITES" /usr/local/sbin -maxdepth 1 -type f 2>/dev/null
    sudo -n find /etc/systemd/system -maxdepth 2 -type f \( -name '*.service' -o -name '*.timer' -o -name '*.conf' \) 2>/dev/null
    for f in /etc/ssh/sshd_config /etc/sudoers /etc/docker/daemon.json /etc/crontab \
             /etc/apt/apt.conf.d/50unattended-upgrades /etc/apt/apt.conf.d/52unattended-upgrades-local \
             /opt/shared-proxy/Caddyfile /opt/shared-proxy/docker-compose.yml; do
      if [ -e "$f" ]; then echo "$f"; fi
    done
    find "$OPS" -maxdepth 1 -type f -name '*.sh' 2>/dev/null
  } | sort -u | while IFS= read -r f; do
    sudo -n sha256sum "$f" | awk -v f="$f" '{print "file\t" f "\t" substr($1, 1, 16)}'
  done
}

c_secret() { # mode and owner only: never read a secret file
  sudo -n true || return 1
  { sudo -n find /opt -maxdepth 2 -name .env -type f
    if [ -e "$OPS/backup.conf" ]; then echo "$OPS/backup.conf"; fi
  } | sort -u | while IFS= read -r f; do
    emit secret "$f" "$(sudo -n stat -c '%a %U' "$f")"
  done
}

c_timer() {
  systemctl list-unit-files --type=timer --state=enabled --no-legend | awk '{print "timer\t" $1 "\tenabled"}'
}

c_failed() { # the leading bullet, if systemctl prints one, is not a unit name
  systemctl list-units --state=failed --no-legend --plain \
    | sed 's/^[^[:alnum:]]*//' | awk 'NF {print "failed\t" $1 "\tfailed"}'
}

c_login() { # accepted logins: address, user and method; failed attempts: a count only
  sudo -n true || return 1
  # "Accepted <method> for <user> from <address> port <n> ssh2". Every method,
  # not only publickey: a password login is exactly the one that must not hide.
  sudo -n journalctl -t sshd -t sshd-session --since "24 hours ago" --no-pager -o cat \
    | awk '/^Accepted [^ ]+ for [^ ]+ from [^ ]+ port / {print "login\t" $6 " " $4 "\t" $2}
           /^(Failed |Invalid user )/ {f++}
           END {print "metric\tssh_failed_24h\t" f + 0}'
}

c_host() {
  df -P / | awk 'NR == 2 {sub(/%/, "", $5); print "metric\tdisk_used_pct\t" $5}' || return 1
  awk '/^MemTotal:/ {t = $2} /^MemAvailable:/ {a = $2} END {if (t) print "metric\tmem_avail_pct\t" int(a * 100 / t)}' /proc/meminfo
}

c_http() { # Caddy's access log is the container log (Caddyfile: access_log)
  docker logs --since 24h "$CADDY" 2>&1 \
    | awk '/"logger":"http\.log\.access/ {n++; if ($0 ~ /"status":5[0-9][0-9]/) e++}
           END {print "metric\thttp_total_24h\t" n + 0; print "metric\thttp_5xx_24h\t" e + 0}'
}

c_cert() { # asks the local Caddy, by name, for each site in sites/
  local f host end now
  now=$(date +%s)
  for f in "$SITES"/*.caddy; do
    [ -e "$f" ] || continue
    host=$(grep -m1 -oE '^[a-z0-9.-]+[.][a-z]{2,}' "$f") \
      || { emit metric "cert_days:${f##*/}" unreadable; continue; }
    end=$(timeout 20 openssl s_client -connect 127.0.0.1:443 -servername "$host" </dev/null 2>/dev/null \
          | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
    if [ -n "$end" ]; then
      emit metric "cert_days:$host" $(( ($(date -d "$end" +%s) - now) / 86400 ))
    else
      emit metric "cert_days:$host" unreadable
    fi
  done
}

collect() {
  { section pkg c_pkg
    section kernel c_kernel
    section ctr c_ctr
    section port c_port
    section pub c_pub
    section ufw c_ufw
    section user c_user
    section key c_key
    section sshd c_sshd
    section file c_file
    section secret c_secret
    section timer c_timer
    section failed c_failed
    section login c_login
    section host c_host
    section http c_http
    section cert c_cert
  } | LC_ALL=C sort -u
}

# Prints the report: "1 text" = warning, "2 text" = change worth knowing, "3 text" = figures.
compare() { # old new [known-ips]
  awk -F'\t' -v disk_max="$DISK_MAX" -v mem_min="$MEM_MIN" -v cert_min="$CERT_MIN" -v e5_max="$HTTP5XX_MAX" '
    function add(level, text) { out[++n] = level " " text }
    function owner(s) { sub(/_.*$/, "", s); return s }   # ctr_state is read by the ctr reader
    function diffable(s, key) {
      if (s ~ /^(metric|failed|login|ctr_state|ctr_restarts)$/) return 0
      return !(s == "kernel" && key == "reboot_required")
    }
    function change(s, key, a, b, how,   lvl) {
      if (s == "pkg") { pk[how]++; if (length(pn) < 160) pn = pn (pn == "" ? "" : ", ") key; else more++; return }
      if (s == "ctr_image") {
        if (how == "removed") add(1, "container " key " is gone (was " a ")")
        else if (how == "added") add(2, "new container " key " (" b ")")
        else add(2, "container " key " image " a " -> " b)
        return
      }
      lvl = (s == "kernel") ? 2 : 1
      if (how == "added") add(lvl, s " added: " key " = " b)
      else if (how == "removed") add(lvl, s " removed: " key " (was " a ")")
      else add(lvl, s " changed: " key ": " a " -> " b)
    }
    # Which file a line came from is set by part=N between the files, not by the
    # file name: the same file given twice (or /dev/null twice) must still work.
    part == 1 { old[$1 FS $2] = $3; if ($2 == "_status") ostat[$1] = $3; next }
    part == 2 { known[$1] = 1; next }
    part == 3 { new[$1 FS $2] = $3; if ($2 == "_status") nstat[$1] = $3 }
    END {
      for (s in nstat) if (nstat[s] != "ok") add(1, "could not read " s " (skipped today)")
      # Changes, only where both days were read in full.
      for (k in new) {
        split(k, p, FS); s = p[1]; key = p[2]; st = owner(s)
        if (key == "_status" || !diffable(s, key) || nstat[st] != "ok" || ostat[st] != "ok") continue
        if (!(k in old)) change(s, key, "", new[k], "added")
        else if (old[k] != new[k]) change(s, key, old[k], new[k], "changed")
      }
      for (k in old) {
        split(k, p, FS); s = p[1]; key = p[2]; st = owner(s)
        if (key == "_status" || !diffable(s, key) || nstat[st] != "ok" || ostat[st] != "ok") continue
        if (!(k in new)) change(s, key, old[k], "", "removed")
      }
      if (pk["changed"] + pk["added"] + pk["removed"] > 0)
        add(2, "packages: " pk["changed"] + 0 " upgraded, " pk["added"] + 0 " added, " pk["removed"] + 0 " removed: " pn (more ? " and " more " more" : ""))
      # The state today, whatever it was yesterday.
      for (k in new) {
        split(k, p, FS); s = p[1]; key = p[2]; v = new[k]
        if (key == "_status") continue
        if (s == "ctr_state" && v !~ /^running\/(healthy|none)$/) add(1, "container " key " is " v)
        else if (s == "ctr_restarts" && (k in old) && ostat["ctr"] == "ok" && v + 0 > old[k] + 0) add(1, "container " key " restarted " (v - old[k]) " time(s)")
        else if (s == "failed") add(1, "unit " key " is failed")
        else if (s == "secret" && v !~ /^600 /) add(1, "secret file " key " has mode " v)
        else if (s == "ufw" && key == "status" && v != "active") add(1, "firewall is " v)
        else if (s == "user" && v ~ /^uid=0 / && key != "root") add(1, "user " key " has uid 0")
        else if (s == "kernel" && key == "reboot_required" && v == "yes") add(2, "a reboot is pending (kernel update)")
        else if (s == "login") {
          split(key, q, " ")
          if (v != "publickey") add(1, "ssh login by " v " from " q[1] " as " q[2] " (only keys are allowed)")
          if (!(q[1] in known)) add(1, "ssh login from a new address " q[1] " as " q[2])
        }
        else if (s == "metric") {
          fig[key] = v
          if (key == "disk_used_pct" && v + 0 > disk_max) add(1, "disk / is " v "% full")
          else if (key == "mem_avail_pct" && v + 0 < mem_min) add(1, "only " v "% of memory is available")
          else if (key == "http_5xx_24h" && v + 0 > e5_max) add(1, v " server errors (5xx) in 24 hours")
          else if (key == "http_total_24h" && v + 0 == 0) add(1, "no requests in the access log in 24 hours (log off, or its format changed?)")
          else if (key ~ /^cert_days:/) {
            h = substr(key, 11)
            if (v == "unreadable") add(1, "certificate of " h " could not be read")
            else if (v + 0 < cert_min) add(1, "certificate of " h " expires in " v " days")
          }
        }
      }
      f = ""
      if ("disk_used_pct" in fig) f = f ", disk " fig["disk_used_pct"] "% used"
      if ("mem_avail_pct" in fig) f = f ", memory " fig["mem_avail_pct"] "% free"
      if ("http_total_24h" in fig) f = f ", " fig["http_total_24h"] " requests / " fig["http_5xx_24h"] " 5xx"
      if ("ssh_failed_24h" in fig) f = f ", " fig["ssh_failed_24h"] " failed ssh attempts"
      if (f != "") add(3, "24h:" substr(f, 2))
      for (i = 1; i <= n; i++) print out[i]
    }' part=1 "$1" part=2 "${3:-/dev/null}" part=3 "$2" | LC_ALL=C sort -n -s -k1,1
}

hc_ping() { # Healthchecks.io: a missing ping alerts on a channel this box does not run
  local url
  # Read it the way backup-box.sh does (the shell sources the file), in a subshell,
  # so quotes, comments and repeated keys mean the same thing in both scripts.
  url=$(. "$OPS/backup.conf" >/dev/null 2>&1; printf '%s' "${HC_AUDIT_URL:-}")
  [ -n "$url" ] || return 0
  # Only a plain address goes into curl's config: no quote or backslash to escape.
  [[ $url =~ ^https?://[A-Za-z0-9./_:-]+$ ]] \
    || { echo "HC_AUDIT_URL is not a plain https address: no ping"; return 0; }
  # Through curl's config on stdin: the address never shows in a process list.
  printf 'url = "%s"\n' "$url" | curl -fsS -m 10 --retry 3 -o /dev/null -K - \
    || echo "healthchecks ping failed (it alerts on its own when the ping is missing)"
}

run() {
  local today snap prev report warn info head msg sent
  today=${BOX_AUDIT_DATE:-$(date -u +%F)}
  [ -d "$STATE" ] || { echo "$STATE missing (install.sh creates it)"; return 1; }
  snap="$STATE/snapshot-$today.tsv"
  prev=$(find "$STATE" -maxdepth 1 -name 'snapshot-*.tsv' ! -name "snapshot-$today.tsv" | LC_ALL=C sort | tail -n 1)
  # BOX_AUDIT_SNAPSHOT_FROM exists for the tests only; the service never sets it.
  if [ -n "${BOX_AUDIT_SNAPSHOT_FROM:-}" ]; then
    cp "$BOX_AUDIT_SNAPSHOT_FROM" "$snap.tmp" || return 1
  else
    collect > "$snap.tmp" || return 1
  fi
  mv "$snap.tmp" "$snap" || return 1
  touch "$STATE/known-ips"
  report=$(compare "${prev:-/dev/null}" "$snap" "$STATE/known-ips" \
    | awk '{l = $1; sub(/^[0-9] /, ""); print (l == 1 ? "WARN " : l == 2 ? "INFO " : "") $0}') || return 1
  printf '%s\n' "$report" > "$STATE/report-$today.txt"

  warn=$(grep -c '^WARN ' <<<"$report")
  info=$(grep -c '^INFO ' <<<"$report")
  if [ -z "$prev" ]; then head="box audit $today: first run, baseline saved"
  elif [ "$warn" -eq 0 ] && [ "$info" -eq 0 ]; then head="box audit $today: OK, nothing changed"
  else head="box audit $today: $warn warning(s), $info change(s)"
  fi
  msg=$(printf '%s\n%s' "$head" "$(head -n "$MAX_LINES" <<<"$report")")
  if [ "$(grep -c . <<<"$report")" -gt "$MAX_LINES" ]; then
    msg=$(printf '%s\n... more in %s' "$msg" "$STATE/report-$today.txt")
  fi
  # box-alert.sh never fails its caller (it also serves OnFailure), and exits 0
  # without a word when backup.conf is missing. Here a lost message must fail the
  # run, so the journal and OnFailure show it.
  [ -r "$OPS/backup.conf" ] || { echo "$OPS/backup.conf missing: no Telegram"; return 1; }
  sent=$(bash "$OPS/box-alert.sh" "$(head -c 3800 <<<"$msg")" 2>&1)
  if [ -n "$sent" ]; then echo "$head"; echo "$sent"; return 1; fi
  echo "$head"
  # The ping means "today's message went out", so it comes only after the send.
  hc_ping
  # Only after the message went out: a new address warns once, then it is known.
  awk -F'\t' '$1 == "login" && $2 != "_status" {split($2, a, " "); print a[1]}' "$snap" >> "$STATE/known-ips"
  LC_ALL=C sort -u -o "$STATE/known-ips" "$STATE/known-ips"

  # Keep the newest KEEP of each.
  find "$STATE" -maxdepth 1 -name 'snapshot-*.tsv' | LC_ALL=C sort | head -n -"$KEEP" | xargs -r rm -f --
  find "$STATE" -maxdepth 1 -name 'report-*.txt' | LC_ALL=C sort | head -n -"$KEEP" | xargs -r rm -f --
  return 0
}

case "${1:-}" in
  run) run ;;
  collect) collect ;;
  compare) [ $# -ge 3 ] || { echo "usage: $0 compare OLD NEW [KNOWN_IPS]" >&2; exit 2; }; compare "$2" "$3" "${4:-/dev/null}" ;;
  *) echo "usage: $0 run | collect | compare OLD NEW [KNOWN_IPS]" >&2; exit 2 ;;
esac
