# Nearby feasibility probes

This is the first implementation slice of [the nearby sharing plan](nearby-sharing-plan.md), on `codex/nearby-feasibility`. It provides repeatable transport and storage checks before connecting nearby delivery to camera media. Milestone 0 is still open: physical offline networking and production Tigris behavior have not been validated.

## Implemented

- A Debug-only screen at **Profile → Development → Nearby transport probe**. One sender connects to one receiver using Bonjour, `Network.framework`, `includePeerToPeer`, TLS 1.3, and exact certificate pins in both directions.
- Disposable, distinct test identities. Both peers prove possession of their own private key; the sender rejects the wrong receiver and the receiver rejects an unapproved sender. This is test provisioning, not production device enrollment or approval.
- Registered identities and directional approval are also available through **Nearby setup**, with an offline cache and public-key pins. See [device identities and consent](nearby-identities.md) for the code exchange and registered connection test. The original fixture mode remains useful for adversarial transport tests.
- A synthetic 256 KiB transfer in 64 KiB blocks with a SHA-256 receipt. The receiver hashes in memory; the receipt does **not** mean the data was saved to disk. There is no camera media, cloud upload, playback, or multi-recipient scheduling in this probe.
- An opt-in object-storage probe for signed SHA-256 enforcement before commit, checksum tampering, concurrent conditional writes, and recovery after a lost response.

The probe suspends the camera preview while its screen is open and stops nearby networking when the app becomes inactive or the screen closes. Production capture and upload code is unchanged. The screen, transport code, and Bonjour declaration are excluded from Release builds.

## Verified locally on 2026-09-24

| Check | Result | What it establishes |
| --- | --- | --- |
| `./tools/verify-nearby.sh` | Passed | Approved peers exchange and verify bytes over loopback; each side rejects the wrong certificate using the app's transport implementation |
| `./tools/verify-relay-storage.sh` against local RustFS | Passed | Corrupt bytes fail with `BadDigest` without occupying the key; altered/omitted checksum is rejected; eight competing writes have exactly one winner; duplicate retry reconciles to the winner's bytes |
| `./tools/verify-local.sh` | Passed | Existing encoder, persisted queue, live upload, recovered media decoding, and backend race checks still pass |
| Debug simulator and unsigned Release device builds | Passed | Both configurations compile with Swift 6 |
| Two physical iPhones without internet or a shared network | Pending | Loopback does not exercise Bonjour permission, discovery, or peer-to-peer radio behavior |
| Actual production Tigris configuration | Pending | RustFS results do not establish another provider's integrity or concurrency behavior |

Only one physical iPhone was connected during this work. No throughput, thermal, latency, multiple-recipient, or production-storage claim follows from these results.

## Run the transport check

On a Mac with macOS 15+, Xcode, OpenSSL 3, and Python 3:

```sh
./tools/verify-nearby.sh
```

The script generates temporary identities, compiles the same `NearbyProbe.swift` used by the app, runs the three loopback cases, and removes its fixture files. A generic connection error or timeout does not count as a successful rejection test: the code must explicitly reject the certificate.

The test identities are imported into memory. The fixture's encrypted PKCS#12 container uses algorithms compatible with Apple's importer; the network connection uses TLS 1.3. Fixtures contain private keys and their import passwords together, so treat them as disposable test credentials. The probe checks an exact preapproved certificate pin; it is not a general certificate enrollment, expiry, or revocation implementation.

## Run the physical offline check

1. Generate a fresh fixture directory, using the same generation for both phones:

   ```sh
   mkdir -p .build
   ./tools/make-nearby-fixtures.sh .build/nearby-identities
   ```

   The destination must not already exist. `*.nearby.json` files are gitignored and are never bundled into the app.

2. Install a signed Debug build on two already-enrolled iPhones. Copy only `a.nearby.json` to sender A and `b.nearby.json` to receiver B through a trusted development transfer. Open the probe screen and import each phone's fixture from Files. Allow local-network access when prompted.
3. First verify the setup on the same Wi-Fi network: tap **Listen** on B, then **Find receiver and send** on A. A should report **Receiver verified 256 KiB (memory only)**. B should report **Received and hashed 256 KiB (memory only)**. This control checks the fixtures and permissions; it does not prove router-free transfer.
4. Disable cellular data, leave Wi-Fi enabled, disconnect both phones from access points, and turn off Personal Hotspot. Keep both apps open and repeat. Record device models, OS versions, network conditions, and the status shown on each phone. If discovery or transfer fails, milestone 0 remains open; do not infer radio support from the loopback or shared-LAN control.
5. Repeat with `unapproved-client.nearby.json` on A and the normal B fixture: B must reject A. Repeat with `wrong-server.nearby.json` on A and the normal B fixture: A must reject B. Tap **Listen** again before each attempt. The rejecting side should show **Peer identity not approved**; neither attempt may report a successful transfer.
6. Restore the approved fixtures. Repeat after Stop, denied/re-enabled local-network permission, and leaving/reopening the screen. Background or lock either phone during discovery or authentication and verify that the probe stops. The 256 KiB transfer may finish too quickly to interrupt reliably; mid-transfer recovery needs the later media stress test.

Only run one probe receiver at a time. Discovery currently attempts the first advertised service, authenticates it, then stops on rejection; there is no recipient picker or retry across other services. Delete the fixtures from both phones and the Mac after testing.

## Run the storage check

With the local RustFS bucket initialized:

```sh
./tools/verify-relay-storage.sh
```

For Tigris, pass an explicit absolute path to a private shell environment file containing the intended provider's configuration, using the variables supported by `server/storage.go`:

```sh
./tools/verify-relay-storage.sh /absolute/path/to/tigris-probe.env
```

Use a fresh shell without unrelated `S3_*` overrides and specify every applicable endpoint, bucket, region, and path-style setting. The script defaults to `server/.env`; passing another file does not also load the local file. Never put storage credentials or signed URLs in the evidence report.

The probe creates random `nearby-probe/` keys, transfers synthetic bytes only, and deletes those keys on normal completion, including test failures. A killed process can leave probe objects; use the random key prefix to identify those objects before cleaning them up. It does not touch capture rows or existing media. The configured identity needs Put/Get/Delete permissions on the probe prefix. In a versioned bucket, follow the bucket's lifecycle policy for deleted versions.

SHA-256 checks deliberately omit `Content-MD5` so MD5 validation cannot disguise a missing SHA-256 guarantee. Eight different authorized payloads race for one key to detect overwrites; a second identical upload must receive `412`, after which the server's existing byte verifier must confirm the stored object. This tests storage behavior, not future grant validation, canonical reservations, or quota accounting.

## Remaining milestone 0 decisions

- Record successful two-phone offline authentication and transfer, including rejection in both directions.
- Run the storage probe on the actual Tigris configuration. Choose direct checksum-bound uploads only after both providers pass. Otherwise implement the plan's bounded Go verification path before permitting relay writes.
- Validate the registered-key connection test on physical phones as well as the disposable fixture test. Key generation, enrollment, and cached consent are implemented; imported fixtures are not a shipping dependency.

Device identity, signed media records, durable nearby copies, delegated upload workers, three-recipient transport and live viewing are now implemented and tested together on native loopback/RustFS. The physical-radio and Tigris decisions above remain open. See [pilot setup and evidence](nearby-pilot.md).
