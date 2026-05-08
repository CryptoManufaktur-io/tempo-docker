#!/usr/bin/env bash
# =============================================================================
# check_sync.sh - Node Sync Status Checker Template
# =============================================================================
# This is a stub template. Customize for your protocol's sync check method.
#
# Exit codes:
#   0 - Node is synced
#   1 - Node is syncing (behind but catching up)
#   2 - Node is diverged (hash mismatch at same height)
#   3 - Local RPC error
#   4 - Public RPC error
#   5 - Configuration error
#   6 - Tool dependency error (curl/jq missing)
#   7 - Container error
#
# Protocol variants:
#   - ETH JSON-RPC: Uses eth_syncing, eth_blockNumber
#   - Tendermint/Cosmos: Uses /status endpoint
#   - Beacon Chain: Uses /eth/v1/node/syncing
# =============================================================================

set -euo pipefail

# =============================================================================
# USAGE
# =============================================================================

usage() {
  cat <<'USAGE'
Usage: check_sync.sh [options]

Options:
  --container NAME         Docker container name or ID to run curl/jq within
  --compose-service NAME   Docker Compose service name to resolve to a container
  --local-rpc URL          Local RPC URL (default: http://127.0.0.1:8545)
  --public-rpc URL         Public/reference RPC URL (required)
  --block-lag N            Acceptable lag in blocks (default: 5)
  --no-install             Do not install curl/jq inside the container
  --env-file PATH          Path to env file to load
  -h, --help               Show this help

Exit Codes:
  0 - Synced (heights match within threshold)
  1 - Syncing (behind public RPC)
  2 - Diverged (hash mismatch)
  3 - Local RPC error
  4 - Public RPC error
  5 - Configuration error
  6 - Missing dependencies
  7 - Container error

Examples:
  ./scripts/check_sync.sh --public-rpc https://rpc.example.com
  ./scripts/check_sync.sh --compose-service node --public-rpc https://rpc.example.com
USAGE
}

# =============================================================================
# CONFIGURATION
# =============================================================================

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
PUBLIC_RPC="${PUBLIC_RPC:-}"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-5}"
INSTALL_TOOLS="${INSTALL_TOOLS:-1}"

# =============================================================================
# HELPERS
# =============================================================================

load_env_file() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    line="${line#export }"
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      local key="${line%%=*}"
      local val="${line#*=}"
      val="${val#"${val%%[![:space:]]*}"}"
      if [[ "$val" =~ ^\".*\"$ ]]; then
        val="${val:1:-1}"
      elif [[ "$val" =~ ^\'.*\'$ ]]; then
        val="${val:1:-1}"
      fi
      export "${key}=${val}"
    fi
  done < "$file"
}

resolve_container() {
  if [[ -n "$CONTAINER" || -z "$DOCKER_SERVICE" ]]; then
    return 0
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "docker not found; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 7
  fi
  if docker compose version >/dev/null 2>&1; then
    CONTAINER="$(docker compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  elif command -v docker-compose >/dev/null 2>&1; then
    CONTAINER="$(docker-compose ps -q "$DOCKER_SERVICE" | head -n 1)"
  else
    echo "docker compose not available; cannot resolve --compose-service $DOCKER_SERVICE"
    exit 7
  fi
  if [[ -z "$CONTAINER" ]]; then
    echo "No running container found for service: $DOCKER_SERVICE"
    exit 7
  fi
}

http_get() {
  local url="$1"
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" curl -sS "$url"
  else
    curl -sS "$url"
  fi
}

http_post() {
  local url="$1"
  local data="$2"
  if [[ -n "$CONTAINER" ]]; then
    docker exec "$CONTAINER" curl -sS -X POST -H "Content-Type: application/json" -d "$data" "$url"
  else
    curl -sS -X POST -H "Content-Type: application/json" -d "$data" "$url"
  fi
}

jq_eval() {
  if [[ -n "$CONTAINER" ]]; then
    docker exec -i "$CONTAINER" jq -r "$1"
  else
    jq -r "$1"
  fi
}

install_tools_in_container() {
  if [[ -z "$CONTAINER" || "$INSTALL_TOOLS" != "1" ]]; then
    return 0
  fi
  echo "==> Ensuring curl and jq are installed inside container"
  docker exec -u root "$CONTAINER" sh -c '
    set -e
    if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
      exit 0
    fi
    if command -v apt-get >/dev/null 2>&1; then
      apt-get update -y >/dev/null
      apt-get install -y curl jq ca-certificates >/dev/null
    elif command -v apk >/dev/null 2>&1; then
      apk add --no-cache curl jq ca-certificates >/dev/null
    else
      echo "Unsupported base image. No apt-get or apk found."
      exit 1
    fi
  '
}

# =============================================================================
# PROTOCOL-SPECIFIC SYNC CHECK
# =============================================================================

# -----------------------------------------------------------------------------
# ETH JSON-RPC variant — Tempo is a Reth-based EVM L1
# -----------------------------------------------------------------------------
check_eth_sync() {
  echo "==> Checking Tempo execution layer sync status"

  # Check if node reports syncing
  local sync_status
  sync_status=$(http_post "$LOCAL_RPC" '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}' | jq_eval '.result')

  if [[ "$sync_status" != "false" && "$sync_status" != "null" ]]; then
    local current_block highest_block
    current_block=$(echo "$sync_status" | jq_eval '.currentBlock // empty')
    highest_block=$(echo "$sync_status" | jq_eval '.highestBlock // empty')
    if [[ -n "$current_block" && -n "$highest_block" ]]; then
      echo "Node is syncing: $((16#${current_block#0x})) / $((16#${highest_block#0x}))"
    else
      echo "Node reports syncing"
    fi
    exit 1
  fi

  # Get local and public block numbers
  local local_hex public_hex
  local_hex=$(http_post "$LOCAL_RPC" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq_eval '.result')
  public_hex=$(http_post "$PUBLIC_RPC" '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' | jq_eval '.result')

  if [[ -z "$local_hex" || "$local_hex" == "null" ]]; then
    echo "Failed to get local block number"
    exit 3
  fi
  if [[ -z "$public_hex" || "$public_hex" == "null" ]]; then
    echo "Failed to get public block number"
    exit 4
  fi

  local local_block=$((16#${local_hex#0x}))
  local public_block=$((16#${public_hex#0x}))
  local lag=$((public_block - local_block))

  echo "Local block:  $local_block"
  echo "Public block: $public_block"
  echo "Lag:          $lag blocks (threshold: $BLOCK_LAG_THRESHOLD)"

  if (( lag <= BLOCK_LAG_THRESHOLD && lag >= -BLOCK_LAG_THRESHOLD )); then
    echo "Node is synced"
    exit 0
  elif (( lag > BLOCK_LAG_THRESHOLD )); then
    echo "Node is syncing (behind by $lag blocks)"
    exit 1
  else
    echo "Node is ahead of public RPC (public may be lagging)"
    exit 0
  fi
}

# -----------------------------------------------------------------------------
# Tendermint/Cosmos variant
# Uncomment and use this for Cosmos SDK chains
# -----------------------------------------------------------------------------
# check_tendermint_sync() {
#   echo "==> Checking Tendermint sync status"
#
#   local local_status public_status
#   local_status=$(http_get "${LOCAL_RPC}/status")
#   public_status=$(http_get "${PUBLIC_RPC}/status")
#
#   local local_height public_height local_catching_up local_hash public_hash
#   local_height=$(echo "$local_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height')
#   public_height=$(echo "$public_status" | jq_eval '.result.sync_info.latest_block_height // .sync_info.latest_block_height')
#   local_catching_up=$(echo "$local_status" | jq_eval '.result.sync_info.catching_up // .sync_info.catching_up')
#   local_hash=$(echo "$local_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')
#   public_hash=$(echo "$public_status" | jq_eval '.result.sync_info.latest_block_hash // .sync_info.latest_block_hash')
#
#   if [[ -z "$local_height" || "$local_height" == "null" ]]; then
#     echo "Failed to get local block height"
#     exit 3
#   fi
#   if [[ -z "$public_height" || "$public_height" == "null" ]]; then
#     echo "Failed to get public block height"
#     exit 4
#   fi
#
#   local lag=$((public_height - local_height))
#
#   echo "Local height:  $local_height"
#   echo "Public height: $public_height"
#   echo "Lag:           $lag blocks (threshold: $BLOCK_LAG_THRESHOLD)"
#   echo "Catching up:   $local_catching_up"
#
#   if [[ "$local_catching_up" == "true" ]]; then
#     echo "Node reports catching_up=true"
#     exit 1
#   fi
#
#   if [[ "$local_height" == "$public_height" && "$local_hash" == "$public_hash" ]]; then
#     echo "Node is synced (height and hash match)"
#     exit 0
#   fi
#
#   if [[ "$local_height" == "$public_height" && "$local_hash" != "$public_hash" ]]; then
#     echo "Heights match but hashes differ - possible fork"
#     exit 2
#   fi
#
#   if (( lag > BLOCK_LAG_THRESHOLD )); then
#     echo "Node is syncing (behind by $lag blocks)"
#     exit 1
#   fi
#
#   echo "Node is synced (within threshold)"
#   exit 0
# }

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

# Pre-parse for --env-file
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--env-file" ]]; then
    ENV_FILE="${args[$((i+1))]:-}"
  fi
done

# Load env file
if [[ -n "${ENV_FILE:-}" ]]; then
  load_env_file "$ENV_FILE"
elif [[ -f ".env" ]]; then
  load_env_file ".env"
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|--compose-service|--local-rpc|--public-rpc|--block-lag|--env-file)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value"; exit 5; fi
      ;;&
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) PUBLIC_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) INSTALL_TOOLS="0"; shift ;;
    --env-file) shift 2 ;;  # Already handled
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 5 ;;
  esac
done

# =============================================================================
# MAIN
# =============================================================================

# Set defaults
LOCAL_RPC="${LOCAL_RPC:-http://127.0.0.1:${RPC_PORT:-8545}}"
PUBLIC_RPC="${PUBLIC_RPC:-}"

# Validate required params
if [[ -z "$PUBLIC_RPC" ]]; then
  echo "PUBLIC_RPC is required. Use --public-rpc or set PUBLIC_RPC."
  exit 5
fi

# Resolve container from service name
resolve_container

# Check host dependencies (if not using container)
if [[ -z "$CONTAINER" ]]; then
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    echo "curl and jq are required on the host when no --container is set."
    exit 6
  fi
else
  install_tools_in_container
fi

# =============================================================================
# RUN SYNC CHECK
# =============================================================================
# Uncomment the appropriate variant for your protocol:

# Tempo is a Reth-based EVM L1 — use the ETH JSON-RPC variant.
check_eth_sync
