# Nearby device identities and peer consent

This implements the identity and server-side consent foundation of milestone 1 in [the engineering plan](nearby-sharing-plan.md). It does not yet enable nearby media delivery or delegated uploads. Production TLS certificate construction, native recipient selection, and an offline approval cache remain to be implemented.

## Device keys and session compatibility

`DeviceIdentity.swift` generates separate P-256 signing and transport keys and persists them together before registration. A single Keychain item is scoped to API URL and account, does not synchronize, and uses `WhenUnlockedThisDeviceOnly`. Callers never handle private-key bytes. Corrupt saved keys and missing keys for a locally registered device surface errors rather than silently replacing that identity.

The optional `Session.deviceId` preserves decoding of existing sessions. Registration binds only the caller's token; other tokens for that account stay unchanged. A new session for the same account can prove the same keys and recover the same device ID. Keys cannot be claimed by another account, moved between roles, or replaced on a bound session. Revoked keys cannot be registered again.

Migration 5 adds `devices`, nullable `sessions.device_id`, `device_challenges`, `peer_invitations`, and `peer_approvals`. Existing roles, sessions, captures, and objects are preserved. An older server binary refuses the upgraded database; roll forward or restore a compatible backup when rehearsing rollback.

The native entry point is currently **Profile → Development → Sharing identity** in Debug builds. Point it at the updated local server; this work has not deployed these endpoints. Registration does not enable discovery or approve recipients. Setup errors stay on that screen and do not stop the camera or owner uploads. Leaving the screen or making the app inactive cancels the setup task. A server commit whose response was lost is recovered on retry.

## Registration protocol

All routes authenticate the existing bearer session. Production uses HTTPS. Public keys, nonces, and signatures use canonical unpadded base64url. Keys are 65-byte uncompressed P-256 points. Both keys produce ECDSA ASN.1 DER signatures over SHA-256, using [Apple CryptoKit](https://developer.apple.com/documentation/cryptokit/p256/signing/publickey/x963representation) and [Go's standard ECDSA implementation](https://pkg.go.dev/crypto/ecdsa).

1. `POST /devices/challenge` with `{signing_public_key, tls_public_key}` returns `{nonce, expires_at}`, valid for five minutes. Both keys must be valid and distinct. A new challenge replaces the caller's previous one. Requests are limited to ten per account per minute.
2. Independently sign the exact payload below with both keys. The Swift client constructs it from its own session and keys, rather than signing arbitrary server-provided bytes.
3. `POST /devices/register` with `{nonce, signing_signature, tls_signature}` returns `{id, account_id, signing_public_key, tls_public_key}`: `201` for a new identity, `200` for an identical registration. Every retry verifies both proofs. Retry a lost response with the same challenge until expiry, or get a fresh challenge for the same keys afterward.
4. `GET /devices/current` returns the bound identity; unbound sessions receive `409`, and devices with revoked sharing access receive `403`.

The payload concatenates:

| Field | Encoding |
| --- | --- |
| Domain | UTF-8 `uploadvideo.device-registration.v1` and one zero byte |
| Challenge | 32 decoded nonce bytes |
| Session binding | 32 bytes of SHA-256 of the exact bearer token |
| Account length | Unsigned 16-bit big-endian byte count |
| Account | UTF-8 account ID |
| Signing public key | 65 uncompressed bytes |
| Transport public key | 65 uncompressed bytes |
| Expiry | Unsigned 64-bit big-endian Unix seconds |

The server checks session/account status, challenge expiry, both signatures, key ownership, and the binding in one transaction. Wrong proofs return `403`; missing/replaced/expired challenges return `410`; conflicting or revoked keys return `409`. Registration itself grants no capture permissions.

## Directional consent

These routes require an active registered device for either a member or admin account:

| Endpoint | Behavior |
| --- | --- |
| `POST /peer-invitations` | `{recipient_account_id, recipient_device_id}` validates that exact enrolled recipient and returns `{token, expires_at}`. The caller is the sender. |
| `POST /peer-invitations/accept` | `{token}` can be accepted only by the selected recipient device. Atomically consumes the invitation and returns the approval and both public identities. |
| `GET /peer-approvals` | Returns `{approvals: [...]}` as a full active snapshot for this device. Other devices, including another device on the same account, do not receive these keys. |
| `DELETE /peer-approvals/{id}` | Either participant can revoke; unrelated callers get `404`. Repeated participant deletion is idempotent. |

Peer invitations are separate from app enrollment and cannot create accounts or sessions. Only token hashes are stored. Invitations expire in 24 hours; replacing a pending invitation for the same direction invalidates the old token. Creation is limited to ten per account per minute. Acceptance rechecks both accounts and devices inside the transaction.

An approval is A → B: B consents to receiving A's future shared media. It does not establish B → A or authorize any capture upload. Recorder-signed per-capture grants and exact-object signatures remain required in the relay milestone.

Concurrent acceptance produces one approval ID. Retrying an accepted token returns that same active approval while the invitation record is retained; expired invitation records are cleaned on later invitation creation. Revocation prevents replay from restoring approval. Fresh consent creates a new approval ID, keeping future grants tied to the old approval distinguishable. Each device may participate in 64 active directional approvals to bound the full cache snapshot; this is separate from the simultaneous-transfer limit.

`DELETE /devices/{id}` revokes sharing access for a device in the caller's account, revokes its approvals, and removes its invitations. It deliberately preserves account bearer sessions and owner upload access. Use the existing account/session revocation commands to disable those. New peer operations require an active device, and future relay routes must do the same. The future native cache must preserve local revocation overrides until synchronized; offline phones cannot learn remote revocations immediately.

## Verification

Verified locally on 2026-09-24: the identity/consent race tests, Swift-to-Go registration, two-launch simulator Keychain check, existing RustFS live-media suite, Debug simulator build, and unsigned Release device build all pass. These checks do not establish physical-device radio or protected-data behavior.

```sh
./tools/verify-identities.sh
./tools/verify-local.sh
```

The identity check compiles the actual Swift registration client and exercises it against a temporary Go server/database, using ephemeral keys without writing the Mac Keychain. It also runs migration, proof tampering, session isolation, registration/acceptance races, expiry, consent, limits, and revocation checks under the Go race detector. The existing local suite checks the encoder, persisted queue, cloud upload, recovery, and media decoding against RustFS.

```sh
./tools/verify-identity-keychain.sh [booted-simulator-udid]
```

This additional check uses a disposable simulator app with its own bundle ID and Keychain access group. Two launches exercise persisted registration; it also checks account/environment isolation, storage attributes, and corrupt/missing keys. The script cleans up its credentials and app. It does not replace the Witness app or use a real account. Xcode and an already-booted iOS simulator are required; the optional argument defaults to `booted`.

Physical-device protected-data behavior, TLS certificate provisioning, offline approved-peer authentication, native approval caching, and production deployment remain separate acceptance gates. Keep the [milestone 0 radio and Tigris checks](nearby-feasibility.md) open too.
