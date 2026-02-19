#!/bin/bash
# Note: Not using set -e to allow continuing after individual chain failures

# Load .env file if it exists
if [ -f .env ]; then
    set -a
    source .env
    set +a
fi

# Aori Multichain Deployment & Upgrade Script
# Usage:
#   ./deploy/deploy.sh testnet                           # Dry run deploy on all testnets
#   ./deploy/deploy.sh testnet --broadcast               # Deploy to all testnets
#   ./deploy/deploy.sh testnet --configure-peers         # Configure peers on all testnets
#   ./deploy/deploy.sh testnet --full                    # Deploy + configure peers
#   ./deploy/deploy.sh mainnet                           # Dry run deploy on all mainnets
#   ./deploy/deploy.sh mainnet --broadcast               # Deploy to all mainnets
#   ./deploy/deploy.sh mainnet --configure-peers         # Configure peers on all mainnets
#   ./deploy/deploy.sh mainnet --full                    # Deploy + configure peers
#   ./deploy/deploy.sh mainnet --upgrade                 # Dry run upgrade on all mainnets
#   ./deploy/deploy.sh mainnet --upgrade --broadcast     # Upgrade all mainnets for real

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color


# Check arguments
if [ -z "$1" ]; then
    echo -e "${RED}Error: Missing network argument${NC}"
    echo "Usage: ./deploy/deploy.sh <testnet|mainnet> [--broadcast|--configure-peers|--full|--upgrade] [--quiet]"
    echo ""
    echo "Options:"
    echo "  (none)                 Dry run deployment"
    echo "  --broadcast            Deploy contracts to all chains"
    echo "  --configure-peers      Configure peers on all chains (requires AORI_PROXY_ADDRESS)"
    echo "  --full                 Deploy + configure peers"
    echo "  --upgrade              Dry run upgrade on all chains (requires AORI_PROXY_ADDRESS)"
    echo "  --upgrade --broadcast  Upgrade contracts on all chains for real"
    echo "  --quiet                Suppress verbose output (show only summary)"
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
            BROADCAST="--broadcast"
            VERIFY="--verify"
            # Only set MODE to deploy if no other mode was already set
            if [ "$MODE" == "dry-run" ]; then
                MODE="deploy"
            fi
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
            ;;
        "--quiet"|"-q")
            QUIET="true"
            ;;
    esac
    shift
done

# Upgrade dry-run: if upgrade mode but no broadcast flag, it's a dry run
if [ "$MODE" == "upgrade" ] && [ -z "$BROADCAST" ]; then
    MODE="upgrade-dry-run"
fi

# Helper function for conditional logging
log() {
    if [ -z "$QUIET" ]; then
        echo -e "$@"
    fi
}

log_always() {
    echo -e "$@"
}

# Helper to extract chain name from RPC var (e.g., "ETHEREUM_RPC_URL" -> "ETHEREUM")
get_chain_name() {
    local rpc_var=$1
    local name="${rpc_var%_RPC_URL}"
    echo "${name%_URL}"
}

# Helper to get address entry for a chain from DEPLOYED_ADDRESSES array
get_chain_addresses() {
    local target_chain=$1
    for entry in "${DEPLOYED_ADDRESSES[@]}"; do
        if [ "${entry%%|*}" == "$target_chain" ]; then
            echo "$entry"
            return
        fi
    done
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

# OWNER_ADDRESS and DEPLOY_SALT only needed for deploy modes, not upgrades
if [ "$MODE" != "upgrade" ] && [ "$MODE" != "upgrade-dry-run" ]; then
    if [ -z "$OWNER_ADDRESS" ]; then
        missing_vars+=("OWNER_ADDRESS")
    fi

    if [ -z "$DEPLOY_SALT" ]; then
        missing_vars+=("DEPLOY_SALT")
    fi
fi

# AORI_PROXY_ADDRESS required for configure-peers and upgrade (but not for --full, we compute it)
if ([ "$MODE" == "configure-peers" ] || [ "$MODE" == "upgrade" ] || [ "$MODE" == "upgrade-dry-run" ]) && [ -z "$AORI_PROXY_ADDRESS" ]; then
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

# Set forge quiet flag once (used by all functions)
FORGE_QUIET=""
if [ -n "$QUIET" ]; then
    FORGE_QUIET="--quiet"
fi

# Track results
DEPLOY_SUCCESS=()
DEPLOY_FAILED=()
DEPLOY_SKIPPED=()
PEERS_SUCCESS=()
PEERS_FAILED=()
UPGRADE_SUCCESS=()
UPGRADE_FAILED=()

# Store deployed addresses (chain|proxy|impl format)
DEPLOYED_ADDRESSES=()

# Function to deploy to a chain
deploy_chain() {
    local rpc_var=$1
    local rpc_url="${!rpc_var}"
    local chain_name=$(get_chain_name "$rpc_var")

    log "${GREEN}=== Deploying to $chain_name ===${NC}"
    log "RPC: $rpc_var"

    # Capture output to parse addresses
    local output
    local exit_code=0
    output=$(forge script script/DeployMultichain.s.sol:DeployMultichain \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        $BROADCAST $VERIFY $FORGE_QUIET 2>&1) || exit_code=$?

    if [ $exit_code -eq 0 ]; then
        # Check if skipped
        if echo "$output" | grep -q "SKIPPING: Already Deployed"; then
            DEPLOY_SKIPPED+=("$chain_name")
            # Parse the existing proxy address
            local proxy_addr=$(echo "$output" | grep -E "Proxy already exists at:" | awk '{print $NF}')
            DEPLOYED_ADDRESSES+=("$chain_name|$proxy_addr|skipped")
            log "${YELLOW}Skipped (already deployed): $chain_name${NC}"
        else
            DEPLOY_SUCCESS+=("$chain_name")
            # Parse addresses from output
            local proxy_addr=$(echo "$output" | grep -E "Proxy \(Aori\):|Proxy.*deployed.*at:" | tail -1 | awk '{print $NF}')
            local impl_addr=$(echo "$output" | grep -E "Implementation:" | tail -1 | awk '{print $NF}')
            DEPLOYED_ADDRESSES+=("$chain_name|$proxy_addr|$impl_addr")
            log "${GREEN}Deploy success: $chain_name${NC}"
        fi
        return 0
    else
        DEPLOY_FAILED+=("$chain_name")
        log_always "${RED}Deploy failed: $chain_name${NC}"
        if [ -z "$QUIET" ]; then
            echo "$output" | tail -20
        fi
        return 1
    fi
}

# Function to configure peers on a chain
configure_peers_chain() {
    local rpc_var=$1
    local rpc_url="${!rpc_var}"
    local chain_name=$(get_chain_name "$rpc_var")

    log "${BLUE}=== Configuring peers on $chain_name ===${NC}"
    log "RPC: $rpc_var"

    if forge script script/ConfigurePeers.s.sol:ConfigurePeers \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        --broadcast $FORGE_QUIET; then
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
    local chain_name=$(get_chain_name "$rpc_var")

    log "${YELLOW}=== Upgrading on $chain_name ===${NC}"
    log "RPC: $rpc_var"

    if forge script script/UpgradeAori.s.sol:UpgradeMultichain \
        --rpc-url "$rpc_url" \
        --private-key "$PRIVATE_KEY" \
        $BROADCAST $VERIFY $FORGE_QUIET; then
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


    for rpc_var in "${RPCS[@]}"; do
        deploy_chain "$rpc_var" || true
        log ""
    done
fi

if [ "$MODE" == "configure-peers" ] || [ "$MODE" == "full" ]; then
    log "${BLUE}=== Phase 2: Configure Peers ===${NC}"
    log ""

    # For --full mode, use the proxy address from phase 1 deployment
    if [ "$MODE" == "full" ] && [ -z "$AORI_PROXY_ADDRESS" ]; then
        if [ ${#DEPLOYED_ADDRESSES[@]} -gt 0 ]; then
            # Use the proxy address from first successful deployment
            first_entry="${DEPLOYED_ADDRESSES[0]}"
            PROXY_ADDR=$(echo "$first_entry" | cut -d'|' -f2)
            export AORI_PROXY_ADDRESS="$PROXY_ADDR"
            log "Using proxy address from deployment: $AORI_PROXY_ADDRESS"
        else
            log_always "${RED}Error: No deployments completed, cannot configure peers${NC}"
            exit 1
        fi
        log ""
    fi

    for rpc_var in "${RPCS[@]}"; do
        configure_peers_chain "$rpc_var" || true
        log ""
    done
fi

if [ "$MODE" == "upgrade" ] || [ "$MODE" == "upgrade-dry-run" ]; then
    if [ "$MODE" == "upgrade-dry-run" ]; then
        log "${YELLOW}=== Upgrade Dry Run (simulation only) ===${NC}"
    else
        log "${YELLOW}=== Upgrading Contracts ===${NC}"
    fi
    log ""

    for rpc_var in "${RPCS[@]}"; do
        upgrade_chain "$rpc_var" || true
        log ""
    done
fi

# Summary
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}=== Deployment Summary ===${NC}"
echo -e "${GREEN}========================================${NC}"
echo "Network: $NETWORK"
echo "Mode: $MODE"
if [ -n "$BROADCAST" ]; then
    echo "Artifacts: broadcast/"
fi
echo ""

if [ ${#DEPLOY_SUCCESS[@]} -ne 0 ]; then
    echo -e "${GREEN}Deployments successful (${#DEPLOY_SUCCESS[@]}):${NC}"
    for chain in "${DEPLOY_SUCCESS[@]}"; do
        echo "  ✓ $chain"
        entry=$(get_chain_addresses "$chain")
        if [ -n "$entry" ]; then
            proxy_addr=$(echo "$entry" | cut -d'|' -f2)
            impl_addr=$(echo "$entry" | cut -d'|' -f3)
            if [ -n "$proxy_addr" ]; then
                echo "    Proxy:          $proxy_addr"
            fi
            if [ -n "$impl_addr" ] && [ "$impl_addr" != "skipped" ]; then
                echo "    Implementation: $impl_addr"
            fi
        fi
    done
    echo ""
fi

if [ ${#DEPLOY_SKIPPED[@]} -ne 0 ]; then
    echo -e "${YELLOW}Deployments skipped (${#DEPLOY_SKIPPED[@]}):${NC}"
    for chain in "${DEPLOY_SKIPPED[@]}"; do
        echo "  ⊘ $chain (already deployed)"
        entry=$(get_chain_addresses "$chain")
        if [ -n "$entry" ]; then
            proxy_addr=$(echo "$entry" | cut -d'|' -f2)
            if [ -n "$proxy_addr" ]; then
                echo "    Proxy: $proxy_addr"
            fi
        fi
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

if [ "$MODE" == "upgrade-dry-run" ]; then
    echo -e "${YELLOW}This was an upgrade dry run. To upgrade for real:${NC}"
    echo "  AORI_PROXY_ADDRESS=$AORI_PROXY_ADDRESS ./deploy/deploy.sh $NETWORK --upgrade --broadcast"
fi

if [ "$MODE" == "deploy" ]; then
    echo -e "${YELLOW}IMPORTANT: Peers must be configured for cross-chain messaging!${NC}"
    echo ""
    # Get proxy address from deployment if available
    if [ ${#DEPLOYED_ADDRESSES[@]} -gt 0 ]; then
        first_entry="${DEPLOYED_ADDRESSES[0]}"
        proxy_addr=$(echo "$first_entry" | cut -d'|' -f2)
        echo "Run:"
        echo "  AORI_PROXY_ADDRESS=$proxy_addr ./deploy/deploy.sh $NETWORK --configure-peers"
    else
        echo "Set AORI_PROXY_ADDRESS to the deployed proxy address, then run:"
        echo "  AORI_PROXY_ADDRESS=0x... ./deploy/deploy.sh $NETWORK --configure-peers"
    fi
    echo ""
    echo "Or run full deployment next time:"
    echo "  ./deploy/deploy.sh $NETWORK --full"
fi

# Exit with error if any failures
if [ ${#DEPLOY_FAILED[@]} -ne 0 ] || [ ${#PEERS_FAILED[@]} -ne 0 ] || [ ${#UPGRADE_FAILED[@]} -ne 0 ]; then
    exit 1
fi

echo -e "${GREEN}All operations completed successfully!${NC}"
