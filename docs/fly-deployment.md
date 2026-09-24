# Fly.io deployment plan

September 24, 2026. Production hosting is Fly.io with Tigris; this supersedes the earlier R2 deployment proposal. Local RustFS remains available.

## Plan

1. Run one Go container on one shared-CPU Machine (512 MB) in `ewr`, with an encrypted 1 GB volume mounted at `/data`. SQLite, including WAL/SHM files, stays on that volume. Verify container permissions and survival across a restart.
2. Provision a private Tigris bucket attached to the Fly app. Read Fly's `AWS_ENDPOINT_URL_S3`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, and `BUCKET_NAME` secrets directly. Preserve the existing short-lived signed PUT/GET flow. Verify overwrite rejection, private reads, and lost-acknowledgment recovery against Tigris.
3. Let Fly Proxy terminate HTTPS and route to port 8080. Keep the Machine running for the live-upload pilot. Check `/health` every 15 seconds. SQLite schema initialization runs in the actual app process, where the volume is mounted.
4. Deploy using `fly deploy --ha=false`. Keep exactly one Machine: there is no SQLite replication. Set the Release iOS URL to the deployed HTTPS endpoint. Verify real API enrollment, synthetic live video/photo uploads and playback before Stop, profile persistence, and restart recovery.
5. Enable daily volume snapshots retained for 14 days. Provide consistent SQLite backup/download commands and take a verified initial backup. Treat deploy/restart downtime as a known limitation of this single-instance pilot.

## Why these settings

- Fly's root filesystem is ephemeral. Volumes persist data but attach to only one Machine and are not automatically replicated. [Fly volume overview](https://docs.fly.io/volumes/overview/)
- `fly.toml` supplies mounts, VM size, HTTPS, health checks, and autostop configuration. A release-command Machine has no volume, so it cannot initialize this SQLite database. [Fly configuration](https://docs.fly.io/reference/configuration/)
- `fly storage create -a APP` creates a private bucket by default and injects its credentials as app secrets. Tigris supports the existing S3 adapter and conditional operations. [Fly Tigris docs](https://docs.fly.io/tigris/), [Tigris Go guide](https://www.tigrisdata.com/docs/ai-agents/go-s3-sdk/)

## Status

Implementation and deployment verification in progress. Final resource identifiers and operating commands will be recorded here once deployed.
