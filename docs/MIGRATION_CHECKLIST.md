# TypeScript → Rust CLI Migration Checklist

Quick reference for migrating from TypeScript/Hardhat to Rust CLI.

## 📊 Command Mapping

### **CRITICAL Commands (Must Implement)**

| TypeScript/Hardhat | Rust CLI Equivalent | Status | Implementation File |
|-------------------|---------------------|--------|---------------------|
| `npx hardhat lz:oapp:solana:create --eid 40168 --program-id <ID>` | `cargo aori init --program-id <ID> --network testnet` | 🚧 Stub | `cli/src/commands/init.rs` |
| `npx hardhat lz:oapp:solana:init-config --oapp-config layerzero.config.ts` | `cargo aori init-config --remote-chains arbitrum,base` | ❌ TODO | Add new command |
| `npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts` | `cargo aori wire --config layerzero.config.ts` | ❌ TODO | Add new command |
| `npx hardhat lz:oapp:send --from-eid 40168 --dst-eid 40231 --message "Hello"` | `cargo aori send --from solana --to arbitrum --message "Hello"` | 🚧 Stub | `cli/src/commands/send.rs` |

### **Important Commands (Debugging)**

| TypeScript/Hardhat | Rust CLI Equivalent | Status |
|-------------------|---------------------|--------|
| `npx hardhat lz:oapp:solana:debug --eid 40168` | `cargo aori debug --chain solana` | 🚧 Stub |
| `npx hardhat lz:oapp:evm:debug --network arbitrum-sepolia` | `cargo aori debug --chain arbitrum` | 🚧 Stub |
| `npx hardhat lz:oapp:get --oapp-config layerzero.config.ts` | `cargo aori debug --all-chains` | ❌ TODO |
| `npx hardhat lz:oapp:config:get --oapp-config layerzero.config.ts` | `cargo aori config get --chain solana --remote arbitrum` | ❌ TODO |

### **Advanced Commands (Optional)**

| TypeScript/Hardhat | Rust CLI Equivalent | Status |
|-------------------|---------------------|--------|
| `npx hardhat lz:oapp:solana:retry-message <params>` | `cargo aori retry <params>` | ❌ TODO |
| N/A | `cargo aori settle --from solana --to arbitrum --intent-id <ID>` | 🚧 Stub |

---

## 🔧 What Each Command Actually Does

### **1. `init` - Initialize Solana Store**
```bash
cargo aori init --program-id <PROGRAM_ID> --network testnet
```

**Calls:** `init_store` instruction on your Solana program

**Accounts:**
- `payer` - Your wallet (pays for account creation)
- `store` - Store PDA (derived: `[b"Store"]`)
- `lz_receive_types_accounts` - PDA for Executor
- Remaining accounts: LayerZero Endpoint registration

**Args:**
- `admin` - Your wallet public key
- `endpoint` - LayerZero Endpoint program ID

**Returns:** Store PDA address

**Saves to:** `deployments/solana-testnet/OApp.json`
```json
{
  "programId": "<YOUR_PROGRAM_ID>",
  "oapp": "<STORE_PDA_ADDRESS>"
}
```

---

### **2. `init-config` - Initialize LayerZero Configs**
```bash
cargo aori init-config --remote-chains arbitrum,base --network testnet
```

**For each remote chain, calls:**
1. **LayerZero Endpoint**: `init_send_library`
2. **LayerZero Endpoint**: `init_receive_library`  
3. **ULN Message Library**: `init_send_config`
4. **ULN Message Library**: `init_receive_config`

**Creates PDAs:**
- `SendLibraryConfig` - Per destination chain
- `ReceiveLibraryConfig` - Per source chain
- `UlnSettings` - DVN configuration
- `ExecutorConfig` - Gas limits

**Why needed:** LayerZero requires these accounts before wiring

---

### **3. `wire` - Full Cross-Chain Setup**
```bash
cargo aori wire --config config.json
```

**Does everything:**
1. Runs `init-config` if needed
2. Sets peer addresses on all chains
3. Sets enforced options
4. Configures DVNs (Data Verification Networks)
5. Sets delegates

**This is the big one** - replaces manual configuration

**Config format (example JSON):**
```json
{
  "connections": [
    {
      "from": { "chain": "solana", "eid": 40168 },
      "to": { "chain": "arbitrum", "eid": 40231 },
      "peerAddress": "0x1234...",
      "enforcedOptions": {
        "msgType": 1,
        "gas": 200000
      }
    }
  ]
}
```

---

### **4. `send` - Cross-Chain Messaging**
```bash
cargo aori send --from solana --to arbitrum --message "Hello" --network testnet
```

**Flow:**
1. Convert chains to EIDs (solana → 40168, arbitrum → 40231)
2. Call `quote_send` to get fee
3. Build `send` instruction with:
   - `dst_eid`: 40231
   - `message`: Encoded string
   - `options`: Empty (relying on enforced options)
   - `native_fee`: From quote
4. Add compute budget instructions
5. Send transaction
6. Return signature

---

### **5. `debug` - State Inspection**
```bash
cargo aori debug --chain solana --network testnet
```

**Reads and displays:**
- **Store Account:**
  - Admin
  - Endpoint program
  - Last received string
- **Peer Configs:**
  - Remote chain EID
  - Peer address
  - Enforced options (send, sendAndCall)
- **LayerZero Configs:**
  - Send library
  - Receive library
  - ULN settings (DVNs, confirmations)

---

### **6. `config set-peer` - Manual Peer Setup**
```bash
cargo aori config set-peer \
  --chain solana \
  --remote arbitrum \
  --address 0x1234567890abcdef... \
  --network testnet
```

**Calls:** `set_peer_config` instruction

**Params:**
- `remote_eid`: Chain to EID mapping (arbitrum → 40231)
- `config`: PeerConfigParam::PeerAddress variant
- `peer`: 32-byte address (left-pad if needed)

---

## 🛠️ Implementation Helpers

### **EID Mapping** (Already in your CLI)
```rust
fn chain_to_eid(chain: &str, network: &str) -> u32 {
    match (chain, network) {
        ("solana", "testnet") => 40168,
        ("arbitrum", "testnet") => 40231,
        // etc.
    }
}
```

### **Load Deployment Info**
```rust
fn load_solana_deployment(network: &str) -> Result<(String, String)> {
    let path = format!("deployments/solana-{}/OApp.json", network);
    let contents = std::fs::read_to_string(path)?;
    let json: serde_json::Value = serde_json::from_str(&contents)?;
    
    let program_id = json["programId"].as_str().unwrap();
    let oapp = json["oapp"].as_str().unwrap();
    
    Ok((program_id.to_string(), oapp.to_string()))
}
```

### **Save Deployment Info**
```rust
fn save_solana_deployment(eid: u32, program_id: &str, oapp: &str) -> Result<()> {
    let network = match eid {
        40168 => "solana-testnet",
        30168 => "solana-mainnet",
        _ => return Err(anyhow::anyhow!("Unknown Solana EID")),
    };
    
    let dir = format!("deployments/{}", network);
    std::fs::create_dir_all(&dir)?;
    
    let json = serde_json::json!({
        "programId": program_id,
        "oapp": oapp
    });
    
    std::fs::write(
        format!("{}/OApp.json", dir),
        serde_json::to_string_pretty(&json)?
    )?;
    
    Ok(())
}
```

---

## 📝 Minimal Implementation Order

To match TypeScript functionality, implement in this order:

1. **`init`** - Initialize Store account
2. **`send`** - Quote + send messages (most used)
3. **`debug`** - Read state (debugging)
4. **`config set-peer`** - Set peer manually
5. **`init-config`** - Initialize LZ configs
6. **`wire`** - Automate all setup (combines 4 + 5)

After these 6, you can delete the TypeScript infrastructure.

---

## 🚀 Quick Migration Path

### **Option A: Full Replacement** (Recommended)
1. Implement all 6 commands above
2. Test cross-chain messaging end-to-end
3. Delete TypeScript (`lib/`, `tasks/`, `node_modules/`)
4. Pure Forge + Anchor + Rust workflow

### **Option B: Hybrid** (Transitional)
1. Implement `init` and `send` commands
2. Keep TypeScript for wiring/config (rarely used)
3. Use Rust CLI for daily dev (sending messages, debugging)
4. Later: implement `wire` and delete TypeScript

### **Option C: Minimal**
1. Implement only `send` command
2. Use raw `solana` CLI for `init`
3. Manually set peers via raw instructions
4. Keep TypeScript for complex wiring

---

**Recommendation:** Go with **Option A** - implement all 6 core commands. You'll have a clean, native Rust workflow with no Node.js dependencies! 🎯

See `TYPESCRIPT_FUNCTIONALITY_AUDIT.md` for detailed function descriptions.
