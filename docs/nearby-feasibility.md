# Nearby feasibility checks

The original Bonjour and synthetic-byte experiments have been retired. The app now uses Wi-Fi Aware with certified device identities, explicit recipient consent, durable fragments and delegated cloud recovery. Current setup and physical-device results are in [the pilot guide](nearby-pilot.md); protocol details are in [device identities and consent](nearby-identities.md).

## Transport checks

Run `./tools/verify-nearby-media.sh` on a Mac with Xcode and the local RustFS environment. It builds the production pairing and media protocol, exercises three recipients over localhost, and checks live video/photo delivery and cloud recovery. Test identities are ephemeral; no fixture imports or alternate transport are bundled into Nima.

For physical radio validation, follow the offline and reconnect checks in the pilot guide. Leave Wi-Fi enabled while disconnecting from access points and cellular data. Loopback success alone does not establish router-free discovery, throughput, thermal behavior, or hardware compatibility.

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

## Remaining storage validation

Run the storage check against the actual production Tigris configuration before relying on provider-specific checksum and conditional-write behavior. RustFS results do not establish another provider's integrity or concurrency guarantees.
