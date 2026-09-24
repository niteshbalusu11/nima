# Server

Production: **https://upload-video-api.fly.dev**

One Go container on Fly, one SQLite volume, and one private Tigris bucket. No separate database service or proxy container. RustFS remains available for local development.

## Deploy

[GitHub Actions](https://github.com/niteshbalusu11/streamvideo/actions/workflows/deploy-fly.yml) deploys pushes to `master` that change `server/**`, `web/**`, `tools/deploy-fly.sh`, or the deployment workflow. iOS-only changes do not trigger a deploy. To trigger a deployment on demand, choose **Run workflow** in Actions, or run:

```sh
gh workflow run deploy-fly.yml --ref master
```

The workflow runs the Go tests with the race detector, builds the container on the GitHub runner, deploys with `--ha=false`, and checks HTTPS health. Deployments run one at a time. `FLY_API_TOKEN` is a GitHub repository secret containing an app-scoped Fly deploy token; Tigris credentials stay on Fly.

The CI deploy token is valid for one year. To replace it without printing the value, pipe a new app-scoped token directly into GitHub Secrets:

```sh
flyctl tokens create deploy -a upload-video-api --name github-actions-streamvideo --expiry 8760h \
  | gh secret set FLY_API_TOKEN --repo niteshbalusu11/streamvideo
```

All deployments go through this workflow. `tools/deploy-fly.sh` is the CI implementation, not a separate manual deployment step.

The Vite site is built into the same container and served at `https://upload-video-api.fly.dev/app/`. After the first web deployment, configure the private Tigris bucket for browser uploads from that origin:

```sh
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo web-cors --origin https://upload-video-api.fly.dev' -a upload-video-api
```

`web-cors` permits PUT and GET from that exact origin; each object still requires a short-lived signed URL. Run it again after deploying the live dashboard so browser video playback can fetch fragments. It replaces the bucket's CORS rules, so review existing rules first if the bucket gains another browser client. The camera site accepts member and admin invites but offers no invite creation UI.

## Database migrations

The app runs the numbered SQL migrations in `migrations.go` before starting the HTTP server, on the Machine where `/data` is mounted. SQLite `user_version` records progress. Pending migrations run under one write lock and transaction; a failure rolls back the batch and stops startup without deleting data. A binary refuses to open a database newer than its migration list.

Migration 1 is the current schema, including admin/member roles, and adopts the existing prerelease database. For future schema changes, append a migration, add an upgrade test with existing data, and push to `master`. Never edit or reorder an applied migration. Repeated startup is safe; no Fly SQL commands, reset, or separate release-command Machine is needed. Take a backup before destructive schema changes. Deploy an older binary only if it supports the database version; otherwise fix forward through CI.

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
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo invite --admin --out /data/admin-invite.png --text-out /data/admin-invite.txt' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo accounts' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo invite --account ACCOUNT_ID --out /data/replacement.png' -a upload-video-api
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo revoke --account ACCOUNT_ID' -a upload-video-api
```

Download an invite with `flyctl ssh sftp get /data/admin-invite.png ./admin-invite.png -a upload-video-api -u app`. If this network cannot establish Fly's SSH tunnel, use `tools/fly-download.py` instead. Hand out QR codes individually; each is a secret, expires after 24 hours, and is single-use. An optional `--ttl` changes its lifetime.

Sessions do not expire automatically. A phone stays signed in using its saved Keychain token. Enrollment returns `token`, `account_id`, and `role`; sessions have no expiry field. Unused invites still expire after 24 hours.

Only the CLI creates admins (`--admin`). Omit that flag for a member invite. In the app, admins open **Profile → Invite person** to create a member invite and show its QR or copy its token. Each invite creates a separate member account; admin status grants no access to other people’s profiles or media. New users can paste the token or scan the QR. In-app invites last 24 hours; generating another does not cancel an existing invite.

For the private live dashboard, create a separate super-admin invite through the CLI:

```sh
flyctl machine exec MACHINE_ID 'su-exec app:app uploadvideo invite --super-admin --out /data/dashboard-invite.png --text-out /data/dashboard-invite.txt' -a upload-video-api
```

Download the text file privately, then enter its one-time code at `https://upload-video-api.fly.dev/app/?dashboard=1`. The dashboard session stays in that browser tab's session storage. A super admin can view other accounts' captures through read-only `/super-admin/` endpoints; ordinary admins remain limited to their own media. This permission is checked from the account on every request. Revoke the super-admin account through the existing CLI if access should end. Previously issued signed download URLs remain usable until their two-minute expiry.

The dashboard polls for new captures and appends verified MP4 fragments in a browser player. A video is typically a few seconds behind the phone, depending on network delay. The native iPhone app does not yet call `/finish`, so the dashboard displays an idle video as waiting for more fragments after uploads stop; its “finished” label is available for browser recordings that send `/finish`.

`--account` binds a fresh invite to an existing active account, useful for a replacement phone or retrieval helper. It preserves the account role and cannot be combined with `--admin`. The admin-only `revoke` command remains available if explicitly needed; nothing invokes it automatically. Account revocation blocks all its sessions; previously issued storage URLs expire within two minutes.

## Retrieve media

Issue a separate invite bound to the recording account, then redeem it with `tools/enroll.py` to save a private local session file. Use the deployed API:

```sh
python3 tools/enroll.py --api https://upload-video-api.fly.dev --out viewer.session.json
python3 tools/retrieve.py --api https://upload-video-api.fly.dev --session viewer.session.json
python3 tools/retrieve.py --api https://upload-video-api.fly.dev --session viewer.session.json --capture CAPTURE_ID --out retrieved/CAPTURE_ID
```

The helper saves JPEGs and playable fragmented MP4 snapshots, even while recording continues. It checks hashes and reports missing sequences. No `/finish` or final upload acknowledgment is required to recover media already in Tigris.
When a capture has location metadata, the helper also writes a private `location.json` sidecar next to the media.

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
- Authenticated: `GET/PATCH /me`, `PUT /captures/{id}`, `POST /captures/{id}/objects/reserve`, `POST /captures/{id}/objects/ack`, `GET /captures`, `GET /captures/{id}`, `DELETE /captures/{id}`.
- Admin only: `POST /invites` with `{}`; returns `{token, expires_at}`. Clients cannot choose role, account, or expiry. Limited to ten creations per admin per minute, with no total allowance.
- Super admin only: `GET /super-admin/captures` lists the latest 40 captures across accounts; `GET /super-admin/captures/{id}` returns verified fragments and short-lived download URLs. Use `?tail=1` to join a video near its latest fragment, then `?after=SEQUENCE` for new fragments.
- Optional: `POST /captures/{id}/finish`; retrieval does not depend on it.

`PUT /captures/{id}` accepts an optional `location` object with `latitude`, `longitude`, `horizontal_accuracy_m`, and Unix `timestamp`. The location is fixed for that capture, returned by the owner's capture list and detail endpoints, and cleared on deletion. Older clients may omit it.
Migration 3 adds nullable location columns, so existing captures remain valid without a location.

Protected requests check the session token, explicit revocation, active membership and ownership. Enrollment is limited to ten attempts per peer IP per minute; clients behind the same proxy may share that allowance. Objects are capped at 12 MiB and account reservations at 10 GiB per account. Uploaded data is immutable through conditional PUTs and verified by SHA-256.

For deployment decisions, actual resources and verification results, see [the deployment note](../docs/fly-deployment.md). Official references: [Fly configuration](https://docs.fly.io/reference/configuration/), [volumes](https://docs.fly.io/volumes/overview/), [Tigris](https://docs.fly.io/tigris/).

### Capture deletion

`DELETE /captures/{id}` is owner-only and idempotent, returning `202 {"ok":true}` once SQLite commits the deletion. Admins have no extra media access. It also accepts a new capture ID to cancel a photo/video that has not reached the server yet. Deleted captures disappear from listings and return 410 to their owner on subsequent upload/read requests (404 to anyone else).

Migration 2 adds `captures.deleted_at`. This permanent tombstone prevents a stale upload queue from recreating a capture. Storage removal starts immediately and retries at startup and every 30 seconds. Object keys remain for five minutes to clean up late PUTs signed before deletion (URLs expire after two minutes; the app's upload timeout is 30 seconds). After that window, successful removals also discard object metadata. Failed removals remain queued in SQLite. Deleted objects stop consuming account quota immediately. Use an unversioned private bucket; object version retention is not managed by this pilot.
