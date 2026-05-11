# FideX 1.0 Conformance Specification

This document defines what tests an implementation must pass to be declared
**FideX 1.0 Compliant**. Each test cites the section of
`fidex-protocol-specification.md` that it verifies.

## Profiles

| Profile    | Required test buckets | Optional        |
| ---------- | --------------------- | --------------- |
| `core`     | 01, 02, 03, 04        | —               |
| `enhanced` | core + 05, 06         | 07              |
| `edge`     | core + 05, 06, 07     | —               |

A run passes a profile only when every required bucket in that profile
returns exit code 0.

---

## Test bucket 01 — Discovery

**Spec §6.2 (AS5 Configuration Endpoint), §5.1 (JWKS).**

- `01.01` AS5 config document is reachable and returns valid JSON.
- `01.02` All required top-level fields present: `fidex_version`,
  `supported_versions` (non-empty array), `node_id`, `organization_name`,
  `public_domain`, `endpoints`, `security`.
- `01.03` `endpoints` object has `receive_message`, `receive_receipt`,
  `register`, `jwks` — each an absolute URL.
- `01.04` `security` object declares `signature_algorithm`,
  `encryption_algorithm`, `content_encryption`, `minimum_key_size`.
- `01.05` `endpoints.jwks` GET returns a valid JWKS with at least one
  RSA key whose `use="enc"` and whose modulus is real (≥ 2048-bit
  equivalent, not a placeholder).
- `01.06` `endpoints.jwks` includes a key whose `use="sig"` (may be the
  same RSA key — single dual-purpose key is permitted by spec).

## Test bucket 02 — Registration

**Spec §6.3–6.5 (Partner registration handshake).**

- `02.01` NUT can be added as a partner by the reference peer, given only
  the NUT's AS5 config URL. The peer's partner row must persist with the
  NUT's `node_id` as `partner_id` and the JWKS cached.
- `02.02` NUT can add the reference peer as a partner, given only the
  peer's AS5 config URL. The NUT's partner row must persist with the
  peer's published `message_endpoint`, `receive_receipt`, and JWKS.

## Test bucket 03 — Transmit (outbound encryption)

**Spec §4 (Envelope), §5 (Crypto).**

- `03.01` NUT accepts a `POST /api/v1/transmit` (or equivalent internal
  endpoint) carrying `{destination_partner_id, document_type, payload}`.
- `03.02` NUT signs the business document with its own private key and
  encrypts the resulting JWS to the partner's encryption public key,
  producing a compact JWE.
- `03.03` NUT wraps the JWE in a spec §4 envelope (`routing_header` +
  `encrypted_payload`) and POSTs it to the partner's `receive_message`
  URL.
- `03.04` The receiving peer responds 2xx and persists the inbound message.

## Test bucket 04 — Receive (inbound decryption)

**Spec §4, §5.**

- `04.01` NUT's `receive_message` endpoint accepts a spec-shaped envelope
  whose `receiver_id` matches the NUT.
- `04.02` NUT decrypts the JWE with its private key.
- `04.03` NUT verifies the JWS signature with the sender's signing key
  fetched from the cached JWKS.
- `04.04` NUT persists the decrypted business document with status
  `DELIVERED`. Envelopes failing decryption/verification are stored with
  status `QUARANTINED` (not silently dropped, not 5xx'd).

## Test bucket 05 — Receipts (J-MDN) [planned]

**Spec §7 (Message disposition notifications).**

- `05.01` On successful decrypt, NUT generates a signed J-MDN receipt
  containing `original_message_id`, `status="processed"`, `timestamp`,
  and a `hash_verification` over the original encrypted payload.
- `05.02` NUT POSTs the receipt to the original sender's
  `receive_receipt` URL.
- `05.03` Sender validates the receipt signature and updates the
  outbound message status to DELIVERED.

## Test bucket 06 — Error handling [planned]

**Spec §8 (Error semantics).**

- `06.01` Malformed envelope → HTTP 400 with `error_code=VALIDATION_ERROR`.
- `06.02` Unknown sender → HTTP 401 with `error_code=UNKNOWN_PARTNER`.
- `06.03` Duplicate `message_id` → HTTP 409 (idempotency).
- `06.04` JWS signature mismatch → HTTP 401 with
  `error_code=SIGNATURE_INVALID`.

## Test bucket 07 — Security [planned]

**Spec §5 (Crypto), §9 (Security considerations).**

- `07.01` NUT rejects keys smaller than `security.minimum_key_size`.
- `07.02` NUT rejects algorithms outside `signature_algorithm` /
  `encryption_algorithm` whitelist.
- `07.03` NUT refuses non-HTTPS peer URLs in production mode (with a
  documented escape hatch for dev/test).
- `07.04` Replay protection: NUT rejects an envelope whose `message_id`
  has been seen within the configured window.

---

## Reporting

The runner emits two artifacts after a complete run:

### `conformance-report.json`

```json
{
  "schema": "fidex-conformance/v1",
  "run_id": "2026-05-11T20:45:00Z",
  "implementation": {
    "name": "FideXNode",
    "version": "git:8f92b07",
    "url": "http://localhost:18443/.well-known/as5-configuration"
  },
  "spec_version": "1.0",
  "profile": "core",
  "buckets": [
    {
      "id": "01",
      "name": "Discovery",
      "tests": [
        {"id": "01.01", "result": "PASS", "spec_ref": "§6.2"},
        ...
      ],
      "passed": 6, "failed": 0
    },
    ...
  ],
  "verdict": "PASS",
  "compliance_level": "core"
}
```

### `badge.svg`

A small Shields.io-style badge:

```
[ FideX 1.0 ] [ core ✓ ]
```

Coloured green on full pass, amber on partial, red on fail. Implementations
embed it in their README to advertise their conformance level.
