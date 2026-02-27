# Aori CLI

Rust-based CLI for cross-chain Aori operations on Solana and EVM chains.

## Installation

```bash
# From the cli directory
cargo build --release

# The binary will be at ../target/release/aori
# Optionally, install it globally:
cargo install --path .
```

## Configuration

The CLI reads configuration from your `.env` file in the workspace root:

```bash
# Solana
SOLANA_PRIVATE_KEY=your_base58_key
# OR
SOLANA_KEYPAIR_PATH=/path/to/keypair.json
RPC_URL_SOLANA_TESTNET=https://api.devnet.solana.com

# EVM
PRIVATE_KEY=0x...
ARBITRUM_SEPOLIA_RPC_URL=https://...
BASE_SEPOLIA_RPC_URL=https://...
```

## Usage

### Send Cross-Chain Message

```bash
# Solana → Arbitrum
cargo run -- send \
  --from solana \
  --to arbitrum \
  --message "Hello from Solana" \
  --network testnet

# Arbitrum → Solana
cargo run -- send \
  --from arbitrum \
  --to solana \
  --message "Hello from Arbitrum" \
  --network testnet
```

### Settle Intent

```bash
cargo run -- settle \
  --from solana \
  --to arbitrum \
  --intent-id abc123 \
  --network testnet
```

### Configure Peers

```bash
# Set peer
cargo run -- config \
  --action set-peer \
  --chain solana \
  --remote-chain arbitrum \
  --peer-address 0x1234... \
  --network testnet

# Get peer
cargo run -- config \
  --action get-peer \
  --chain solana \
  --remote-chain arbitrum \
  --network testnet
```

### Initialize OApp (Solana)

```bash
cargo run -- init \
  --program-id <YOUR_PROGRAM_ID> \
  --network testnet
```

### Debug State

```bash
# View Solana state
cargo run -- debug --chain solana --network testnet

# View Arbitrum state
cargo run -- debug --chain arbitrum --network testnet
```

## Development

The CLI is structured as follows:

```
cli/
├── src/
│   ├── main.rs              # CLI entry point and command parsing
│   ├── commands/
│   │   ├── send.rs         # Cross-chain messaging
│   │   ├── settle.rs       # Intent settlement
│   │   ├── config.rs       # Peer configuration
│   │   ├── init.rs         # OApp initialization
│   │   └── debug.rs        # State inspection
│   ├── solana/
│   │   └── client.rs       # Solana RPC client
│   └── evm/
│       └── client.rs       # EVM client (alloy-based)
└── Cargo.toml
```

## TODO

- [ ] Implement actual Solana instruction building (send, quote, init)
- [ ] Implement EVM contract calls using alloy
- [ ] Add intent settlement logic
- [ ] Add peer configuration (setPeer/getPeer)
- [ ] Add debug state reading
- [ ] Add transaction status polling
- [ ] Add gas estimation
- [ ] Add multi-sig support
- [ ] Add batch operations

## vs TypeScript/Hardhat Setup

This Rust CLI replaces the entire `lib/` and `tasks/` TypeScript infrastructure with:

✅ Native Rust performance
✅ Single language for Solana + EVM
✅ No Node.js dependencies
✅ Smaller binary (~10MB vs 500MB node_modules)
✅ Integrates with Forge workflow
✅ Type-safe at compile time

## Building for Production

```bash
# Optimized release build
cargo build --release

# The binary will be at ../target/release/aori
# Copy it to your PATH or use directly
cp ../target/release/aori /usr/local/bin/
```
