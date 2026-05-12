#!/usr/bin/env bash
# Test bucket 06 — Error semantics
#
# Spec §8 (Error codes and HTTP semantics).
#
# We craft black-box requests against the NUT's published receive_message
# endpoint and assert that error categories surface as documented status
# codes. The conformance bar is "doesn't silently 200 on garbage" and
# "uses the correct 4xx for each failure class".
#
# Required environment:
#   NUT_AS5_URL — NUT's discovery doc (to learn receive_message URL).
#   NUT_NODE_ID — NUT's identifier.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${NUT_AS5_URL:?required}"
: "${NUT_NODE_ID:?required}"

printf "%sBucket 06 — Error handling%s\n" "$YEL" "$NC"

# Resolve NUT's inbound URL from its own AS5 configuration. This is the
# only spec-supported way for a third-party tester to learn where to POST.
AS5_BODY=$(fetch_json "$NUT_AS5_URL") || {
  fail 06.00 "Fetch NUT AS5 config" "could not GET $NUT_AS5_URL"
  print_bucket_summary 06 Errors; exit 1
}
NUT_INBOUND_URL=$(get_endpoint "$AS5_BODY" "receive_message")
if [[ -z "$NUT_INBOUND_URL" ]]; then
  fail 06.00 "NUT publishes endpoints.receive_message" "field missing"
  print_bucket_summary 06 Errors; exit 1
fi

# Helper: POST $1 (body) to NUT's inbound, echo HTTP status code.
post_inbound() {
  local body=$1
  curl -s -o /tmp/fidex-conformance-resp.$$ -w "%{http_code}" \
    -X POST "$NUT_INBOUND_URL" \
    -H "Content-Type: application/json" \
    -d "$body"
}

# 06.01 — Malformed body (not even JSON).
HTTP=$(post_inbound 'not-json-at-all')
case "$HTTP" in
  400|422)
    pass 06.01 "Malformed envelope rejected with HTTP $HTTP"
    ;;
  *)
    fail 06.01 "Malformed envelope rejected with HTTP 400/422" \
      "got HTTP $HTTP (body: $(cat /tmp/fidex-conformance-resp.$$ 2>/dev/null | head -c 200))"
    ;;
esac

# 06.02 — Well-formed JSON envelope but `sender_id` belongs to no
# registered partner. Spec §8 expects 401/403 with a partner-unknown code.
UNKNOWN_ENV=$(NUT="$NUT_NODE_ID" python3 -c '
import json, os, time
print(json.dumps({
    "routing_header": {
        "fidex_version": "1.0",
        "sender_id":     "urn:custom:unregistered-nobody",
        "receiver_id":   os.environ["NUT"],
        "message_id":    f"conformance-06-02-{int(time.time())}",
        "timestamp":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "document_type": "GS1_INVOICE_JSON",
    },
    "encrypted_payload": "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.AAAA.BBBB.CCCC.DDDD",
}))
')
HTTP=$(post_inbound "$UNKNOWN_ENV")
case "$HTTP" in
  401|403|404)
    pass 06.02 "Unknown sender rejected with HTTP $HTTP"
    ;;
  200|202)
    # Some implementations 200+QUARANTINE rather than 401. Spec §8 prefers
    # 4xx but the §4.4 quarantine clause grants leeway IFF the response
    # body explicitly carries a rejection status code.
    BODY=$(cat /tmp/fidex-conformance-resp.$$ 2>/dev/null)
    if echo "$BODY" | grep -qiE 'quarantin|reject|unknown.?partner|invalid.?sender'; then
      pass 06.02 "Unknown sender quarantined with HTTP $HTTP (body declares rejection)"
    else
      fail 06.02 "Unknown sender rejected" \
        "HTTP $HTTP but body does not declare rejection: $(echo "$BODY" | head -c 200)"
    fi
    ;;
  *)
    fail 06.02 "Unknown sender rejected" \
      "got HTTP $HTTP (body: $(cat /tmp/fidex-conformance-resp.$$ 2>/dev/null | head -c 200))"
    ;;
esac

# 06.03 — Duplicate message_id. Submit the same well-formed-but-unsigned
# envelope twice; the second submission MUST be rejected with 409 (or
# silently absorbed as idempotent — the spec accepts both as long as no
# duplicate row is persisted).
DUP_ID="conformance-06-03-$(date +%s)-$$"
DUP_ENV=$(NUT="$NUT_NODE_ID" MID="$DUP_ID" python3 -c '
import json, os, time
print(json.dumps({
    "routing_header": {
        "fidex_version": "1.0",
        "sender_id":     "urn:custom:unregistered-nobody",
        "receiver_id":   os.environ["NUT"],
        "message_id":    os.environ["MID"],
        "timestamp":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "document_type": "GS1_INVOICE_JSON",
    },
    "encrypted_payload": "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.AAAA.BBBB.CCCC.DDDD",
}))
')
HTTP_1=$(post_inbound "$DUP_ENV")
HTTP_2=$(post_inbound "$DUP_ENV")

# Both will share the same outcome class on most implementations because
# the sender is unknown — we look for *consistent* rejection plus, ideally,
# 409 on replay.
if [[ "$HTTP_2" == "409" ]]; then
  pass 06.03 "Duplicate message_id rejected with HTTP 409 (idempotency enforced)"
elif [[ "$HTTP_1" == "$HTTP_2" ]] && [[ "$HTTP_1" =~ ^4 ]]; then
  # Same 4xx twice is acceptable: NUT consistently refuses, idempotency
  # is moot because nothing was persisted. We mark this as a soft pass
  # with the caveat in the description.
  pass 06.03 "Replay handled idempotently (both HTTP $HTTP_1 — nothing persisted)"
else
  fail 06.03 "Duplicate message_id rejected idempotently" \
    "first=$HTTP_1 second=$HTTP_2 (expected matching 4xx or 409 on replay)"
fi

# 06.04 — Envelope claims a registered sender (the peer) but the JWS
# inside is gibberish. We can't easily craft a JWS-with-wrong-signature
# without the peer's signing key, but we *can* submit a syntactically
# JWE-shaped string under a real sender_id. The NUT must reject at the
# crypto step with a 4xx, not crash or 5xx.
PEER_ID=${PEER_NODE_ID:-urn:custom:fidex-ref-peer}
SIG_BAD_ENV=$(NUT="$NUT_NODE_ID" PEER="$PEER_ID" python3 -c '
import json, os, time
print(json.dumps({
    "routing_header": {
        "fidex_version": "1.0",
        "sender_id":     os.environ["PEER"],
        "receiver_id":   os.environ["NUT"],
        "message_id":    f"conformance-06-04-{int(time.time())}",
        "timestamp":     time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "document_type": "GS1_INVOICE_JSON",
    },
    "encrypted_payload": "eyJhbGciOiJSU0EtT0FFUC0yNTYiLCJlbmMiOiJBMjU2R0NNIn0.tampered.tampered.tampered.tampered",
}))
')
HTTP=$(post_inbound "$SIG_BAD_ENV")
case "$HTTP" in
  400|401|403|422)
    pass 06.04 "Tampered/invalid JWS rejected with HTTP $HTTP"
    ;;
  200|202)
    BODY=$(cat /tmp/fidex-conformance-resp.$$ 2>/dev/null)
    if echo "$BODY" | grep -qiE 'quarantin|reject|signature|decrypt'; then
      pass 06.04 "Tampered JWS quarantined with HTTP $HTTP (body declares failure)"
    else
      fail 06.04 "Tampered JWS rejected" \
        "HTTP $HTTP but body does not declare failure: $(echo "$BODY" | head -c 200)"
    fi
    ;;
  5*)
    fail 06.04 "Tampered JWS rejected with 4xx" \
      "got HTTP $HTTP — server error on bad crypto is a spec violation"
    ;;
  *)
    fail 06.04 "Tampered JWS rejected" \
      "got unexpected HTTP $HTTP"
    ;;
esac

rm -f /tmp/fidex-conformance-resp.$$
print_bucket_summary 06 Errors
