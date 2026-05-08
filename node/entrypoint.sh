#!/usr/bin/env bash
# =============================================================================
# Docker Entrypoint Script Template
# =============================================================================
# This script runs before the main process starts.
# Use it to:
#   - Set up data directories
#   - Initialize configuration files
#   - Handle environment variable expansion
#   - Perform health checks before starting
# =============================================================================

set -euo pipefail

# =============================================================================
# CONFIGURATION
# =============================================================================

DATA_DIR="${DATA_DIR:-/data}"
LOG_LEVEL="${LOG_LEVEL:-info}"
NETWORK="${NETWORK:-mainnet}"

# =============================================================================
# INITIALIZATION
# =============================================================================

# Init-once flag: prevent re-initialization on container restart.
# This is critical for snapshot restores — you don't want to re-download
# hundreds of GBs every time the container restarts.
if [[ ! -f "${DATA_DIR}/.initialized" ]]; then
    echo "First run — initializing node..."

    # Ensure data directory exists
    if [[ ! -d "${DATA_DIR}" ]]; then
        mkdir -p "${DATA_DIR}"
    fi

    # Initialize config if not present
    # Example for Cosmos chains:
    # if [[ ! -f "${DATA_DIR}/config/config.toml" ]]; then
    #     echo "Initializing node configuration..."
    #     node init --home "${DATA_DIR}"
    # fi

    touch "${DATA_DIR}/.initialized"
fi

# =============================================================================
# NETWORK-SPECIFIC SETUP
# =============================================================================

case "${NETWORK}" in
    mainnet)
        echo "Configuring for mainnet..."
        # CHAIN_ID="mainnet-1"
        # GENESIS_URL="https://example.com/mainnet/genesis.json"
        ;;
    testnet)
        echo "Configuring for testnet..."
        # CHAIN_ID="testnet-1"
        # GENESIS_URL="https://example.com/testnet/genesis.json"
        ;;
    *)
        echo "ERROR: Unknown network: ${NETWORK}"
        echo "Supported networks: mainnet, testnet"
        exit 1
        ;;
esac

# Download genesis if not present
# if [ -n "${GENESIS_URL}" ] && [ ! -f "${DATA_DIR}/config/genesis.json" ]; then
#     echo "Downloading genesis file..."
#     curl -fsSL "${GENESIS_URL}" -o "${DATA_DIR}/config/genesis.json"
# fi

# =============================================================================
# START NODE
# =============================================================================

echo "Starting node..."
echo "  Data dir: ${DATA_DIR}"
echo "  Network:  ${NETWORK}"
echo "  Log level: ${LOG_LEVEL}"

# Execute the main command (passed as arguments to this script)
# EXTRA_FLAGS allows users to pass additional flags via environment variable.
# Word splitting is intentional so "EXTRA_FLAGS=--flag1 --flag2" expands correctly.
if [[ $# -eq 0 ]]; then
    echo "No command provided, using default..."
    # shellcheck disable=SC2086
    # exec node --data-dir="${DATA_DIR}" --log-level="${LOG_LEVEL}" ${EXTRA_FLAGS:-}
    exec sleep infinity  # Placeholder - replace with actual command
else
    # shellcheck disable=SC2086
    exec "$@" ${EXTRA_FLAGS:-}
fi
