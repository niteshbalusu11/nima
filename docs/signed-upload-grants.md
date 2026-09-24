# Signed upload grants

## Purpose and scope

A **creator** iPhone records a video and owns its cloud capture. An **uploader** iPhone is a separately enrolled, preapproved recipient that saves the video over the nearby Bonjour peer connection and may later relay its saved fragments into the creator's private cloud capture. The creator can be offline throughout recording and handoff. The uploader needs internet only when redeeming and uploading.

This document specifies the authorization and upload flow. It extends [Bonjour peer video sharing](bonjour-peer-video-sharing.md). The existing creator-to-cloud upload remains independent. A grant permits uploading signed fragments to one capture; it grants no capture read, delete, account access, arbitrary bucket access, or permission to finish the capture. The bucket name, object keys, and S3 credentials remain server-controlled.

## Actors and prerequisites

- **Creator device:** enrolled in the Go API; holds a device-only signing key in its iOS Keychain. The server stores the matching public key, key ID, device ID, and owning account ID.
- **Uploader device:** separately enrolled; has a server session bound to its device ID. It accepted the creator's invitation with relay permission. The creator selected it for automatic delivery and cached its device ID and public key before going offline.
- **Go API:** stores active device identities and approval records, owns capture metadata and quota enforcement, and holds the credentials for the private Tigris bucket.
- **Peer connection:** uses mutually authenticated TLS over Bonjour peer-to-peer Wi-Fi. Device identity comes from the authenticated keys, never a Bonjour name or TXT record.

The current API sessions identify only an account. Before implementing grants, add device registration and bind every new or migrated session to a specific device ID. Registration must prove possession of the submitted signing key. Bind grant-signing keys to the device record; do not accept public keys supplied by an uploader during redemption. Revoking a device or relay approval must stop new redemptions and reservations.

Use a dedicated P-256 grant-signing key, separate from the peer TLS identity. Register its uncompressed X9.63 public-key representation; CryptoKit can sign on iOS, and Go's `crypto/ecdsa` can verify the DER-encoded ECDSA signature. A replacement phone gets a new device ID and key. The private key never leaves the creator's Keychain.

## Grant and fragment formats

Use a versioned, deterministic binary encoding rather than independently serialized JSON. Sign the exact payload bytes, including a distinct domain prefix. IDs are 16 raw bytes on the wire: account, device, and grant IDs render as lowercase 32-character hex; the capture ID renders as a lowercase canonical UUID. Integers are unsigned big-endian; reject trailing bytes, unknown versions, invalid IDs, and values outside server limits. The API transports payload and signature as unpadded base64url strings; it never reconstructs the signed bytes from JSON fields.

| Grant v1 field, in signed order | Meaning |
| --- | --- |
| `SV-RELAY-GRANT-v1\0` | Domain prefix; prevents a signature for another message type from authorizing a grant. |
| `grant_id` (16 bytes) | Cryptographically random, unique one-time redemption identifier. |
| `capture_id` (16 bytes) | The creator's capture ID, generated when recording starts. |
| `creator_account_id`, `creator_device_id` (16 bytes each) | Claimed owner; the server must match these against its device record. |
| `uploader_device_id` (16 bytes) | The one authorized receiving device; the server must match it to the caller's session. |
| `capture_kind` (1 byte) | `1 = video` in v1. |
| `destination_id` (2-byte length, then ASCII) | Server-managed destination, initially `primary`; maximum 64 bytes. It is not an S3 URL or bucket name selected by a peer. |
| `issued_at`, `expires_at` (8 bytes each) | Unix seconds. The server applies a fixed maximum lifetime and modest clock-skew allowance. |
| `max_bytes` (8 bytes) | Total unique fragment bytes this grant may reserve, also subject to the creator account's quota. |
| `scope` (1 byte) | `1 = upload signed fragments only`; reject all other values in v1. |

Each completed fragment carries a separate creator-signed manifest. The same manifest can be sent to multiple approved uploaders, while each uploader gets its own grant. The manifest's signed bytes are, in order: `SV-RELAY-FRAGMENT-v1\0`, `capture_id` (16 bytes), `sequence` (4-byte unsigned integer), `kind` (`1 = init`, `2 = media`), `size` (8 bytes), SHA-256 (32 bytes), MD5 (16 bytes, for the current storage adapter), `duration` and `start_time` (each an IEEE-754 binary64 value in big-endian bit order). Reject non-finite or negative timing values; enforce the existing sequence, kind, size, and duration limits. The sender must sign the exact metadata it uses for its own cloud reservation so identical creator and uploader reservations compare equal.

The signature is CryptoKit P-256 ECDSA over SHA-256 of the complete domain-prefixed payload, encoded as DER. The server hashes those *received bytes* and verifies the DER signature with the registered public key. The peer wire envelope contains `{payload_base64url, signature_base64url, key_id}`. `key_id` chooses a registered key version; it is not trusted until the signature and device record are checked. Limit envelope sizes before parsing.

## End-to-end flow

### 1. Setup while online, ahead of any recording

1. On enrollment or migration, each phone creates its signing key, registers its public key with proof of possession, and gets a device-bound session. Store the private key in that device's Keychain.
2. The creator invites a particular device. The uploader accepts receiving and optional relay. The API records an active, directional `creator_device_id -> uploader_device_id` approval with `relay_allowed = true`.
3. Both apps cache the approved identity and permission. This is the only stage that requires the creator to contact the API. If approval is revoked while a phone is offline, the server still rejects later redemption or new upload reservations.

### 2. Create and deliver a grant while recording

1. `Camera.record()` creates the capture ID. For each selected uploader, the creator generates a fresh random `grant_id`, sets a bounded byte allowance and expiration, encodes Grant v1, and signs it locally. It persists the signed envelope with that capture's local queue before attempting peer delivery. Grant creation needs no server call or S3 credential. If signing or storage fails, recording continues and that peer's relay state is unavailable.
2. After the nearby TLS connection authenticates both devices, the creator sends the grant envelope and capture ID to that uploader. A grant for another uploader is never forwarded as authorization for this one.
3. As `SegmentWriter` emits each init or media fragment, the creator persists the bytes and exact metadata, signs its manifest, and sends the bytes plus signed manifest. Local capture and the creator's own cloud worker must not wait on peer signing, transfer, or acknowledgement.
4. The uploader checks the peer identity, grant target and signature with its cached creator key, checks each fragment's SHA-256 against the received bytes, and durably stores the grant, manifests, and fragments. It acknowledges a fragment to the creator only after durable local storage. Its checks provide immediate feedback; the API repeats authoritative checks later.

### 3. Redeem when the uploader has internet

`POST /relay-grants/redeem` requires the uploader's own bearer session. Request body: `{ "grant": { "payload_base64url": "...", "signature_base64url": "...", "key_id": "..." } }`. A successful response returns `grant_id`, `capture_id`, `expires_at`, and the remaining allowance. It returns no S3 credential.

In one database transaction, the API:

1. Authenticates an active, device-bound uploader session. Parses the bounded Grant v1 envelope and verifies the signature against the registered creator key.
2. Confirms the signed account belongs to the creator device, both devices/accounts are active, the caller is the named uploader, the directional relay approval is still active, and the scope and destination match server policy.
3. Checks server time against `issued_at` and `expires_at`, the maximum grant lifetime, byte limit, and capture ID/kind. A grant that expired while the uploader was offline cannot be redeemed.
4. Inserts a `relay_grants` row keyed uniquely by `grant_id`, storing a hash of the exact signed envelope and its limits. If the creator's capture does not exist yet because it was offline, inserts the capture under the **creator account**, using the signed kind and `issued_at` as its creation time. If it already exists, verifies its owner and kind.
5. Returns the existing row on an identical retry after a lost response. Reuse of a `grant_id` with different bytes, owner, or uploader fails with a conflict. The grant ID can be redeemed only once into one durable authorization.

### 4. Reserve, upload, and acknowledge each fragment

1. The uploader calls `POST /relay-grants/{grant_id}/objects/reserve` with the creator-signed fragment envelope. The API rechecks the caller's device session, grant, current approval/revocation, expiry, capture ID, signature, fragment limits, creator account quota, and the grant's remaining allowance. It accounts for each distinct sequence once, atomically, so retries and multiple uploaders cannot inflate usage.
2. Reuse the existing immutable `(capture_id, sequence)` object reservation. If the creator or another uploader already reserved identical metadata, return its status. If it is acknowledged, return `acknowledged: true`. Different bytes or metadata for the same sequence return `409 Conflict`.
3. For an unacknowledged object, return a short-lived upload authorization for **only that object**. The current adapter uses a two-minute presigned PUT with signed content headers and `If-None-Match: *`. The uploader sends the persisted bytes, then calls `POST /relay-grants/{grant_id}/objects/ack` with the sequence. The API verifies the stored size and SHA-256 before acknowledging it.
4. On a lost PUT or acknowledgement response, the uploader retries reserve/ack. If an identical object is already present, verification completes the acknowledgement. A conditional PUT failure from a simultaneous creator/uploader upload triggers this reconciliation, not a different-object retry.

The grant is **single-redemption**, not a single-fragment token. It allows repeated reserve/ack calls for signed fragments up to its expiry and limits. A presigned PUT URL is itself reusable until expiration; `If-None-Match: *` prevents an existing object from being overwritten, but does not make the URL intrinsically single-use.

### 5. Expiry, revocation, and result reporting

Check current device and approval status on redemption and every new reservation. Expiry or revocation blocks new upload URLs. An already-issued presigned URL can remain valid until its short expiration; do not claim immediate revocation of that URL. An acknowledgement of an object reserved before revocation may verify what was already stored, without issuing new upload rights. The creator's normal upload path stays usable.

Track three independent outcomes: uploader **saved locally**, creator **uploaded to cloud**, and uploader **relayed to cloud**. Show cloud success only after server verification. If a grant expires before the uploader reconnects, keep and report the local copy according to the app's retention policy; it cannot silently acquire a replacement grant while the creator is offline.

## Server changes

- Add `devices` with account ownership, signing public key/key ID, and revocation state; bind `sessions` to `device_id`. Add directional `peer_approvals` with relay permission and revocation state.
- Add `relay_grants` with unique grant ID, signed-envelope hash, creator/uploader device IDs, capture ID, limits, expiry, redeemed time, and revocation state. Add per-grant distinct-sequence accounting so allowance checks are idempotent and atomic.
- Add the three relay endpoints above, with separate authorization from the existing owner-only capture routes. Do not weaken `owned()` for ordinary capture reads or writes.
- Extract common object validation, reservation, and acknowledgement logic from the owner path so relay and creator uploads enforce the same invariants. The server chooses bucket and object key; the signed `destination_id` only selects an approved server policy.
- Bound request sizes, rate-limit redemption/reservation, avoid logging raw grants or signed URLs, and return stable `401` (session), `403` (permission/signature), `409` (conflict), `410` (expired), or `413` (size/quota) outcomes.

**Storage integrity gate:** The current presigned PUT signs `Content-MD5`, while SHA-256 is verified after the object has landed. An untrusted uploader could attempt to occupy an immutable key with bytes that fail the expected SHA-256 and block a correct retry. Before shipping direct relay PUTs, verify on Tigris that it enforces a presigned `x-amz-checksum-sha256` header matching the creator-signed manifest. If it does not, send relay uploads through the Go API for SHA-256 verification before writing to the final key, or use isolated temporary keys and promote only verified bytes. Post-upload verification alone is insufficient to prevent key poisoning.

## Acceptance checks

1. Creator offline: a preapproved uploader receives a grant and fragments, saves them, later redeems, and the server stores a capture owned by the creator account.
2. The creator and uploader may race to upload the same fragment; identical metadata converges to one acknowledged object. A changed sequence, digest, size, timing value, or signed payload fails.
3. A wrong uploader, unknown key, invalid signature, forged creator account, revoked device/approval, expired grant, unsupported destination/scope, and conflicting replay all fail. An identical redemption retry succeeds idempotently.
4. Grant byte and object limits, creator quota, and object size limits apply across retries and concurrent uploaders. A grant cannot list, download, finish, delete, or upload into another capture.
5. A stored fragment with a lost PUT/ack response is reconciled by digest. A malicious or corrupted PUT cannot permanently occupy the final object key; verify this against the actual Tigris endpoint before enabling direct relay PUTs.
6. If the creator or uploader app is killed, its durable grant/fragment queue can resume the appropriate transfer. Expired grants remain local-only and are reported as such.

## References

- [Apple: Storing CryptoKit keys in the Keychain](https://developer.apple.com/documentation/cryptokit/storing-cryptokit-keys-in-the-keychain)
- [Apple: P-256 signing key](https://developer.apple.com/documentation/cryptokit/p256/signing/privatekey)
- [Go: `crypto/ecdsa.VerifyASN1`](https://pkg.go.dev/crypto/ecdsa#VerifyASN1)
- [AWS: presigned requests are not single-use](https://docs.aws.amazon.com/prescriptive-guidance/latest/presigned-url-best-practices/faq.html)
- [AWS: conditional PUT and SHA-256 checksum](https://docs.aws.amazon.com/AmazonS3/latest/API/API_PutObject.html)
