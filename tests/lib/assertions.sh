#!/usr/bin/env bash
# Shared assertions for the FideX conformance suite.
#
# Tests source this file and call its functions; the file defines pass/fail
# helpers and shared JSON validators used across buckets.
#
# Required by every test: GREEN/RED/YEL color codes and the assert_* helpers.

# ── Colours ────────────────────────────────────────────────────────────────
GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[1;33m'; NC=$'\033[0m'

# ── pass/fail accounting ───────────────────────────────────────────────────
TEST_PASS=0
TEST_FAIL=0
TEST_RESULTS=()    # lines: "PASS|FAIL|id|description|reason"

pass() {
  local id=$1; shift
  local desc=$*
  TEST_PASS=$((TEST_PASS + 1))
  TEST_RESULTS+=("PASS|$id|$desc|")
  printf "  ${GREEN}PASS${NC}  %s — %s\n" "$id" "$desc"
}

fail() {
  local id=$1; shift
  local desc=$1; shift
  local reason=$*
  TEST_FAIL=$((TEST_FAIL + 1))
  TEST_RESULTS+=("FAIL|$id|$desc|$reason")
  printf "  ${RED}FAIL${NC}  %s — %s\n        reason: %s\n" "$id" "$desc" "$reason"
}

# ── HTTP helpers ───────────────────────────────────────────────────────────

# fetch_json URL -> echoes body on stdout, returns 0 if HTTP 2xx and body is
# valid JSON, 1 otherwise.
fetch_json() {
  local url=$1
  local body
  body=$(curl -fsS "$url" 2>/dev/null) || return 1
  echo "$body" | python3 -c "import json, sys; json.loads(sys.stdin.read())" 2>/dev/null || return 1
  echo "$body"
}

# ── JSON validators ────────────────────────────────────────────────────────

# check_as5_config_spec BODY  → 0 if the body satisfies spec §6.2, 1 otherwise.
# On failure prints the first missing field to stderr.
check_as5_config_spec() {
  FIDEX_JSON="$1" python3 - <<'PY' || return 1
import json, os, sys
try:
    cfg = json.loads(os.environ["FIDEX_JSON"])
except Exception as e:
    print(f"not JSON: {e}", file=sys.stderr); sys.exit(1)
required = ["fidex_version", "supported_versions", "node_id",
            "organization_name", "public_domain", "endpoints", "security"]
for f in required:
    if not cfg.get(f):
        print(f"missing top-level: {f}", file=sys.stderr); sys.exit(1)
if not isinstance(cfg.get("supported_versions"), list) or not cfg["supported_versions"]:
    print("supported_versions must be non-empty array", file=sys.stderr); sys.exit(1)
ep = cfg["endpoints"]
for k in ("receive_message", "receive_receipt", "register", "jwks"):
    if not ep.get(k):
        print(f"missing endpoints.{k}", file=sys.stderr); sys.exit(1)
sec = cfg["security"]
for k in ("signature_algorithm", "encryption_algorithm",
          "content_encryption", "minimum_key_size"):
    if not sec.get(k):
        print(f"missing security.{k}", file=sys.stderr); sys.exit(1)
PY
}

# check_jwks_has_enc BODY → 0 if JWKS has a real-looking enc key, 1 otherwise.
check_jwks_has_enc() {
  FIDEX_JSON="$1" python3 - <<'PY' || return 1
import json, os, sys
jwks = json.loads(os.environ["FIDEX_JSON"])
keys = jwks.get("keys", [])
if not keys:
    print("no keys", file=sys.stderr); sys.exit(1)
enc = [k for k in keys if k.get("use") == "enc"]
if not enc:
    print(f"no use=enc key (got use values: {[k.get('use') for k in keys]})", file=sys.stderr)
    sys.exit(1)
n = enc[0].get("n", "")
if len(n) < 100:
    print(f"enc modulus suspiciously short ({len(n)} chars)", file=sys.stderr); sys.exit(1)
if "mock" in n.lower():
    print("enc key looks like a mock", file=sys.stderr); sys.exit(1)
PY
}

# check_jwks_has_sig BODY → 0 if JWKS has at least one sig-capable key.
check_jwks_has_sig() {
  FIDEX_JSON="$1" python3 - <<'PY' || return 1
import json, os, sys
jwks = json.loads(os.environ["FIDEX_JSON"])
keys = jwks.get("keys", [])
sig = [k for k in keys if k.get("use") == "sig"]
if not sig:
    print(f"no use=sig key (got: {[k.get('use') for k in keys]})", file=sys.stderr)
    sys.exit(1)
PY
}

# get_endpoint AS5_BODY field → echo the endpoints.<field> value, or empty.
get_endpoint() {
  FIDEX_JSON="$1" FIDEX_FIELD="$2" python3 -c '
import json, os
cfg = json.loads(os.environ["FIDEX_JSON"])
print(cfg.get("endpoints", {}).get(os.environ["FIDEX_FIELD"], ""))
'
}

# get_node_id AS5_BODY → echo the node_id.
get_node_id() {
  FIDEX_JSON="$1" python3 -c '
import json, os
cfg = json.loads(os.environ["FIDEX_JSON"])
print(cfg.get("node_id", ""))
'
}

# ── Summary printer ────────────────────────────────────────────────────────
print_bucket_summary() {
  local bucket_id=$1 bucket_name=$2
  local total=$((TEST_PASS + TEST_FAIL))
  printf "\n  ${YEL}Bucket %s (%s):${NC} %d/%d passed\n" \
    "$bucket_id" "$bucket_name" "$TEST_PASS" "$total"
  if [[ $TEST_FAIL -gt 0 ]]; then return 1; fi
  return 0
}
