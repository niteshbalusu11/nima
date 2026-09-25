# Nearby device identities and peer consent

Nima uses registered device keys, server-signed credentials, and a permission signed by both phones. Wi-Fi Aware handles device pairing; the app separately verifies enrolled identities and asks the recipient to **Save and back up**. See [the pilot guide](nearby-pilot.md) for setup and [the migration plan](wifi-aware-plan.md) for the design.

## Device keys and session compatibility

`DeviceIdentity.swift` generates separate P-256 signing and transport keys and persists them together before registration. A single Keychain item is scoped to API URL and account, does not synchronize, and uses `WhenUnlockedThisDeviceOnly`. Callers never handle private-key bytes. Corrupt saved keys and missing keys for a locally registered device surface errors rather than silently replacing that identity.

The optional `Session.deviceId` preserves decoding of existing sessions. Registration binds only the caller's token; other tokens for that account stay unchanged. A new session for the same account can prove the same keys and recover the same device ID. Keys cannot be claimed by another account, moved between roles, or replaced on a bound session. Revoked keys cannot be registered again.

Registration and sharing schema migrations preserve existing accounts, sessions, captures, and objects. The unmerged Nearby migration no longer creates the obsolete peer-invitation table. Account-enrollment invitations are separate and remain supported.

Open **Nearby** once while online to register the device and cache its credential. Setup errors do not stop normal camera or owner uploads. A server commit whose response was lost is recovered on retry.

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
| `GET /devices/credential` | Returns a server-signed device credential valid for 30 days and the server's public verification key. |
| `PUT /peer-approvals/{id}` | Synchronizes a permission signed by both devices, or its revocation tombstone. Either participant may submit it; both accounts/devices and signatures are checked. |
| `GET /peer-approvals` | Returns `{approvals: [...]}` as a full active snapshot with participant display names for this device. Other devices, including another device on the same account, do not receive these keys. |
| `DELETE /peer-approvals/{id}` | Either participant can revoke; unrelated callers get `404`. Repeated participant deletion is idempotent. |

An approval is A → B: B consents to receiving A's shared media. It does not establish B → A or authorize arbitrary capture uploads. Recorder-signed per-capture grants and exact-object signatures are also required for cloud recovery.

Concurrent synchronization is idempotent. Revocation prevents replay from restoring an approval. Fresh consent creates a new permission ID. Each device may participate in 64 active directional approvals to bound the cache; this is separate from the three-recipient transfer limit. The manual contact-code and peer-invitation API has been removed.

`DELETE /devices/{id}` revokes sharing access for a device in the caller's account and revokes its approvals. Account bearer sessions and owner upload access remain valid. Use account/session revocation to disable those. Offline phones learn remote revocations when they reconnect.

## Native approval and offline behavior

Both phones first open Nearby while online to cache their credentials. The recorder taps **Share nearby**. The recipient uses **Join nearby → Choose a phone**, or **Pair a phone** if needed, then explicitly accepts **Save and back up**. Apple's PIN pairing and app consent are separate. See [the pilot guide](nearby-pilot.md) for the complete flow.

On the encrypted connection, each phone verifies the other's server-signed credential against its own cached authority, binds it to the TLS key, and checks fresh challenge signatures. Both devices sign the same directional permission and persist it before media transfers. Either phone can synchronize it later; pairing and consent do not require an online server once credentials are cached.

`PeerStore` is scoped on disk to server, account, and device. It persists a bounded snapshot with complete file protection, owner-only permissions, atomic replacement, and backup exclusion. Corrupt, mismatched, oversized, or unwritable state is surfaced rather than used for authentication. Cached approvals remain usable when ordinary network requests fail. A known `401`/`403` disables the local cache and persists that state. Refreshes are serialized.

**Remove** persists a local override immediately, including during an outstanding refresh. The next sync sends a tombstone for an unsynchronized permission, deletes the approval, and fetches a full snapshot. Removals made during that request survive both the response and restart. Failed persistence disables use of in-memory permissions. A revoked permission ID cannot be saved again.

An offline removal affects this phone immediately. The other phone and server learn it after synchronization; it cannot erase bytes already received. Changing accounts cannot reuse another device's cache. Nearby pauses when the app leaves the foreground or the session changes.

## Registered-key TLS

`DeviceIdentity.tlsIdentity()` creates a self-signed certificate locally with [Apple swift-certificates](https://github.com/apple/swift-certificates/tree/1.21.0), then combines it with the private key using [SecIdentityCreate](https://developer.apple.com/documentation/security/secidentitycreate(_:_:_:)). There is no handcrafted ASN.1 or upload of private keys. X509 1.21.0 and its transitive dependencies are pinned in the Xcode workspace's `Package.resolved`.

The certificate is a TLS key container with a generic subject; it includes no account ID, device ID, or name. Regenerating it does not change the registered key or require renewed consent. TLS 1.3 proves key possession; `NearbyPairing` then binds that key to the certified device, verifies signing-key challenges and the current permission, and checks consent before sending media. Discovery and transport use only Wi-Fi Aware. The Bonjour transport, synthetic-byte probe, and fixture-import screen have been removed.

## Verification

```sh
./tools/verify-identities.sh
./tools/verify-peers.sh
./tools/verify-signed-media.sh
./tools/verify-nearby-media.sh
```

The peer and signed-media checks create permissions using both ephemeral device signatures, then exercise the actual Swift cache against an isolated Go server. Coverage includes offline restart, refresh/removal races, fresh consent, cache isolation, failed writes, and persisted device revocation. Server tests cover permission isolation, limits, concurrent synchronization, revocation, and removed peer-code routes.

The nearby-media check compiles the production pairing/channel/transfer code with the app's pinned Apple packages. A test-only localhost listener exercises authenticated pairing, declined consent, wrong TLS identity, three recipients, reconnect, real media, live playback and delegated RustFS recovery. It has no Bonjour discovery or alternate shipping transport. These tests do not establish physical radio performance; actual device evidence and remaining checks are in [the pilot guide](nearby-pilot.md).

```sh
./tools/verify-identity-keychain.sh [booted-simulator-udid]
```

The additional Keychain check uses a disposable simulator app with its own bundle ID and access group. Two launches exercise persisted registration, account/environment isolation, storage attributes, and corrupt/missing keys. It cleans up its own credentials and app without replacing Nima or using a real account.
