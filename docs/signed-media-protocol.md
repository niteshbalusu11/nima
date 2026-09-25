# Signed media v1 and durable receiving

This is the signed-record and storage portion of milestone 2 in [the engineering plan](nearby-sharing-plan.md). `MediaRecords.swift` signs/verifies records; `server/media_records.go` verifies the same bytes. `OwnerMediaRecords.swift` prepares stable records from retained camera objects and `ReceivedMediaStore.swift` persists approved copies. The camera persists ending intent, and the [relay HTTP backend](relay-api.md) consumes the same records behind an admission switch. Automatic native sharing/upload workers and nearby transport are not wired to these modules yet.

## Envelope and encoding

An envelope is JSON `{ "payload": "…", "signature": "…" }`. Both strings use canonical, unpadded base64url. Reject whitespace, padding, invalid characters, and alternate spellings. The decoded payload is at most 512 bytes; the ECDSA ASN.1 DER signature is at most 80 bytes. Sign SHA-256 of the exact payload with the recorder's registered P-256 signing key, separate from its TLS key. Never sign JSON or reconstruct signature input by serializing JSON.

Persist and retransmit the original envelope. SHA-256 of **payload bytes** identifies a record; the signature is deliberately excluded, because two valid ECDSA signatures over identical payloads need not have identical bytes. Every supplied signature is still verified. A duplicate record ID with a different payload is a conflict, regardless of signature validity.

Each payload starts with the exact ASCII domain below, including its final zero byte. Version and record kind are part of this signed domain. Reject unsupported domains, truncated fields, and trailing bytes. All integer fields use unsigned big-endian encoding; 64-bit integers must also fit a positive signed 64-bit value where noted. Doubles use their 64-bit IEEE 754 bit pattern in big-endian order. No variable-length strings, padding, or alignment occur after the domain.

Account, device, approval, and grant IDs are 16 raw bytes, rendered as 32 lowercase hex characters in app/server APIs. A capture UUID is 16 raw bytes, rendered as its canonical lowercase hyphenated UUID. Hashes are raw bytes. The signing-key ID is SHA-256 of the registered 65-byte uncompressed P-256 public key.

### Capture descriptor

Domain: `uploadvideo.media.capture.v1\0` (29 bytes). Total payload: **118 bytes**.

| Ordered field | Bytes |
| --- | ---: |
| Capture UUID | 16 |
| Recorder account ID | 16 |
| Recorder device ID | 16 |
| Signing-key SHA-256 | 32 |
| Kind: video = 1, photo = 2 | 1 |
| Creation time: Unix seconds, greater than zero | 8 |

The claimed account/device/key must exactly match the registered signature-verification identity. Before admitting new data, reject a creation time more than 300 seconds in the future. This record is immutable and excludes the owner's location metadata.

### Recipient grant

Domain: `uploadvideo.media.grant.v1\0` (27 bytes). Total payload: **165 bytes**.

| Ordered field | Bytes |
| --- | ---: |
| Unique grant ID | 16 |
| Capture-descriptor payload SHA-256 | 32 |
| Sender device ID | 16 |
| Recipient account ID | 16 |
| Recipient device ID | 16 |
| Directional approval ID | 16 |
| Destination: primary = 1 | 1 |
| Scope: upload recorder-signed material only = 1 | 1 |
| Issued time: Unix seconds, greater than zero | 8 |
| Expiry time: Unix seconds | 8 |
| Maximum distinct media bytes | 8 |

Require exact descriptor and approval bindings, distinct sender/recipient devices, and the registered recorder's signature. Expiry must be after issue and within 30 days of issue. Admission requires issue no more than 300 seconds in the future and expiry strictly after now. Allowance is positive and at most 3 GiB for video or 12 MiB for a photo; the issuing code should bind a photo's grant to its actual size. Destination is a fixed application storage destination, never a URL supplied by the sender.

Cryptographic verification is separate from current authorization. Relay routes must additionally check the authenticated recipient session, active accounts/devices/approval, revocation, quotas, and capture deletion within their transaction. A valid signature alone grants no HTTP access. Stored expired grants remain available as provenance; they do not authorize new receive commits or relay attempts.

### Object manifest

Domain: `uploadvideo.media.object.v1\0` (28 bytes). Total payload: **137 bytes**.

| Ordered field | Bytes |
| --- | ---: |
| Capture-descriptor payload SHA-256 | 32 |
| Sequence | 4 |
| Kind: initialization = 1, video media = 2, photo = 3 | 1 |
| Media byte length | 8 |
| Media SHA-256 | 32 |
| Media MD5 for the existing storage adapter | 16 |
| Duration in seconds: Float64 | 8 |
| Start time in seconds: Float64 | 8 |

Size is 1 through 12 MiB. Sequences are 0 through 100000. A video has initialization at 0 and media at positive sequences; a photo has exactly kind photo at sequence 0. Non-media objects have zero duration/start. All times must be finite and nonnegative, with positive-zero encoding; reject negative zero, infinities, and NaN. Duration is at most 60 seconds and start at most 6000000 seconds (100000 × 60). Preserve the exact numbers when adapting to the owner's existing JSON reservation format.

SHA-256 is the integrity authority; also verify MD5 so the retained bytes agree with the existing upload adapter. The server adapter produces lowercase SHA-256 hex and standard padded MD5 base64. No byte re-encoding, transcoding, location, uploader ID, or storage key appears in this signed object metadata.

### Completion

Domain: `uploadvideo.media.completion.v1\0` (32 bytes). Total payload: **81 bytes**.

| Ordered field | Bytes |
| --- | ---: |
| Capture-descriptor payload SHA-256 | 32 |
| Ending: stopped = 1, interrupted = 2 | 1 |
| Last sequence | 4 |
| Object count | 4 |
| Total media bytes, including initialization | 8 |

The declared set is exactly sequences 0 through last, with count equal to last + 1. Last is at most 100000; bytes are positive, at least count, at most count × 12 MiB, and at most 3 GiB. Photos require last 0 and at most 12 MiB.

Sender integration must sign this only after the included objects are committed and writer finalization is known. It must not infer normal completion from silence, cloud acknowledgement, or process restart. Missing or inconsistent terminal evidence stays unknown. An interrupted completion certifies a contiguous recorded set and an interrupted ending; it does not certify footage across a missing object.

Receivers may persist completion before all declared objects arrive. A conflicting total, exclusion of already saved sequences, or a later object outside the declaration fails. `completed()` returns an ending only when every declared sequence exists and the byte total agrees. Persisted completion alone does not mean the receiver or cloud has the full capture.

## Recorder contract

`OwnerMediaRecords.prepare()` takes an explicit set of up to three outgoing approval IDs. An empty selection produces no sharing records. It reads retained `UploadQueue` objects independently of their cloud acknowledgement flags, so objects remain available while or after the owner's upload worker sends them. Its constructor verifies that the private identity matches the registered device.

The source is partitioned by API URL, account, and device. It persists the descriptor, individual object manifests, recipient grants, and optional completion as separate protected records, synchronizing each before returning it. Retries and reopening reuse the exact saved envelopes. Before signing a new object it streams and checks the original's byte length and both hashes. Previously signed metadata must continue to match the queue. Location is omitted. Expired grants can be replaced with a fresh grant ID for an explicitly selected, still-approved recipient; old grants remain stored without changing the descriptor or manifests. Permission and capture deletion are checked again after preparation. Transport must also cancel active work on revocation/deletion and verify bytes at the receiver; a prepared file URL is not a permanent authorization.

`Camera` asks `UploadQueue.finishCapture()` to persist terminal intent after the encoder finishes. The queue requires exactly the encoder's emitted object count and contiguous sequences, stores the ending on the final object's metadata, and rejects fragments after that ending. Ordinary cloud acknowledgements preserve it. User Stop is `stopped`; camera interruption, background suspension, and forced capture shutdown use `interrupted`. Missing fragments, process termination, or failed terminal persistence leave the ending unknown. The signed completion is produced only from matching durable counts/totals; a single committed photo is complete immediately. Source signing failures do not block the owner's normal cloud uploads.

The source actor is intended to have one live instance per device. Its signed records are separate from the owner queue; deletion prevents offering media, while metadata retention/cleanup remains part of the pending app storage policy. No automatic recipient selection or media sender is enabled yet.

## Receive-store contract

The store is partitioned by API URL, local account, and local registered device. It stores copies under the recorder's identity, separately from `UploadQueue` and its owner-upload acknowledgement flag. Application Support files are excluded from backup and use complete file protection. Constructors do not scan/hash media on the main actor; the receiving actor restores and validates its index before serving inventory or accepting data.

`begin()` accepts descriptor/grant/manifest envelopes and the already TLS-authenticated sender. It independently resolves current directional consent from `PeerStore`, verifies all signatures and bindings, checks time/allowance/terminal limits, and persists the grant. The caller must not substitute an unverified advertised identity for that sender. An existing sequence returns its original receipt only after rechecking the stored bytes; conflicting metadata is rejected.

New media gets an opaque write ID and a private staging directory. `append()` accepts at most 64 KiB per call and never accumulates a whole media object. At most two writes can be staged. Reservations include each object's full size plus an 8 KiB control-record allowance. The store caps its partition at 1 GiB, 100000 objects, and 4096 grant records, and preserves 100 MiB of free space plus outstanding reservations. A receiver can contain records from multiple approved recorders; connection scheduling will enforce the one-active-sender UI policy.

`commit()` rechecks local consent and grant expiry, validates complete length and both hashes, synchronizes/closes the media file, writes and synchronizes metadata, synchronizes the staging directory, renames it into the committed namespace, and synchronizes the parent directory. Only then does it return a receipt. File and directory synchronization are used for process-restart durability; these tests are **not** a sudden-power-loss or device-storage-failure guarantee.

Control files use explicitly named staging paths so restart can remove incomplete writes, including writes that died before publishing a grant. Exact grant retries preserve the first envelope, while a fresh valid grant ID is retained alongside older permission for the same capture. A write failure after publication disables the live index until reopen; it cannot turn an uncertain commit into an acknowledgement.

Reopening removes staging files and reconstructs its index from bounded, signature-verified records. It hashes saved media before advertising any receipt. Corrupt/missing records or bytes fail closed instead of advertising a partial index. Sparse inventory is preserved. Grant expiry/revocation prevents new work but does not delete existing copies. `relayGrants()` returns only currently approved, time-valid grants, and `savedObject()` exposes the original signed envelopes and verified file for the later relay worker.

Before enabling real receiving, integrate this reservation accounting with the **combined 3 GiB owner-plus-received budget across all local partitions**, deletion/retention controls, and foreground lifecycle cancellation. The isolated store cap is not the complete application storage policy. No AppModel receive worker is enabled by this slice.

## Verification and remaining integration

Run `./tools/verify-signed-media.sh`. It uses temporary enrolled accounts and ephemeral signing keys, without changing the developer's Keychain or deploying anything. The native probe generates valid and validly-signed malformed records, verifies their behavior in Swift, and passes them to the actual Go verifier. The committed public-key/signature fixture at `server/testdata/signed-media-v1.json` is checked by ordinary `go test -race ./...` and the Swift probe; it contains no private keys or account sessions. Regenerate only deliberately with `UPDATE_SIGNED_MEDIA_FIXTURES=1 ./tools/verify-signed-media.sh`, reviewing any protocol differences.

The receive tests cover video/photo ownership, corrupt and truncated bodies, oversized chunks, identical retries with different valid signatures, conflicts, missing sequences, normal/interrupted completion semantics, expiration, account isolation, local revocation during a write, disk-write failure, corrupted saved files, and a separate process exiting with an actual open partial receive. Another process reopens the store, confirms only committed sequences, and verifies recovery after the missing fragment arrives. Test bytes exercise storage/integrity; the existing `verify-local.sh` suite separately checks actual encoded media.

Source tests prepare a growing recording, deliver its signed objects into the real receive store, acknowledge owner cloud uploads, persist an interruption, and reopen both metadata and queue. They check exact signature reuse, grant renewal, explicit recipient selection, mismatched private keys, revocation, deletion, and corruption before signing. The existing live encoder test additionally checks durable terminal intent after `AVAssetWriter` finishes while cloud uploads run concurrently.

Remaining milestone 2 work includes combined storage accounting, retention/deletion controls, and foreground sharing-worker integration. The [server relay routes](relay-api.md) are implemented and tested behind a disabled-by-default switch. Next milestones connect framing and multi-recipient delivery and the native recipient upload worker, then integrate the user-facing recovery and playback flows. Physical offline networking and actual Tigris integrity checks remain release gates.
