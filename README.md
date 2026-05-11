# Tempo Docker

Docker deployment for a [Tempo](https://docs.tempo.xyz/) Mainnet RPC node. Tempo is an EVM-compatible Layer 1 built on Reth; this repo wraps the upstream `ghcr.io/tempoxyz/tempo` image with the standard `ethd`/`tempod` lifecycle.

- **Network:** Tempo Mainnet
- **Chain ID:** `4217` (`0x1079`)
- **RPC mode:** follow (fetches block ordering from a trusted upstream and re-executes locally)

This is tempo-docker v1.0.0

## Quick Start

```bash
# Clone and enter directory
git clone https://github.com/CryptoManufaktur-io/tempo-docker.git
cd tempo-docker

# Configure
cp default.env .env
vim .env   # set DOMAIN, RPC_HOST, and WS_HOST as needed

# Start the node. First start downloads the archive snapshot when DATA_VOLUME is empty.
./tempod up -d

# Tail logs
./tempod logs -f tempo

# Check sync against the default public Tempo RPC
./tempod check-sync
```

The node runs in **follow mode**: it pulls block ordering from the trusted upstream RPC and re-executes every transaction locally, validating each block. The repo pins follow mode to Tempo's upstream default for mainnet.

## Prerequisites

- Docker Engine 23+ with Compose V2
- Git
- 1000 GB minimum / 2000 GB recommended NVMe for production RPC nodes

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
| `./tempod logs -f tempo` | Follow logs for the tempo node |
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
| `PROJECT_NAME` | Container name prefix | `tempo` |
| `NETWORK` | Network (mainnet only — chain id 4217) | `mainnet` |
| `CHAIN_ID` | Decimal chain ID | `4217` |
| `NODE_DOCKER_REPO` | Docker image repository | `ghcr.io/tempoxyz/tempo` |
| `NODE_DOCKER_TAG` | Docker image tag | `1.6.0` |
| `DATA_VOLUME` | Docker volume for node state | `tempo-data` |
| `SKIP_SNAPSHOT_BOOTSTRAP` | Skip automatic pre-start snapshot bootstrap | `false` |
| `RPC_PORT` | HTTP RPC port | `8545` |
| `WS_PORT` | WebSocket port | `8546` |
| `P2P_PORT` | P2P host/container port | `30303` |
| `BOOTNODES` | Comma-separated Tempo execution bootnodes | pinned defaults |
| `LOG_LEVEL` | Logging verbosity | `info` |
| `SCRIPT_TAG` | Pin repo to git tag | (empty = latest) |

### Data Storage

Node state is stored in a Compose project-prefixed Docker named volume by default, not in the repo checkout. With the production clone dir `tempo`, the default volume is `tempo_tempo-data`. Use `./tempod space` to inspect Docker volume usage.

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
   RPC_HOST=tempo
   WS_HOST=tempows
   ```

## Checking Sync Status

```bash
# Basic sync check (defaults to https://rpc.presto.tempo.xyz)
./tempod check-sync

# With container execution
./tempod check-sync --compose-service tempo

# Custom thresholds
./tempod check-sync --public-rpc https://rpc.example.com --block-lag 10
```

Exit codes:
- `0` - Synced
- `1` - Syncing (behind but catching up)
- `2` - Diverged (possible fork)
- `3-7` - Various errors

## Directory Structure

```
.
├── ethd                    # Canonical CLI script
├── tempod                  # Symlink alias to ethd
├── scripts/
│   └── check_sync.sh       # Sync checker (chain ID, block lag, block hash)
├── default.env             # Default configuration
├── tempo.yml               # Main compose file (download + tempo services)
├── rpc-shared.yml          # Localhost port exposure overlay
└── ext-network.yml         # Traefik / Prometheus overlay
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

Tempo RPC nodes run archive mode by default. The one-time archive snapshot is much smaller than the long-term production storage requirement; size hosts for upstream RPC guidance, not only for the initial extracted snapshot.

### Network Upgrades

Tempo publishes required mainnet releases ahead of activation. Check the upstream release page before rollout or restart work and bump `NODE_DOCKER_TAG` once the required tag is available.

### Logs

```bash
# Recent logs
./tempod logs --tail 100

# Follow specific service
./tempod logs -f tempo

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
