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

# Capture a baseline of existing inbound message_ids BEFORE the peer
# delivers, so we can distinguish the new inbound row from any that
# already existed (e.g. a receipt persisted during bucket 03).
#
# We previously used `MAX(id)` here, but that only works on schemas with
# an integer auto-increment `id` column. The PHP reference node keys
# fidex_messages by `message_id` (TEXT) and has no `id` column, so the
# baseline query failed silently and the test reported a false negative
# even when the peer's envelope had arrived and been persisted. The new
# strategy is portable: snapshot the existing message_id set, then look
# for any message_id present after the worker drain that wasn't in the
# baseline.
BASELINE_FILE=$(mktemp)
sqlite3 "$NUT_DB_PATH" \
  "SELECT message_id FROM $NUT_MESSAGES_TABLE WHERE direction='$NUT_MESSAGES_DIRECTION';" \
  2>/dev/null | sort -u > "$BASELINE_FILE" || true

# 04.02 — Drain peer's queue worker (one-shot).
if WORKER_OUT=$(bash -c "$PEER_WORKER_CMD" 2>&1); then
  pass 04.02 "Peer queue worker ran successfully"
else
  fail 04.02 "Peer queue worker ran successfully" "$(echo "$WORKER_OUT" | tail -3)"
fi

# 04.03 — Verify NUT persisted a fresh inbound row with DELIVERED status
# (implies successful decrypt + verify).
#
# Implementations whose inbound pipeline is asynchronous (PHP enqueues a
# process_inbound job, then the cron worker advances status to DELIVERED)
# need their worker drained between the envelope arrival and the status
# check. We kick NUT_WORKER_CMD as a *background* process so the polling
# loop can observe its progress without blocking on a slow decrypt. The
# 60s budget matches the worker's internal timeout used by the runner so
# even a pure-PHP RSA-OAEP decrypt at 4096-bit on slow hardware can finish
# inside one iteration. For in-process workers (Go) NUT_WORKER_CMD is
# empty and the loop just polls.
CURRENT_FILE=$(mktemp)
NUT_WORKER_PID=""
if [[ -n "${NUT_WORKER_CMD:-}" ]]; then
  bash -c "$NUT_WORKER_CMD" >/dev/null 2>&1 &
  NUT_WORKER_PID=$!
fi

DEADLINE=$((SECONDS + 60))
FOUND_COUNT=0
FOUND_STATUS=""
NEW_MID=""
while (( SECONDS < DEADLINE )); do
  if [[ -f "$NUT_DB_PATH" ]]; then
    sqlite3 "$NUT_DB_PATH" \
      "SELECT message_id FROM $NUT_MESSAGES_TABLE WHERE direction='$NUT_MESSAGES_DIRECTION';" \
      2>/dev/null | sort -u > "$CURRENT_FILE" || true
    # comm -13 emits lines unique to the second file (i.e. new since baseline).
    NEW_MID=$(comm -13 "$BASELINE_FILE" "$CURRENT_FILE" | tail -1)
    if [[ -n "$NEW_MID" ]]; then
      FOUND_COUNT=1
      FOUND_STATUS=$(sqlite3 "$NUT_DB_PATH" \
        "SELECT status FROM $NUT_MESSAGES_TABLE WHERE message_id='$NEW_MID' LIMIT 1;" \
        2>/dev/null || echo "")
      # Terminal-state shortcut. If the status is still RECEIVED / queued,
      # we keep polling (and re-kicking the NUT worker) until either it
      # reaches a terminal state or the budget runs out.
      case "$FOUND_STATUS" in
        DELIVERED|delivered|DECRYPTED|decrypted|QUARANTINED|quarantined|FAILED|failed) break ;;
      esac
    fi
  fi
  # Re-kick the NUT worker if our background drain has exited and the
  # inbound row is still in a non-terminal state — drains are one-shot,
  # so we need a new process each pass to walk the remaining jobs.
  if [[ -n "${NUT_WORKER_CMD:-}" ]] && ! kill -0 "$NUT_WORKER_PID" 2>/dev/null; then
    bash -c "$NUT_WORKER_CMD" >/dev/null 2>&1 &
    NUT_WORKER_PID=$!
  fi
  sleep 0.5
done
[[ -n "$NUT_WORKER_PID" ]] && kill "$NUT_WORKER_PID" 2>/dev/null || true
rm -f "$BASELINE_FILE" "$CURRENT_FILE"

if [[ "$FOUND_COUNT" -ge 1 ]]; then
  pass 04.03 "NUT received the inbound envelope from peer (message_id=$NEW_MID)"
  case "$FOUND_STATUS" in
    DELIVERED|delivered|DECRYPTED|decrypted)
      # Both states prove the JWE was decrypted+verified — DECRYPTED is the
      # canonical intermediate in PHP's inbound flow (RECEIVED → DECRYPTED
      # → DELIVERED) and DELIVERED is the terminal state in both PHP and
      # Go nodes.
      pass 04.04 "NUT decrypted+verified the JWE (status=$FOUND_STATUS)"
      ;;
    RECEIVED|received|PENDING|pending)
      # The envelope landed but the NUT's worker never advanced status.
      # That's fine for proving 04.03 (delivery interop), but means we
      # can't conclude 04.04 (decrypt+verify). Surface this honestly so
      # operators know whether to provide a NUT_WORKER_CMD.
      fail 04.04 "NUT decrypted+verified the JWE" \
        "status=$FOUND_STATUS — envelope received but inbound worker never ran (provide --node-worker-cmd?)"
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
    "no new inbound row in $NUT_MESSAGES_TABLE within 20s"
fi

print_bucket_summary 04 Receive
