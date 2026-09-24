# Server

Production: **https://upload-video-api.fly.dev**

One Go container on Fly, one SQLite volume, and one private Tigris bucket. No separate database service or proxy container. RustFS remains available for local development.

## Deploy

From the repository root:

```sh
./tools/deploy-fly.sh
```

Configuration lives in [fly.toml](fly.toml): `ewr`, 1 shared CPU, 512 MB memory, a 1 GB volume at `/data`, HTTPS, and `/health` checks. Keep **one Machine**; `--ha=false` prevents an automatic spare. A deploy or restart briefly interrupts the API; the phone's upload queue retries.

Tigris credentials are Fly secrets, set automatically by `fly storage create -a upload-video-api`. The server reads `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_REGION`, and `BUCKET_NAME`. Nothing secret goes into the app or `fly.toml`. The bucket is private, with two-minute signed URLs. Existing `S3_*` variables still work for local RustFS.

```sh
flyctl status -a upload-video-api
flyctl checks list -a upload-video-api
flyctl volumes list -a upload-video-api
flyctl logs -a upload-video-api
```

## Invitations and accounts

Run admin commands inside the existing container as `app`. Find its ID with `flyctl machine list -a upload-video-api`.

```sh
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo invite --out /data/invite.png' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo accounts' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo invite --account ACCOUNT_ID --out /data/replacement.png' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo revoke --account ACCOUNT_ID' -a upload-video-api
```

Download an invite with `flyctl ssh sftp get /data/invite.png ./invite.png -a upload-video-api -u app`. If this network cannot establish Fly's SSH tunnel, use `tools/fly-download.py` instead. Hand out QR codes individually; each is a secret, expires after 24 hours, and is single-use. An optional `--ttl` changes its lifetime.

Sessions last seven days. `--account` binds a fresh invite to an existing active account, useful for a replacement phone or retrieval helper. A lost device's session can be revoked separately with `revoke --session-hash HASH`. Account revocation blocks all its sessions; previously issued storage URLs expire within two minutes.

## Retrieve media

Issue a separate invite bound to the recording account, then redeem it with `tools/enroll.py` to save a private local session file. Use the deployed API:

```sh
python3 tools/enroll.py --api https://upload-video-api.fly.dev --out viewer.session.json
python3 tools/retrieve.py --api https://upload-video-api.fly.dev --session viewer.session.json
python3 tools/retrieve.py --api https://upload-video-api.fly.dev --session viewer.session.json --capture CAPTURE_ID --out retrieved/CAPTURE_ID
```

The helper saves JPEGs and playable fragmented MP4 snapshots, even while recording continues. It checks hashes and reports missing sequences. No `/finish` or final upload acknowledgment is required to recover media already in Tigris.

## SQLite backup

Fly takes daily volume snapshots, retained for 14 days. For a consistent SQLite backup that can be copied off the volume:

```sh
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo backup --out /data/backup-YYYY-MM-DD.sqlite' -a upload-video-api
python3 tools/fly-download.py --machine MACHINE_ID /data/backup-YYYY-MM-DD.sqlite ./backup-YYYY-MM-DD.sqlite
```

Protect backups as user data. They contain account/media metadata, not the media objects themselves. To restore, stop the app, preserve the old database and WAL/SHM files together, and restore to a fresh path before starting. Never overwrite an open SQLite database. This pilot has one database copy on one host; snapshots do not provide high availability.

## Local development

`./tools/start-local.sh` runs the API and RustFS using `server/.env`; see `.env.example`. Point `UploadVideo/Configuration/Local.xcconfig` at the local API to override the app's Fly URL. Run `./tools/verify-local.sh` for the synthetic live-media test, or `cd server && go test -race ./...` for backend tests.

## API

- Public: `GET /health`, `POST /enroll`.
- Authenticated: `GET/PATCH /me`, `PUT /captures/{id}`, `POST /captures/{id}/objects/reserve`, `POST /captures/{id}/objects/ack`, `GET /captures`, `GET /captures/{id}`.
- Optional: `POST /captures/{id}/finish`; retrieval does not depend on it.

Protected requests check session expiry/revocation, active membership and ownership. Enrollment is limited to ten attempts per peer IP per minute; clients behind the same proxy may share that allowance. Objects are capped at 12 MiB and account reservations at 5 GiB. Uploaded data is immutable through conditional PUTs and verified by SHA-256.

For deployment decisions, actual resources and verification results, see [the deployment note](../docs/fly-deployment.md). Official references: [Fly configuration](https://docs.fly.io/reference/configuration/), [volumes](https://docs.fly.io/volumes/overview/), [Tigris](https://docs.fly.io/tigris/).
