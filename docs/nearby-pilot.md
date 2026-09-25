# Nearby sharing pilot

The feature is implemented on `codex/nearby-feasibility`. Both phones need this branch's iOS build and a backend built from this branch. The existing TestFlight build and deployed API have not been updated by this work.

## What is testable

- One recorder sends original video fragments and photos directly to up to three approved recipients, independently of its own cloud uploads.
- Recipients verify and save each object before acknowledging it, resume from their saved inventory, watch verified video live, and retain copies across relaunches.
- Each recipient uploads with its own session and a recorder-signed, device-bound permission. The cloud capture belongs to the recorder. Concurrent contributors and complementary partial copies converge at the same canonical objects.
- Local received-copy deletion does not delete the recorder's cloud capture. Revoked/expired permissions leave local copies intact. Unknown and interrupted endings remain distinct from a normal Stop.

Foreground operation is supported. Keep the app open while receiving or uploading. Locking/backgrounding stops nearby sessions; reopening resumes selected outgoing work and cloud retries. Receiving must be selected again. No automatic force-quit/background delivery is promised.

## Install and pair two phones

1. Run this branch's Go server against RustFS for the first pilot. Set `NEARBY_RELAY_ENABLED=true` in its environment; the default is **false**. This flag admits delegated cloud requests, not enrollment or ordinary owner uploads. The server applies additive migrations through version 6 at startup.
2. For a local Mac server, edit the private `server/.env`: use `LISTEN_ADDR=0.0.0.0:8080`, `STORAGE_BIND_IP=0.0.0.0`, and `S3_PUBLIC_ENDPOINT=http://YOUR_MAC_LAN_IP:9000`, keeping `S3_ENDPOINT=http://127.0.0.1:9000`. Start with `./tools/start-local.sh`. Both phones must be able to reach the API and the signed storage URL when testing cloud upload.
3. For Debug builds, put `API_BASE_URL = http:/$()/YOUR_MAC_LAN_IP:8080` in the ignored `UploadVideo/Configuration/Local.xcconfig`. Open `UploadVideo.xcodeproj`, choose the `UploadVideo` scheme, and run on each iPhone using valid development signing. Xcode installation requires Developer Mode. Both builds must use exactly the same API URL.
4. Enroll each phone with its own app invite from that server. In **Nearby → People**, set up each phone. B uses **Share my contact**; A pastes that contact and creates an invitation. B pastes A's invitation and explicitly allows saving and uploading A's media. Do this while online, before disconnecting the phones.
5. A selects B under **Share new captures**. B selects **Receive from A**. Allow Local Network access. Existing media from before selection is not broadcast; enabling sharing during recording includes that recording. A's selection persists across relaunches until turned off.

For TestFlight, follow [the existing distribution instructions](testflight.md) with a new build number and an HTTPS test backend containing this PR. Release ignores `Local.xcconfig`; set its API endpoint deliberately. TestFlight enrollment and this app's invite are separate. Uploading an archive or merging/deploying this PR was not performed as part of implementation.

## First two-phone test

1. With pairing complete, disable cellular and disconnect both phones from access points; leave Wi-Fi enabled. Keep both apps in the foreground. Confirm that B connects without a router or internet.
2. A records for 60 seconds and takes a photo during the recording. B should show growing saved counts and the photo in **Received**. Open the video there and verify video/audio playback **before A stops**.
3. Stop normally. B should have every part and a known ending. Move B out of range and back during another recording; saved counts must catch up after reconnecting. Repeat with C, then D, if available. A slow recipient must not stall another recipient or the camera.
4. Leave A offline or close its app. Give B a route to the configured API/storage server. B should upload into A's capture; check A's cloud dashboard from another client. Repeat with A and B online simultaneously, and with multiple recipients online.
5. Kill A during another recording. Available fragments should survive and upload, while the ending stays unknown unless A persisted terminal evidence. Missing parts must remain visible; the player must not concatenate across a gap.
6. Remove a received copy, relaunch, and confirm it stays removed locally while the recorder's cloud copy remains. Revoke a person in **People** and confirm nearby access stops and their old grant no longer authorizes uploads after revocation is known.
7. Background/lock both roles, deny Local Network, exhaust the receive allowance, and restore connectivity. Confirm accurate paused states and normal camera uploads remain independent of recipient errors.

Record device/iOS versions, access-point/cellular configuration, discovery time, receipt delay, queue growth, playback delay, and failures. The supported recipient count and battery/thermal behavior still require the [30-minute physical-device matrix](nearby-sharing-plan.md#physical-iphone-matrix).

## Automated evidence

On September 24, 2026:

- `./tools/verify-nearby-media.sh`: four registered identities; actual mutual TLS over loopback; real H.264/AAC and JPEG arriving during capture; three independent recipients; disconnect/reconnect; receiver-local HLS playback before Stop; owner upload in parallel; recipient store reopen; native B/C/D uploads into A's capture on real RustFS; complementary partial copies; interrupted ending; gap-safe playback; revoked grant preserving local copies; local-only deletion; combined/cross-account storage accounting and upload-slot cancellation.
- `./tools/verify-signed-media.sh`: Swift/Go signed-record compatibility, tampering, durable receipts, sparse coverage and interrupted receive/restart cases.
- `./tools/verify-local.sh`: full Go race suite, RustFS conditional/checksum writes and original live encoder/uploader/gallery regressions.
- Debug iOS Simulator and unsigned Release iOS builds compile.

These are native/localhost tests, not evidence of iPhone-to-iPhone radio performance. The app supports iOS 17 and later; that OS/device matrix has not been exercised here.

## Storage and transport boundaries

Received media is capped at 1 GiB within a combined 3 GiB durable-media budget across accounts, plus a 100 MiB free-space floor and reservations for in-flight writes. Nothing is automatically evicted. Two total cloud slots prioritize the phone's own uploads. Each nearby connection has at most one video and one photo object in flight and alternates chunks up to 64 KiB; the wire bounds controls to 8 KiB and authenticates only approved registered keys.

Saved receipts are independent of cloud acknowledgements. Receipt inventories are reconstructed on reconnect; terminal evidence can arrive before missing media. Playback serves only the contiguous verified prefix through a random-path listener bound to `127.0.0.1`. Playback failures do not stop saving or cloud upload. If a later unusually long fragment exceeds the player's fixed HLS target duration, **Retry playback** opens a new playlist session. Exporting an incomplete video saves only its available contiguous prefix and is labeled accordingly.

Release's HTTP exception is limited to `127.0.0.1` for that on-device player. API/storage requests continue requiring HTTPS, and nearby connections require TLS 1.3. Apple supports [IP-specific ATS exceptions from iOS 17](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains).

## Before enabling Tigris relay uploads

Run `./tools/verify-relay-storage.sh /absolute/path/to/private-tigris.env` against the intended Tigris configuration. This checks signed SHA-256 enforcement before final-key occupancy and conditional-write races using disposable objects, then removes them. See [probe setup](nearby-feasibility.md#run-the-storage-check). Ordinary existing Tigris uploads passing does not establish the stronger delegated-upload integrity guarantee.

Keep relay admission disabled on production until this check and the device pilot pass. RustFS is the verified provider for this PR's end-to-end test. No production setting, TestFlight build, or deployed service was changed by this implementation.
