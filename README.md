# Upload Video

Native iPhone app built with SwiftUI. The project currently contains the app shell; camera capture, live encryption, and upload have not been implemented yet.

## Open and run

Open `UploadVideo.xcodeproj` in Xcode, choose the **UploadVideo** scheme and an iPhone simulator, then run. The deployment target is iOS 17.0.

To run on an iPhone, set a unique bundle identifier and your development team in the target's Signing & Capabilities settings. Camera and microphone access must be tested on a device; the simulator does not provide a real camera feed.

## Build from the command line

```sh
xcodebuild -project UploadVideo.xcodeproj -scheme UploadVideo -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```
