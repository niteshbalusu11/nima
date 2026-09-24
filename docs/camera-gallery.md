# Camera feedback and local gallery

The bottom-left thumbnail opens Recents. Tap a photo to view it or a video to play it. The gallery uses this phone's retained media for the signed-in account and works offline. It requires no Photos read permission.

Each capture shows **Pending** until every local upload object has been acknowledged after server verification, then **Uploaded**. Status updates while the gallery is open and persists across app launches. These badges describe uploads, independently of saving to the system Photos library.

A photo triggers a brief dark shutter animation and a light system haptic when AVFoundation reports that it captured the photo. The hardware flash is explicitly off. During video recording the photo button is on the right; the gallery remains visible on the left but opens only after recording finishes. Viewing the gallery suspends the camera while uploads continue.

Thumbnails and playable videos are generated off the main/capture queues from the retained JPEGs and video fragments. Playback uses the same passthrough export as Photos. The gallery shows captures retained on this phone for the current account; it does not download a cloud library.

## Verification — September 24, 2026

- Queue probes cover account isolation, grouping video fragments into one capture, newest-first ordering, incomplete video handling, and durable Pending → Uploaded transitions.
- The Swift/RustFS integration test verifies live video and photo uploads before Stop, thumbnails, audio/video sync, Photos export, and zero-based timestamps in downloaded live MP4 fragments.
- Simulator checks cover the bottom-left entry, offline photo/video previews, and badges updating to Uploaded after reconnecting.
- Debug Simulator and Release iPhone builds pass. The previously recorded phone video exports for gallery playback with its correct 6.53-second duration.
- The new video writer subtracts one source-clock origin from both tracks. Existing stored fragments are retained as recorded; gallery playback exports them locally.

Physical shutter feedback and haptics still need a capture on the updated phone; the simulator has no capture camera.

## Logout and deletion

- **Profile → Log Out** confirms, removes the session from Keychain, stops the camera/upload workers, and returns to Enter invite. It works offline, even when Profile cannot load. Media stays on disk and pending uploads pause. Signing in requires a fresh invite; an ordinary invite creates a new account, while the CLI `invite --account` can restore the previous account and its local gallery. Other devices and cloud copies are unaffected.
- **Recents → capture → trash** confirms removal from the app and cloud. An internet connection is required. Failed requests preserve the capture for retry. Copies already saved in Apple Photos stay there.
- The app cancels and awaits upload workers before deletion, then waits for the API to persist deletion before removing originals and preview files. A local deletion journal protects against termination during filesystem cleanup; a server 410 also clears a stale pending capture. No new permissions or dependencies are needed.
- Cloud deletion is owner-only, including for admins. SQLite remembers the deletion and retries Tigris cleanup after interruption. Existing signed upload URLs are covered by a follow-up cleanup window; see `server/README.md`.

Verification includes Swift queue restart/deletion probes, Go race tests, RustFS uploads and deletion, migration from populated version 1, and the existing live video/audio test. Simulator checks cover photo/video deletion, offline deletion preserving media, offline logout followed by relaunch, and cancellation of a deliberately delayed upload reservation during deletion (DELETE 202, late reservation 410). The production smoke test creates and deletes only a disposable synthetic capture.
