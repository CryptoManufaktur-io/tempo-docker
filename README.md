# Tempo Docker

Docker deployment for a [Tempo](https://docs.tempo.xyz/) Mainnet RPC node. Tempo is an EVM-compatible Layer 1 built on Reth; this repo wraps the upstream `ghcr.io/tempoxyz/tempo` image with the standard `ethd`/`tempod` lifecycle.

This is tempo-docker v1.0.0

## Quick Start

```bash
# Clone and enter directory
git clone https://github.com/your-org/tempo-docker.git
cd tempo-docker

# Configure
cp default.env .env
vim .env   # set DOMAIN, RPC_HOST, WS_HOST, MONIKER as needed

# One-time bootstrap: download the archive snapshot (this populates DATA_DIR)
./tempod up download

# Start the node
./tempod up -d

# Tail logs
./tempod logs -f tempo

# Check sync against a trusted public Tempo RPC
./tempod check-sync --compose-service tempo --public-rpc <trusted-tempo-rpc>
```

The node runs in **follow mode**: it pulls block ordering from the trusted upstream RPC and re-executes every transaction locally, validating each block.

## Prerequisites

- Docker Engine 23+ with Compose V2
- Git
- 50+ GiB free disk space (varies by protocol)

### Installing Docker

```bash
# On Debian/Ubuntu, ethd can install Docker for you:
./tempod install
```

## Command Reference

| Command | Description |
|---------|-------------|
| `./tempod up` | Start the node |
| `./tempod down` | Stop the node |
| `./tempod restart` | Restart the node |
| `./tempod logs -f` | Follow logs (Ctrl+C to exit) |
| `./tempod logs -f node` | Follow logs for specific service |
| `./tempod update` | Update images and configuration |
| `./tempod check-sync` | Check sync status against public RPC |
| `./tempod version` | Show client versions |
| `./tempod space` | Show disk space usage |
| `./tempod terminate` | Stop and delete all data (destructive!) |
| `./tempod cmd <args>` | Run arbitrary docker compose command |
| `./tempod help` | Show full help |

Most production `*-docker` repos keep `ethd` as the canonical script and add a protocol alias symlink (for example `injectived -> ethd`).

### Update Options

```bash
./tempod update                    # Standard update
./tempod update --refresh-targets  # Reset image tags to defaults
./tempod update --non-interactive  # No prompts (for automation)
./tempod update --debug            # Debug mode for CI
```

## Configuration

### Environment Variables

Edit `.env` to customize your deployment. Key variables:

| Variable | Description | Default |
|----------|-------------|---------|
| `COMPOSE_FILE` | Compose files to use (colon-separated) | `tempo.yml` |
| `PROJECT_NAME` | Container name prefix | `project` |
| `NETWORK` | Network to connect to | `mainnet` |
| `NODE_DOCKER_REPO` | Docker image repository | `example/node` |
| `NODE_DOCKER_TAG` | Docker image tag | `latest` |
| `DATA_DIR` | Data directory path | `./data` |
| `RPC_PORT` | HTTP RPC port | `8545` |
| `WS_PORT` | WebSocket port | `8546` |
| `LOG_LEVEL` | Logging verbosity | `info` |
| `SCRIPT_TAG` | Pin repo to git tag | (empty = latest) |

### Compose File Overlays

Add overlays to `COMPOSE_FILE` in `.env`:

```bash
# Expose RPC ports locally
COMPOSE_FILE=tempo.yml:rpc-shared.yml

# Connect to external Traefik network
COMPOSE_FILE=tempo.yml:ext-network.yml

# Both
COMPOSE_FILE=tempo.yml:rpc-shared.yml:ext-network.yml

# Custom overrides (create custom.yml, not tracked by git)
COMPOSE_FILE=tempo.yml:custom.yml
```

### Traefik Integration

For secure web proxy with Traefik:

1. Add `:ext-network.yml` to `COMPOSE_FILE`
2. Configure in `.env`:
   ```bash
   DOCKER_EXT_NETWORK=traefik_default
   DOMAIN=example.com
   RPC_HOST=mynode
   ```
3. Uncomment Traefik labels in `tempo.yml`

## Checking Sync Status

```bash
# Basic sync check (requires --public-rpc)
./tempod check-sync --public-rpc https://rpc.example.com

# With container execution
./tempod check-sync --compose-service node --public-rpc https://rpc.example.com

# Custom thresholds
./tempod check-sync --public-rpc https://rpc.example.com --block-lag 10
```

Exit codes:
- `0` - Synced
- `1` - Syncing (behind but catching up)
- `2` - Diverged (possible fork)
- `3-7` - Various errors

## Customization Guide

When using this template for a new protocol:

### 1. Rename Files and Core Vars

```bash
# Rename compose file
mv tempo.yml myprotocol.yml

# Then edit default.env:
# COMPOSE_FILE=myprotocol.yml
# PROJECT_NAME=myprotocol
```

### 2. Create Protocol Alias Script

```bash
ln -s ethd myprotocold
```

### 3. Update ethd

Edit the header variables:

```bash
__project_name="MyProtocol Docker"
__app_name="MyProtocol node"
__sample_service="myprotocol"
```

Also customize these functions in `ethd`:

- **`version()`** — Add commands to report client versions
- **`__prep_conffiles()`** — Config file setup before start
- **`start()`** — Modify if you need screen-based startup for long init
- **`__env_migrate()`** — Add `__old_vars`/`__new_vars` for variable renames

### 4. Configure Services

Edit your renamed compose file:
- Update service name from `node` to protocol-specific (e.g., `op-node`)
- Set actual Docker image, command, and environment
- Configure port mappings and volume mounts
- Uncomment and customize health checks
- Add additional services if needed (e.g., execution + consensus layer)

### 5. Implement Sync Check

Edit `scripts/check_sync.sh` and uncomment the appropriate variant:

| Protocol Type | Function | RPC Pattern |
|--------------|----------|-------------|
| EVM (geth, reth, op-geth) | `check_eth_sync()` | JSON-RPC `eth_syncing`, `eth_blockNumber` |
| Cosmos/Tendermint | `check_tendermint_sync()` | REST `/status` endpoint |
| Custom | Implement your own | Follow exit code conventions below |

### 6. Configure default.env

Update protocol-specific variables and add new ones as needed. Keep `ENV_VERSION` updated when adding or renaming variables.

## Directory Structure

```
.
├── ethd                    # Canonical CLI script
├── <protocol>d             # Optional symlink alias to ethd
├── scripts/
│   └── check_sync.sh       # Sync checker
├── node/                   # Dockerfile templates
│   ├── Dockerfile.binary   # For pre-built binaries
│   ├── Dockerfile.source   # For source builds
│   └── entrypoint.sh       # Entrypoint template
├── default.env             # Default configuration
├── tempo.yml             # Main compose file (rename to <protocol>.yml)
├── ext-network.yml         # External network overlay
├── rpc-shared.yml          # Local RPC exposure
├── .env                    # Your configuration (git-ignored)
├── .gitignore              # Git ignore rules
├── .pre-commit-config.yaml # Pre-commit hooks
└── data/                   # Node data (git-ignored)
```

## Troubleshooting

### Pre-commit

```bash
pre-commit install
pre-commit run --all-files
```

### Docker Issues

```bash
# Check Docker status
sudo systemctl status docker

# Check if user is in docker group
groups | grep docker

# Fix permissions
sudo usermod -aG docker $USER
newgrp docker
```

### Disk Space

```bash
# Check space usage
./tempod space

# Prune unused Docker data
docker system prune -a
```

### Logs

```bash
# Recent logs
./tempod logs --tail 100

# Follow specific service
./tempod logs -f node

# Save logs to file
./tempod logs > node.log 2>&1
```

### Update Issues

If update fails mid-migration:
- Original config saved to `.env.bak`
- Partial migration saved to `.env.partial`
- Restore with: `cp .env.bak .env`

## License

Apache 2.0 - See [LICENSE](LICENSE)
