# Pilot device checks

Verification on September 24, 2026:

- Go race-enabled tests: concurrent invite redemption, expiry, account isolation, profile ownership, revocation/re-enrollment, immutable reservations, missing acknowledgment recovery, size validation, enrollment throttling and SQLite backup restore.
- RustFS: signed upload/download, denied public access, conditional PUT rejects overwrite, recovery of an unacknowledged object.
- Real app Swift encoder/queue/uploader on macOS: 480×640 H.264 + AAC, deliberate raw-frame gap, concurrent JPEG, remote download **before Stop**, clean FFmpeg decoding, durable queue acknowledgments.
- Signed simulator: enrollment through the local API, Keychain session survives relaunch, optional profile edits persist.
- Builds: Debug simulator and unsigned Release for physical iOS both compile. Release has no HTTP transport exception.
- Queue: reconstruction after offline capture, account isolation, initialization-before-media ordering, saved originals retained.

- Deployed Fly/Tigris: HTTPS health, invite enrollment, synthetic live video/audio/photo retrieval before Stop, private access, conditional PUT, lost acknowledgment recovery, Machine restart persistence, and downloaded SQLite backup integrity. See [fly-deployment.md](fly-deployment.md).

These checks do not replace physical iPhone validation. Before handing out the app:

1. Set actual signing team, bundle ID and HTTPS API configuration. Install through Xcode first; confirm the intended TestFlight distribution path.
2. Scan a fresh invite. Relaunch: camera opens directly. Reusing the QR fails. Blank profile works; saved name/email/Signal fields persist.
3. Record on the phone for at least 30 minutes. Retrieve playable video/audio while recording. Take photos during recording and retrieve each before Stop.
4. Disable networking for 60 seconds, record/take photos, restore networking, and confirm pending uploads drain. Measure delay and queue growth on cellular.
5. Force-quit while recording. Retrieve already-uploaded media without the phone; reopen and verify completed local fragments resume. The unfinished fragment may be lost.
6. Lock/background and return; capture stops honestly. Deny microphone: silent video still uploads. Deny camera: Settings action appears.
7. Confirm low-storage stops capture visibly and preserves pending files. The pilot retains saved files as well, with a 256 MiB cap.
8. Revoke an account and confirm new upload/download authorization fails. Previously issued signed URLs expire within two minutes.
9. Confirm the physical iPhone uses the deployed Fly HTTPS API and uploads to its private Tigris bucket. Server/storage integration, restart persistence and downloaded backup integrity have already passed.

Do not label the pilot ready until physical-device live video/photo upload, retrieval without the source phone, and private Tigris access have passed.
