# FideX Conformance Suite

A self-service interoperability and conformance test suite for the **FideX
AS5 protocol** (see `FideX-protocol/fidex-protocol-specification.md`).

The suite is modelled after the [Drummond Group](https://www.drummondgroup.com/)
interoperability certification programs used in AS2/AS4/ebMS — adapted for an
open, vendor-neutral OSS workflow.

> **Status:** Phase 1 (beta). All three conformance profiles are
> implemented: `core` (discovery + registration + transmit + receive),
> `enhanced` (+ J-MDN receipts + error semantics), `edge` (+ active
> security probes). Reference verdict: FideXNode (Go) `master` certified
> at `core` (17/17); gaps for `enhanced`/`edge` documented in its
> CONFORMANCE.md.

## What "FideX Conformant" means

An implementation passes the suite when every required test in
`conformance-spec.md` returns OK against a known-good reference node.
Implementations get back a single artifact:

- `results/conformance-report.html` — human-readable per-test outcome.
- `results/conformance-report.json` — machine-parseable result blob (for
  CI gating and badging).
- `results/badge.svg` — embeddable "FideX 1.0 Compliant" badge.

## Quick start

```bash
# Run the full edge profile against your local node under test.
./runner.sh \
    --node-name      "MyImpl 1.0" \
    --node-as5-url   http://your-node:port/.well-known/as5-configuration \
    --node-id        urn:custom:your-node \
    --node-transmit-url      http://your-node:port/api/v1/transmit \
    --node-transmit-api-key  your-internal-key \
    --node-discover-url      http://your-node:port/admin/dashboard/partners/discover \
    --node-discover-api-key  your-internal-key \
    --node-db-path   /path/to/your-node.sqlite \
    --profile        edge       # or 'core' / 'enhanced'

# Outputs:
#   results/conformance-report.json   — full per-bucket verdict
#   results/badge.svg                 — embeddable "FideX 1.0 Compliant" badge
```

The runner auto-boots the bundled FideX-php reference peer on
`localhost:18081`; set `PEER_REPO=/path/to/FideX-php` if your checkout
lives elsewhere. Override `PEER_PORT` if 18081 is taken.

The reference peer is the canonical
[FideX-php](https://github.com/GreicodexJM/fidex-protocol) node. Vendors who
do not run a PHP toolchain can use the Docker image bundled here.

## Repo layout

```
FideX-conformance/
├── README.md
├── LICENSE                       # MIT — wide adoption
├── conformance-spec.md           # what each test verifies + spec section refs
├── runner.sh                     # one-shot orchestrator + report generator
├── reference-node/
│   └── docker-compose.yml        # bundled FideX-php reference peer
├── tests/
│   ├── 01-discovery.sh           # /.well-known/as5-configuration + JWKS shape
│   ├── 02-registration.sh        # both directions of partner onboarding
│   ├── 03-transmit.sh            # outbound JWE delivery (NUT → peer)
│   ├── 04-receive.sh             # inbound JWE decryption (peer → NUT)
│   ├── 05-receipts.sh            # signed J-MDN round-trip (spec §7)
│   ├── 06-errors.sh              # malformed/unknown/replay/tampered (§8)
│   ├── 07-security.sh            # min-key-size, alg whitelist, HTTPS, replay (§5/§9)
│   └── lib/
│       └── assertions.sh         # check_as5_config, check_jwks_enc, …
├── report-templates/
│   ├── report.html.tmpl
│   └── badge.svg.tmpl
├── results/                      # gitignored runtime artifacts
└── examples/                     # sample valid + invalid payloads
```

## How the suite talks to a node

Two endpoints per node-under-test (NUT):

- **Discovery URL** — the NUT's AS5 configuration document, used to learn
  its real public-facing receive/receipt/jwks endpoints (spec §6.2 — paths
  are implementation-defined).
- **Transmit URL + API key** — the NUT's internal "queue this for delivery"
  endpoint, used by tests 03/05 to push outbound messages.

The reference peer plays both roles symmetrically (peer of the NUT, AND the
side that receives encrypted envelopes the NUT sent).

## Conformance levels

Following the spec's §6.2 `conformance_profile`:

| Profile  | Required tests              | Use case                          |
| -------- | --------------------------- | --------------------------------- |
| `core`   | 01–04                       | Minimum interop, B2B receive-only |
| `enhanced` | 01–06                     | Bidirectional + receipts          |
| `edge`   | 01–07                       | Production-ready, full security   |

The badge encodes which profile passed.

## Contributing

Every test must:

1. Be self-contained — bash + python3 + curl + sqlite3 only, no Go/PHP/JS toolchain.
2. Read its NUT config from environment variables exported by `runner.sh`.
3. Emit either `PASS: <description>` or `FAIL: <description> — <reason>`
   on stdout. Exit `0` for pass, `1` for fail.
4. Cite the spec section it covers in a comment block at the top.

See `tests/01-discovery.sh` for the canonical template.

## License

MIT — see `LICENSE`. Pull requests welcome.
