# Internal TestFlight

## App identity

- iPhone display name: Witness.
- App Store Connect listing: Witness: Live Capture (the exact name Witness was unavailable).
- Organization: ProData Platform Inc, team `GNQ3HY2357`.
- Bundle ID: `com.prodata.uploadvideo`.
- App Store Connect app ID: `6815790780`; SKU: `upload-video-ios`.
- Version: `0.1.0`, build `1`; iPhone only, iOS 17 or later.
- API: `https://upload-video-api.fly.dev`.

[Open TestFlight](https://appstoreconnect.apple.com/teams/1356bac6-cf3f-47f2-8e94-47ec5b2b3a64/apps/6815790780/testflight).

## First upload status

On September 24, 2026, Xcode 26.6 successfully archived and uploaded version `0.1.0 (1)` with internal-only distribution. Apple accepted the listing name, completed processing, and shows the build as **Testing**. The build is assigned to `ProData Internal`, which uses manual build selection and currently contains the requesting user's existing ProData admin account.

A fresh, single-use enrollment QR is saved privately at `server/data/fly/witness-testflight-2026-09-24.png`; it expires 24 hours after issuance. This is the app's invite, separate from the TestFlight invitation. The file is gitignored.

## Archive and upload

Sign into Xcode with a ProData account that can manage signing and upload builds. Automatic signing is configured in the project. Increase `CURRENT_PROJECT_VERSION` for each new upload; use the matching build number in the archive path below.

From the repository root:

```sh
xcodebuild -project UploadVideo.xcodeproj -scheme UploadVideo \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/Witness-0.1.0-1.xcarchive \
  -allowProvisioningUpdates archive

xcodebuild -exportArchive \
  -archivePath build/Witness-0.1.0-1.xcarchive \
  -exportPath build/testflight-upload \
  -exportOptionsPlist UploadVideo/Configuration/TestFlight-ExportOptions.plist \
  -allowProvisioningUpdates
```

The second command uploads to Apple. Its export options explicitly restrict the build to internal TestFlight. Release does not include `Local.xcconfig`, preventing a local HTTP server override from reaching testers.

The archive includes the app icon, camera/microphone/Photos permission descriptions, and a privacy manifest declaring disk-space checks under reason `E174.1` (checking space before saving captured media). The current pilot uses Apple's HTTPS, Keychain and file protection, with CryptoKit checksums; it has no custom media encryption. `ITSAppUsesNonExemptEncryption` is false for this implementation. Reassess that declaration when media encryption changes.

## Tester setup and first use

After Apple processes the upload, add the build to an internal group and select the intended existing App Store Connect users. Apple permits up to 100 internal testers with eligible team roles. Internal TestFlight builds do not require external beta review and are available for up to 90 days. TestFlight access does not bypass the app's single-use invite enrollment.

Install TestFlight on the iPhone using the invited Apple Account, accept the TestFlight invitation, and install Witness. Issue a fresh app invite using the [server instructions](../server/README.md), then scan it in Witness. Keep invite QR files and account credentials out of source control.

Follow the [physical-device checklist](device-checklist.md), starting with live video/photo upload, retrieval before Stop, Photos saving, and offline recovery. Distribution readiness does not establish field readiness: physical-device capture/cellular/thermal testing and app-level media encryption remain outstanding. Local media retention is capped at 3 GiB without automatic cleanup.

## Apple references

- [Internal testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers/)
- [TestFlight](https://developer.apple.com/testflight/)
- [Encryption declarations](https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations)
- [Required-reason API manifest](https://developer.apple.com/documentation/technotes/tn3183-adding-required-reason-api-entries-to-your-privacy-manifest)
