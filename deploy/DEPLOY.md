# Aori Deployment Guide

This guide covers deploying Aori contracts across multiple chains using Forge scripts with CREATE3 for deterministic addresses.

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Environment Setup](#environment-setup)
- [Dry Run / Preview Addresses](#dry-run--preview-addresses)
- [Testnet Deployment](#testnet-deployment)
- [Mainnet Deployment](#mainnet-deployment)
- [Post-Deployment Configuration](#post-deployment-configuration)
- [Upgrading Contracts](#upgrading-contracts)
- [Supported Chains](#supported-chains)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

Deploy to all chains with a single command:

```bash
# Dry run on all testnets
./deploy/deploy.sh testnet

# Deploy to all testnets
./deploy/deploy.sh testnet --broadcast

# Configure peers on all testnets (after deployment)
AORI_PROXY_ADDRESS=0x... ./deploy/deploy.sh testnet --configure-peers

# Full deployment: deploy + configure peers
./deploy/deploy.sh testnet --full

# Quiet mode (suppress verbose output)
./deploy/deploy.sh testnet --broadcast --quiet
```

**Features:**
- **Skip-if-deployed**: Re-running on a chain where Aori is already deployed will skip that chain automatically
- **Artifacts**: Foundry saves transaction logs to `broadcast/` folder automatically

Or use npm scripts:

```bash
# Testnet
pnpm deploy:testnet:dry    # Dry run
pnpm deploy:testnet        # Deploy contracts
pnpm deploy:testnet:peers  # Configure peers (requires AORI_PROXY_ADDRESS)
pnpm deploy:testnet:full   # Deploy + configure peers

# Mainnet
pnpm deploy:mainnet:dry    # Dry run
pnpm deploy:mainnet        # Deploy contracts
pnpm deploy:mainnet:peers  # Configure peers (requires AORI_PROXY_ADDRESS)
pnpm deploy:mainnet:full   # Deploy + configure peers
```

Make sure environment variables are set first (see [Environment Setup](#environment-setup)).

**Important:** For cross-chain functionality, peers MUST be configured after deployment. Use `--full` or run `--configure-peers` separately.

---

## Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation) installed
- Node.js 18+ and pnpm
- RPC URLs for target chains
- Deployer private key with ETH/native tokens on each chain
- Owner address (multisig recommended for mainnet)

```bash
# Install dependencies
pnpm install

# Build contracts
forge build
```

---

## Environment Setup

Create a `.env` file (never commit this):

```bash
# Required
PRIVATE_KEY=0x...
OWNER_ADDRESS=0x...

# Testnet RPC URLs
SEPOLIA_RPC_URL=https://...
BASE_SEPOLIA_RPC_URL=https://...
ARBITRUM_SEPOLIA_RPC_URL=https://...
OPTIMISM_SEPOLIA_RPC_URL=https://...

# Mainnet RPC URLs
ETHEREUM_RPC_URL=https://...
BASE_RPC_URL=https://...
ARBITRUM_RPC_URL=https://...
OPTIMISM_RPC_URL=https://...
BSC_RPC_URL=https://...
PLASMA_RPC_URL=https://...
MONAD_RPC_URL=https://...
STABLE_RPC_URL=https://...

# Block Explorer API Keys (for --verify)
ETHERSCAN_API_KEY=...
BASESCAN_API_KEY=...
ARBISCAN_API_KEY=...
OPTIMISM_ETHERSCAN_API_KEY=...
BSCSCAN_API_KEY=...
```

**Optional env vars with defaults:**
- `DEPLOY_SALT` - CREATE3 salt (default: `aori-v1`)
- `MAX_FILLS_PER_SETTLE` - Max orders per batch (default: `200`)
- `INITIAL_SOLVERS` - Comma-separated solver addresses
- `INITIAL_HOOKS` - Comma-separated hook addresses

Load environment:

```bash
source .env
```

---

## Dry Run / Preview Addresses

Before deploying, preview the deterministic addresses that will be used across all chains.

### Preview Testnet Addresses

```bash
forge script script/DeployAori.s.sol:PreviewDeployment \
  --rpc-url $SEPOLIA_RPC_URL
```

### Preview Mainnet Addresses

```bash
MAINNET=true forge script script/DeployAori.s.sol:PreviewDeployment \
  --rpc-url $ETHEREUM_RPC_URL
```

### Simulate Deployment (Dry Run)

Run without `--broadcast` to simulate:

```bash
forge script script/DeployAori.s.sol:DeployAori \
  --rpc-url $SEPOLIA_RPC_URL
```

This executes the full deployment logic locally without sending transactions.

---

## Testnet Deployment

### Option 1: Single Chain Deployment

Deploy to one chain at a time with full control:

```bash
# Deploy to Sepolia
forge script script/DeployAori.s.sol:DeployAori \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast --verify

# Deploy to Base Sepolia
forge script script/DeployAori.s.sol:DeployAori \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify

# Deploy to Arbitrum Sepolia
forge script script/DeployAori.s.sol:DeployAori \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast --verify

# Deploy to Optimism Sepolia
forge script script/DeployAori.s.sol:DeployAori \
  --rpc-url $OPTIMISM_SEPOLIA_RPC_URL \
  --broadcast --verify
```

### Option 2: Multichain Deployment Script

Deploy using the multichain script (automatically includes all testnet chains as supported):

```bash
# Deploy to each testnet
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast --verify

forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast --verify

forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $ARBITRUM_SEPOLIA_RPC_URL \
  --broadcast --verify

forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $OPTIMISM_SEPOLIA_RPC_URL \
  --broadcast --verify
```

### Configure Peers (Required for Cross-Chain)

After deploying to all chains, configure peers on each chain:

```bash
# Set AORI_PROXY_ADDRESS to the deployed proxy address
export AORI_PROXY_ADDRESS=0x...

# Configure peers on Sepolia
forge script script/ConfigurePeers.s.sol:ConfigurePeers \
  --rpc-url $SEPOLIA_RPC_URL \
  --broadcast

# Configure peers on Base Sepolia
forge script script/ConfigurePeers.s.sol:ConfigurePeers \
  --rpc-url $BASE_SEPOLIA_RPC_URL \
  --broadcast

# Repeat for all chains...
```

---

## Mainnet Deployment

### Pre-Deployment Checklist

- [ ] Test deployment on testnets first
- [ ] Verify owner address is a multisig
- [ ] Ensure deployer has sufficient ETH on all chains
- [ ] Double-check DEPLOY_SALT matches testnet (or use new salt)
- [ ] Review MAX_FILLS_PER_SETTLE setting

### Deploy to Mainnets

```bash
# Deploy to Ethereum (MAINNET=true is set automatically by deploy.sh mainnet)
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast --verify

# Deploy to Base
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $BASE_RPC_URL \
  --broadcast --verify

# Deploy to Arbitrum
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $ARBITRUM_RPC_URL \
  --broadcast --verify

# Deploy to Optimism
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $OPTIMISM_RPC_URL \
  --broadcast --verify

# Deploy to BSC
forge script script/DeployMultichain.s.sol:DeployMultichain \
  --rpc-url $BSC_RPC_URL \
  --broadcast --verify

# Continue for remaining chains...
```

### Configure Mainnet Peers

```bash
export AORI_PROXY_ADDRESS=0x...

forge script script/ConfigurePeers.s.sol:ConfigurePeers \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast

# Repeat for all mainnet chains...
# Or use: ./deploy/deploy.sh mainnet --configure-peers
```

---

## Post-Deployment Configuration

### Add Solvers

```bash
AORI_PROXY_ADDRESS=0x... \
SOLVERS=0xSolver1,0xSolver2 \
forge script script/ConfigurePeers.s.sol:AddSolvers \
  --rpc-url $RPC_URL \
  --broadcast
```

### Add Hooks

```bash
AORI_PROXY_ADDRESS=0x... \
HOOKS=0xHook1,0xHook2 \
forge script script/ConfigurePeers.s.sol:AddHooks \
  --rpc-url $RPC_URL \
  --broadcast
```

### Add Supported Chains

```bash
AORI_PROXY_ADDRESS=0x... \
CHAIN_EIDS=30101,30184,30110 \
forge script script/ConfigurePeers.s.sol:AddSupportedChains \
  --rpc-url $RPC_URL \
  --broadcast
```

### Configure Single Peer

For adding a new chain to existing deployment:

```bash
AORI_PROXY_ADDRESS=0x... \
REMOTE_EID=30184 \
REMOTE_AORI_ADDRESS=0x... \
forge script script/ConfigurePeers.s.sol:ConfigureSinglePeer \
  --rpc-url $RPC_URL \
  --broadcast
```

### Verify Deployment

```bash
AORI_PROXY_ADDRESS=0x... \
MAINNET=true \
forge script script/DeployMultichain.s.sol:VerifyDeployments \
  --rpc-url $RPC_URL
```

---

## Upgrading Contracts

### Prepare Upgrade (Deploy New Implementation)

```bash
AORI_PROXY_ADDRESS=0x... \
forge script script/UpgradeAori.s.sol:PrepareUpgrade \
  --rpc-url $RPC_URL \
  --broadcast --verify
```

### Execute Upgrade

```bash
# Using newly deployed implementation
AORI_PROXY_ADDRESS=0x... \
NEW_IMPLEMENTATION=0x... \
forge script script/UpgradeAori.s.sol:UpgradeAori \
  --rpc-url $RPC_URL \
  --broadcast

# Or deploy and upgrade in one step (omit NEW_IMPLEMENTATION)
AORI_PROXY_ADDRESS=0x... \
forge script script/UpgradeAori.s.sol:UpgradeAori \
  --rpc-url $RPC_URL \
  --broadcast --verify
```

### Multichain Upgrade

Run on each chain:

```bash
AORI_PROXY_ADDRESS=0x... \
forge script script/UpgradeAori.s.sol:UpgradeMultichain \
  --rpc-url $ETHEREUM_RPC_URL \
  --broadcast --verify

# Repeat for all chains...
```

### Verify Upgrade

```bash
AORI_PROXY_ADDRESS=0x... \
EXPECTED_IMPLEMENTATION=0x... \
forge script script/UpgradeAori.s.sol:VerifyUpgrade \
  --rpc-url $RPC_URL
```

---

## Supported Chains

### Mainnets

| Network   | Chain ID | LayerZero EID | RPC Env Var       |
|-----------|----------|---------------|-------------------|
| Ethereum  | 1        | 30101         | ETHEREUM_RPC_URL  |
| Base      | 8453     | 30184         | BASE_RPC_URL      |
| Arbitrum  | 42161    | 30110         | ARBITRUM_RPC_URL  |
| Optimism  | 10       | 30111         | OPTIMISM_RPC_URL  |
| BSC       | 56       | 30102         | BSC_RPC_URL       |
| Plasma    | 9745     | 30383         | PLASMA_RPC_URL    |
| Monad     | 143      | 30390         | MONAD_RPC_URL     |
| Stable    | 988      | 30396         | STABLE_RPC_URL    |

### Testnets

| Network          | Chain ID  | LayerZero EID | RPC Env Var              |
|------------------|-----------|---------------|--------------------------|
| Sepolia          | 11155111  | 40161         | SEPOLIA_RPC_URL          |
| Base Sepolia     | 84532     | 40245         | BASE_SEPOLIA_RPC_URL     |
| Arbitrum Sepolia | 421614    | 40231         | ARBITRUM_SEPOLIA_RPC_URL |
| Optimism Sepolia | 11155420  | 40232         | OPTIMISM_SEPOLIA_RPC_URL |

---

## Troubleshooting

### "Chain not supported"

The chain ID is not configured in `BaseScript.sol`. Add the chain configuration or verify you're on the correct network.

### "CREATE3 factory not deployed on this chain"

The Aori CREATE3 factory (`0x2Dfcc7415D89af828cbef005F0d072D8b3F23183`) is not deployed on this chain. Contact the Aori team to deploy the factory.

### "Implementation address mismatch!"

The CREATE3 deployment produced an unexpected address. Verify:
- Same DEPLOY_SALT used
- Same deployer address
- Factory is deployed at expected address

### "Caller is not owner"

The PRIVATE_KEY does not correspond to the contract owner. Verify the owner address with:

```bash
cast call $AORI_PROXY_ADDRESS "owner()(address)" --rpc-url $RPC_URL
```

### Gas Estimation Issues

Add gas limit and price flags:

```bash
forge script ... --gas-limit 5000000 --gas-price 50gwei
```

### Verification Failures

Manually verify on block explorer or retry with explicit compiler settings:

```bash
forge verify-contract $ADDRESS Aori \
  --chain-id $CHAIN_ID \
  --constructor-args $(cast abi-encode "constructor(address,uint32)" $ENDPOINT $EID)
```

---

## Script Reference

| Script | Contract | Purpose |
|--------|----------|---------|
| `DeployAori.s.sol` | `DeployAori` | Single chain deployment |
| `DeployAori.s.sol` | `PreviewDeployment` | Preview addresses (dry run) |
| `DeployMultichain.s.sol` | `DeployMultichain` | Deploy with all chains supported |
| `DeployMultichain.s.sol` | `PrintDeploymentInfo` | Print expected addresses |
| `DeployMultichain.s.sol` | `VerifyDeployments` | Verify deployment state |
| `ConfigurePeers.s.sol` | `ConfigurePeers` | Configure all peers |
| `ConfigurePeers.s.sol` | `ConfigureSinglePeer` | Configure one peer |
| `ConfigurePeers.s.sol` | `AddSolvers` | Whitelist solvers |
| `ConfigurePeers.s.sol` | `AddHooks` | Whitelist hooks |
| `ConfigurePeers.s.sol` | `AddSupportedChains` | Add chain EIDs |
| `UpgradeAori.s.sol` | `UpgradeAori` | Upgrade proxy |
| `UpgradeAori.s.sol` | `PrepareUpgrade` | Deploy new implementation |
| `UpgradeAori.s.sol` | `VerifyUpgrade` | Verify upgrade success |
| `UpgradeAori.s.sol` | `UpgradeMultichain` | Upgrade on each chain |

---

## CREATE3 Deterministic Addresses

Aori uses CREATE3 for deterministic deployment addresses across all chains. Key points:

- **Same address everywhere**: Using the same `DEPLOY_SALT` and deployer produces identical proxy addresses on all chains
- **Factory address**: `0x2Dfcc7415D89af828cbef005F0d072D8b3F23183` (Aori CREATE3 factory)
- **Salt namespacing**: The factory hashes the salt with `msg.sender` for deployer isolation
- **Bytecode independent**: Unlike CREATE2, CREATE3 address doesn't depend on bytecode (allowing different immutables per chain)

This enables pre-configuring peers before all chains are deployed, since addresses are known in advance.
