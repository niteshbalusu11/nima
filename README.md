# Witness

Invite-only native iPhone camera. Scan an invite once, then shoot. Photos upload immediately; video uploads in roughly one-second fragments **while recording**. Optional profile: name, email, Signal username.

Internal TestFlight uses the ProData Platform Inc account. See [the TestFlight release instructions](docs/testflight.md) for signing, uploading and tester setup.

The phone stays signed in; sessions have no automatic expiry. Unused invite QR codes expire after 24 hours and can only be redeemed once.

SwiftUI/AVFoundation → a small Go API with SQLite → private S3-compatible storage. RustFS locally; Tigris on Fly.io in production. App-level encryption is deferred for this pilot. Release builds use HTTPS; local Debug builds permit HTTP.

## Web camera

`web/` is a small React/Vite camera for phone browsers. Open `/app/` on the deployed HTTPS API, enter an existing invite (member or admin), then take photos or record video. Video chunks upload while recording; photos upload after capture. The website can edit name, email, and Signal username. It cannot create invites. Pending uploads are kept in the browser and retried while the site is open or when it is reopened. Keep the page in the foreground while recording.

The private live dashboard is at `/app/?dashboard=1`. A CLI-issued super-admin invite grants read-only access to captures from every account. The dashboard shows photos as they upload and plays verified video fragments while recording continues. See [server instructions](server/README.md) for invitation and browser storage setup.

To run the built site locally, run `cd web && npm ci && npm run build` before `./tools/start-local.sh`, then open `http://127.0.0.1:8080/app/` on the Mac. From `server/`, run `./uploadvideo web-cors --origin http://127.0.0.1:8080` with the local `.env` loaded so RustFS accepts browser PUTs. Phone camera access requires HTTPS; use the deployed site for device checks.

## Deployed server

The app points to **https://upload-video-api.fly.dev** by default. The backend is one Go container with one SQLite volume and a private Tigris bucket. See [server/fly.toml](server/fly.toml) and [server instructions](server/README.md).

Redeploy with `./tools/deploy-fly.sh`.

## Run locally

Requires Go 1.26.1+, Docker/OrbStack, and Xcode. Start Docker, then:

```sh
./tools/start-local.sh
```

This generates private local credentials in `server/.env`, starts RustFS, creates the private bucket, and runs the API on **http://127.0.0.1:8080**. RustFS console: **http://127.0.0.1:9001**. Console credentials are in `.env`; they never go into the app.

In another terminal, issue an invite:

```sh
cd server
./uploadvideo invite --out data/invite.png
```

For local API testing, copy `UploadVideo/Configuration/Local.xcconfig.example` to `Local.xcconfig` and use `http:/$()/127.0.0.1:8080` for the simulator. Open `UploadVideo.xcodeproj` in Xcode. Run from Xcode with normal signing so Keychain works. The unsigned command-line build below is a compilation check. The simulator can show the UI; a physical iPhone is required for camera/QR testing.

For an iPhone on the same Wi-Fi:

1. In `server/.env`, set `LISTEN_ADDR=0.0.0.0:8080`, `STORAGE_BIND_IP=0.0.0.0`, and `S3_ENDPOINT=http://YOUR_MAC_LAN_IP:9000`. Restart `start-local.sh`. The signed storage URL **must be reachable by the phone**; localhost would point to the phone itself.
   If the server uses a different address to reach storage, keep that address in `S3_ENDPOINT` and set `S3_PUBLIC_ENDPOINT` to the phone-reachable address. The server signs upload and download URLs with `S3_PUBLIC_ENDPOINT`.
2. Copy `UploadVideo/Configuration/Local.xcconfig.example` to `Local.xcconfig` in the same directory. Set `API_BASE_URL` to the Mac's LAN address, preserving the example's Xcode slash syntax.
3. Run the Debug build with the configured ProData signing team and scan the QR. Use a trusted local network for this HTTP development setup. `Local.xcconfig` only affects Debug; Release always defaults to the deployed HTTPS API.

The camera UI has Front/Back/Both and Photo/Video modes, shutter/stop, a photo button during recording, tap-to-focus, a small cloud indicator, and an optional profile sheet. Both uses the rear camera as the full frame with a front-camera picture-in-picture inset in saved photos and video; it requires a device that supports simultaneous camera capture. Video targets 720×1280 at 30 fps and 1.5 Mbps. Single-camera photos request up to 12 MP with balanced processing when the camera format supports it; Both photos use the 720×1280 composite. Microphone denial allows silent video. Profile fields are optional contact details, never login credentials.

The Location button beside the upload icon starts on and remembers the user's choice. With location on and When In Use location permission, each photo upload includes a recent location fix and each video uses one fix from recording start. Turning location off stops collection and omits location from new captures. The server stores latitude, longitude, accuracy, and fix time with the capture. Capturing still works without permission or a recent fix; location is omitted. Location is capture metadata, not embedded in the JPEG/MP4 or the local Photos copy.

Photos save automatically to the iPhone's Photos library after capture, including during video recording. Completed videos save as one MP4 after Stop, reusing the already encoded fragments without re-encoding. The first shutter tap requests add-only Photos permission; denial leaves capture and uploads working and shows “Photos access off.” Enable it later in iOS Settings. Photos saving does not wait for the network, and live uploads do not wait for Photos.

## Verify

```sh
# Backend authorization, recovery, and backup tests
cd server
go test -race ./...
```

With RustFS running and its private bucket initialized, from the repository root:

```sh
./tools/verify-local.sh
```

Requires `ffmpeg`/`ffprobe`. This uses the **app's actual Swift encoder, disk queue, and upload worker** to upload synthetic video/audio and a photo to RustFS, retrieve them before Stop, and decode the retrieved video. It also checks dropped-frame handling, persisted acknowledgments, account isolation, conditional PUTs, and recovery without an upload acknowledgment.

The upcoming nearby-sharing feature has separate [transport and storage feasibility probes](docs/nearby-feasibility.md), available in Debug builds and through local scripts. Physical offline transfer and production Tigris validation are still pending.

```sh
xcodebuild -project UploadVideo.xcodeproj -scheme UploadVideo \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

## Before live use

Local integration tests do not exercise a physical camera, device thermal behavior, cellular networking, or physical-device use of the deployed service. Follow [the device checklist](docs/device-checklist.md) before the pilot. Foreground recording only; locking/backgrounding stops capture. Pending uploads resume when the app opens. Completed fragments survive interruption; the current unfinished fragment may be lost on force-quit.

The app retains both pending and uploaded local media, excluded from iCloud backup, up to 3 GiB with a 100 MiB disk-space floor. It stops recording near that limit. There is no automatic cleanup; Gallery deletion removes a capture from both the phone and cloud. Photos library copies are separate and follow the phone's iCloud Photos settings. Saving to Photos requires permission and successful capture finalization; a force-quit can leave only the retained upload fragments. Failed Photos saves show a short error and are not retried automatically. A long pilot needs retrieval and a way to clear local copies after confirmed upload without deleting cloud media; do not delete the app with pending media. Account storage reservations are capped at 10 GiB per account server-side.

For Fly/Tigris deployment, invitations, revocation, backup and retrieval, see [server/README.md](server/README.md). The original decisions remain in [the implementation plan](docs/implementation-plan.md).
