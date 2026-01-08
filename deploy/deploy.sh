#!/bin/bash
set -e

# Aori Multichain Deployment Script
# Usage:
#   ./deploy/deploy.sh testnet                    # Dry run deploy on all testnets
#   ./deploy/deploy.sh testnet --broadcast        # Deploy to all testnets
#   ./deploy/deploy.sh testnet --configure-peers  # Configure peers on all testnets
#   ./deploy/deploy.sh testnet --full             # Deploy + configure peers
#   ./deploy/deploy.sh mainnet                    # Dry run deploy on all mainnets
#   ./deploy/deploy.sh mainnet --broadcast        # Deploy to all mainnets
#   ./deploy/deploy.sh mainnet --configure-peers  # Configure peers on all mainnets
#   ./deploy/deploy.sh mainnet --full             # Deploy + configure peers

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Deployment artifacts file
ARTIFACTS_DIR="./deploy/artifacts"
ARTIFACTS_FILE="$ARTIFACTS_DIR/deployment-$(date +%Y%m%d-%H%M%S).json"

# Initialize artifacts JSON
init_artifacts() {
    mkdir -p "$ARTIFACTS_DIR"
    cat > "$ARTIFACTS_FILE" << EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "network": "$NETWORK",
  "deploySalt": "${DEPLOY_SALT:-aori-v1}",
  "deployments": {}
}
EOF
    log "${BLUE}Artifacts will be saved to: $ARTIFACTS_FILE${NC}"
}

# Add deployment to artifacts JSON
# Usage: add_deployment_artifact <chain_name> <proxy_address> <impl_address>
add_deployment_artifact() {
    local chain_name=$1
    local proxy_address=$2
    local impl_address=$3

    # Use jq if available, otherwise use sed
    if command -v jq &> /dev/null; then
        local tmp_file=$(mktemp)
        jq --arg chain "$chain_name" \
           --arg proxy "$proxy_address" \
           --arg impl "$impl_address" \
           '.deployments[$chain] = {"proxy": $proxy, "implementation": $impl, "timestamp": (now | todate)}' \
           "$ARTIFACTS_FILE" > "$tmp_file" && mv "$tmp_file" "$ARTIFACTS_FILE"
    fi
}

# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Error: Missing network argument${NC}"
    echo "Usage: ./deploy/deploy.sh <testnet|mainnet> [--broadcast|--configure-peers|--full] [--quiet]"
    echo ""
    echo "Options:"
    echo "  (none)            Dry run deployment"
    echo "  --broadcast       Deploy contracts to all chains"
    echo "  --configure-peers Configure peers on all chains (requires AORI_PROXY_ADDRESS)"
    echo "  --full            Deploy + configure peers"
    echo "  --quiet           Suppress verbose output (show only summary)"
    exit 1
fi

NETWORK=$1
MODE="dry-run"
BROADCAST=""
VERIFY=""
QUIET=""

# Parse remaining arguments
shift
while [ $# -gt 0 ]; do
    case "$1" in
        "--broadcast")
            MODE="deploy"
            BROADCAST="--broadcast"
            VERIFY="--verify"
            ;;
        "--configure-peers")
            MODE="configure-peers"
            BROADCAST="--broadcast"
            ;;
        "--full")
            MODE="full"
            BROADCAST="--broadcast"
            VERIFY="--verify"
            ;;
        "--upgrade")
            MODE="upgrade"
            BROADCAST="--broadcast"
            VERIFY="--verify"
            ;;
        "--quiet"|"-q")
            QUIET="true"
            ;;
    esac
    shift
done

# Helper function for conditional logging
log() {
    if [ -z "$QUIET" ]; then
        echo -e "$@"
    fi
}

log_always() {
    echo -e "$@"
}

# Define chain RPC environment variables
TESTNET_RPCS=(
    "SEPOLIA_RPC_URL"
    "BASE_SEPOLIA_RPC_URL"
    "ARBITRUM_SEPOLIA_RPC_URL"
    "OPTIMISM_SEPOLIA_RPC_URL"
)

MAINNET_RPCS=(
    "ETHEREUM_RPC_URL"
    "BASE_RPC_URL"
    "ARBITRUM_RPC_URL"
    "OPTIMISM_RPC_URL"
    "BSC_RPC_URL"
    "PLASMA_RPC_URL"
    "MONAD_RPC_URL"
    "STABLE_RPC_URL"
)

# Select chains based on network and export MAINNET for forge scripts
if [ "$NETWORK" == "testnet" ]; then
    RPCS=("${TESTNET_RPCS[@]}")
    export MAINNET=false
elif [ "$NETWORK" == "mainnet" ]; then
    RPCS=("${MAINNET_RPCS[@]}")
    export MAINNET=true
else
    echo -e "${RED}Error: Invalid network '$NETWORK'. Use 'testnet' or 'mainnet'${NC}"
    exit 1
fi

# Check required environment variables
log "${GREEN}=== Checking Environment ===${NC}"

missing_vars=()
for rpc_var in "${RPCS[@]}"; do
    if [ -z "${!rpc_var}" ]; then
        missing_vars+=("$rpc_var")
    fi
done

if [ -z "$PRIVATE_KEY" ]; then
    missing_vars+=("PRIVATE_KEY")
fi

if [ -z "$OWNER_ADDRESS" ]; then
    missing_vars+=("OWNER_ADDRESS")
fi

if ([ "$MODE" == "configure-peers" ] || [ "$MODE" == "upgrade" ]) && [ -z "$AORI_PROXY_ADDRESS" ]; then
    missing_vars+=("AORI_PROXY_ADDRESS")
fi

if [ ${#missing_vars[@]} -ne 0 ]; then
    echo -e "${RED}Error: Missing required environment variables:${NC}"
    for var in "${missing_vars[@]}"; do
        echo "  - $var"
    done
    exit 1
fi

log "Network: $NETWORK"
log "Mode: $MODE"
log "Chains: ${#RPCS[@]}"
log ""

# Warning for broadcast modes
if [ "$MODE" != "dry-run" ]; then
    log_always "${YELLOW}WARNING: Broadcasting transactions to $NETWORK chains${NC}"
    log_always "Press Ctrl+C within 5 seconds to cancel..."
    sleep 5
fi

# Track results
declare -a DEPLOY_SUCCESS
declare -a DEPLOY_FAILED
declare -a PEERS_SUCCESS
declare -a PEERS_FAILED
declare -a UPGRADE_SUCCESS
declare -a UPGRADE_FAILED

# Function to deploy to a chain
deploy_chain() {
    local rpc_var=$1
    local rpc_url="${!rpc_var}"
    local chain_name="${rpc_var%_RPC_URL}"
    chain_name="${chain_name%_URL}"

    log "${GREEN}=== Deploying to $chain_name ===${NC}"
    log "RPC: $rpc_var"

    local forge_quiet=""
    if [ -n "$QUIET" ]; then
        forge_quiet="--quiet"
    fi

    if forge script script/DeployMultichain.s.sol:DeployMultichain \
        --rpc-url "$rpc_url" \
        $BROADCAST $VERIFY $forge_quiet; then
        DEPLOY_SUCCESS+=("$chain_name")
        log "${GREEN}Deploy success: $chain_name${NC}"
        return 0
    else
        DEPLOY_FAILED+=("$chain_name")
        log_always "${RED}Deploy failed: $chain_name${NC}"
        return 1
    fi
}

# Function to configure peers on a chain
configure_peers_chain() {
    local rpc_var=$1
    local rpc_url="${!rpc_var}"
    local chain_name="${rpc_var%_RPC_URL}"
    chain_name="${chain_name%_URL}"

    log "${BLUE}=== Configuring peers on $chain_name ===${NC}"
    log "RPC: $rpc_var"

    local forge_quiet=""
    if [ -n "$QUIET" ]; then
        forge_quiet="--quiet"
    fi

    if forge script script/ConfigurePeers.s.sol:ConfigurePeers \
        --rpc-url "$rpc_url" \
        --broadcast $forge_quiet; then
        PEERS_SUCCESS+=("$chain_name")
        log "${GREEN}Peers configured: $chain_name${NC}"
        return 0
    else
        PEERS_FAILED+=("$chain_name")
        log_always "${RED}Peers failed: $chain_name${NC}"
        return 1
    fi
}

# Function to upgrade on a chain
upgrade_chain() {
    local rpc_var=$1
    local rpc_url="${!rpc_var}"
    local chain_name="${rpc_var%_RPC_URL}"
    chain_name="${chain_name%_URL}"

    log "${YELLOW}=== Upgrading on $chain_name ===${NC}"
    log "RPC: $rpc_var"

    local forge_quiet=""
    if [ -n "$QUIET" ]; then
        forge_quiet="--quiet"
    fi

    if forge script script/UpgradeAori.s.sol:UpgradeMultichain \
        --rpc-url "$rpc_url" \
        $BROADCAST $VERIFY $forge_quiet; then
        UPGRADE_SUCCESS+=("$chain_name")
        log "${GREEN}Upgrade success: $chain_name${NC}"
        return 0
    else
        UPGRADE_FAILED+=("$chain_name")
        log_always "${RED}Upgrade failed: $chain_name${NC}"
        return 1
    fi
}

# Execute based on mode
if [ "$MODE" == "dry-run" ] || [ "$MODE" == "deploy" ] || [ "$MODE" == "full" ]; then
    log "${GREEN}=== Phase 1: Deployment ===${NC}"
    log ""

    # Initialize artifacts file for broadcast mode
    if [ -n "$BROADCAST" ]; then
        init_artifacts
        log ""
    fi

    for rpc_var in "${RPCS[@]}"; do
        deploy_chain "$rpc_var"
        log ""
    done
fi

if [ "$MODE" == "configure-peers" ] || [ "$MODE" == "full" ]; then
    log "${BLUE}=== Phase 2: Configure Peers ===${NC}"
    log ""

    for rpc_var in "${RPCS[@]}"; do
        configure_peers_chain "$rpc_var"
        log ""
    done
fi

if [ "$MODE" == "upgrade" ]; then
    log "${YELLOW}=== Upgrading Contracts ===${NC}"
    log ""

    for rpc_var in "${RPCS[@]}"; do
        upgrade_chain "$rpc_var"
        log ""
    done
fi

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}=== Deployment Summary ===${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Network: $NETWORK"
echo "Mode: $MODE"
if [ -n "$BROADCAST" ] && [ -f "$ARTIFACTS_FILE" ]; then
    echo "Artifacts: $ARTIFACTS_FILE"
fi
echo ""

if [ ${#DEPLOY_SUCCESS[@]} -ne 0 ]; then
    echo -e "${GREEN}Deployments successful (${#DEPLOY_SUCCESS[@]}):${NC}"
    for chain in "${DEPLOY_SUCCESS[@]}"; do
        echo "  ✓ $chain"
    done
    echo ""
fi

if [ ${#DEPLOY_FAILED[@]} -ne 0 ]; then
    echo -e "${RED}Deployments failed (${#DEPLOY_FAILED[@]}):${NC}"
    for chain in "${DEPLOY_FAILED[@]}"; do
        echo "  ✗ $chain"
    done
    echo ""
fi

if [ ${#PEERS_SUCCESS[@]} -ne 0 ]; then
    echo -e "${GREEN}Peers configured (${#PEERS_SUCCESS[@]}):${NC}"
    for chain in "${PEERS_SUCCESS[@]}"; do
        echo "  ✓ $chain"
    done
    echo ""
fi

if [ ${#PEERS_FAILED[@]} -ne 0 ]; then
    echo -e "${RED}Peers failed (${#PEERS_FAILED[@]}):${NC}"
    for chain in "${PEERS_FAILED[@]}"; do
        echo "  ✗ $chain"
    done
    echo ""
fi

if [ ${#UPGRADE_SUCCESS[@]} -ne 0 ]; then
    echo -e "${GREEN}Upgrades successful (${#UPGRADE_SUCCESS[@]}):${NC}"
    for chain in "${UPGRADE_SUCCESS[@]}"; do
        echo "  ✓ $chain"
    done
    echo ""
fi

if [ ${#UPGRADE_FAILED[@]} -ne 0 ]; then
    echo -e "${RED}Upgrades failed (${#UPGRADE_FAILED[@]}):${NC}"
    for chain in "${UPGRADE_FAILED[@]}"; do
        echo "  ✗ $chain"
    done
    echo ""
fi

# Next steps
if [ "$MODE" == "dry-run" ]; then
    echo -e "${YELLOW}This was a dry run. To deploy for real:${NC}"
    echo "  ./deploy/deploy.sh $NETWORK --broadcast"
    echo ""
    echo "To deploy and configure peers in one command:"
    echo "  ./deploy/deploy.sh $NETWORK --full"
fi

if [ "$MODE" == "deploy" ]; then
    echo -e "${YELLOW}IMPORTANT: Peers must be configured for cross-chain messaging!${NC}"
    echo ""
    echo "Set AORI_PROXY_ADDRESS to the deployed proxy address, then run:"
    echo "  AORI_PROXY_ADDRESS=0x... ./deploy/deploy.sh $NETWORK --configure-peers"
    echo ""
    echo "Or run full deployment next time:"
    echo "  ./deploy/deploy.sh $NETWORK --full"
fi

# Exit with error if any failures
if [ ${#DEPLOY_FAILED[@]} -ne 0 ] || [ ${#PEERS_FAILED[@]} -ne 0 ] || [ ${#UPGRADE_FAILED[@]} -ne 0 ]; then
    exit 1
fi

echo -e "${GREEN}All operations completed successfully!${NC}"
