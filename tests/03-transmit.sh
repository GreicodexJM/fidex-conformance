#!/usr/bin/env bash
# Test bucket 03 — Transmit (outbound JWE)
#
# Spec §4 (Envelope), §5 (Crypto).
#
# NUT signs+encrypts a business document, wraps it in a spec-shaped envelope,
# and POSTs to the peer's receive_message URL. We verify the peer received,
# decrypted, and persisted the message.
#
# Required environment:
#   NUT_TRANSMIT_URL           — NUT's POST /api/v1/transmit URL
#   NUT_TRANSMIT_AUTH_HEADER   — Authorization header value for transmit
#   PEER_NODE_ID               — destination partner id
#   PEER_DB_PATH               — sqlite path on peer node
#   PEER_MESSAGES_TABLE        — messages table name (default: fidex_messages)
#   PEER_MESSAGES_DIRECTION    — direction column expected value (default: inbound)
#   NUT_NODE_ID                — sender id (for filtering the peer's table)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${NUT_TRANSMIT_URL:?required}"
: "${PEER_NODE_ID:?required}"
: "${PEER_DB_PATH:?required}"
: "${NUT_NODE_ID:?required}"
PEER_MESSAGES_TABLE=${PEER_MESSAGES_TABLE:-fidex_messages}
PEER_MESSAGES_DIRECTION=${PEER_MESSAGES_DIRECTION:-inbound}

printf "%sBucket 03 — Transmit%s\n" "$YEL" "$NC"

# 03.01 — Build payload and submit to NUT's transmit endpoint.
PAYLOAD=$(python3 -c '
import json
print(json.dumps({
    "destination_partner_id": "'"$PEER_NODE_ID"'",
    "document_type": "GS1_ORDER_JSON",
    "payload": {
        "order_id": "CONFORMANCE-03",
        "items": [{"sku":"ABC-1","qty":1}],
    },
}))
')
AUTH_HDR=()
[[ -n "${NUT_TRANSMIT_AUTH_HEADER:-}" ]] && AUTH_HDR=(-H "Authorization: ${NUT_TRANSMIT_AUTH_HEADER}")
RESP=$(curl -fsS -X POST "$NUT_TRANSMIT_URL" \
  "${AUTH_HDR[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1) || {
  fail 03.01 "NUT accepts POST /api/v1/transmit" "$RESP"
  print_bucket_summary 03 Transmit; exit 1
}
MSG_ID=$(FIDEX_JSON="$RESP" python3 -c '
import json, os
r = json.loads(os.environ["FIDEX_JSON"])
print((r.get("data") or r).get("message_id", ""))
')
if [[ -n "$MSG_ID" ]]; then
  pass 03.01 "NUT accepted transmit, queued message_id=$MSG_ID"
else
  fail 03.01 "NUT accepted transmit" "no message_id in response: $RESP"
  print_bucket_summary 03 Transmit; exit 1
fi

# 03.02-03.04 — Wait for peer to record the inbound message. NUT must
# encrypt + envelope + deliver, peer must decrypt + persist. We verify by
# polling the peer's DB for a fresh inbound row.
#
# Snapshot the peer's existing inbound message_ids BEFORE kicking the NUT
# worker so we can detect the *new* row even if previous buckets left
# stale rows behind. Filtering by message_id delta is portable across
# implementations — PHP exposes a sender_id column but Go embeds the
# sender id inside the payload JSON, so we can't safely filter on it.
BASELINE_FILE=$(mktemp)
sqlite3 "$PEER_DB_PATH" \
  "SELECT message_id FROM $PEER_MESSAGES_TABLE WHERE direction='$PEER_MESSAGES_DIRECTION';" \
  2>/dev/null | sort -u > "$BASELINE_FILE" || true
CURRENT_FILE=$(mktemp)

# Some implementations (notably PHP nodes whose queue worker is a cron job
# rather than an in-process loop) accept the transmit request immediately
# but only build + send the envelope when their worker runs. The runner
# exports NUT_WORKER_CMD when the NUT needs to be kicked between phases;
# we drain it as a *background* process so the polling loop can observe
# its progress without blocking on a slow encrypt. The 60s budget matches
# the worker's internal timeout used by the runner so even a pure-PHP
# RSA-OAEP sign+encrypt at 4096-bit on slow hardware can finish inside
# one iteration.
NUT_WORKER_PID=""
if [[ -n "${NUT_WORKER_CMD:-}" ]]; then
  bash -c "$NUT_WORKER_CMD" >/dev/null 2>&1 &
  NUT_WORKER_PID=$!
fi

DEADLINE=$((SECONDS + 60))
DELIVERED=0
COUNT=0
while (( SECONDS < DEADLINE )); do
  sqlite3 "$PEER_DB_PATH" \
    "SELECT message_id FROM $PEER_MESSAGES_TABLE WHERE direction='$PEER_MESSAGES_DIRECTION';" \
    2>/dev/null | sort -u > "$CURRENT_FILE" || true
  COUNT=$(comm -13 "$BASELINE_FILE" "$CURRENT_FILE" | wc -l)
  if [[ "$COUNT" -ge 1 ]]; then DELIVERED=1; break; fi
  # Re-kick the NUT worker if our background drain has exited but the
  # peer's table is still empty — drains are one-shot, so we need a new
  # process each pass to walk any remaining transmit jobs.
  if [[ -n "${NUT_WORKER_CMD:-}" ]] && ! kill -0 "$NUT_WORKER_PID" 2>/dev/null; then
    bash -c "$NUT_WORKER_CMD" >/dev/null 2>&1 &
    NUT_WORKER_PID=$!
  fi
  sleep 0.5
done
[[ -n "$NUT_WORKER_PID" ]] && kill "$NUT_WORKER_PID" 2>/dev/null || true
rm -f "$BASELINE_FILE" "$CURRENT_FILE"

if [[ $DELIVERED -eq 1 ]]; then
  pass 03.02 "NUT produced a deliverable JWE envelope"
  pass 03.03 "NUT POSTed envelope to peer's receive_message URL"
  pass 03.04 "Peer received and persisted the inbound message ($COUNT row)"
else
  fail 03.02 "NUT delivered the encrypted envelope to peer" \
    "no new inbound row in $PEER_MESSAGES_TABLE within 30s (sender_id=$NUT_NODE_ID — check NUT outbound worker)"
fi

print_bucket_summary 03 Transmit
