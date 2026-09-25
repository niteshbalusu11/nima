# Wi-Fi Aware migration

## Outcome

Keep Nima's existing bundle identity, capture pipeline and delegated cloud recovery. Replace manual contact/invitation exchange with **Share nearby** and **Join nearby**, Apple's device picker/PIN pairing, and one explicit save-and-backup consent. One recorder serves up to three recipients independently. No multi-hop forwarding.

Camera/cloud upload keep their existing OS support; Nearby requires iOS 26+ and a positive `WACapabilities` check. Unsupported devices receive a concise explanation. The existing ngrok/RustFS pilot remains the test backend. First account enrollment and initial device credential issuance require connectivity. Two enrolled phones with valid cached credentials can establish a new sharing permission offline.

## Implementation and verification

1. **Native discovery and transport.** Declare Wi-Fi Aware publish/subscribe capabilities, use DeviceDiscoveryUI for pairing, and TCP over Wi-Fi Aware for bounded reliable fragments. Use the SDK's listener/browser providers with the existing Network byte channel. Reconnect only to the selected system-paired device. Verify Debug/Release builds and development provisioning with the existing app identifier; confirm physical radio behavior separately.
2. **Offline identity and consent.** Issue a 30-day, server-signed device credential over the authenticated HTTPS session. Cache the server verification key from that response, never from a peer. Exchange credentials and fresh challenges on the encrypted paired connection, verify possession of registered signing keys, and have both devices sign the same directional permission. No session token or storage credential goes to a peer. Persist consent before media is accepted. Verify forged/expired credentials, wrong server, swapped identities, replayed challenges, declined consent and revocation.
3. **Deferred server authorization.** Either participant can synchronize the jointly signed permission after reconnecting. The backend checks both registered keys and active account/device state, enforces bounded peer counts, and never restores a revoked permission ID. Synchronize before delegated uploads; retain pending permissions across offline restarts and authoritative refreshes. Verify races, idempotence, conflicting IDs, forged signatures and revoke-before-first-sync.
4. **Media integration and UX.** Share opens the native advertiser; Join opens the native picker and starts receiving after consent. Exchange authorization internally, then reuse original fragments, durable receipts, live playback, bounded queues, storage budgets, and recorder-owned cloud upload. Preserve separate control over each recipient. Pause on background/logout; resume only explicitly selected sharing, and require Join again for receiving. Remove manual-code controls from the user flow. Verify actual native encoder/receiver/cloud recovery and no capture regression.
5. **Pilot.** Update PR #7 and its setup instructions. Build/install over `com.prodata.uploadvideo`, preserving app data. Restart only the local pilot backend when its migration is ready. Exercise two nearby iPhones with no internet/access point, then restore only the recipient's internet and verify recorder ownership. Test three recipients, interruption/reconnect, rejected permission and live playback before Stop. Do not infer physical radio performance from loopback tests.

## Protocol limits and security

- Wi-Fi Aware supplies authenticated/encrypted radio pairing. App credentials and challenge signatures establish invite-only account identity separately.
- Device credentials expire after 30 days and refresh while online. Offline devices cannot learn server-side revocations instantly; local removals apply immediately, and the server checks current revocation before any upload authorization.
- Directional permissions bind both registered devices/keys, a random permission ID, the backend authority and creation time. Replay of a revoked permission cannot recreate it; both signatures are required for a new ID.
- Existing saved fragments and accounts are preserved. Schema changes are additive. Existing code-based approvals remain readable for stored media, but new pairing uses the native flow.
- Runtime/capability checks and clear errors are required. Wi-Fi Aware does not grant unlimited background execution. No automatic internet relay, mesh routing or background recording is added.

## Primary references

- [Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware): hardware/runtime capabilities, offline and simultaneous connections.
- [Apple sample](https://developer.apple.com/documentation/wifiaware/building-peer-to-peer-apps): pairing, services and connection setup.
- [Adopting Wi-Fi Aware](https://developer.apple.com/documentation/wifiaware/adopting-wi-fi-aware): entitlements and service declarations.
- [DeviceDiscoveryUI](https://developer.apple.com/documentation/devicediscoveryui): native advertiser and device picker.

Implementation status and actual verification evidence will be recorded in `docs/nearby-pilot.md`.
