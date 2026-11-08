# Off-box backup for the shared server

Installed on the box on 5.11.2026 and proven with a full restore check of a file
downloaded from R2. Moved into this repo on 8.11.2026: the files here are the ones
running on the box (same sha256 for every script and unit). Runbook 00 points here.

## What it does

Every night at 00:20 UTC, after the demo reset and before the 01:30 update reboot:

1. Takes a consistent copy of the clinicdemo SQLite database and of the trading
   journal, both through SQLite's own backup call.
2. Tars the clinicdemo files, the trading data and settings, every tenant's secrets
   file and the Caddy site files.
3. Dumps kehilapp from Atlas with the procedure proven on 3.11.2026 (runbook 00).
4. Encrypts everything to a public key. The private key is not on the box.
5. Uploads to R2 with curl, then checks the stored size.
6. Sends a Telegram line: success every night, so silence is itself an alarm.

A failure names the step in Telegram. `clinicdemo-cron.service` also alerts on failure,
at most once an hour.

## Setup, in order

1. **Key, on the PC:** `gpg --quick-generate-key 'box backup' future-default default never`
   with a passphrase. Export the public half with `gpg --armor --export 'box backup'`.
   Keep the private key and passphrase somewhere that survives the loss of the PC:
   without them every backup is unreadable.
2. **R2:** a bucket `box-backups`; an API token with Object Read & Write on that bucket
   only, limited to the box's address; a lifecycle rule deleting objects after 30 days;
   a bucket lock of 14 days, so a stolen token cannot delete recent backups.
   The box leaves over IPv4 and IPv6, so the token's address filter needs both.
3. **On the box:** run `bash /opt/kehilapp/shared-proxy/box/backup/install.sh` once to
   create `/opt/box-ops`, put `backup.conf` (mode 600, see `backup.conf.example`) and
   your own `backup-public.asc` there, run it again. The owner fills `backup.conf` with
   `set-r2-secrets.ps1 -Box deploy@<IP>` and `set-telegram.ps1 -Box deploy@<IP>`.
   The public key is not kept in this repo, because push-time secret scanners flag its
   armored lines. Export it again from the private key on the PC:
   `GNUPGHOME=/e/box-backup-key gpg --armor --export 'box backup' > backup-public.asc`.
4. **Prove it:** `sudo systemctl start box-backup.service`, download the object, and on
   the PC run `GNUPGHOME=/e/box-backup-key restore-check.sh <file> --mongo`. It is not a
   backup until that passes.

Run backups through `systemctl start box-backup.service`: the start of the script sweeps
leftover work folders, so a second copy run by hand could remove the first one's files.

## Tests

`test/test-flow.sh` runs the real scripts with real gpg, tar, curl and SQLite against
`test/fake-r2.py`, which checks AWS signatures with its own implementation. Only `docker`
is a stub. `test/test-real-parts.sh` covers what the stub hides, with the real images: the
PHP snapshot call with all capabilities dropped, and `mongodump --quiet --config`. Passing
that dump to `REAL_ARCHIVE=<path> bash test/test-flow.sh` also restores it into a real mongo.
`test/run-*` folders hold fake data only.

**Proven live on 5.11.2026:** real R2 over IPv4 and IPv6, curl 8.5, gpg 2.4.4, the live
containers, the Atlas dump, the systemd service, and the bucket lock (DELETE answered 409).

**Since then:** the timer started the run on its own (8.11, 00:20:26 UTC, exit 0), and a
unit that failed on purpose reached Telegram through `OnFailure` (7.11).

**Not exercised yet:** a real backup failure reaching Telegram.

## Known limits, accepted

- Backups are not signed. A signing key would sit on the box and be stolen with it. Anyone
  with the token can add a forged newer file, so compare date and size with the Telegram
  line before restoring. The bucket lock keeps the older ones.
- No size cap on what a compromised container streams out; the box has 185 GB free.
- `mongo:7` is a tag, not a digest. `docker run` uses the local copy and does not pull.
- Telegram cannot report a dead box. The missing nightly message does.
- Caddy's certificates are left out: they are issued again on their own.
