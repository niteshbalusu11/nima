# Live encrypted video upload research

Research date: September 24, 2026. This proposal covers native iPhone capture, low-bandwidth encoding, encryption, continuous cloud upload, and recovery. Sources are primary documentation and Apple's SDK. The repository currently has an iOS 17 app shell; this research includes no implementation or device benchmarks.

**Recommendation: continuously capture low-resolution H.264 video, produce approximately one-second fragmented MP4 segments, encrypt each segment on the phone, and immediately upload it as a separate cloud object.** Capture continues while prior segments upload. Start with AVFoundation, CryptoKit, and HTTPS; use direct VideoToolbox or WebRTC only if measurements justify the extra work.

Assumptions: a few seconds of cloud-save delay is acceptable; the primary purpose is preserving footage while recording, with no interactive live-viewer requirement; the cloud should not be able to decrypt media; audio is optional. These assumptions are stricter than encryption in transit/at rest alone. Mesh sharing remains out of scope.

```mermaid
flowchart LR
    A[Camera and optional microphone] --> B[Low bitrate H.264 and AAC]
    B --> C[Short fMP4 segments]
    C --> D[Encrypt on iPhone]
    D --> E[Bounded encrypted upload queue]
    E --> F[Private cloud objects]
    F --> G[Authorized client decrypts and plays]
```

**Quality and bandwidth starting points — proposals to test**

| Profile | Video dimensions, landscape equivalent | Frame rate | Video / mono audio target | Approximate data per hour |
| --- | --- | --- | --- | --- |
| **Default** | 854 × 480 | 15 fps | 500 / 32 kbps | **239 MB** |
| Weak connection | 640 × 360 | 10–12 fps | 250 / 32 kbps | 127 MB |
| Last resort | 426 × 240 | 8–10 fps | 150 / 24 kbps | 78 MB |

Use corresponding portrait dimensions when appropriate. These are starting experiments, not Apple-prescribed settings or guarantees of face identification. The last-resort mode may preserve only scene context. Test whether sacrificing frame rate preserves more useful facial detail than reducing resolution; motion and dim light may require a higher bitrate. No automatic detection of “important parts” is assumed.

Calculations use decimal KB/MB: `(video kbps + audio kbps) × 3,600 ÷ 8 ÷ 1,000`. They exclude container, encryption, transport, metadata, and retry overhead. Default media payload is approximately 66.5 KB per one-second segment or 133 KB per two-second segment. Actual bitrate varies with content and encoder behavior.

## Native iOS capture and segmentation

**This is achievable without waiting for the recording to finish.** Apple explicitly describes a live path from `AVCaptureVideoDataOutput` and `AVCaptureAudioDataOutput` into `AVAssetWriter`, which emits fragmented MP4 data. The application can process each completed fragment while capture continues. [Apple WWDC20: Author fragmented MPEG-4 content with AVAssetWriter](https://developer.apple.com/videos/play/wwdc2020/10011/).

**Proposed first implementation:** capture → H.264 video / optional AAC audio → approximately 1–2-second fMP4 segments → encrypt each segment → upload independently. This introduces a small segment-duration delay rather than a full-recording delay. The delay until cloud durability also includes encoder buffering, encryption, network transfer, and storage acknowledgement. A 1-second segment is an initial measurement target, not a guaranteed maximum loss window.

Use `AVAssetWriter(contentType: .mpeg4)` and its segment delegate, rather than recording a movie to a URL and reading that growing file. Apple's initializer and delegate APIs for this mode are available from iOS 14; the existing iOS 17 target is sufficient. The delegate mode suppresses normal file writing. [Initializer](https://developer.apple.com/documentation/avfoundation/avassetwriter/init(contenttype:)), [segment delegate](https://developer.apple.com/documentation/avfoundation/avassetwriterdelegate/assetwriter(_:didoutputsegmentdata:segmenttype:segmentreport:)). Availability was also checked in the installed iPhoneOS26.5 SDK's `AVAssetWriter.h`.

| API | Relevant behavior |
| --- | --- |
| `outputFileTypeProfile` | Choose `.mpeg4AppleHLS` or `.mpeg4CMAFCompliant` for streaming-compatible fMP4. This is container packaging, not an upload protocol. [Apple API](https://developer.apple.com/documentation/avfoundation/avassetwriter/outputfiletypeprofile) |
| `preferredOutputSegmentInterval` | Set a positive time for automatic segmentation; it cannot change after writing starts. The interval is a preference. [Apple API](https://developer.apple.com/documentation/avfoundation/avassetwriter/preferredoutputsegmentinterval) |
| `initialSegmentStartTime` | Must be numeric when the preferred interval is positive. Align it with the sample timestamp timeline; do not assume camera timestamps start at zero. [Apple API](https://developer.apple.com/documentation/avfoundation/avassetwriter/initialsegmentstarttime) |
| `didOutputSegmentData` | Receives an initialization segment, then media segments. Preserve the initialization data: a media segment is not a complete standalone MP4. The optional segment report supports timing/index construction. [Apple delegate](https://developer.apple.com/documentation/avfoundation/avassetwriterdelegate) |
| `movieFragmentInterval` | Helps recover a partially written movie file after interruption. It is a different mode; the SDK explicitly says this property and `shouldOptimizeForNetworkUse` are ignored for segment delegate output. [Apple API](https://developer.apple.com/documentation/avfoundation/avassetwriter/moviefragmentinterval) |
| `producesCombinableFragments` | Concerns combining fragments produced by multiple writers. It is unnecessary for the proposed single writer; it does not enable live uploading. [Apple API](https://developer.apple.com/documentation/avfoundation/avassetwriter/producescombinablefragments) |

With automatic segmentation and encoding enabled, AVAssetWriter forces a sync sample near each boundary and permits one audio and one video input. With automatic **passthrough**, it waits for existing sync samples and allows only one input. Manual `flushSegment()` requires an indefinite interval, supports passthrough only, and must happen before a sync sample. These distinctions matter if replacing the writer's encoder with VideoToolbox later. Apple also leaves playlist creation to the application. [WWDC20](https://developer.apple.com/videos/play/wwdc2020/10011/), corroborated by `AVAssetWriter.h` lines 708–731 in the installed SDK.

## Compression, latency, and deliberate frame loss

Use the writer's compression settings first. Its `outputSettings` selects encoding; `nil` means passing through already encoded samples. H.264 bitrate and keyframe controls have public AVFoundation keys. [Output settings](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/outputsettings), [compression keys](https://developer.apple.com/documentation/avfoundation/avvideomaxkeyframeintervalkey).

**Proposed settings:** SDR H.264, low resolution and frame rate, roughly one keyframe per segment, and frame reordering disabled. Shorter keyframe intervals improve recovery after loss but consume bitrate; measure the resulting visual quality rather than using all-keyframe video. Apple documents that keyframes reset interframe dependencies, and that disabling frame reordering prevents reordered B frames. [Keyframe intervals](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxkeyframeinterval), [frame reordering](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_allowframereordering).

For capture, enable `alwaysDiscardsLateVideoFrames`, keep callbacks short, and avoid retaining camera sample buffers unnecessarily. Apple's guidance says this bounds the video output queue to one frame and prevents accumulating latency. Set actual device frame duration within the active format's supported range; an encoder's expected-frame-rate hint does not configure the camera. [Apple TN2445: Handling Frame Drops](https://developer.apple.com/library/archive/technotes/tn2445/_index.html).

Set `expectsMediaDataInRealTime` for camera-fed writer inputs and respect their readiness. **Design implication:** drop raw frames before encoding when overloaded; after encoding, discard complete segments at verified sync boundaries rather than arbitrary dependent frames. Preserve timestamps and record missing intervals. [Real-time writer input](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/expectsmediadatainrealtime), [keyframe dependencies](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_maxkeyframeinterval).

Direct `VTCompressionSession` is a possible second step if measurements show a need for finer rate control. Apple exposes `RealTime`, `AverageBitRate`, `DataRateLimits`, frame-reordering and keyframe controls, but warns that encoders may not support every property. `AverageBitRate` is a target, not a hard ceiling: complex frames can temporarily exceed it. [Compression properties](https://developer.apple.com/documentation/videotoolbox/compression-properties), [average bitrate semantics](https://developer.apple.com/documentation/videotoolbox/kvtcompressionpropertykey_averagebitrate).

Do not enable every low-latency option blindly. Apple's low-latency VideoToolbox mode uses hardware encoding, but the current `EnableLowLatencyRateControl` documentation specifies an infinite-GOP default. Independent loss-tolerant segments still need explicit, verified sync boundaries. A standard real-time encoder is a simpler starting point for seconds-scale uploads. [WWDC21: Low-latency encoding](https://developer.apple.com/videos/play/wwdc2021/10158/), [current low-latency flag](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablelowlatencyratecontrol).

**Adaptation proposal:** initially lower capture frame rate or omit raw frames when the network falls behind. Change resolution/encoding profile at a controlled writer restart, preserving the new initialization segment and a timeline discontinuity. Treat seamless mid-recording bitrate changes with the writer's built-in encoder as unproven; benchmark a direct VideoToolbox path before relying on it. Avoid making hardware acceleration a universal claim without checking the chosen device, codec, and encoder configuration.

## iPhone lifecycle constraints

Design ordinary recording for an unlocked iPhone with the app in the foreground. Apple documents a camera interruption when an app enters the background; locking or leaving the app must therefore be handled as an interruption, not promised as continued capture. Video-call/Picture-in-Picture and iPad multitasking facilities are separate use cases, not a general background-camera entitlement for this app. [Background camera interruption](https://developer.apple.com/documentation/avfoundation/avcapturesession/interruptionreason/videodevicenotavailableinbackground), [Apple's multitasking camera scope](https://developer.apple.com/documentation/avkit/accessing-the-camera-while-multitasking-on-ipad).

Previously created encrypted segments can use background `URLSession` uploads, but Apple requires file-backed upload bodies for transfers that survive the app exiting. Background scheduling is system controlled. Use it for draining encrypted pending files after an interruption, without promising continuous camera capture or immediate background delivery. [Background transfer constraints](https://developer.apple.com/documentation/foundation/downloading-files-in-the-background).

System termination and a user force-quit differ: force-quitting from the app switcher cancels background transfers and prevents automatic relaunch. Retained encrypted files can be retried after the user reopens the app. [Background session lifecycle](https://developer.apple.com/documentation/foundation/urlsessionconfiguration/background(withidentifier:)).

Keep current iOS API examples separate from deployment requirements: Apple's newer `SampleBufferReceiver` is iOS 26+, while the older input APIs support the project's iOS 17 baseline. [Receiver API](https://developer.apple.com/documentation/avfoundation/avassetwriterinput/samplebufferreceiver).

**Encryption before upload**

Assumption for this proposal: neither our application server nor the storage provider should possess usable video-decryption keys. HTTPS alone protects the connection; server-managed encryption at rest still permits authorized server-side decryption. Encrypting on the iPhone lets storage receive opaque bytes. This is an architecture choice, not a requirement implied by the word “encrypted.” [AWS client-side encryption explanation](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingClientSideEncryption.html)

Proposed format: generate a fresh 256-bit recording key, then AES-GCM-encrypt each completed initialization/media segment separately with CryptoKit. Compress first, encrypt second. Plaintext exists transiently in the capture/encoding process; persist only ciphertext for retries. CryptoKit produces ciphertext, a nonce, and an authentication tag. Bind a versioned header containing recording ID, segment sequence, segment type, and initialization/version ID as authenticated additional data. This prevents moving a valid encrypted segment into the wrong recording or position without detection by the client. [AES-GCM sealed boxes](https://developer.apple.com/documentation/cryptokit/aes/gcm/sealedbox), [authenticated data API](https://developer.apple.com/documentation/cryptokit/aes/gcm/seal(_:using:nonce:authenticating:))

Use a fresh nonce for every new encryption operation; CryptoKit can generate it. Retrying an upload sends the already-persisted ciphertext, not a newly encrypted message with a reused nonce. A rejected authentication tag means the entire segment is discarded. Independent encryption units allow later segments to decrypt despite a missing earlier one; independent video decoding also requires the sync-frame boundaries described above. [Nonce requirement](https://developer.apple.com/documentation/cryptokit/aes/gcm/nonce), [automatic nonce generation](https://developer.apple.com/documentation/cryptokit/aes/gcm/seal(_:using:nonce:))

Store device secrets in Keychain. Before claiming recovery after phone loss, also establish a way to recover the recording key elsewhere: for example, wrap it to a verified recovery/second-device public key and upload that encrypted key envelope at the beginning. CryptoKit's HPKE is a candidate for this small key envelope; use independently encrypted AES-GCM units for the media. An authenticated recipient-key setup and a tested recovery flow are still needed. [Keychain storage](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain), [HPKE](https://developer.apple.com/documentation/cryptokit/hpke)

**If the only key is on a lost phone, the uploaded footage is unusable.** Logging into the account again does not itself recreate a cryptographic key. Recovery material must survive separately. Giving our service a usable recovery key would change the privacy promise.

With this design, playback/export decrypts on an authorized client; ordinary server-side thumbnails and transcoding cannot inspect footage. Our app needs a retrieval/decryption layer before supplying playable media to its player; an opaque AES-GCM object URL is not directly playable HLS. Sensitive thumbnails and descriptive metadata should also be encrypted. The service still sees necessary account/object identifiers, sizes, and upload timing. These are implications of the proposed trust boundary.

**Upload transport and storage**

| Approach | Fit for this app |
| --- | --- |
| **Short encrypted objects over HTTPS — recommended** | Straightforward native networking and cloud storage; bounded units for retry, acknowledgement, and loss. Buffering one short segment adds latency. |
| WebRTC with an additional end-to-end media-encryption layer | Worth revisiting for interactive live viewers or a measured subsecond latency requirement. A receiver/storage pipeline and key distribution are still needed; a real-time media connection alone does not establish durable cloud storage. |

SFrame is an IETF-defined mechanism for encrypted media that intermediaries can forward without reading. It explicitly leaves key management to the application. LiveKit demonstrates an existing WebRTC implementation with E2EE support, but application key generation/distribution remains our responsibility. A cloud component that decodes or transcodes encrypted media would need the keys, changing our trust boundary. The simpler fit judgment above is ours. [IETF SFrame](https://www.rfc-editor.org/rfc/rfc9605.html), [LiveKit encryption](https://docs.livekit.io/transport/encryption/)

Use one immutable object per encrypted segment plus initialization data and incremental recording metadata. Do not wait for the stop button to make the recording discoverable. A new authorized device must be able to find and play the surviving segments even if the recording phone never returns.

This is compatible with the adjacent [authentication/backend research](authentication-and-backend.md), which proposes Supabase private Storage. Its standard uploads are intended for objects up to 6 MB; our proposed segments are roughly tens to hundreds of KB. Native HTTPS requests should use the provider's supported authentication and request format. Validate background transfer integration separately from ordinary SDK uploading. [Supabase upload guidance](https://supabase.com/docs/guides/storage/uploads/standard-uploads)

S3 illustrates why “one endless multipart upload” is a poor initial design: ordinary parts have a 5 MiB minimum except the final part, and the assembled object requires multipart completion. At 532 kbps, collecting 5 MiB takes about 79 seconds. Separate small object uploads avoid that delay. This S3 API constraint does not refer to ordinary HTTP multipart/form-data uploads. [S3 limits](https://docs.aws.amazon.com/AmazonS3/latest/userguide/qfacts.html), [multipart completion](https://docs.aws.amazon.com/AmazonS3/latest/userguide/mpuoverview.html)

Treat a segment as remotely saved only after storage confirms success, not after the phone reports bytes sent. S3 documents that a successful PUT stores the entire object, and subsequent reads can retrieve it. Other providers' acknowledgement/recovery behavior should be tested directly. Reconcile an upload whose response was lost by checking the expected object and its ciphertext checksum; “already exists” alone does not prove it contains the expected bytes. [S3 PutObject](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html), [S3 consistency](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Welcome.html#ConsistencyModel)

Enforce invite-only membership and recording ownership on every authorized upload/download, on the server. For Supabase, use restrictive storage RLS policies; never put a privileged service key in the app. For a signed-URL provider, scope short-lived URLs to specific objects and treat them as temporary bearer capabilities. This complements encryption. [Supabase storage authorization](https://supabase.com/docs/guides/storage/security/access-control), [S3 presigned uploads](https://docs.aws.amazon.com/AmazonS3/latest/userguide/PresignedUrlUploadObject.html)

One-second segments mean about 3,600 media objects per recording hour; two-second segments mean 1,800. Budget for request and metadata operations as well as stored bytes. These are arithmetic counts, excluding initialization, retries, and downloads; no cloud bill is estimated here.

**Handling slow or missing connectivity**

Proposed policy, to validate on devices:

1. Keep capture, encoding, encryption, and upload off the main UI thread and avoid waiting for networking inside capture callbacks.
2. Persist a bounded queue of encrypted segments. Start by testing a 10-second maximum backlog and one or two active uploads.
3. Use observed upload completion time and queue age to step down bitrate/frame rate. Leave bandwidth headroom; a nominal encoder bitrate is not an instantaneous network ceiling.
4. When the backlog reaches its limit, expire stale unsent media segments and prioritize recent footage. Keep required initialization data and key envelopes; never evict those as ordinary stale media. This deliberately trades older missing sections for recent cloud preservation.
5. Retry failed segments only within their useful age, using the same bytes. HTTP remains a reliable transport; dropping happens at our frame/segment queue and request-cancellation layer, not by accepting a corrupt partial encrypted object.
6. Track gaps and original timestamps explicitly. Recovery/playback skips to the next independently decodable segment without inventing footage or silently reporting uninterrupted recording.

During a complete outage, nothing can reach the cloud. A finite queue only bridges a finite gap. Keeping all offline footage would be a separate retention/backfill policy; it is not required for this loss-tolerant first version.

Compute protection delay as: segment formation + encoder buffering + upload queue + network transfer + storage acknowledgement. A one-second segment at 532 kbps is about 66.5 KB; at 1 Mbps useful uplink, its transfer alone is about 0.53 seconds. Thus a roughly 1–3-second target on a healthy connection is plausible for one-second segments, but it is an estimate to test, not a guaranteed maximum. Two-second segments take about 1.06 seconds to transfer on that link, before the other delays.

Upload initialization data and the recoverable key envelope early. A “recoverable in the cloud” status requires those dependencies as well as acknowledged media. Store enough metadata incrementally that cloud objects remain discoverable if the phone disappears between object upload and metadata acknowledgement. Sequence numbers expose interior gaps; an abrupt end is not proof that no additional footage was captured. An authenticated final record can identify a clean stop when it actually arrives.

**A focused validation experiment**

Implement only a minimal record/stop screen and the end-to-end pipeline first. Proposed success criteria:

- **Actual live preservation:** download and decrypt completed segments on another client while the phone is still recording. With the one-second profile, target p95 capture-to-storage acknowledgement below three seconds on a controlled 1 Mbps uplink, then report measured latency on cellular. Measure startup and final partial-segment delay separately, and verify audio/video synchronization across gaps and encoder restarts.
- **Useful detail:** compare the proposed profiles in daylight, indoor light, dim light, walking, and fast camera movement, with faces at representative distances. Choose quality by reviewing recovered cloud footage. If faces are not usable, raise bitrate/resolution; do not declare success merely because video decodes.
- **Loss isolation:** intentionally omit a middle segment, terminate capture mid-segment, lose an upload response, and disconnect networking for 5, 15, and 60 seconds. The next retained sync segment must decode; memory/queue size must remain bounded; acknowledged earlier footage must survive without normal finalization.
- **Privacy and recovery:** verify uploaded objects and retry files contain ciphertext, tampering fails authentication, retries preserve bytes, and a second authorized device can recover without the recording phone.
- **iPhone lifecycle:** test lock, background, interruptions, relaunch, network changes, and 30-minute thermal/battery behavior on physical iPhones including the oldest supported test device. Report capture stoppage separately from completion of already-created uploads.
- **Access control:** verify an uninvited user, another recording owner, and a revoked member cannot obtain new authorized access.

This research establishes an available native architecture, not measured production behavior. The implementation decisions still needing confirmation are the recovery model, acceptable cloud-save delay, and the lowest quality that passes real scene testing.
