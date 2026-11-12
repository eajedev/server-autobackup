# Eaje Autobackup

Our own version of Contabo's paid **Auto Backup** add-on — same rhythm, same
retention, no monthly add-on fee. Built for the Contabo Cloud VPS 12 that runs
Coolify and all production sites (173.212.225.215).

## How it matches Contabo's add-on

| | Contabo Auto Backup (paid) | Eaje Autobackup (this) |
|---|---|---|
| Frequency | 1 backup per day | 1 backup per day (systemd timer, 03:30 + up to 30 min random delay) |
| Model | First backup full, then daily incremental | Restic: first snapshot full, every later one incremental + deduplicated |
| Minimum interval | At least 8 h between backups | Same 8 h guard enforced in the script |
| Retention | Max 10 backups, each max 10 days, oldest deleted first | `--keep-daily 10 --keep-within 10d`, oldest pruned first |
| Storage | Off-server, Contabo data center | Off-server — **you pick the destination** (S3 / B2 / SFTP), see below |
| Encryption | Not documented by Contabo | Every backup encrypted (restic, AES-256) — the storage provider cannot read it |
| Integrity checks | Contabo explicitly does not promise restores work | `restic check` every run + 5 % data read-back every Sunday |
| Schedule control | Contabo picks the time (window 09:00–17:00 CET) | We pick ours: 03:30 server time, the quiet hour |
| Missed runs | Managed by Contabo | Timer is `Persistent=true` — a run missed while the server was off fires at boot |
| Price | ≈ €6.70/mo on Cloud VPS 12 (configurator, Oct 2026) | €0 + whatever the off-server storage costs |

## What gets backed up

- `/data` — Coolify itself: app definitions, env files, keys, app storage
- `/var/lib/docker/volumes` — every app's persistent volumes
- **Database dumps first**: every running Postgres container gets a
  `pg_dumpall`, every MySQL/MariaDB container a `mysqldump --all-databases`,
  gzipped into the backup — so a database restore is a clean SQL import,
  not surgery on a copied data directory
- `/etc`, `/root` — server configuration

## Honest differences (read before relying on it)

1. **It is not a hypervisor disk image.** Contabo's add-on copies the whole
   disk and restores it in two clicks. This system restores everything that
   matters — Coolify, all apps, all databases, all volumes — onto a fresh
   VPS (procedure below), but the OS itself is reinstalled, not imaged.
   The optional snapshot layer (§ Layers) covers whole-disk rollback within
   the plan's 3 included snapshot slots.
2. **The 10-day window is real.** Damage noticed after 10 days is past every
   restore point — same limit as Contabo's add-on. If that ever feels too
   short, raising the two retention numbers in `autobackup.sh` is a
   one-line change (storage cost grows accordingly).
3. **The repository password is the keys to everything.** It is generated at
   install into `/etc/eaje-autobackup/repo-password`. Keep a copy off the
   server (password manager). Lose it and the backups are unreadable —
   by design.

## Layers

1. **Daily engine (the add-on equivalent)** — `autobackup.sh` + systemd
   timer. Restic incremental backups, 10 restore points / 10 days,
   off-server, encrypted.
2. **Optional: true disk snapshots** — `contabo-snapshot-rotate.sh` uses
   Contabo's API to take a real snapshot on a weekly rhythm and rotates
   within the 3 slots the plan already includes. It only ever deletes
   snapshots named `autobackup-*`, never manual ones, and only after the
   new snapshot exists. Needs API credentials created in the Contabo panel
   (`contabo-api.env`). Suggested schedule: Sunday 04:30 via cron:
   `30 4 * * 0 root /usr/local/bin/contabo-snapshot-rotate.sh`

## Install (on the VPS, as root)

```bash
git clone <this repo> server-autobackup   # or copy the folder up
cd server-autobackup
./install.sh
```

Then:

1. Edit `/etc/eaje-autobackup/config.env` — set `RESTIC_REPOSITORY`
   (and the S3 keys if the repository is S3). **This is the one real
   decision**: where the backups live. Recommendation: Contabo Object
   Storage — separate infrastructure from the VPS, S3-compatible, one bill.
   Backblaze B2 or any second server over SFTP work just as well.
2. Save the repo password off-server (see above).
3. Initialise and take the first (full) backup:
   ```bash
   eaje-autobackup.sh --init
   eaje-autobackup.sh --force
   ```
4. Confirm: `cat /var/lib/eaje-autobackup/status.json` and
   `restic snapshots` (with the config env loaded) show the first restore
   point. From here the timer runs it daily on its own.

## Restore (the whole point — test this before you need it)

On a fresh Ubuntu VPS:

1. Install Docker + Coolify the standard way, then stop Coolify.
2. Install restic, point `RESTIC_REPOSITORY` / `RESTIC_PASSWORD_FILE` at
   the backup repo, and run:
   ```bash
   restic restore latest --target /
   ```
   This returns `/data`, the docker volumes, `/etc`, `/root`, and the DB
   dumps (under `/var/lib/eaje-autobackup/dumps`).
3. Start Docker + Coolify. Apps whose databases live in volumes come back
   with their data. For a database that must be rebuilt from its dump:
   ```bash
   gunzip -c /var/lib/eaje-autobackup/dumps/<container>.sql.gz | docker exec -i <container> psql -U postgres
   ```
4. Verify each site answers, then re-point DNS if the IP changed.

## Operations

- Status: `cat /var/lib/eaje-autobackup/status.json`
- Log: `/var/log/eaje-autobackup.log`
- Force a run now: `eaje-autobackup.sh --force`
- Timer state: `systemctl list-timers eaje-autobackup.timer`
- List restore points: `restic snapshots` (config env loaded)

## Files

| File | Purpose |
|---|---|
| `autobackup.sh` | The daily engine (dumps → backup → retention → check → status) |
| `config.env.example` | Repository + credentials config template |
| `eaje-autobackup.service` / `.timer` | systemd oneshot + daily schedule |
| `contabo-snapshot-rotate.sh` | Optional weekly true-snapshot layer (Contabo API) |
| `contabo-api.env.example` | API credentials template for the snapshot layer |
| `install.sh` | One-shot installer |
