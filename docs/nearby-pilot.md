# Nearby sharing pilot

The feature is implemented on `codex/nearby-feasibility`. Both phones need this branch's iOS build and a backend built from this branch. The existing TestFlight build and deployed API have not been updated by this work.

## What is testable

- One recorder sends original video fragments and photos directly to up to three approved recipients, independently of its own cloud uploads.
- Recipients verify and save each object before acknowledging it, resume from their saved inventory, watch verified video live, and retain copies across relaunches.
- Each recipient uploads with its own session and a recorder-signed, device-bound permission. The cloud capture belongs to the recorder. Concurrent contributors and complementary partial copies converge at the same canonical objects.
- Local received-copy deletion does not delete the recorder's cloud capture. Revoked/expired permissions leave local copies intact. Unknown and interrupted endings remain distinct from a normal Stop.

Foreground operation is supported. Keep the app open while receiving or uploading. Locking/backgrounding stops nearby sessions; reopening resumes selected outgoing work and cloud retries. Receiving must be selected again. No automatic force-quit/background delivery is promised.

## Install and pair two phones

Debug builds on this branch are pinned to `https://26bd-50-222-161-203.ngrok-free.app`, reaching the Go API and RustFS on Nitesh's Mac. Pull the latest branch and build **Debug** with your own valid development signing. No `Local.xcconfig` is needed; the pin takes precedence over local overrides. Release still uses the deployed API, which has not been updated by this work. The Mac, RustFS, gateway and ngrok must stay running.

Nearby requires **iOS 26 or later and Wi-Fi Aware-capable hardware** (checked at runtime). Camera and cloud upload keep their iOS 17 minimum. Enable the Wi-Fi Aware Publish and Subscribe capability in your signing profile; the checked-in entitlements and service declaration are included in both build configurations. The app's identity remains Nima / `com.prodata.uploadvideo` for the installed pilot build.

1. Enroll each phone with its own invite from the test server. Open **Nearby** once while online; Nima registers the phone and caches a server-signed credential valid for 30 days. Existing users also need this initial credential download after updating. Give the account a name in Profile so the consent sheet identifies it clearly.
2. The recorder taps **Share nearby**. The recipient taps **Join nearby**, selects the recorder in Apple's native picker, and follows the system PIN pairing. Close the recorder's system pairing sheet with **Done** when pairing completes. The app maintains the selected connection and handles its account/permission exchange automatically.
3. On first connection, the recipient taps **Save and back up**. This explicitly allows storing the recorder's media and uploading it to the recorder's account. Previously approved connections do not repeat this consent. Pairing does not exchange either user's login token.
4. The recorder returns to the camera and records. The recipient keeps Nearby open and watches saved copies under **Received**, including live playback. The recorder can use **Add nearby person** for up to three simultaneous recipients and stop each recipient independently.
5. Use **People → Remove** to revoke a sharing permission. Device pairing and app permissions are distinct: merely remaining paired in iOS does not restore a removed app permission. A removed peer may require refreshing the server state and starting a fresh consent flow.

After initial credential download, first pairing and consent can happen without internet. Permissions signed by both devices are saved locally and synchronized by either phone when online. The server validates active accounts/devices and both signatures before allowing delegated uploads. A recipient can therefore restore cloud media while the recorder remains offline.

For a different backend, update the temporary Debug pin and its publicly reachable signed-storage endpoint. First enrollment still needs internet. If ngrok assigns a new URL, rebuild both phones; sessions/identities are scoped to the API URL and new sign-in is required. Use replacement invites for existing accounts to retain cloud ownership.

## First two-phone test

1. After both phones have downloaded their initial credentials, test first pairing while offline. Disable cellular and disconnect both phones from access points; leave Wi-Fi enabled. Keep both apps in the foreground. Use Share/Join and confirm that first pairing, consent and transfer complete without a router or internet.
2. A records for 60 seconds and takes a photo during the recording. B should show growing saved counts and the photo in **Received**. Open the video there and verify video/audio playback **before A stops**.
3. Stop normally. B should have every part and a known ending. Move B out of range and back during another recording; saved counts must catch up after reconnecting. Repeat with C, then D, if available. A slow recipient must not stall another recipient or the camera.
4. Leave A offline or close its app. Give B a route to the configured API/storage server. B should upload into A's capture; check A's cloud dashboard from another client. Repeat with A and B online simultaneously, and with multiple recipients online.
5. Kill A during another recording. Available fragments should survive and upload, while the ending stays unknown unless A persisted terminal evidence. Missing parts must remain visible; the player must not concatenate across a gap.
6. Remove a received copy, relaunch, and confirm it stays removed locally while the recorder's cloud copy remains. Revoke a person in **People** and confirm nearby access stops and their old grant no longer authorizes uploads after revocation is known.
7. Background/lock both roles, deny Local Network, exhaust the receive allowance, and restore connectivity. Confirm accurate paused states and normal camera uploads remain independent of recipient errors.

Record device/iOS versions, access-point/cellular configuration, discovery time, receipt delay, queue growth, playback delay, and failures. The supported recipient count and battery/thermal behavior still require the [30-minute physical-device matrix](nearby-sharing-plan.md#physical-iphone-matrix).

## Automated evidence

The Wi-Fi Aware migration adds automated checks for server-issued credentials, wrong authority, expiry/future dates, signature tampering, credential substitution across TLS connections, fresh challenge proofs, declined consent, first pairing without an HTTP approval request, reconnect without repeated consent, durable permission storage, deferred two-party authorization, concurrent synchronization and revoked-permission replay. The original native media test continues to cover live recording, three recipients and cloud recovery on RustFS. These native tests use loopback TLS, not Wi-Fi Aware radio.

Validation rerun for the Wi-Fi Aware migration on September 25, 2026:

- `./tools/verify-nearby-media.sh`: four registered identities; actual mutual TLS over loopback; real H.264/AAC and JPEG arriving during capture; three independent recipients; disconnect/reconnect; receiver-local HLS playback before Stop; owner upload in parallel; recipient store reopen; native B/C/D uploads into A's capture on real RustFS; complementary partial copies; interrupted ending; gap-safe playback; revoked grant preserving local copies; local-only deletion; combined/cross-account storage accounting and upload-slot cancellation.
- `./tools/verify-signed-media.sh`: Swift/Go signed-record compatibility, tampering, durable receipts, sparse coverage and interrupted receive/restart cases.
- `./tools/verify-peers.sh`: durable approvals, offline restart, refresh/revocation races, consent and cache isolation. The Go race suite also covers concurrent signed-permission synchronization and revoke-before-first-sync.
- `./tools/verify-local.sh`: full Go race suite, RustFS conditional/checksum writes and original live encoder/uploader/gallery regressions.
- Signed Debug iPhone and unsigned Release iOS builds compile with the Wi-Fi Aware entitlement. The new frameworks are weak-linked, preserving startup support below iOS 26. Debug Simulator compilation is also checked; Simulator cannot validate Wi-Fi Aware radio.
- The ngrok-facing RustFS checksum and conditional-create race probe passes, including the public signed-storage route.

These are native/localhost tests, not evidence of iPhone-to-iPhone radio performance. Camera/cloud upload support iOS 17 and later; Nearby is gated to supported iOS 26+ devices. The physical OS/device matrix has not been exercised here.

## Storage and transport boundaries

Received media is capped at 1 GiB within a combined 3 GiB durable-media budget across accounts, plus a 100 MiB free-space floor and reservations for in-flight writes. Nothing is automatically evicted. Two total cloud slots prioritize the phone's own uploads. Each nearby connection has at most one video and one photo object in flight and alternates chunks up to 64 KiB; the wire bounds controls to 8 KiB and authenticates only approved registered keys.

Saved receipts are independent of cloud acknowledgements. Receipt inventories are reconstructed on reconnect; terminal evidence can arrive before missing media. Playback serves only the contiguous verified prefix through a random-path listener bound to `127.0.0.1`. Playback failures do not stop saving or cloud upload. If a later unusually long fragment exceeds the player's fixed HLS target duration, **Retry playback** opens a new playlist session. Exporting an incomplete video saves only its available contiguous prefix and is labeled accordingly.

Release's HTTP exception is limited to `127.0.0.1` for that on-device player. API/storage requests continue requiring HTTPS, and nearby connections require TLS 1.3 over Wi-Fi Aware. A server-signed credential must match the TLS peer key before any app identity or permission is accepted. Apple supports [IP-specific ATS exceptions from iOS 17](https://developer.apple.com/documentation/bundleresources/information-property-list/nsapptransportsecurity/nsexceptiondomains).

## Before enabling Tigris relay uploads

Run `./tools/verify-relay-storage.sh /absolute/path/to/private-tigris.env` against the intended Tigris configuration. This checks signed SHA-256 enforcement before final-key occupancy and conditional-write races using disposable objects, then removes them. See [probe setup](nearby-feasibility.md#run-the-storage-check). Ordinary existing Tigris uploads passing does not establish the stronger delegated-upload integrity guarantee.

Keep relay admission disabled on production until this check and the device pilot pass. RustFS is the verified provider for this PR's end-to-end test. No production setting, TestFlight build, or deployed service was changed by this implementation.
