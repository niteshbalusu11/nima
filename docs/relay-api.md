# Delegated fragment uploads

The backend portion of the nearby sharing plan is implemented behind `NEARBY_RELAY_ENABLED=true`. The default is disabled. No deployment or production configuration has been changed. Actual Tigris checksum/concurrency verification and physical-device acceptance remain release gates; RustFS tests alone do not authorize enabling a pilot.

Migration 6 adds `shared_captures`, `shared_object_records`, `relay_grants`, `relay_grant_objects`, and `captures.owner_metadata_pending`. Existing sessions, media objects, ownership, deletion tombstones, and legacy capture behavior remain intact. The existing unique capture/sequence and canonical random object key are shared by owner and recipient uploads. The server preserves the first validated manifest envelope for each relayed object, including when that object was initially uploaded by its owner.

## Requests

Every envelope uses [signed media v1](signed-media-protocol.md). All relay calls authenticate with the recipient's own device-bound session. They never substitute the recorder into the request's account context, grant download/list/delete permission, or authorize unrestricted owner routes. JSON bodies remain bounded to 8 KiB.

| POST route | Body | Result |
| --- | --- | --- |
| `/relay-grants/redeem` | `approval_id`, `descriptor`, `grant` | `id`, `capture_id`, `recorder_account_id` |
| `/relay-grants/{id}/objects/reserve` | `manifest` | `acknowledged: true`, or `acknowledged: false`, `url`, `headers` |
| `/relay-grants/{id}/objects/ack` | `sequence` | `ok: true` after storage verification |
| `/relay-grants/{id}/completion` | `completion` | `ok: true` after accepting signed terminal evidence |
| `/captures/{id}/completion` | `completion` | Owner-only forwarding of the original recorder's signed evidence |

Redemption resolves the active approval from the server, verifies the recorder's registered signature and recipient binding, and checks the 30-day lifetime, clock skew, destination, and allowance. It creates a missing capture under the recorder, or binds the same descriptor to an existing capture with matching owner/kind. A grant ID is immutable by signed payload; a fresh valid ECDSA signature over the same payload preserves the first stored envelope. A deleted capture cannot be recreated, including when deletion preceded any upload.

Reservation and acknowledgement recheck the current session, recipient device, both participants' active accounts/devices, approval, grant expiry, and tombstone. Reservation verifies the signed manifest, reuses the canonical object for an exact retry, and rejects conflicting metadata. It charges the recorder's 10 GiB account allowance once per object and the grant allowance once per distinct sequence. Shared captures are bounded to 3 GiB. Rejection rolls back allocations and quota mappings together. A full recipient account does not consume or block the recorder's allowance.

SHA-256, length, content type, and conditional-create requirements are bound into relay upload authorization. URLs last at most two minutes and do not extend beyond grant expiry. The selected implementation is direct presigned PUT; no proxy fallback is shipped. Local presigning occurs while deletion is serialized, but storage byte verification happens outside the SQLite transaction. Acknowledgement rechecks authorization/deletion afterward before marking the object verified. Already issued URLs have the existing bounded residual lifetime; deletion retains their keys through the existing five-minute cleanup grace period.

Clients must send the supplied headers, treat `412` as a reason to request `/ack`, and retry transient storage conflicts with fresh authorization. The owner worker now treats storage `409` as transient so a competing contributor does not stop recording. An upload response alone never constitutes cloud verification.

Relay errors include `code` alongside `error`: `relay_disabled`, `approval_revoked`, `grant_expired`, `capture_deleted`, `metadata_conflict`, `invalid_signature`, `invalid_metadata`, `grant_quota`, `capture_quota`, `account_quota`, `upload_missing`, `not_found`, and `unavailable`. Existing session/device middleware can return its existing 401/403/409 errors without a code. Recipient workers must isolate these errors from the owner's capture-stop and local-delete logic.

## Owner metadata and completion

`PUT /captures/{id}` accepts an optional signed `descriptor` from the registered recording device. Owner-first and relay-first creation converge on that immutable descriptor. A capture created by a relay has pending owner metadata; A's next owner-only PUT fills or explicitly omits location once and clears the flag atomically. Relay requests cannot supply location. Subsequent mismatched owner location retains the existing conflict behavior.

Terminal evidence may arrive before some fragments. It cannot exclude an existing reservation, claim an inconsistent total, or be replaced with another ending. Both owner and relay reservations must respect it. A recipient cannot assert its own completion. For shared capture detail responses, `recording_ending` is `unknown`, `stopped`, or `interrupted`; `cloud_complete` is true only with signed terminal evidence, every expected sequence, matching byte totals, and verified objects. The detail response's legacy `finished` field is true for shared media only when cloud-complete and normally stopped. `POST /finish` rejects shared captures; attaching a descriptor clears any prior legacy finish flag. Capture-list clients must inspect the shared detail status for completion. Legacy capture detail behavior stays unchanged.

## Verification and remaining work

`go test -race ./...` covers concurrent A/B/C reservations, grant/account quota deduplication, owner identity, distinct devices on one account, renewal/re-signing conflicts, invalid signatures, expiration, photos, complementary fragments, a server/database restart, missing terminal evidence, location ordering, migration preservation, deleted-capture resurrection, and revocation/deletion during a deliberately paused storage verification.

`./tools/verify-local.sh` additionally runs the actual relay endpoints against RustFS: corrupt bytes fail before final-key occupancy, then A/B/C race to upload the same signed object, exactly one conditional write wins, and both recipients acknowledge and skip the verified duplicate. The existing real encoder/live-upload test still passes. `./tools/verify-relay-storage.sh` uses the same relay presigner for isolated SHA-256 and conditional-write checks.

The native recipient upload scheduler, shared upload slots, nearby media framing/delivery, combined local storage accounting, and user-facing recovery/playback are still pending. The backend is testable but the complete nearby feature is not enabled in the app.
