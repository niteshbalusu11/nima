# Camera feedback and local gallery

The bottom-left thumbnail opens Recents. Tap a photo to view it or a video to play it. The gallery uses this phone's retained media for the signed-in account and works offline. It requires no Photos read permission or new server endpoint.

Each capture shows **Pending** until every local upload object has been acknowledged after server verification, then **Uploaded**. Status updates while the gallery is open and persists across app launches. These badges describe uploads, independently of saving to the system Photos library.

A photo triggers a brief dark shutter animation and a light system haptic when AVFoundation reports that it captured the photo. The hardware flash is explicitly off. During video recording the photo button is on the right; the gallery remains visible on the left but opens only after recording finishes. Viewing the gallery suspends the camera while uploads continue.

Thumbnails and playable videos are generated off the main/capture queues from the retained JPEGs and video fragments. Playback uses the same passthrough export as Photos. The existing local storage limit and retention behavior are unchanged; this is not a cloud library or a deletion interface.

## Verification — September 24, 2026

- Queue probes cover account isolation, grouping video fragments into one capture, newest-first ordering, incomplete video handling, and durable Pending → Uploaded transitions.
- The Swift/RustFS integration test verifies live video and photo uploads before Stop, thumbnails, audio/video sync, Photos export, and zero-based timestamps in downloaded live MP4 fragments.
- Simulator checks cover the bottom-left entry, offline photo/video previews, and badges updating to Uploaded after reconnecting.
- Debug Simulator and Release iPhone builds pass. The previously recorded phone video exports for gallery playback with its correct 6.53-second duration.
- The new video writer subtracts one source-clock origin from both tracks. Existing stored fragments are retained as recorded; gallery playback exports them locally.

Physical shutter feedback and haptics still need a capture on the updated phone; the simulator has no capture camera.
