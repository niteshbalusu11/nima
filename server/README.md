# Server

One Go process, one SQLite database. RustFS and R2 use the same S3 adapter. Accounts, profiles, hashed invites and hashed sessions remain in SQLite. Storage object names contain only random identifiers.

## Configuration

`tools/start-local.sh` generates `.env` with random local credentials. See `.env.example` for all settings. If running commands manually:

```sh
cd server
set -a
source .env
set +a
go build -o uploadvideo .
docker compose up -d
./uploadvideo init-bucket
./uploadvideo serve
```

Local defaults bind to loopback. For a phone, set both the API bind address and storage bind address, and use the Mac's LAN IP in `S3_ENDPOINT`. Presigned URLs use that exact endpoint; never rewrite their hostname after signing. The console stays loopback-only.

The Compose file pins the RustFS image tested here. RustFS documents its [Docker setup](https://docs.rustfs.com/en/installation/container/docker); its S3 compatibility makes it useful for local integration tests. R2 remains a separate release check.

For production, set:

```dotenv
APP_ENV=production
API_DOMAIN=your-api-domain.example
S3_ENDPOINT=https://YOUR_ACCOUNT_ID.r2.cloudflarestorage.com
S3_REGION=auto
S3_BUCKET=your-private-bucket
S3_PATH_STYLE=false
S3_ACCESS_KEY_ID=your-r2-access-key
S3_SECRET_ACCESS_KEY=your-r2-secret
```

Create a **private** R2 bucket and credentials restricted to that bucket with read/write access. Do not enable public access. The adapter uses conditional PUT, signed Content-MD5 and Content-Length, and server-side SHA-256 verification. R2 compatibility reference: https://developers.cloudflare.com/r2/api/s3/api/ . No browser CORS setup is required for the native app.

Point the domain at the server and allow ports 80/443, then:

```sh
docker compose -f compose.production.yml up -d --build
```

Caddy terminates HTTPS; SQLite uses the named `api-data` volume. Set the iOS Release `API_BASE_URL` to this HTTPS domain. The app includes no storage credentials. Production deployment has been scaffolded, not deployed or validated against R2.

## Admin commands

Run against the same `DATABASE_PATH` as the API. In production prefix these with `docker compose -f compose.production.yml exec api`.

```sh
./uploadvideo invite --out data/invite.png
./uploadvideo accounts
./uploadvideo invite --account ACCOUNT_ID --out data/replacement.png
./uploadvideo revoke --account ACCOUNT_ID
./uploadvideo revoke --session-hash SESSION_HASH
./uploadvideo backup --out data/backup-2026-09-24.sqlite
```

Invites expire after 24 hours by default (`--ttl 2h` to change). Redemption is atomic and single-use. A new invite creates an account unless `--account` binds it to an existing active account. A bound invite adds an independently revocable session; revoke a lost device's session separately. Sessions last seven days. QR images and optional `--text-out` files are bearer secrets: keep them private and hand them out individually.

`accounts` lists IDs and optional names to identify the account for retrieval/replacement. Session hashes are in the `sessions` table; raw session tokens are never stored server-side. Account revocation blocks all its sessions and bound invites. A revoked account cannot be re-enrolled with this CLI.

Enrollment allows ten attempts per peer IP per minute. Behind the included reverse proxy, clients share the proxy's allowance; for a small pilot enroll in batches. Forwarded headers are deliberately not trusted. Protected requests check session expiry, revocation, membership and ownership on each call. Already issued signed URLs remain valid for up to two minutes after revocation.

## Retrieve during recording

The app has no gallery yet. Issue a **separate bound invite for the recording account** and redeem it for a local retrieval session. `--text-out` is convenient for a local test; otherwise copy the physical QR's text with a QR reader.

```sh
./uploadvideo invite --account ACCOUNT_ID --out data/retrieval-invite.png --text-out data/retrieval-invite.txt
python3 ../tools/enroll.py --api http://127.0.0.1:8080 --out data/viewer.session.json
# Paste the QR text at the hidden prompt.
python3 ../tools/retrieve.py --session data/viewer.session.json
python3 ../tools/retrieve.py --session data/viewer.session.json --capture CAPTURE_ID --out ../retrieved/CAPTURE_ID
```

The helper retrieves only that account's captures, verifies hashes, saves JPEGs, and assembles playable fragmented MP4 runs. Missing segments are reported and split into separate files. Run it again for a newer snapshot while recording continues. The server reconciles reserved objects directly with storage, even if the phone disappeared before sending `/ack` or `/finish`.

## Backup and restore

`backup` uses SQLite `VACUUM INTO` for a consistent backup even in WAL mode. Protect this file as user data, store backups on your own infrastructure, and back up the media bucket separately. The command does not copy media.

To restore: stop the API, retain the existing database and its WAL/SHM files together, set `DATABASE_PATH` to a **new path** containing the backup, then restart. Do not overwrite a live WAL database. The automated tests restore a backup and authenticate the original session with its persisted profile.

## API

| Method | Route | Purpose |
| --- | --- | --- |
| GET | `/health` | Database/process health; no storage probe |
| POST | `/enroll` | Consume invite, return independent session |
| GET/PATCH | `/me` | Own optional profile |
| PUT | `/captures/{id}` | Idempotently register video/photo |
| POST | `/captures/{id}/objects/reserve` | Persist immutable object metadata, return two-minute signed PUT |
| POST | `/captures/{id}/objects/ack` | Verify stored length and SHA-256, then acknowledge |
| POST | `/captures/{id}/finish` | Optional completion hint; not required or currently sent by the app |
| GET | `/captures?after=ID` | Own captures, up to 100, ordered by ID |
| GET | `/captures/{id}?after=SEQUENCE` | Up to 50 objects and authorized downloads; reconcile missing acknowledgments |

All except `/health` and `/enroll` require `Authorization: Bearer TOKEN`. The phone never sends this token to storage. Reservations enforce 12 MiB/object, 5 GiB/account including pending reservations, and unique sequence/digest bindings. Two upload workers keep photos independent of video. Retries reserve the same bytes and sequence again; the conditional PUT cannot overwrite an accepted object.

## Known pilot limits

- Local HTTP is a Debug-only development convenience. App-level encryption and mesh are deferred.
- No cleanup automation or quota reclaim. Retained local media requires deliberate cleanup after retrieval; pending media must not be deleted.
- No background camera or guaranteed background transfers. The queue drains on reopening.
- Completion hints are optional; retrieval works on partial recordings.
- JSON/request sizes and enrollment attempts are bounded; there is no general-purpose multi-tenant traffic management. Intended for a small supervised pilot.
