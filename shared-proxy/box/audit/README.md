# Daily audit of the shared box

Every morning at 06:00 UTC the box takes a snapshot of what matters, compares it
with the last one, checks a few limits, and sends one Telegram message. It changes
nothing on the box and uses no AI. The message comes every day, also when nothing
changed: a missing message is the alarm.

```
box audit 2026-11-11: 2 warning(s), 1 change(s)
WARN port added: tcp 0.0.0.0:8080 = listening
WARN ssh login from a new address 198.51.100.9 as deploy
INFO packages: 4 upgraded, 0 added, 0 removed: openssl, libssl3t64, ...
24h: disk 4% used, memory 93% free, 1200 requests / 2 5xx, 57 failed ssh attempts
```

## What it looks at

| Section | Read from | Warns when |
|---|---|---|
| `pkg` | `dpkg-query` | never (one INFO line with the count) |
| `kernel` | `uname -r`, `/var/run/reboot-required` | never (INFO: new kernel, reboot pending) |
| `ctr` | `docker inspect` | a container is gone, not running, unhealthy, or restarted |
| `port` | `ss -tuln` | a listening port appears or disappears |
| `pub` | `docker ps` | a container publishes a port (rule 1 of ADDING-A-TENANT) |
| `ufw` | `ufw status verbose` | a rule changes, or the firewall is not active |
| `user` | `getent passwd` | a login user appears, or a second uid 0 |
| `key` | `ssh-keygen -lf` on every `authorized_keys` | a key is added or removed |
| `sshd` | `sshd -T` (effective settings) | a security setting changes |
| `file` | `sha256sum` of ssh, sudo, cron, sysctl, systemd, Docker, Caddy and box-ops files | a hash changes |
| `secret` | `stat` of every `/opt/*/.env` and `backup.conf` | mode is not 600, or owner changes |
| `timer` | `systemctl list-unit-files --type=timer` | an enabled timer appears or disappears |
| `failed` | `systemctl list-units --state=failed` | any unit is failed |
| `login` | journal of `sshd`, last 24 h | any login that is not by key; a login from an address never seen before (once) |
| `host` | `df /`, `/proc/meminfo` | disk over 80%, memory available under 10% |
| `http` | Caddy's access log (container log), last 24 h | more than 20 answers of 5xx, or no requests at all (log off or format changed) |
| `cert` | the certificate the local Caddy serves for each `sites/*.caddy` | under 14 days left, unreadable, or no host name in the file |

The limits are variables at the top of `box-audit.sh`.

**What it never records:** a secret value (secret files get mode and owner, config
files a hash), the comment of an SSH key, or any raw log line. Failed SSH attempts
are a count. The snapshot is meant to be read later by an AI (level 3), and text
that a stranger can put in a log must not reach it.

**A reader that fails** (for example `sudo -n` refusing) marks its section
`unavailable`: the message says "could not read X" and the section is not compared
that day. Without this, an empty section would read as "everything was removed".

**A message that did not go out fails the run.** `box-alert.sh` never fails its
caller and says nothing when `backup.conf` is missing, so the run checks both: no
`backup.conf`, or any output from `box-alert.sh`, exits 1 (journal + OnFailure).
New login addresses are learned only after the message went out, so a lost
"new address" warning comes again the next day.

## Files on the box

| Path | What |
|---|---|
| `/opt/box-ops/box-audit.sh` | the script (installed by `install.sh`) |
| `/var/lib/box-audit/snapshot-<date>.tsv` | one snapshot a day, the last 30 kept |
| `/var/lib/box-audit/report-<date>.txt` | the full report (the message is cut at 25 lines) |
| `/var/lib/box-audit/known-ips` | addresses that logged in before |
| `/etc/systemd/system/box-audit.{service,timer}` | runs as `deploy`, alerts through `box-alert@` on failure |

## Install

The backup must be installed first: the audit reuses `box-alert.sh`, the Telegram
settings in `backup.conf` and `box-alert@.service`.

```bash
B=/opt/kehilapp/shared-proxy/box/audit
bash $B/install.sh                          # state folder, script, units, timer
sudo systemctl start box-audit.service      # first run: "baseline saved"
journalctl -u box-audit -n 5 --no-pager
```

The first run only saves the baseline. Read `/var/lib/box-audit/snapshot-*.tsv`
once: every section should have `_status ok`. The next day's message is the first
real comparison.

## Tests

```bash
bash test/test-audit.sh        # 125 checks, about a minute in Git Bash
```

- **compare:** 31 changes, each one checked twice, present after the change and
  absent when nothing changed, so a check cannot pass because the line is always
  there. Plus: a section unreadable today or yesterday, a container recreated by
  a deploy, the first run, a known address.
- **run:** three days with a fake Telegram: baseline, two warnings, then "OK"
  (a new address warns once), and old snapshots are removed. A failed send and a
  missing `backup.conf` fail the run, and the address is not learned.
- **parsers:** fake `journalctl`, `systemctl`, `ss`, `ufw`, `sshd` and `docker`
  print sample output (key, password and keyboard-interactive logins, a hostile
  user name, the systemctl bullet, the ufw table header, a repeated `port`).
  The samples follow the documented formats; they are not captures from the box.
- **collect:** on a machine that is not the box most readers fail; each section
  must still end with a status line.
- **Mutation check:** the suite was run against five broken copies of the script
  (port changes ignored, secret mode not checked, new addresses ignored, password
  logins ignored, only key logins parsed); each was caught (4, 1, 3, 1 and 2
  failures). Run one with `BOX_AUDIT_UNDER_TEST=<copy> bash test/test-audit.sh`.

## Not proven yet

- The readers ran only on a machine that is not the box. The first run on the box
  is the test: every section must say `_status ok`. Then replace the parser
  samples in the test with real captures.
- `sshd -T` with Ubuntu's socket-activated ssh: it worked by hand on 29.10 and 8.11;
  if it fails under the timer, the message says "could not read sshd" every day.
- UDP sockets in `ss` that come and go (DHCP, time sync) would show as port
  changes. Watch the first week; filter them if they do.
- Whether Docker counts the start after a reboot as a restart. If it does, the
  morning after a reboot shows "restarted" for every container.
- A container stopped on purpose, or a secret file that is not 600 by design,
  would warn every day. None exists today.
- How many packages change on an ordinary day.
