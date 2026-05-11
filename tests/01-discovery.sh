#!/usr/bin/env bash
# Test bucket 01 — Discovery
#
# Spec §6.2 (AS5 Configuration Endpoint) and §5.1 (JWKS endpoint).
#
# Reads from environment (exported by runner.sh):
#   NUT_AS5_URL       — node-under-test AS5 config URL
#   NUT_NODE_ID       — expected node_id of NUT (optional, used for validation)
#   PEER_AS5_URL      — reference peer AS5 config URL (for symmetry checks)
#
# Exits 0 if every required test passes, 1 otherwise.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/assertions.sh"

: "${NUT_AS5_URL:?NUT_AS5_URL is required}"

printf "%sBucket 01 — Discovery%s\n" "$YEL" "$NC"

# 01.01 — AS5 config reachable + valid JSON
NUT_AS5_BODY=$(fetch_json "$NUT_AS5_URL") || {
  fail 01.01 "AS5 config reachable + valid JSON" "could not fetch or parse $NUT_AS5_URL"
  print_bucket_summary 01 Discovery; exit 1
}
pass 01.01 "AS5 config reachable + valid JSON"

# 01.02–01.04 — spec §6.2 shape
ERR=$(check_as5_config_spec "$NUT_AS5_BODY" 2>&1 >/dev/null) && {
  pass 01.02 "AS5 config: all top-level required fields present"
  pass 01.03 "AS5 config: endpoints object has receive_message/receive_receipt/register/jwks"
  pass 01.04 "AS5 config: security object declares algos + minimum_key_size"
} || {
  fail 01.02 "AS5 config: spec §6.2 shape" "$ERR"
}

# 01.05 — JWKS reachable + has enc key
JWKS_URL=$(get_endpoint "$NUT_AS5_BODY" "jwks")
if [[ -z "$JWKS_URL" ]]; then
  fail 01.05 "JWKS endpoint published in AS5 config" "endpoints.jwks empty"
else
  NUT_JWKS=$(fetch_json "$JWKS_URL") || {
    fail 01.05 "JWKS endpoint reachable" "$JWKS_URL not fetchable"
    NUT_JWKS=""
  }
  if [[ -n "$NUT_JWKS" ]]; then
    if ERR=$(check_jwks_has_enc "$NUT_JWKS" 2>&1 >/dev/null); then
      pass 01.05 "JWKS has real RSA encryption key (use=enc, n≥2048-bit, not mock)"
    else
      fail 01.05 "JWKS has real encryption key" "$ERR"
    fi
    if ERR=$(check_jwks_has_sig "$NUT_JWKS" 2>&1 >/dev/null); then
      pass 01.06 "JWKS has signing key (use=sig)"
    else
      fail 01.06 "JWKS has signing key" "$ERR"
    fi
  fi
fi

print_bucket_summary 01 Discovery
