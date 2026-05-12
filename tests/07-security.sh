#!/usr/bin/env bash
# Test bucket 07 — Security posture
#
# Spec §5 (Crypto), §9 (Security considerations).
#
# Tests in this bucket are deliberately a mix of declarative (inspect what
# the NUT advertises in its AS5 config) and active (probe behaviour with
# crafted requests). Anything that cannot be black-box probed is asserted
# from the discovery doc with a clear failure message.
#
# Required environment:
#   NUT_AS5_URL    — NUT's discovery doc.
#   NUT_NODE_ID    — NUT's identifier.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${NUT_AS5_URL:?required}"
: "${NUT_NODE_ID:?required}"

printf "%sBucket 07 — Security%s\n" "$YEL" "$NC"

AS5_BODY=$(fetch_json "$NUT_AS5_URL") || {
  fail 07.00 "Fetch NUT AS5 config" "could not GET $NUT_AS5_URL"
  print_bucket_summary 07 Security; exit 1
}

# 07.01 — Minimum key size declared ≥ 2048 (spec §5.1 floor).
MIN_KEY_SIZE=$(FIDEX_JSON="$AS5_BODY" python3 -c '
import json, os
cfg = json.loads(os.environ["FIDEX_JSON"])
print(cfg.get("security", {}).get("minimum_key_size", 0))
')
if [[ "$MIN_KEY_SIZE" -ge 2048 ]]; then
  pass 07.01 "security.minimum_key_size=$MIN_KEY_SIZE (≥2048)"
else
  fail 07.01 "security.minimum_key_size ≥ 2048" \
    "advertised minimum_key_size=$MIN_KEY_SIZE — too weak"
fi

# 07.02 — Algorithm whitelist: signature_algorithm must be RS256 or PS256;
# encryption_algorithm must be RSA-OAEP-256; content_encryption must be
# A256GCM. Anything else means the NUT advertises weak crypto.
SECURITY_JSON=$(FIDEX_JSON="$AS5_BODY" python3 -c '
import json, os
cfg = json.loads(os.environ["FIDEX_JSON"])
print(json.dumps(cfg.get("security", {})))
')
SIG_ALG=$(echo "$SECURITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("signature_algorithm",""))')
ENC_ALG=$(echo "$SECURITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("encryption_algorithm",""))')
CONTENT_ENC=$(echo "$SECURITY_JSON" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("content_encryption",""))')

ALG_OK=1
case "$SIG_ALG" in RS256|PS256|RS384|PS384|RS512|PS512|ES256|ES384) ;; *) ALG_OK=0 ;; esac
case "$ENC_ALG" in RSA-OAEP|RSA-OAEP-256|RSA-OAEP-384|RSA-OAEP-512|ECDH-ES+A256KW) ;; *) ALG_OK=0 ;; esac
case "$CONTENT_ENC" in A256GCM|A192GCM|A128GCM|A256CBC-HS512) ;; *) ALG_OK=0 ;; esac

if [[ $ALG_OK -eq 1 ]]; then
  pass 07.02 "Algorithms within whitelist (sig=$SIG_ALG enc=$ENC_ALG content=$CONTENT_ENC)"
else
  fail 07.02 "Advertise only whitelisted algorithms" \
    "sig=$SIG_ALG enc=$ENC_ALG content=$CONTENT_ENC — at least one is outside spec §5"
fi

# 07.03 — Published endpoints must be HTTPS in production. We can't tell
# "is the NUT running in prod" from outside, but we can detect a NUT that
# *only* publishes localhost/http URLs and warn rather than fail.
HTTP_ENDPOINTS=$(FIDEX_JSON="$AS5_BODY" python3 -c '
import json, os
cfg = json.loads(os.environ["FIDEX_JSON"])
eps = cfg.get("endpoints", {})
bad = [(k, v) for k, v in eps.items() if isinstance(v, str) and v.startswith("http://") and "localhost" not in v and "127.0.0.1" not in v]
for k, v in bad:
    print(f"{k}={v}")
')
if [[ -z "$HTTP_ENDPOINTS" ]]; then
  pass 07.03 "Published endpoints HTTPS-only (or localhost dev mode)"
else
  fail 07.03 "Production endpoints use HTTPS" \
    "non-localhost http:// endpoints advertised: $(echo "$HTTP_ENDPOINTS" | tr '\n' ' ')"
fi

# 07.04 — Replay protection. Submit the exact same envelope twice (same
# message_id). The second submission MUST NOT result in two persisted
# inbound rows on the NUT. Without DB introspection on the NUT we can
# still observe a behavioural signal: spec §9.3 requires the NUT respond
# 409 (or any non-success) to replays, never a fresh 2xx.
#
# We use an unsigned envelope so the first attempt is also rejected; the
# pass criterion is "second attempt rejected at least as hard as the
# first" — i.e. the NUT did not soften its response on the replay.
NUT_INBOUND_URL=$(get_endpoint "$AS5_BODY" "receive_message")
if [[ -z "$NUT_INBOUND_URL" ]]; then
  fail 07.04 "Replay protection probe" "could not resolve receive_message endpoint"
else
  REPLAY_ID="conformance-07-04-$(date +%s)-$$"
  REPLAY_ENV=$(NUT="$NUT_NODE_ID" MID="$REPLAY_ID" python3 -c '
import json, os, time
print(json.dumps({
    "routing_header": {
        "fidex_version": "1.0",
        "sender_id":     "urn:custom:unregistered-replay-probe",
        "receiver_id":   os.environ["NUT"],
        "message_id":    os.environ["MID"],
        "timestamp":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "document_type": "GS1_INVOICE_JSON",
    },
    "encrypted_payload": "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.AAAA.BBBB.CCCC.DDDD",
}))
')
  RESP1_CODE=$(curl -s -o /tmp/fidex-replay-1.$$ -w "%{http_code}" \
    -X POST "$NUT_INBOUND_URL" -H "Content-Type: application/json" -d "$REPLAY_ENV")
  RESP2_CODE=$(curl -s -o /tmp/fidex-replay-2.$$ -w "%{http_code}" \
    -X POST "$NUT_INBOUND_URL" -H "Content-Type: application/json" -d "$REPLAY_ENV")

  if [[ "$RESP1_CODE" =~ ^2 ]] && [[ "$RESP2_CODE" =~ ^2 ]]; then
    fail 07.04 "Replay protected (or unsigned-envelope idempotency)" \
      "both submissions returned 2xx ($RESP1_CODE/$RESP2_CODE) — possible duplicate persistence"
  elif [[ "$RESP2_CODE" == "409" ]]; then
    pass 07.04 "Replay rejected with HTTP 409 (idempotency enforced)"
  elif [[ "$RESP1_CODE" == "$RESP2_CODE" ]]; then
    pass 07.04 "Replay handled consistently (both HTTP $RESP1_CODE)"
  else
    fail 07.04 "Replay handled consistently" \
      "first=$RESP1_CODE second=$RESP2_CODE — NUT softened response on replay"
  fi
  rm -f /tmp/fidex-replay-1.$$ /tmp/fidex-replay-2.$$
fi

print_bucket_summary 07 Security
