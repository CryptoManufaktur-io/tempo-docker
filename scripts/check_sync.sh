#!/usr/bin/env bash
# =============================================================================
# check_sync.sh - Tempo Node Sync Status Checker
# =============================================================================
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
  --public-rpc URL         Public/reference RPC URL (default: https://rpc.presto.tempo.xyz)
  --block-lag N            Acceptable lag in blocks (default: 5)
  --no-install             Accepted for compatibility; no container installs are performed
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
  ./scripts/check_sync.sh
  ./scripts/check_sync.sh --public-rpc https://rpc.example.com
  ./scripts/check_sync.sh --compose-service tempo
USAGE
}

# =============================================================================
# CONFIGURATION
# =============================================================================

ENV_FILE="${ENV_FILE:-}"
CONTAINER="${CONTAINER:-}"
DOCKER_SERVICE="${DOCKER_SERVICE:-}"
LOCAL_RPC="${LOCAL_RPC:-}"
TEMPO_PUBLIC_RPC_DEFAULT="https://rpc.presto.tempo.xyz"
TEMPO_EXPECTED_CHAIN_ID="0x1079"
REFERENCE_RPC="$TEMPO_PUBLIC_RPC_DEFAULT"
BLOCK_LAG_THRESHOLD="${BLOCK_LAG_THRESHOLD:-5}"
EXPECTED_CHAIN_ID="$TEMPO_EXPECTED_CHAIN_ID"

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

host_http_post() {
  local url="$1"
  local data="$2"
  curl -sS --fail -X POST -H "Content-Type: application/json" -d "$data" "$url"
}

container_http_post() {
  local url="$1"
  local data="$2"
  local host port path

  if [[ "$url" =~ ^http://([^/:]+)(:([0-9]+))?(/.*)?$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[3]:-80}"
    path="${BASH_REMATCH[4]:-/}"
  else
    echo "Container local RPC must use http://host:port/path, got: $url" >&2
    return 1
  fi

  docker exec \
    -e RPC_HOST="$host" \
    -e RPC_PORT="$port" \
    -e RPC_PATH="$path" \
    -e RPC_PAYLOAD="$data" \
    "$CONTAINER" \
    bash -ec '
      exec 3<>"/dev/tcp/${RPC_HOST}/${RPC_PORT}"
      printf "POST %s HTTP/1.1\r\nHost: %s\r\nContent-Type: application/json\r\nContent-Length: %s\r\nConnection: close\r\n\r\n%s" \
        "${RPC_PATH}" "${RPC_HOST}" "${#RPC_PAYLOAD}" "${RPC_PAYLOAD}" >&3
      cat <&3
    ' | awk 'body { print } /^\r?$/ { body = 1 }'
}

local_http_post() {
  local data="$1"
  if [[ -n "$CONTAINER" ]]; then
    container_http_post "$LOCAL_RPC" "$data"
  else
    host_http_post "$LOCAL_RPC" "$data"
  fi
}

public_http_post() {
  local data="$1"
  host_http_post "$REFERENCE_RPC" "$data"
}

jq_eval() {
  jq -r "$1"
}

# =============================================================================
# PROTOCOL-SPECIFIC SYNC CHECK
# =============================================================================

# -----------------------------------------------------------------------------
# ETH JSON-RPC variant — Tempo is a Reth-based EVM L1
# -----------------------------------------------------------------------------
check_eth_sync() {
  echo "==> Checking Tempo execution layer sync status"

  local chain_id_response chain_id
  if ! chain_id_response=$(local_http_post '{"jsonrpc":"2.0","method":"eth_chainId","params":[],"id":1}'); then
    echo "Failed to query local eth_chainId"
    exit 3
  fi
  chain_id=$(echo "$chain_id_response" | jq_eval '.result // empty')
  if [[ "$chain_id" != "$EXPECTED_CHAIN_ID" ]]; then
    echo "Unexpected local chain ID: ${chain_id:-<empty>} (expected: $EXPECTED_CHAIN_ID)"
    exit 3
  fi
  echo "Chain ID:     $chain_id"

  # Check if node reports syncing
  local sync_response sync_status
  if ! sync_response=$(local_http_post '{"jsonrpc":"2.0","method":"eth_syncing","params":[],"id":1}'); then
    echo "Failed to query local eth_syncing"
    exit 3
  fi
  sync_status=$(echo "$sync_response" | jq_eval '.result')

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
  local local_hex public_hex local_block_response public_block_response
  if ! local_block_response=$(local_http_post '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'); then
    echo "Failed to query local eth_blockNumber"
    exit 3
  fi
  if ! public_block_response=$(public_http_post '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}'); then
    echo "Failed to query public eth_blockNumber"
    exit 4
  fi
  local_hex=$(echo "$local_block_response" | jq_eval '.result')
  public_hex=$(echo "$public_block_response" | jq_eval '.result')

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
  local compare_block compare_hex local_hash public_hash local_hash_response public_hash_response

  if (( local_block < public_block )); then
    compare_block=$local_block
  else
    compare_block=$public_block
  fi
  compare_hex=$(printf '0x%x' "$compare_block")
  if ! local_hash_response=$(local_http_post "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$compare_hex\",false],\"id\":1}"); then
    echo "Failed to query local block hash at $compare_hex"
    exit 3
  fi
  if ! public_hash_response=$(public_http_post "{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"$compare_hex\",false],\"id\":1}"); then
    echo "Failed to query public block hash at $compare_hex"
    exit 4
  fi
  local_hash=$(echo "$local_hash_response" | jq_eval '.result.hash // empty')
  public_hash=$(echo "$public_hash_response" | jq_eval '.result.hash // empty')

  if [[ -z "$local_hash" || "$local_hash" == "null" ]]; then
    echo "Failed to get local block hash at $compare_hex"
    exit 3
  fi
  if [[ -z "$public_hash" || "$public_hash" == "null" ]]; then
    echo "Failed to get public block hash at $compare_hex"
    exit 4
  fi

  echo "Local block:  $local_block"
  echo "Public block: $public_block"
  echo "Lag:          $lag blocks (threshold: $BLOCK_LAG_THRESHOLD)"
  echo "Hash check:   block $compare_block"

  if [[ "$local_hash" != "$public_hash" ]]; then
    echo "Diverged: local/public hashes differ at block $compare_block"
    echo "Local hash:   $local_hash"
    echo "Public hash:  $public_hash"
    exit 2
  fi

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
#   public_status=$(http_get "${REFERENCE_RPC}/status")
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
REFERENCE_RPC="$TEMPO_PUBLIC_RPC_DEFAULT"
EXPECTED_CHAIN_ID="$TEMPO_EXPECTED_CHAIN_ID"

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --container|--compose-service|--local-rpc|--public-rpc|--block-lag|--env-file)
      if [[ $# -lt 2 ]]; then echo "Error: $1 requires a value"; exit 5; fi
      ;;&
    --container) CONTAINER="$2"; shift 2 ;;
    --compose-service) DOCKER_SERVICE="$2"; shift 2 ;;
    --local-rpc) LOCAL_RPC="$2"; shift 2 ;;
    --public-rpc) REFERENCE_RPC="$2"; shift 2 ;;
    --block-lag) BLOCK_LAG_THRESHOLD="$2"; shift 2 ;;
    --no-install) shift ;;
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
REFERENCE_RPC="${REFERENCE_RPC:-$TEMPO_PUBLIC_RPC_DEFAULT}"

# Resolve container from service name
resolve_container

# Check dependencies. Public RPC and JSON parsing always run from the host.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "curl and jq are required on the host."
  exit 6
fi
if [[ -n "$CONTAINER" ]] && ! command -v docker >/dev/null 2>&1; then
  echo "docker is required when --container or --compose-service is set."
  exit 7
fi

# =============================================================================
# RUN SYNC CHECK
# =============================================================================
# Uncomment the appropriate variant for your protocol:

# Tempo is a Reth-based EVM L1 — use the ETH JSON-RPC variant.
check_eth_sync
