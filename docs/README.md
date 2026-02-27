# Aori Documentation

Documentation for the Aori cross-chain intent settlement protocol.

## 📚 Documentation Index

### **Rust CLI Documentation**

The Aori CLI is a Rust-based tool for cross-chain operations on Solana and EVM chains.

- **[Implementation Guide](./IMPLEMENTATION_COMPLETE.md)** - Complete implementation details and usage
- **[Migration Checklist](./MIGRATION_CHECKLIST.md)** - Guide for migrating from TypeScript to Rust CLI
- **[CLI Quick Start](./CLI_QUICKSTART.md)** - Quick start guide for the Rust CLI
- **[CLI Success Guide](./CLI_SUCCESS.md)** - Build and setup instructions
- **[TypeScript Functionality Audit](./TYPESCRIPT_FUNCTIONALITY_AUDIT.md)** - Complete audit of replaced TypeScript functionality

### **CLI Quick Reference**

See `../cli/CHEAT_SHEET.md` for common commands and usage examples.

### **Protocol Documentation**

Core protocol documentation is located in the `_docs/` directory:

- **[V4 Implementation Plan](../_docs/V4_IMPLEMENTATION_PLAN.md)** - Protocol architecture and design
- **[Fee Implementation](../_docs/FEE_IMPLEMENTATION.md)** - Fee mechanism details
- **[Market Order Plan](../_docs/MARKET_ORDER_PLAN.md)** - Market order implementation
- **[Options Implementation](../_docs/OPTIONS_IMPLEMENTATION.md)** - Options struct details
- **[Audit Reports](../_docs/audit/)** - Security audit findings and fixes

---

## 🚀 Quick Start

### **Using the Rust CLI**

```bash
# Build the CLI
cd cli
cargo build --release

# Initialize Solana OApp
cargo run -- init --program-id <YOUR_PROGRAM_ID> --network testnet

# Send cross-chain message
cargo run -- send \
  --from solana \
  --to arbitrum \
  --message "Hello from Solana!" \
  --network testnet

# Debug state
cargo run -- debug --chain solana --network testnet
```

For detailed instructions, see the [Implementation Guide](./IMPLEMENTATION_COMPLETE.md).

---

## 🏗️ Architecture

### **Project Structure**

```
aori/
├── programs/          # Solana programs (Anchor)
├── contracts/         # EVM contracts (Solidity)
├── cli/               # Rust CLI for cross-chain ops
├── docs/              # Documentation
└── deployments/       # Deployment artifacts
```

### **Technology Stack**

- **Solana:** Anchor framework, anchor-client
- **EVM:** Solidity, Forge, LayerZero OApp
- **CLI:** Rust, clap, tokio
- **Cross-chain:** LayerZero V2 protocol

---

## 🔗 External Resources

- [LayerZero V2 Docs](https://docs.layerzero.network/v2)
- [Anchor Framework](https://www.anchor-lang.com/)
- [Foundry Book](https://book.getfoundry.sh/)
- [Solana Cookbook](https://solanacookbook.com/)

---

## 📝 Contributing

See the main [README](../README.md) for contribution guidelines.
