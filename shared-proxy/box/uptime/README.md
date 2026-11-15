# Uptime check of the shared box

Every 2 minutes the box fetches each public site the way a visitor does (DNS, TLS,
Caddy, the app) and checks two things: the answer is 200, and it holds a marker
text. A 200 error page or an empty shell counts as down.

Two failures in a row send one Telegram line, through the bot the backup and the
daily audit already use:

```
DOWN kehilapp-api: HTTP 503 (https://kehilapp.letstalkanddesign.com/readyz)
UP kehilapp-api: answering again after about 6 min
```

Nothing is sent while nothing changes. A message that did not go out is retried
on the next run, and the run fails (journal, and `box-alert@` tries once more).

## What it checks

`uptime-targets.txt`, one line per check: name, public address, marker.

| Name | Address | Marker | Proves |
|---|---|---|---|
| `clinicdemo-booking` | `/booking/` | `ltd-booking` | WordPress, its database and the booking plugin |
| `kehilapp-web` | `/` | `id="root"` | the resident app's page |
| `kehilapp-api` | `/readyz` | `"db":"up"` | the API and its database |

The trading desk has no public address and is not checked here.

## When the whole box is down

A box that is down cannot send anything. With `HC_UPTIME_URL` in `backup.conf`,
every run pings Healthchecks.io, whatever the sites answered: the ping means "the
check ran". If pings stop (box down, timer stopped, script broken), Healthchecks
alerts on its own channel. Setup, once, by the owner:

1. At healthchecks.io: a new check, period 5 minutes, grace 5 minutes.
2. On the PC: `powershell -ExecutionPolicy Bypass -File set-uptime-hc.ps1 -Box deploy@<IP>`
   and paste the check's ping address when asked. It is written into `backup.conf`
   on the box and never printed.

The address goes to curl on stdin, never on a command line.

## Install and change

```bash
# on the box, from a copy of this folder
bash install.sh      # first run by hand, then the timer
```

A new site: one line in `uptime-targets.txt`, then `install.sh` again. Pick a
marker that only the real page has (ASCII, no spaces), read from the live page.

State lives in `/var/lib/box-uptime/<name>` (`up|down`, failures in a row, since).
The unit runs as `deploy` with `ProtectSystem=strict` and can write only there.
A site taken off the list loses its state file on the next run.

## Tests

`bash test/run-tests.sh` in Linux: a stand-in curl and a stand-in `box-alert.sh`.
36 checks: silent when up, no alert on one failure, one DOWN on the second, no
repeats, one UP with the downtime, a failed send retried and failing the run, a
missing `backup.conf` not lost silently, the Healthchecks address only on stdin,
odd addresses and bad target lines refused, a targets file with Windows line
endings or without a final newline, a site taken off the list. Five mutants fail
(alert on the first failure, a failed send taken as sent, the marker not checked,
the CR kept, the last line skipped). The box side of `set-uptime-hc.ps1` was run in
a container: a `backup.conf` without a final newline, an old address replaced, an
odd address refused. A dry run on the box on 14.11.2026 reached all three sites.
