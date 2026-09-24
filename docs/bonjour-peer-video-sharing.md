# Preapproved nearby video recipients

## Goal

Let an enrolled user approve other enrolled iPhones as video recipients before the phones have ever met. When recording starts, the app sends completed video fragments to approved receivers that are nearby and available, while keeping its existing cloud upload independent. The nearby transfer works without internet, cellular service, a router, or a shared Wi-Fi network.

This proposal uses **Apple peer-to-peer Wi-Fi with Bonjour and Network.framework**, rather than Wi-Fi Aware. Wi-Fi Aware's system pairing requires a nearby first encounter and a PIN. Apple peer-to-peer Wi-Fi can discover a Bonjour service without that pairing step; our app must authenticate peers itself. It works between Apple devices, and the current iOS 17 deployment target can remain unchanged. This is direct one-hop sharing, not mesh forwarding.

## Assumptions and limits

- Each phone has this invite-only app installed and enrolled through the existing Go API.
- Both phones have Wi-Fi enabled and are physically close enough for a peer-to-peer link. They do not need internet during discovery or transfer.
- The receiving app must be running and listening when the sender looks for it. Pairing or prior approval cannot guarantee delivery to an app that is closed, suspended, or out of range. Foreground receive mode is the first supported behavior; background behavior requires separate device validation.
- iOS Local Network access must have been granted on both phones. Ask for it during setup, not at the start of an urgent recording.
- Only completed fragments are transmitted. A receiver may miss the current unfinished fragment if capture is interrupted.
- A remotely revoked approval cannot reach an offline phone until its next sync. Each phone can block a peer locally immediately.

## Setup ahead of time

1. **Create device identity.** Each installation generates a unique device ID and a TLS identity (private key and certificate). Keep the private key in that phone's Keychain. Register the device's public identity with the existing authenticated Go API. A replacement phone gets a new device identity.
2. **Invite.** The sender creates a single-use, expiring recipient invitation with the API and shares its link/code through any channel. The invitation identifies the sender device and the intended permission: receive and save video from this sender. It contains no Wi-Fi password, IP address, or static Bonjour address.
3. **Accept.** An enrolled recipient opens the invitation and explicitly enables automatic receiving from that sender. The server records the approval and returns each device's authenticated public identity to the other. The sender marks that recipient as selected for automatic local delivery. An invitation alone does not authorize delivery until the recipient accepts.
4. **Cache locally.** Both apps store the approved device IDs and public-key fingerprints so later nearby connections can be authenticated offline. The UI lets either side disable a relationship; the app syncs additions/revocations when internet is available.

The invitation exchange relies on the server's existing authenticated sessions to bind public keys to enrolled devices. Do not treat a user-provided nickname, Bonjour name, or TXT record as proof of identity. If invitations are transported outside the app, the server still validates single use, expiry, sender, recipient acceptance, and revocation.

## Nearby discovery and authentication

1. A receiver with auto-receive enabled advertises a fixed app-specific Bonjour service and starts a `NWListener` with peer-to-peer Wi-Fi enabled.
2. At recording start, the sender starts an `NWBrowser` for that service, also with peer-to-peer Wi-Fi enabled. It discovers nearby services without internet or a shared access point.
3. For each discovered endpoint, the sender opens a TLS connection. Both sides verify that the remote certificate/public key matches a locally approved device and that the allowed role is correct. Unknown or revoked devices are rejected before any media is sent.
4. The sender maintains one connection per approved, reachable receiver and stops browsing when discovery is no longer useful. It may retry discovery during an active recording so a receiver that arrives later can join. Only actual TLS authentication can establish identity; do not put a stable device ID or public key in the Bonjour service name or TXT record.

Implementation uses the existing `NWBrowser`/`NWListener`/`NWConnection` APIs available at the app's deployment target, with `includePeerToPeer` on browser, listener, and connection parameters. Set `NSLocalNetworkUsageDescription` and declare the service in `NSBonjourServices`. The app must provision and validate its own TLS identities; Network.framework provides the transport, not the recipient approval policy.

## Video delivery and storage

- Reuse the current `SegmentWriter` output: an initialization fragment followed by numbered, roughly one-second H.264/AAC fMP4 media fragments. `Camera` already puts those bytes and metadata into `UploadQueue` before cloud upload.
- Add a separate local-delivery worker that reads persisted fragment bytes. It must not delay camera callbacks or alter the existing cloud worker. Cloud acknowledgement and each receiver's acknowledgement are independent.
- Send a capture ID, fragment sequence/type, byte length, SHA-256 digest, and segment timing with each fragment. Send initialization data before media. The receiver writes each fragment atomically, verifies its digest, then acknowledges `(capture ID, sequence)`.
- Keep bounded per-recipient state so a slow or disconnected receiver cannot block capture, other receivers, or cloud upload. Retry unacknowledged fragments while their local bytes remain available. A late receiver can receive retained fragments from the start of the capture before catching up; if retention or bandwidth prevents this, show it as incomplete rather than claiming a full copy.
- Save received media in the app's protected storage as fragments plus a manifest so the completed prefix remains recoverable after a disconnect. Provide a simple way to view/export a received capture. Adding a finished video to Photos is optional and requires its own permission flow.
- Respect the app's current 256 MiB local media cap and disk-space floor. Define retention and cleanup before promising long offline backfill or unlimited recipients. Show per-recipient states such as connected, receiving, incomplete, and unavailable; never show “saved” before the receiver acknowledges durable storage.

## Security and privacy

- Use authenticated TLS for every local media connection, with peer identities checked against the preapproved list. Do not use a shared certificate embedded in every app installation or disable certificate validation.
- Store private keys only on their own devices. Send only public keys/certificates through the invitation service. Rotate/re-enroll after a device replacement; revocation updates the server and cached allowlists when online.
- Bonjour advertisements disclose only the app service, not a permanent user/device ID, email, or invite token. Untrusted nearby apps may see the service and attempt connections, so reject them during authentication and bound connection attempts.
- Link encryption protects bytes in transit. This proposal does not claim end-to-end encryption of the cloud copy or new encryption at rest for received files; those are separate decisions from the current pilot.

## Delivery semantics and product behavior

- **Best effort while nearby:** each selected receiver gets its own stream and independently saved copy. Radio throughput is shared across receivers; measure delay and queue growth with two or more recipients.
- **Offline at capture time:** previously synced approvals and public keys are sufficient. The setup invitation needs a communication channel, but recording does not need cloud availability.
- **Unavailable receiver:** recording and cloud upload continue. The UI reports that no local copy reached that peer. The app may retry retained fragments when that peer reconnects, subject to local storage limits.
- **Foreground-first:** do not promise unattended receiving on a sleeping or force-quit iPhone. A future background mode requires proof on physical devices and an explicit product decision.

## First milestone and acceptance checks

1. Two iPhones accept an invitation while apart; neither has been locally paired. They later discover each other with Wi-Fi enabled and no internet or shared Wi-Fi network, authenticate, and transfer a test payload.
2. While one phone records, a previously approved receiver saves playable video/audio fragments before the sender taps Stop. The existing cloud upload still works.
3. An unapproved or revoked phone sees no media. A receiver that declines the invitation does not receive anything.
4. With three phones, the sender transfers the same recording to two approved receivers and reports each receiver's own acknowledgement/status.
5. Interrupt the link and the sender. Already acknowledged fragments remain recoverable on the receiver; the sender reports any missing portion accurately.
6. Test Local Network denial, receiving app unavailable, low storage, and a receiver entering range mid-recording on physical iPhones.

## Sources

- [Apple: iOS Wi-Fi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview) — Apple peer-to-peer Wi-Fi needs no configured network and works between Apple devices.
- [Apple: Choosing the right networking API](https://developer.apple.com/documentation/technotes/tn3151-choosing-the-right-networking-api) — Bonjour discovery and Network.framework peer-to-peer Wi-Fi.
- [Apple: Building a custom peer-to-peer protocol](https://developer.apple.com/documentation/network/building-a-custom-peer-to-peer-protocol) — iOS Bonjour and TLS sample.
- [Apple: Moving from Multipeer Connectivity to Network framework](https://developer.apple.com/documentation/technotes/tn3213-moving-from-multipeer-connectivity-to-network-framework) — identity, TLS, peer-to-peer configuration, and Bonjour privacy.
- [Apple: Understanding local network privacy](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy) — Local Network permission and Bonjour service declaration.
