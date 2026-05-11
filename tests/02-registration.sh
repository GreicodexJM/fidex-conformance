#!/usr/bin/env bash
# Test bucket 02 — Registration
#
# Spec §6.3–6.5 (Partner registration handshake).
#
# Verifies both directions:
#   02.01 — reference peer registers the NUT
#   02.02 — NUT registers the reference peer
#
# Required environment:
#   NUT_AS5_URL                — node-under-test AS5 config URL
#   NUT_NODE_ID                — expected node_id of NUT
#   NUT_DISCOVER_URL           — NUT's "add a partner from URL" internal API
#   NUT_DISCOVER_AUTH_HEADER   — full Authorization header value (optional)
#   PEER_AS5_URL               — reference peer AS5 config URL
#   PEER_NODE_ID               — expected node_id of reference peer
#   PEER_REGISTER_URL          — peer's "add a partner from URL" API
#   PEER_REGISTER_AUTH_HEADER  — full Authorization header value for peer
#   PEER_DB_PATH               — sqlite path to verify peer DB after register
#   PEER_PARTNERS_TABLE        — partners table name (default: fidex_partners)
#   PEER_PARTNERS_ID_COL       — partner id column (default: partner_id)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${NUT_AS5_URL:?required}"
: "${NUT_NODE_ID:?required}"
: "${NUT_DISCOVER_URL:?required}"
: "${PEER_AS5_URL:?required}"
: "${PEER_NODE_ID:?required}"
: "${PEER_REGISTER_URL:?required}"
: "${PEER_DB_PATH:?required}"
PEER_PARTNERS_TABLE=${PEER_PARTNERS_TABLE:-fidex_partners}
PEER_PARTNERS_ID_COL=${PEER_PARTNERS_ID_COL:-partner_id}

printf "%sBucket 02 — Registration%s\n" "$YEL" "$NC"

# 02.01 — peer registers NUT
AUTH_HDR=()
[[ -n "${PEER_REGISTER_AUTH_HEADER:-}" ]] && AUTH_HDR=(-H "Authorization: ${PEER_REGISTER_AUTH_HEADER}")
RESP=$(curl -fsS -X POST "$PEER_REGISTER_URL" \
  "${AUTH_HDR[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"as5_config_url\":\"$NUT_AS5_URL\"}" 2>&1) || {
  fail 02.01 "Reference peer can register NUT from AS5 URL" "$RESP"
  RESP=""
}
if [[ -n "$RESP" ]]; then
  # Either {data: {partner_id, ...}} or {partner_id, ...}
  PID=$(FIDEX_JSON="$RESP" python3 -c '
import json, os
r = json.loads(os.environ["FIDEX_JSON"])
print((r.get("data") or r).get("partner_id", ""))
')
  if [[ "$PID" == "$NUT_NODE_ID" ]]; then
    pass 02.01 "Reference peer accepted NUT registration (partner_id=$PID)"
  else
    fail 02.01 "Reference peer accepted NUT registration" "expected partner_id=$NUT_NODE_ID, got $PID"
  fi

  # Verify peer DB has the partner row.
  COUNT=$(sqlite3 "$PEER_DB_PATH" \
    "SELECT COUNT(*) FROM $PEER_PARTNERS_TABLE WHERE $PEER_PARTNERS_ID_COL='$NUT_NODE_ID';" 2>/dev/null || echo "0")
  if [[ "$COUNT" -ge 1 ]]; then
    pass 02.01.b "Peer DB has partner row for NUT"
  else
    fail 02.01.b "Peer DB has partner row for NUT" "$PEER_PARTNERS_TABLE row count=0"
  fi
fi

# 02.02 — NUT registers peer
AUTH_HDR=()
[[ -n "${NUT_DISCOVER_AUTH_HEADER:-}" ]] && AUTH_HDR=(-H "Authorization: ${NUT_DISCOVER_AUTH_HEADER}")
RESP=$(curl -fsS -X POST "$NUT_DISCOVER_URL" \
  "${AUTH_HDR[@]}" \
  -H "Content-Type: application/json" \
  -d "{\"discovery_url\":\"$PEER_AS5_URL\",\"as5_config_url\":\"$PEER_AS5_URL\"}" 2>&1) || {
  fail 02.02 "NUT can register reference peer" "$RESP"
  RESP=""
}
if [[ -n "$RESP" ]]; then
  PID=$(FIDEX_JSON="$RESP" python3 -c '
import json, os
r = json.loads(os.environ["FIDEX_JSON"])
print((r.get("data") or r).get("partner_id", ""))
')
  if [[ "$PID" == "$PEER_NODE_ID" ]]; then
    pass 02.02 "NUT accepted peer registration (partner_id=$PID)"
  else
    fail 02.02 "NUT accepted peer registration" "expected partner_id=$PEER_NODE_ID, got $PID"
  fi
fi

print_bucket_summary 02 Registration
