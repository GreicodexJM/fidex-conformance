#!/usr/bin/env bash
# Test bucket 04 — Receive (inbound JWE)
#
# Spec §4 (Envelope), §5 (Crypto).
#
# Reverse of 03: reference peer transmits an envelope to the NUT. We then
# verify the NUT decrypted and stored it. Requires the peer to have a queue
# worker that can run on demand (PHP's bin/worker.php).
#
# Required environment:
#   PEER_TRANSMIT_URL          — peer's POST /api/v1/transmit URL
#   PEER_TRANSMIT_AUTH_HEADER  — Authorization header for peer transmit
#   PEER_WORKER_CMD            — shell command to drain peer's queue once
#                                (e.g. "cd /repo && FIDEX_DB_PATH=… php bin/worker.php")
#   NUT_NODE_ID                — destination partner id (the NUT)
#   NUT_DB_PATH                — sqlite path on NUT node
#   NUT_MESSAGES_TABLE         — messages table name (default: messages)
#   NUT_MESSAGES_DIRECTION     — direction value (default: INBOUND)
#   PEER_NODE_ID               — sender id (for filtering NUT's table)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${PEER_TRANSMIT_URL:?required}"
: "${PEER_WORKER_CMD:?required}"
: "${NUT_NODE_ID:?required}"
: "${NUT_DB_PATH:?required}"
: "${PEER_NODE_ID:?required}"
: "${PEER_DB_PATH:?required}"
NUT_MESSAGES_TABLE=${NUT_MESSAGES_TABLE:-messages}
NUT_MESSAGES_DIRECTION=${NUT_MESSAGES_DIRECTION:-INBOUND}
PEER_QUEUE_TABLE=${PEER_QUEUE_TABLE:-fidex_queue}

printf "%sBucket 04 — Receive%s\n" "$YEL" "$NC"

# Bucket isolation: bucket 03 may have left a pending process_inbound / send_jmdn
# job in the peer's queue (since the peer's worker isn't a daemon in this
# harness). Clear stale jobs so 04 measures only the new round-trip.
sqlite3 "$PEER_DB_PATH" "DELETE FROM $PEER_QUEUE_TABLE WHERE status != 'done';" 2>/dev/null || true

# Use a unique marker in the business document so we can find the row in
# the NUT's DB even if the NUT only persists the decrypted business doc
# (no routing_header). Marker is a UUID-like string with a known prefix.
MARKER="CONFORMANCE-04-$(date +%s)-$$"

# 04.01 — Peer queues a message destined for the NUT.
PAYLOAD=$(MARKER="$MARKER" NUT="$NUT_NODE_ID" python3 -c '
import json, os
print(json.dumps({
    "destination_partner_id": os.environ["NUT"],
    "document_type": "GS1_INVOICE_JSON",
    "payload": {
        "invoice_id": os.environ["MARKER"],
        "lines": [{"sku":"XYZ-7","qty":3}],
    },
}))
')
AUTH_HDR=()
[[ -n "${PEER_TRANSMIT_AUTH_HEADER:-}" ]] && AUTH_HDR=(-H "Authorization: ${PEER_TRANSMIT_AUTH_HEADER}")
RESP=$(curl -fsS -X POST "$PEER_TRANSMIT_URL" \
  "${AUTH_HDR[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1) || {
  fail 04.01 "Peer accepts transmit destined for NUT" "$RESP"
  print_bucket_summary 04 Receive; exit 1
}
pass 04.01 "Peer queued outbound message destined for NUT"

# Capture id baseline BEFORE the worker delivers, so we can distinguish the
# new inbound row from any that already existed (e.g. a receipt persisted
# during bucket 03). id-delta is more portable than timestamp comparisons —
# implementations use wildly different created_at formats.
BASELINE_MAX_ID=$(sqlite3 "$NUT_DB_PATH" \
  "SELECT COALESCE(MAX(id),0) FROM $NUT_MESSAGES_TABLE WHERE direction='$NUT_MESSAGES_DIRECTION';" \
  2>/dev/null || echo "0")

# 04.02 — Drain peer's queue worker (one-shot).
if WORKER_OUT=$(bash -c "$PEER_WORKER_CMD" 2>&1); then
  pass 04.02 "Peer queue worker ran successfully"
else
  fail 04.02 "Peer queue worker ran successfully" "$(echo "$WORKER_OUT" | tail -3)"
fi

# 04.03 — Verify NUT persisted a fresh inbound row with DELIVERED status
# (implies successful decrypt + verify).

DEADLINE=$((SECONDS + 20))
FOUND_COUNT=0
FOUND_STATUS=""
while (( SECONDS < DEADLINE )); do
  if [[ -f "$NUT_DB_PATH" ]]; then
    FOUND_COUNT=$(sqlite3 "$NUT_DB_PATH" \
      "SELECT COUNT(*) FROM $NUT_MESSAGES_TABLE WHERE direction='$NUT_MESSAGES_DIRECTION' AND id > $BASELINE_MAX_ID;" \
      2>/dev/null || echo "0")
    if [[ "$FOUND_COUNT" -ge 1 ]]; then
      FOUND_STATUS=$(sqlite3 "$NUT_DB_PATH" \
        "SELECT status FROM $NUT_MESSAGES_TABLE WHERE direction='$NUT_MESSAGES_DIRECTION' AND id > $BASELINE_MAX_ID ORDER BY id DESC LIMIT 1;" \
        2>/dev/null || echo "")
      break
    fi
  fi
  sleep 0.5
done

if [[ "$FOUND_COUNT" -ge 1 ]]; then
  pass 04.03 "NUT received the inbound envelope from peer ($FOUND_COUNT row)"
  case "$FOUND_STATUS" in
    DELIVERED|delivered)
      pass 04.04 "NUT decrypted+verified the JWE (status=$FOUND_STATUS)"
      ;;
    QUARANTINED|quarantined)
      fail 04.04 "NUT decrypted+verified the JWE" \
        "status=$FOUND_STATUS — envelope reached NUT but crypto step failed"
      ;;
    *)
      fail 04.04 "NUT decrypted+verified the JWE" \
        "unexpected status=$FOUND_STATUS"
      ;;
  esac
else
  fail 04.03 "NUT received the inbound envelope from peer" \
    "no new inbound row in $NUT_MESSAGES_TABLE within 20s (baseline_max_id=$BASELINE_MAX_ID)"
fi

print_bucket_summary 04 Receive
