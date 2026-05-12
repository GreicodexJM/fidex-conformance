#!/usr/bin/env bash
# FideX conformance suite — orchestrator.
#
# Boots a reference peer (FideX-php) and runs the four test buckets against
# the configured node under test, then emits a JSON report and an
# SVG/HTML badge.
#
# Usage:
#   ./runner.sh \
#       --node-name "MyImplementation 0.4" \
#       --node-as5-url http://localhost:9000/.well-known/as5-configuration \
#       --node-id urn:custom:my-impl \
#       --node-transmit-url http://localhost:9001/api/v1/transmit \
#       --node-transmit-api-key MY_KEY_32_CHARS \
#       --node-discover-url http://localhost:9001/admin/dashboard/partners/discover \
#       --node-db-path /var/lib/mynode/state.sqlite \
#       --node-messages-table messages \
#       --node-messages-direction INBOUND \
#       --node-worker-cmd "cd /repo && php bin/worker.php" \
#       --profile core
#
# --node-worker-cmd is OPTIONAL. Implementations whose queue worker runs
# in-process (e.g. the Go reference node polls its queue every 10s) can
# omit it. Implementations that run their worker as a cron job (e.g. the
# PHP reference node's bin/worker.php) MUST pass a drain command so the
# transmit + receive buckets can advance the NUT's outbound and inbound
# queues between phases.
#
# Defaults boot the FideX-php node bundled under reference-node/ as the peer.

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

# ── Defaults ──────────────────────────────────────────────────────────────
PROFILE=core
NODE_NAME="UnknownImplementation"
NODE_AS5_URL=""
NODE_ID=""
NODE_TRANSMIT_URL=""
NODE_TRANSMIT_API_KEY=""
NODE_DISCOVER_URL=""
NODE_DISCOVER_API_KEY=""
NODE_DB_PATH=""
NODE_MESSAGES_TABLE=messages
NODE_MESSAGES_DIRECTION=INBOUND
# NUT_WORKER_CMD lets implementations whose queue worker is NOT in-process
# (e.g. fidex-php's bin/worker.php cron) advance their outbound + inbound
# queue between test phases. Implementations that already run a background
# worker (Go) can leave this empty — the test buckets treat empty as a
# no-op and trust the in-process loop to drain.
NODE_WORKER_CMD=""

PEER_TYPE=${PEER_TYPE:-php}
PEER_REPO=${PEER_REPO:-/home/javier/Documents/Projects/Startup_Ideas/FideX-php}
PEER_PORT=${PEER_PORT:-18081}
# Go peer exposes a second (internal) port for the transmit/admin API.
PEER_INTERNAL_PORT=${PEER_INTERNAL_PORT:-19082}
PEER_NODE_ID=urn:custom:fidex-ref-peer
PEER_API_KEY=conformance-peer-key-32-chars-aaaaaaa

while [[ $# -gt 0 ]]; do
  case "$1" in
    --node-name) NODE_NAME=$2; shift 2 ;;
    --node-as5-url) NODE_AS5_URL=$2; shift 2 ;;
    --node-id) NODE_ID=$2; shift 2 ;;
    --node-transmit-url) NODE_TRANSMIT_URL=$2; shift 2 ;;
    --node-transmit-api-key) NODE_TRANSMIT_API_KEY=$2; shift 2 ;;
    --node-discover-url) NODE_DISCOVER_URL=$2; shift 2 ;;
    --node-discover-api-key) NODE_DISCOVER_API_KEY=$2; shift 2 ;;
    --node-db-path) NODE_DB_PATH=$2; shift 2 ;;
    --node-messages-table) NODE_MESSAGES_TABLE=$2; shift 2 ;;
    --node-messages-direction) NODE_MESSAGES_DIRECTION=$2; shift 2 ;;
    --node-worker-cmd) NODE_WORKER_CMD=$2; shift 2 ;;
    --peer-type) PEER_TYPE=$2; shift 2 ;;
    --peer-repo) PEER_REPO=$2; shift 2 ;;
    --peer-port) PEER_PORT=$2; shift 2 ;;
    --peer-internal-port) PEER_INTERNAL_PORT=$2; shift 2 ;;
    --profile) PROFILE=$2; shift 2 ;;
    --help|-h)
      head -40 "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
done

case "$PEER_TYPE" in
  php|go) ;;
  *) echo "--peer-type must be 'php' or 'go' (got: $PEER_TYPE)" >&2; exit 2 ;;
esac

[[ -z "$NODE_AS5_URL" ]] && { echo "--node-as5-url is required" >&2; exit 2; }
[[ -z "$NODE_ID" ]] && { echo "--node-id is required" >&2; exit 2; }

GREEN=$'\033[0;32m'; RED=$'\033[0;31m'; YEL=$'\033[1;33m'; NC=$'\033[0m'
say() { printf "${GREEN}[runner]${NC} %s\n" "$*"; }
warn(){ printf "${YEL}[runner]${NC} %s\n" "$*"; }
die() { printf "${RED}[runner] %s${NC}\n" "$*" >&2; exit 1; }

WORK=$(mktemp -d /tmp/fidex-conformance.XXXXXX)
PEER_DIR="$WORK/peer"
mkdir -p "$PEER_DIR" "$HERE/results"

cleanup() {
  warn "cleaning up..."
  if [[ "$PEER_TYPE" == "php" ]]; then
    pkill -KILL -f "php -S 0.0.0.0:$PEER_PORT" 2>/dev/null || true
    if [[ -f "$PEER_REPO/.env.bak.conformance" ]]; then
      mv "$PEER_REPO/.env.bak.conformance" "$PEER_REPO/.env" 2>/dev/null || true
    fi
  else
    [[ -n "${PEER_PID:-}" ]] && kill -KILL "$PEER_PID" 2>/dev/null || true
    pkill -KILL -f "$PEER_DIR/fidex-node" 2>/dev/null || true
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ── Preflight: ports must be free ─────────────────────────────────────────
if ss -tlnp 2>/dev/null | grep -qE ":${PEER_PORT}\s"; then
  die "port $PEER_PORT is already in use. Stop the conflicting process or set PEER_PORT to a free port."
fi
if [[ "$PEER_TYPE" == "go" ]] && ss -tlnp 2>/dev/null | grep -qE ":${PEER_INTERNAL_PORT}\s"; then
  die "port $PEER_INTERNAL_PORT (peer internal) is in use. Set PEER_INTERNAL_PORT to a free port."
fi

# ── Boot reference peer ───────────────────────────────────────────────────
if [[ "$PEER_TYPE" == "php" ]]; then
  # PHP peer requires RSA key pairs (sign + enc). The bootstrap loads them
  # if they exist; otherwise /health reports degraded and returns 503 — which
  # `curl -fsS` treats as a hard failure. Generate them on demand so CI jobs
  # that only install dependencies still get a healthy peer.
  if [[ ! -f "$PEER_REPO/keys/sign_private.pem" || ! -f "$PEER_REPO/keys/enc_private.pem" ]]; then
    say "Generating reference peer keys (missing in $PEER_REPO/keys/) ..."
    (cd "$PEER_REPO" && rm -f keys/*.pem && php bin/generate-keys.php >/dev/null 2>&1) \
      || warn "peer key generation reported errors — health check may still fail"
  fi
  # Ensure the peer DB schema exists before the server first touches PDO.
  # We previously ran migrate.php AFTER the health-check loop, but /health
  # itself does a SELECT against the queue and a clean sqlite file works fine
  # for that; the explicit migrate is still useful for the partner/message
  # tables exercised by the test buckets.
  (cd "$PEER_REPO" \
    && FIDEX_DB_DRIVER=sqlite \
       FIDEX_DB_PATH="$PEER_DIR/fidex.sqlite" \
       php bin/migrate.php >/dev/null 2>&1) || warn "peer migration printed errors"

  say "Starting reference peer (FideX-php) on :$PEER_PORT ..."
  if [[ -f "$PEER_REPO/.env" ]]; then mv "$PEER_REPO/.env" "$PEER_REPO/.env.bak.conformance"; fi
  (cd "$PEER_REPO" \
    && FIDEX_NODE_ID="$PEER_NODE_ID" \
       FIDEX_NODE_NAME="FideX Reference Peer" \
       FIDEX_NODE_BASE_URL="http://localhost:$PEER_PORT" \
       FIDEX_API_KEY="$PEER_API_KEY" \
       FIDEX_DB_DRIVER=sqlite \
       FIDEX_DB_PATH="$PEER_DIR/fidex.sqlite" \
       FIDEX_ALLOW_HTTP_REGISTRATION=true \
       nohup php -S 0.0.0.0:"$PEER_PORT" -t "$PEER_REPO/public/" "$PEER_REPO/public/index.php" > "$PEER_DIR/peer.log" 2>&1 &)
  DEADLINE=$((SECONDS + 15))
  LAST_HEALTH_CODE=
  LAST_HEALTH_BODY=
  until curl -fsS "http://localhost:$PEER_PORT/health" >/dev/null 2>&1; do
    if (( SECONDS > DEADLINE )); then
      # Capture the actual response so we know if it's a 503 (degraded —
      # usually missing keys), a 500 (bootstrap fatal), or a 404 (route
      # not mounted). The access log alone doesn't reveal the status code.
      LAST_HEALTH_BODY=$(curl -sS -o - -w "HTTP_CODE=%{http_code}\n" \
        "http://localhost:$PEER_PORT/health" 2>&1 || echo "(curl failed)")
      printf "%s---- /health probe result ----%s\n" "$RED" "$NC" >&2
      printf "%s\n" "$LAST_HEALTH_BODY" >&2
      printf "%s---- peer.log (first 50 lines) ----%s\n" "$RED" "$NC" >&2
      head -50 "$PEER_DIR/peer.log" >&2 2>/dev/null || echo "(peer.log absent)" >&2
      printf "%s---- peer.log (last 50 lines) ----%s\n" "$RED" "$NC" >&2
      tail -50 "$PEER_DIR/peer.log" >&2 2>/dev/null || echo "(peer.log absent)" >&2
      printf "%s---- end peer.log ----%s\n" "$RED" "$NC" >&2
      die "reference peer never became healthy"
    fi
    sleep 0.3
  done
  say "Reference peer healthy at http://localhost:$PEER_PORT"
else
  # Go reference peer. Expects a pre-built binary at $PEER_REPO/fidex-node or
  # builds one on the fly when the source tree is present.
  PEER_BIN="$PEER_REPO/fidex-node"
  if [[ ! -x "$PEER_BIN" ]]; then
    if command -v go >/dev/null 2>&1 && [[ -d "$PEER_REPO/cmd/fidex-node" ]]; then
      say "Building Go reference peer..."
      (cd "$PEER_REPO" && go build -o fidex-node ./cmd/fidex-node) \
        || die "go build failed in $PEER_REPO"
    else
      die "Go peer binary not found at $PEER_BIN and 'go' is unavailable. Build it first."
    fi
  fi
  say "Starting reference peer (FideX-go) on public:$PEER_PORT internal:$PEER_INTERNAL_PORT ..."
  mkdir -p "$PEER_DIR/keys"
  (cd "$PEER_DIR" \
    && FIDEX_NODE_ID="$PEER_NODE_ID" \
       FIDEX_ORG_NAME="FideX Reference Peer (Go)" \
       FIDEX_PUBLIC_DOMAIN="localhost:$PEER_PORT" \
       FIDEX_PUBLIC_PORT="$PEER_PORT" \
       FIDEX_INTERNAL_PORT="$PEER_INTERNAL_PORT" \
       FIDEX_API_KEY="$PEER_API_KEY" \
       FIDEX_ENABLE_IP_ALLOWLIST=false \
       FIDEX_DB_PATH="$PEER_DIR/fidex.sqlite" \
       FIDEX_PRIVATE_KEY_PATH="$PEER_DIR/keys/private_key.pem" \
       FIDEX_PUBLIC_KEY_PATH="$PEER_DIR/keys/public_key.pem" \
       setsid "$PEER_BIN" > "$PEER_DIR/peer.log" 2>&1 < /dev/null &)
  DEADLINE=$((SECONDS + 20))
  until curl -fsS "http://localhost:$PEER_PORT/health" >/dev/null 2>&1; do
    if (( SECONDS > DEADLINE )); then
      printf "%s---- peer.log (last 50 lines) ----%s\n" "$RED" "$NC" >&2
      tail -50 "$PEER_DIR/peer.log" >&2 2>/dev/null || echo "(peer.log absent)" >&2
      printf "%s---- end peer.log ----%s\n" "$RED" "$NC" >&2
      die "reference peer never became healthy"
    fi
    sleep 0.3
  done
  say "Reference peer healthy at http://localhost:$PEER_PORT"
fi

# ── Export environment for tests ──────────────────────────────────────────
export NUT_AS5_URL="$NODE_AS5_URL"
export NUT_NODE_ID="$NODE_ID"
export NUT_DISCOVER_URL="$NODE_DISCOVER_URL"
export NUT_DISCOVER_AUTH_HEADER=${NODE_DISCOVER_API_KEY:+Bearer $NODE_DISCOVER_API_KEY}
export NUT_TRANSMIT_URL="$NODE_TRANSMIT_URL"
export NUT_TRANSMIT_AUTH_HEADER=${NODE_TRANSMIT_API_KEY:+Bearer $NODE_TRANSMIT_API_KEY}
export NUT_DB_PATH="$NODE_DB_PATH"
export NUT_MESSAGES_TABLE="$NODE_MESSAGES_TABLE"
export NUT_MESSAGES_DIRECTION="$NODE_MESSAGES_DIRECTION"
# Implementations that lack an in-process queue worker (PHP cron) pass
# their drain command here so the transmit/receive buckets can advance
# the NUT's outbound + inbound queues between phases.
export NUT_WORKER_CMD="$NODE_WORKER_CMD"

export PEER_NODE_ID
export PEER_DB_PATH="$PEER_DIR/fidex.sqlite"

if [[ "$PEER_TYPE" == "php" ]]; then
  export PEER_AS5_URL="http://localhost:$PEER_PORT/as5/config"
  export PEER_REGISTER_URL="http://localhost:$PEER_PORT/api/v1/partners/register"
  export PEER_REGISTER_AUTH_HEADER="Bearer $PEER_API_KEY"
  export PEER_PARTNERS_TABLE=fidex_partners
  export PEER_PARTNERS_ID_COL=partner_id
  export PEER_MESSAGES_TABLE=fidex_messages
  export PEER_MESSAGES_DIRECTION=inbound
  export PEER_TRANSMIT_URL="http://localhost:$PEER_PORT/api/v1/transmit"
  export PEER_TRANSMIT_AUTH_HEADER="Bearer $PEER_API_KEY"
  # Worker is wrapped in `timeout 60s` so a delivery loop that won't terminate
  # (dead endpoint, infinite retry, etc.) can't lock up the suite. 60s covers
  # the PHP cURL client's default 30s timeout plus worker bootstrap.
  export PEER_WORKER_CMD="cd '$PEER_REPO' && FIDEX_NODE_ID='$PEER_NODE_ID' FIDEX_NODE_NAME='FideX Reference Peer' FIDEX_NODE_BASE_URL='http://localhost:$PEER_PORT' FIDEX_API_KEY='$PEER_API_KEY' FIDEX_DB_DRIVER=sqlite FIDEX_DB_PATH='$PEER_DIR/fidex.sqlite' FIDEX_ALLOW_HTTP_REGISTRATION=true timeout 60s php bin/worker.php"
else
  # Go peer: AS5 config is published at /.well-known/as5-configuration, the
  # registration endpoint is the public /api/v1/register, but discover-by-URL
  # is the internal /admin/dashboard/partners/discover. Tables follow the Go
  # schema (`messages`, `trading_partners`).
  export PEER_AS5_URL="http://localhost:$PEER_PORT/.well-known/as5-configuration"
  export PEER_REGISTER_URL="http://localhost:$PEER_INTERNAL_PORT/admin/dashboard/partners/discover"
  export PEER_REGISTER_AUTH_HEADER="Bearer $PEER_API_KEY"
  export PEER_PARTNERS_TABLE=trading_partners
  export PEER_PARTNERS_ID_COL=partner_id
  export PEER_MESSAGES_TABLE=messages
  export PEER_MESSAGES_DIRECTION=INBOUND
  export PEER_TRANSMIT_URL="http://localhost:$PEER_INTERNAL_PORT/api/v1/transmit"
  export PEER_TRANSMIT_AUTH_HEADER="Bearer $PEER_API_KEY"
  # Go peer ships an in-process queue worker — no external worker step needed.
  # Provide a no-op so test buckets that conditionally invoke it stay portable.
  export PEER_WORKER_CMD="true"
fi

# ── Run each test bucket, collect verdicts ────────────────────────────────
case "$PROFILE" in
  core)     BUCKETS=("01-discovery" "02-registration" "03-transmit" "04-receive") ;;
  enhanced) BUCKETS=("01-discovery" "02-registration" "03-transmit" "04-receive" "05-receipts" "06-errors") ;;
  edge)     BUCKETS=("01-discovery" "02-registration" "03-transmit" "04-receive" "05-receipts" "06-errors" "07-security") ;;
  *) die "unknown profile: $PROFILE" ;;
esac

declare -A BUCKET_EXIT
for bucket in "${BUCKETS[@]}"; do
  script="$HERE/tests/${bucket}.sh"
  if [[ ! -x "$script" ]]; then
    warn "bucket $bucket script missing ($script) — counted as fail"
    BUCKET_EXIT["$bucket"]=2
    continue
  fi
  printf "\n%s───── %s ─────%s\n" "$YEL" "$bucket" "$NC"
  "$script"; BUCKET_EXIT["$bucket"]=$?
done

# ── Verdict ───────────────────────────────────────────────────────────────
OVERALL=PASS
FAIL_LIST=""
for bucket in "${BUCKETS[@]}"; do
  if [[ "${BUCKET_EXIT[$bucket]:-1}" -ne 0 ]]; then
    OVERALL=FAIL
    FAIL_LIST="$FAIL_LIST $bucket"
  fi
done

RUN_ID=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
REPORT_JSON="$HERE/results/conformance-report.json"
BADGE_SVG="$HERE/results/badge.svg"

# Build the JSON report.
{
  echo "{"
  echo "  \"schema\": \"fidex-conformance/v1\","
  echo "  \"run_id\": \"$RUN_ID\","
  echo "  \"implementation\": {"
  echo "    \"name\": \"$NODE_NAME\","
  echo "    \"node_id\": \"$NODE_ID\","
  echo "    \"as5_url\": \"$NODE_AS5_URL\""
  echo "  },"
  echo "  \"spec_version\": \"1.0\","
  echo "  \"profile\": \"$PROFILE\","
  echo "  \"buckets\": ["
  first=1
  for bucket in "${BUCKETS[@]}"; do
    code=${BUCKET_EXIT[$bucket]:-1}
    result=$([[ "$code" -eq 0 ]] && echo PASS || echo FAIL)
    [[ $first -eq 0 ]] && echo ","
    first=0
    printf "    {\"id\": \"%s\", \"exit_code\": %s, \"result\": \"%s\"}" \
      "$bucket" "$code" "$result"
  done
  echo ""
  echo "  ],"
  echo "  \"verdict\": \"$OVERALL\""
  echo "}"
} > "$REPORT_JSON"

# Compose badge.
COLOUR=$([[ "$OVERALL" == "PASS" ]] && echo "#4c1" || echo "#e05d44")
LABEL="FideX $PROFILE"
VALUE=$([[ "$OVERALL" == "PASS" ]] && echo "compliant" || echo "non-compliant")
cat > "$BADGE_SVG" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" width="200" height="20">
  <linearGradient id="g" x2="0" y2="100%">
    <stop offset="0" stop-color="#bbb" stop-opacity=".1"/>
    <stop offset="1" stop-opacity=".1"/>
  </linearGradient>
  <rect rx="3" width="200" height="20" fill="#555"/>
  <rect rx="3" x="90" width="110" height="20" fill="$COLOUR"/>
  <rect rx="3" width="200" height="20" fill="url(#g)"/>
  <g fill="#fff" text-anchor="middle" font-family="DejaVu Sans,Verdana,sans-serif" font-size="11">
    <text x="45" y="14">$LABEL</text>
    <text x="145" y="14">$VALUE</text>
  </g>
</svg>
SVG

echo
printf "%s════════════════════════════════════════════════%s\n" "$YEL" "$NC"
if [[ "$OVERALL" == "PASS" ]]; then
  printf "${GREEN}✓ %s certified FideX 1.0 (%s profile)${NC}\n" "$NODE_NAME" "$PROFILE"
else
  printf "${RED}✗ %s NOT compliant. Failed buckets:%s${NC}\n" "$NODE_NAME" "$FAIL_LIST"
fi
echo
echo "Report : $REPORT_JSON"
echo "Badge  : $BADGE_SVG"
echo
[[ "$OVERALL" == "PASS" ]] && exit 0 || exit 1
