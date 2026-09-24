# Same-day implementation plan

Deployment update: production now uses one Fly.io container, one SQLite volume, and Tigris. See [fly-deployment.md](fly-deployment.md); references to R2 below record the earlier plan.

September 24, 2026. The implementation now includes the native camera, Go/SQLite API, and local RustFS flow. See [device-checklist.md](device-checklist.md) for verified behavior and remaining device/R2 checks. Target a small supervised pilot today, using private TestFlight when available.

**Required flow: scan invite → record video or take a photo → upload immediately → retrieve the media from another device.** Video upload starts during recording and never depends on pressing Stop. Each photo starts uploading as soon as iOS produces its image data, independently of video finalization.

**Product rule: point, shoot, stream.** After initial enrollment, launch directly into the camera. Upload automatically. Keep the camera screen nearly wordless; optional profile details never block capture.

**Today's scope**

| Area | Decision |
| --- | --- |
| Backend | One Go service, SQLite on durable local disk, HTTPS. |
| Storage | Private R2 bucket; direct iPhone uploads through short-lived signed URLs. |
| Authentication | Physical single-use QR invite; random account ID; revocable session stored in Keychain. No email/password login. |
| Video | Roughly 480p, 15 fps, H.264 around 500 kbps; optional mono AAC around 32 kbps. Approximately one-second fMP4 segments. |
| Frame loss | Dropping raw frames is acceptable when capture/encoding cannot keep up. Preserve original timestamps and audio/video synchronization. |
| Photos | JPEG captured and uploaded immediately through the same upload service. Included in today's release. |
| Encryption | Defer app-level media encryption and encryption-key recovery. Keep HTTPS and R2's provider-managed encryption at rest. Our service and Cloudflare can read the media. |
| UI | Camera first: full-screen preview, Photo/Video selector, large shutter, recording timer, discreet cloud indicator, profile icon. |
| Profile | Optional name, email, and Signal username on one simple page. Stored only in our database; not used for login. |
| Deferred | Mesh, gallery, social sharing, adaptive bitrate, extra camera modes, passkeys, and app-level encryption. |

R2 manages its default storage encryption keys; it is not client-side encryption. [R2 data security](https://developers.cloudflare.com/r2/reference/data-security/)

**1. Establish deployment and installation**

Set the real bundle ID, signing team, icon, and camera/microphone permissions. Install on one physical iPhone immediately. Prepare one server, a domain with HTTPS, a persistent database directory, and a private R2 bucket. Keep R2 credentials on the server.

Upload an initial build to TestFlight early. Private external groups still require the first build to pass review; internal testers must be eligible App Store Connect users. Verify which path today's participants can use. [Internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/), [external review](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers/)

**Verify:** the phone runs the app, reaches our API, and can upload/retrieve an authorized test object.

**2. Implement the small server and QR enrollment**

Use five tables: `accounts`, `invites`, `sessions`, `captures`, and `objects`. A capture has kind `video` or `photo`; video objects are initialization/media segments, and a photo has one JPEG object. Enforce ownership and unique capture/sequence identifiers.

Add nullable `name`, `email`, and `signal_username` fields to `accounts`, with authenticated `GET /me` and `PATCH /me` for the caller's own profile. All fields are optional and clearable. Keep them out of R2 object names/metadata and operational logs. Email and Signal username are contact details only; no verification, messaging integration, or account-recovery flow today.

Admin commands issue a QR invite, revoke access, and enroll a replacement device into an existing account. Consume each invite atomically while creating a session. Generate independent random invite/session secrets, store hashes server-side, and save the session in non-syncing iOS Keychain. Proposed pilot defaults: 24-hour invites and seven-day sessions, both revocable.

The API needs enrollment, session validation, idempotent capture creation, object reservation/upload authorization, upload acknowledgement, optional video finalization, and listing/download authorization. Reserve object references before issuing URLs so uploaded media remains discoverable if the phone disappears. Check active membership and ownership on every protected request. Rate-limit enrollment and bound upload size, batch size, and per-account usage.

**Verify:** invite reuse and concurrent double redemption fail; sessions survive app relaunch; another account and a revoked session cannot obtain access.

**3. Prove live video and photo uploading**

Feed camera/audio samples into `AVAssetWriter` and use its segment callbacks. Upload initialization data first, then each completed media segment while capture continues. Do not use a finished-movie upload flow. Ensure each segment begins at a usable sync boundary. [Apple's live fragment pipeline](https://developer.apple.com/videos/play/wwdc2020/10011/)

Start with one fixed low-bitrate profile and roughly one-second segments. Enable late-frame dropping and skip raw video samples when the writer is not ready rather than accumulating capture latency. Never remove arbitrary bytes or dependent frames from already-encoded segments. Dropping capture frames does not guarantee enough network bandwidth; measure actual upload delay. [Apple frame-drop guidance](https://developer.apple.com/library/archive/technotes/tn2445/_index.html)

Use `AVCapturePhotoOutput` for still photos. Enqueue each JPEG as soon as processing completes, without waiting for a recording to stop or for a batch of photos. Verify photo capture during video on the intended phones. [Photo output](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput)

Add a small retrieval helper: list a capture, download its authorized objects, play/export video from initialization plus ordered segments, or save the JPEG. It must handle partial recordings and report missing intervals. There is no decryption or key-management step today.

**Verify:** another machine plays earlier segments while the phone is still recording, and retrieves a newly captured photo before that video stops.

**4. Add durable retries and interruption handling**

Persist completed segments/photos atomically to a local upload queue before sending. Store capture ID, sequence, digest, and state; reconstruct pending work after relaunch. These local files contain unencrypted media, protected by iOS file protection. Keep capture callbacks and the UI independent of networking.

Use at most two active uploads. While recording, keep a slot available for video when photos are queued. Retry identical bytes with backoff and renew expired URLs. Use conditional PUTs to prevent overwriting accepted objects; reconcile an existing object or lost response against its expected digest. R2 documents conditional PUT support. [R2 compatibility](https://developers.cloudflare.com/r2/api/s3/api/)

Use short-lived, object-specific URLs, initially two minutes. Revocation blocks new URLs; issued URLs last until expiry. Do not expose a public bucket or permanent download links. [Presigned URL behavior](https://developers.cloudflare.com/r2/api/s3/presigned-urls/)

Preserve unsent completed objects while space allows. Start with a 256 MiB queue cap and a free-disk floor; visibly stop new capture before storage is exhausted. Raw frame dropping does not authorize silently deleting captured photos or completed video segments. Keep uploaded local copies for today's pilot until retrieval has been verified and cleanup is explicit.

Foreground capture is the baseline. Handle lock/background as capture interruptions and resume queued uploads on reopening. Add file-backed background transfers only if time permits and device tests pass; they cannot guarantee immediate delivery or continued camera capture. [Apple lifecycle details](research/live-encrypted-video-upload.md)

**Verify:** a 60-second outage, expired URL, lost acknowledgement, server restart, and app relaunch preserve accepted media and resume pending uploads. Finalization must not be required for retrieval.

**5. Finish the minimal UI and operational setup**

Use three small screens/states:

- **First use:** “Scan invite” and the scanner, followed by the camera. Request only the necessary system permissions. No profile-completion step.
- **Camera:** full-screen preview; Photo/Video selector; one large shutter with familiar photo/record/stop states. Show the timer only while recording. A small photo button appears during video so photos can be taken without stopping it. Keep a profile icon in a corner when idle.
- **Profile:** a native form with Name, Email, Signal username, Save, and Back. All optional. No extra settings or dashboard.

Uploads start automatically. No upload button, confirmation after each shot, success toast, tutorial, queue counter, bitrate display, or technical labels on the camera. Use a small cloud icon for uploading/caught-up state and short text only when attention is needed, such as “Offline” or “Storage full.” Never show a cloud-saved state before storage confirmation; recording and upload status remain distinct. Use accessible button labels without adding visible explanatory text.

Add process restart, a health endpoint, redacted logs, and a consistent protected SQLite backup. Test one restore and keep the last working server/app build for rollback. Do not add an admin website or extra services today.

**Verify:** the enrolled app opens directly to the camera; one tap takes a photo or starts recording; upload needs no further action. Empty profile fields do not block capture, edits persist, and another account cannot read/update the profile. Restarting the server preserves account, profile, and capture metadata.

**6. Reserve the final 60–90 minutes for live-use checks**

1. Record for at least 30 minutes on Wi-Fi/cellular; retrieve usable video/audio during recording. Measure upload delay, queue growth, and thermal behavior. Aim for cloud progress within a few seconds on a healthy connection, not a guaranteed latency.
2. Take several photos, including during video. Retrieve each independently without waiting for Stop; verify photos do not block ongoing video upload.
3. Interrupt networking for 60 seconds and terminate the app without clean finalization. Recover uploaded media without the source phone and retry pending files after reopening.
4. Reject reused/expired QR codes, cross-account media/profile access, revoked sessions, and conflicting duplicate object reservations.
5. Verify visible behavior for lock/background, dropped frames, microphone denial, and low storage. Check recovered timestamps/audio sync when frames were dropped.
6. Verify server restart/backup recovery and the actual TestFlight installation route.

**Release condition:** both video and photos upload during capture, already uploaded media can be retrieved without the source phone, and access checks work. Cut gallery, camera polish, and automatic background draining if time is tight. Keep live uploads, photo support, persistent retry on reopening, and truthful cloud-save status.

**Repository layout**

- `server/`: Go API, SQLite migrations, admin commands, deployment instructions.
- `UploadVideo/`: enrollment/session, capture, persistent upload queue, camera UI, and optional profile form.
- `tools/retrieve/`: small local download/playback/export helper.

Build in this order: installation/infrastructure → enrollment/API → live video and photo proof → retries → UI/deployment → device checks. App-level encryption is explicitly deferred for this pilot; earlier research describing encrypted media/key recovery is not today's implementation scope. The plan was subsequently implemented; actual validation and remaining release checks are tracked in `device-checklist.md`.
