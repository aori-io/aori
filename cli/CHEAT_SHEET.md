# Aori CLI Cheat Sheet

Quick reference for common operations.

## 🚀 Setup

```bash
# Build CLI
cd cli && cargo build --release

# Install globally (optional)
cargo install --path .
```

## 📋 Common Commands

### Initialize Solana OApp
```bash
cargo run -- init \
  --program-id <YOUR_PROGRAM_ID> \
  --network testnet
```

### Send Cross-Chain Message
```bash
# Solana → Arbitrum
cargo run -- send \
  --from solana \
  --to arbitrum \
  --message "Hello from Solana!" \
  --network testnet

# Other chains: base, optimism, ethereum
```

### Configure Peers
```bash
# Set peer
cargo run -- config set-peer \
  --chain solana \
  --remote-chain arbitrum \
  --peer-address 0x1234567890abcdef1234567890abcdef12345678

# Get peer
cargo run -- config get-peer \
  --chain solana \
  --remote-chain arbitrum
```

### Debug State
```bash
cargo run -- debug \
  --chain solana \
  --network testnet
```

## 🌐 Endpoint IDs

| Chain | Testnet | Mainnet |
|-------|---------|---------|
| Solana | 40168 | 30168 |
| Arbitrum | 40231 | 30110 |
| Base | 40245 | 30184 |
| Optimism | 40232 | 30111 |
| Ethereum | 40161 | 30101 |

## ⚙️ Environment Variables

```bash
# Required in .env
SOLANA_PRIVATE_KEY=<base58_key>
# OR
SOLANA_KEYPAIR_PATH=/path/to/keypair.json

RPC_URL_SOLANA_TESTNET=https://api.devnet.solana.com
RPC_URL_SOLANA=https://api.mainnet-beta.solana.com
```

## 🔗 Useful Links

- **Solscan (Devnet):** https://solscan.io/tx/`<SIGNATURE>`?cluster=devnet
- **LayerZero Scan (Testnet):** https://testnet.layerzeroscan.com/tx/`<SIGNATURE>`
- **LayerZero Scan (Mainnet):** https://layerzeroscan.com/tx/`<SIGNATURE>`

## 🏗️ Full Deployment Flow

```bash
# 1. Build Solana program
anchor build -v -e MYOAPP_ID=<PROGRAM_ID>

# 2. Deploy to devnet
solana program deploy target/verifiable/my_oapp.so -u devnet

# 3. Initialize OApp
cd cli
cargo run -- init --program-id <PROGRAM_ID> --network testnet

# 4. Set peer for Arbitrum
cargo run -- config set-peer \
  --chain solana \
  --remote-chain arbitrum \
  --peer-address <ARBITRUM_CONTRACT>

# 5. Send test message
cargo run -- send \
  --from solana \
  --to arbitrum \
  --message "Test message"

# 6. Verify state
cargo run -- debug --chain solana
```

## 🐛 Troubleshooting

**Error: "Program ID not found"**
- Run `init` command first to create deployment file
- Or check `deployments/solana-testnet/OApp.json` exists

**Error: "No Solana keypair found"**
- Set `SOLANA_PRIVATE_KEY` in `.env`
- Or set `SOLANA_KEYPAIR_PATH`
- Or place keypair at `~/.config/solana/id.json`

**Error: "Failed to fetch peer account"**
- Peer not configured yet
- Run `config set-peer` first

**Error: "Transaction failed"**
- Check you have enough SOL (run `solana balance -u devnet`)
- Check program is deployed
- Check Store is initialized

## 💡 Tips

- Use `--network testnet` for Solana Devnet
- Use `--network mainnet` for Solana Mainnet
- Peer addresses must be 20 bytes (EVM) or 32 bytes (Solana)
- EVM addresses are automatically left-padded to 32 bytes
- Store PDA is deterministic: `find_program_address(&[b"Store"], &program_id)`
