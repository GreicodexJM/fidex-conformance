#!/usr/bin/env bash
# Test bucket 05 — Receipts (signed J-MDN)
#
# Spec §7 (Message disposition notifications).
#
# Round-trip:
#   1. Peer transmits a fresh envelope to NUT (similar to bucket 04).
#   2. NUT decrypts + verifies + persists, generates a signed J-MDN,
#      POSTs it to peer's receive_receipt URL.
#   3. Peer accepts the J-MDN, validates the signature against NUT's sig key
#      from cached JWKS, updates its outbound message status to DELIVERED.
#
# Test evidence is observed in the peer's DB: the outbound row corresponding
# to step 1 must flip from queued/delivering to delivered (or status_text
# equivalent). If it stays in delivering after the NUT processes the
# envelope, the NUT failed to emit/deliver a valid J-MDN.
#
# Required environment (inherited from runner.sh):
#   PEER_TRANSMIT_URL, PEER_TRANSMIT_AUTH_HEADER, PEER_WORKER_CMD,
#   PEER_DB_PATH, NUT_NODE_ID, PEER_NODE_ID.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${PEER_TRANSMIT_URL:?required}"
: "${PEER_WORKER_CMD:?required}"
: "${NUT_NODE_ID:?required}"
: "${PEER_NODE_ID:?required}"
: "${PEER_DB_PATH:?required}"
PEER_QUEUE_TABLE=${PEER_QUEUE_TABLE:-fidex_queue}
PEER_MESSAGES_TABLE=${PEER_MESSAGES_TABLE:-fidex_messages}

printf "%sBucket 05 — Receipts (J-MDN)%s\n" "$YEL" "$NC"

# Bucket isolation: prior buckets may have left pending jobs that would
# distort our latency window. Also blow away any stale "delivering" rows
# whose receipts never arrived in prior runs.
sqlite3 "$PEER_DB_PATH" "DELETE FROM $PEER_QUEUE_TABLE WHERE status != 'done';" 2>/dev/null || true

MARKER="CONFORMANCE-05-$(date +%s)-$$"

# 05.01 — Peer queues a new outbound message destined for the NUT.
PAYLOAD=$(MARKER="$MARKER" NUT="$NUT_NODE_ID" python3 -c '
import json, os
print(json.dumps({
    "destination_partner_id": os.environ["NUT"],
    "document_type": "GS1_ORDER_JSON",
    "payload": {
        "order_id": os.environ["MARKER"],
        "items": [{"sku":"RCT-1","qty":1}],
    },
}))
')
AUTH_HDR=()
[[ -n "${PEER_TRANSMIT_AUTH_HEADER:-}" ]] && AUTH_HDR=(-H "Authorization: ${PEER_TRANSMIT_AUTH_HEADER}")
TRANSMIT_RESP=$(curl -fsS -X POST "$PEER_TRANSMIT_URL" \
  "${AUTH_HDR[@]}" \
  -H "Content-Type: application/json" \
  -d "$PAYLOAD" 2>&1) || {
  fail 05.01 "Peer accepted outbound transmit destined for NUT" "$TRANSMIT_RESP"
  print_bucket_summary 05 Receipts; exit 1
}

# Extract the peer's local outbound message id so we can poll its status.
PEER_OUTBOUND_ID=$(FIDEX_JSON="$TRANSMIT_RESP" python3 -c '
import json, os
r = json.loads(os.environ["FIDEX_JSON"])
print((r.get("data") or r).get("message_id", ""))
')
if [[ -z "$PEER_OUTBOUND_ID" ]]; then
  fail 05.01 "Peer returned an outbound message_id" "$TRANSMIT_RESP"
  print_bucket_summary 05 Receipts; exit 1
fi
pass 05.01 "Peer queued outbound message_id=$PEER_OUTBOUND_ID"

# 05.02 — Drain peer's worker so the envelope reaches the NUT. Once NUT
# processes the envelope and emits its J-MDN, peer's worker is also what
# reconciles the inbound receipt back onto the outbound row.
if WORKER_OUT=$(bash -c "$PEER_WORKER_CMD" 2>&1); then
  pass 05.02 "Peer worker dispatched the outbound envelope to NUT"
else
  fail 05.02 "Peer worker dispatched the outbound envelope to NUT" \
    "$(echo "$WORKER_OUT" | tail -3)"
fi

# 05.03 — NUT generated a J-MDN. Evidence: the peer received the receipt
# (i.e. an INBOUND row whose document_type indicates a receipt, OR the
# outbound row's status flipped to delivered within the deadline).
#
# We accept either signal because spec §7 leaves storage shape as an
# implementation detail; the spec-binding observable is "sender knows the
# receiver disposed of the message".
DEADLINE=$((SECONDS + 30))
OUTBOUND_STATUS=""
while (( SECONDS < DEADLINE )); do
  OUTBOUND_STATUS=$(sqlite3 "$PEER_DB_PATH" \
    "SELECT status FROM $PEER_MESSAGES_TABLE WHERE direction='outbound' AND message_id='$PEER_OUTBOUND_ID' LIMIT 1;" \
    2>/dev/null || echo "")
  case "$OUTBOUND_STATUS" in
    delivered|DELIVERED|completed|COMPLETED|acknowledged|ACKNOWLEDGED) break ;;
  esac
  # Worker is one-shot — re-drain so any newly-enqueued process_receipt
  # job (peer received the J-MDN POST and queued reconciliation) actually
  # runs before the deadline. timeout in PEER_WORKER_CMD caps each tick.
  bash -c "$PEER_WORKER_CMD" >/dev/null 2>&1 || true
  sleep 1
done

case "$OUTBOUND_STATUS" in
  delivered|DELIVERED|completed|COMPLETED|acknowledged|ACKNOWLEDGED)
    pass 05.03 "NUT emitted J-MDN; peer reconciled outbound status=$OUTBOUND_STATUS"
    ;;
  "")
    fail 05.03 "NUT emitted a J-MDN and peer reconciled it" \
      "outbound row not found for message_id=$PEER_OUTBOUND_ID"
    ;;
  *)
    fail 05.03 "NUT emitted a J-MDN and peer reconciled it" \
      "outbound status stuck at '$OUTBOUND_STATUS' after 30s (no J-MDN received or rejected)"
    ;;
esac

print_bucket_summary 05 Receipts
