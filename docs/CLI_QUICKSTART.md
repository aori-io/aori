# Aori Rust CLI - Quick Start

You now have a **Rust-based CLI** for cross-chain Aori operations! This replaces the entire TypeScript/Hardhat setup with native Rust.

## 🚀 Quick Start

### 1. Build the CLI

```bash
cd cli
cargo build --release
```

The binary will be at `../target/release/aori`

### 2. Test It

```bash
# Check available commands
cargo run -- --help

# Send a cross-chain message
cargo run -- send \
  --from solana \
  --to arbitrum \
  --message "Hello from Solana" \
  --network testnet
```

## 📋 Available Commands

### Send Cross-Chain Message

```bash
# Solana → Arbitrum
cargo run -- send --from solana --to arbitrum --message "Hello" --network testnet

# Arbitrum → Solana
cargo run -- send --from arbitrum --to solana --message "Hello" --network testnet

# Supports: solana, arbitrum, base, optimism, ethereum
```

### Settle Intent (Coming Soon)

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
  --peer-address 0x1234...

# Get peer
cargo run -- config \
  --action get-peer \
  --chain solana \
  --remote-chain arbitrum
```

### Initialize Solana OApp

```bash
cargo run -- init \
  --program-id <YOUR_PROGRAM_ID> \
  --network testnet
```

### Debug State

```bash
# View Solana OApp state
cargo run -- debug --chain solana --network testnet

# View EVM OApp state
cargo run -- debug --chain arbitrum --network testnet
```

## ⚙️ Configuration

The CLI reads from your `.env` file:

```bash
# Solana
SOLANA_PRIVATE_KEY=your_base58_private_key
# OR
SOLANA_KEYPAIR_PATH=/path/to/keypair.json
RPC_URL_SOLANA_TESTNET=https://api.devnet.solana.com
RPC_URL_SOLANA=https://api.mainnet-beta.solana.com

# EVM
PRIVATE_KEY=0x...
ARBITRUM_SEPOLIA_RPC_URL=https://...
BASE_SEPOLIA_RPC_URL=https://...
OPTIMISM_SEPOLIA_RPC_URL=https://...
ETHEREUM_SEPOLIA_RPC_URL=https://...
```

## 🏗️ Architecture

```
cli/
├── src/
│   ├── main.rs              # CLI entry + command routing
│   ├── commands/
│   │   ├── send.rs         # Cross-chain messaging
│   │   ├── settle.rs       # Intent settlement
│   │   ├── config.rs       # Peer management
│   │   ├── init.rs         # OApp initialization
│   │   └── debug.rs        # State inspection
│   ├── solana/
│   │   └── client.rs       # Solana RPC + transaction building
│   └── evm/
│       └── client.rs       # EVM client using alloy-rs
```

## 🔨 Implementation Status

### ✅ Completed
- CLI structure and command parsing
- Chain detection and routing
- Environment configuration
- Error handling
- Network detection (testnet/mainnet)

### 🚧 TODO (Implement These Next)
- [ ] **Solana client**: Build actual instructions using anchor-client
- [ ] **EVM client**: Contract calls using alloy
- [ ] **Intent settlement**: Cross-chain atomic swap logic
- [ ] **Peer config**: setPeer/getPeer implementations
- [ ] **Debug**: Read and display on-chain state
- [ ] **Transaction polling**: Wait for confirmation
- [ ] **Gas estimation**: Accurate fee calculation

## 📦 vs TypeScript Setup

| Feature | TypeScript/Hardhat | Rust CLI |
|---------|-------------------|----------|
| **Size** | ~500MB node_modules | ~10MB binary |
| **Speed** | ~2s startup | Instant |
| **Type Safety** | Runtime (TS) | Compile-time |
| **Dependencies** | Node.js + 200+ packages | Rust only |
| **Integration** | Hardhat ecosystem | Forge + Anchor |
| **Language** | TypeScript | Rust (native) |

## 🎯 Next Steps

### 1. Implement Solana Transaction Building

In `cli/src/solana/client.rs`, implement:
- `quote_send()` - Call the quote instruction
- `send_message()` - Build and send the send instruction

Example:
```rust
use anchor_client::solana_sdk::instruction::Instruction;

pub async fn send_message(&self, dst_eid: u32, message: &str, fee: u64) -> Result<String> {
    // Build instruction using anchor-client
    let ix = build_send_instruction(
        &self.program_id,
        &self.keypair.pubkey(),
        dst_eid,
        message,
        fee,
    )?;
    
    // Send transaction
    let sig = self.rpc_client.send_and_confirm_transaction(&tx)?;
    Ok(sig.to_string())
}
```

### 2. Implement EVM Contract Calls

In `cli/src/evm/client.rs`, implement:
- Contract ABI parsing
- `quote_send()` - Call contract.quote()
- `send_message()` - Call contract.send()

Example using alloy:
```rust
use alloy::providers::Provider;
use alloy::contract::Contract;

pub async fn send_message(&self, dst_eid: u32, message: &str, fee: u128) -> Result<String> {
    let contract = Contract::new(contract_address, abi, provider);
    let tx = contract.send(dst_eid, message, options).value(fee);
    let receipt = tx.send().await?.get_receipt().await?;
    Ok(format!("{:?}", receipt.transaction_hash))
}
```

### 3. Add to Your Workflow

Once implemented, use it like:

```bash
# Instead of: npx hardhat lz:oapp:send --from-eid 40168 --dst-eid 40231
# Use:
cargo aori send --from solana --to arbitrum --message "Hello"

# Build optimized binary for production
cargo build --release
cp target/release/aori /usr/local/bin/

# Now just:
aori send --from solana --to arbitrum --message "Hello"
```

## 🗑️ What You Can Now Delete

Once you implement the actual Solana/EVM clients, you can delete:

```bash
rm -rf lib/
rm -rf tasks/
rm -rf node_modules/
rm hardhat.config.ts
rm layerzero.config.ts
rm package.json
rm pnpm-lock.yaml
rm tsconfig.json
```

Keep only:
- `programs/` (Solana program)
- `contracts/` (Forge contracts)
- `cli/` (Your new Rust CLI)
- `foundry.toml`
- `Anchor.toml`
- `Cargo.toml`

## 📚 Resources

- [anchor-client docs](https://docs.rs/anchor-client)
- [alloy docs](https://alloy.rs)
- [clap docs](https://docs.rs/clap)
- [Solana CLI reference](https://docs.solanalabs.com/cli)

## 💡 Pro Tips

1. **Install globally**: `cargo install --path cli` to get the `aori` command everywhere
2. **Use aliases**: `alias aori-test="cargo run --bin aori --"`
3. **Debug mode**: `RUST_LOG=debug cargo run -- send ...`
4. **Fast rebuilds**: Use `cargo check` during development
5. **Cross-compile**: Build for different platforms with `cargo build --release --target x86_64-unknown-linux-gnu`

---

You now have a foundation for a native Rust CLI! The structure is there - now implement the actual Solana/EVM interactions to make it functional. 🚀
