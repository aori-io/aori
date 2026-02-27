# TypeScript Infrastructure Functionality Audit

Complete list of what `lib/` and `tasks/` provide before deletion.

## 📋 Overview

The TypeScript setup provides **LayerZero DevTools integration** for wiring, configuration, and cross-chain operations. Your Rust CLI needs to replicate these core functionalities.

---

## 🔧 Core Functionalities by Directory

### **`lib/` - TypeScript Client SDK**

#### **Purpose:**
TypeScript client for interacting with your Solana program + LayerZero DevTools integration

#### **Key Files & Functions:**

| File | Functions | What It Does |
|------|-----------|--------------|
| **`lib/client/myoapp.ts`** | `MyOApp` class | TypeScript wrapper around your Solana program |
| | `initStore()` | Creates the Store PDA account |
| | `send()` | Sends cross-chain messages |
| | `quote()` | Gets fee quote for sending |
| | `setPeerConfig()` | Configures peer address & enforced options |
| | `getPeer()` | Reads peer configuration |
| | `getStore()` | Fetches Store account data |
| | `getEnforcedOptions()` | Gets enforced options for a peer |
| | `getSendLibraryProgram()` | Gets the message library being used |
| **`lib/client/pda.ts`** | `MyOAppPDA` class | PDA derivation helpers |
| | `oapp()` | Derives Store PDA |
| | `peer(eid)` | Derives PeerConfig PDA for remote chain |
| | `lzReceiveTypesAccounts()` | Derives LzReceiveTypes PDA |
| **`lib/sdk.ts`** | `CustomOAppSDK` class | LayerZero DevTools integration wrapper |
| | `getOwner()` | Gets OApp admin |
| | `getPeer(eid)` | Gets peer address for chain |
| | `setPeer(eid, address)` | Sets peer address |
| | `setEnforcedOptions()` | Sets enforced options |
| | `getEnforcedOptions()` | Gets enforced options |
| | `getDelegate()` | Gets OApp delegate |
| | `getEndpointSDK()` | Gets LayerZero Endpoint SDK |
| **`lib/config.ts`** | `initConfig` | Initializes SendConfig/ReceiveConfig accounts |
| | `initOAppAccounts` | Batch initialization configurator |
| **`lib/factory.ts`** | `createSimpleOAppFactory()` | Creates SDK factory for DevTools |
| **`lib/scripts/generate.ts`** | `generateTypeScriptSDK()` | Generates TS bindings from Anchor IDL |

#### **Generated Files (`lib/client/generated/`):**
- Auto-generated TypeScript bindings from Anchor IDL
- Accounts, Instructions, Types, Errors
- **Created by:** `pnpm gen:api` (runs Kinobi on `target/idl/my_oapp.json`)

---

### **`tasks/` - Hardhat Tasks**

#### **Purpose:**
CLI commands for deployment, configuration, debugging, and cross-chain operations

---

### **`tasks/common/` - Cross-Chain Tasks**

| Task | Command | What It Does | CLI Equivalent Needed |
|------|---------|--------------|----------------------|
| **wire.ts** | `npx hardhat lz:oapp:wire` | **CRITICAL**: Wires cross-chain pathways. Sets peers, enforced options, DVN configs, and delegates across all chains in `layerzero.config.ts` | ✅ **Must implement** - Core functionality |
| **send.ts** | `npx hardhat lz:oapp:send` | Sends cross-chain message from any chain to any chain. Detects chain type and routes to Solana or EVM | ✅ Already in Rust CLI (stub) |
| **config.get.ts** | `npx hardhat lz:oapp:config:get` | Gets LayerZero config (SendLibrary, ReceiveLibrary, ULN configs, Executor configs) for all chains | ⚠️ **Optional** - Nice for debugging |
| **oappGet.ts** | `npx hardhat lz:oapp:get` | Fetches and displays OApp state across all chains (Store data, contract data) | ⚠️ **Optional** - Debug helper |

---

### **`tasks/solana/` - Solana-Specific Tasks**

| Task | Command | What It Does | CLI Equivalent Needed |
|------|---------|--------------|----------------------|
| **oappCreate.ts** | `npx hardhat lz:oapp:solana:create` | **CRITICAL**: Initializes the Store PDA account on Solana. First step after deploying program | ✅ **Must implement** |
| **initConfig.ts** | `npx hardhat lz:oapp:solana:init-config` | **CRITICAL**: Initializes SendConfig and ReceiveConfig PDAs for each remote chain. Required before wiring | ✅ **Must implement** |
| **debug.ts** | `npx hardhat lz:oapp:solana:debug` | Displays Solana OApp state: Store account, admin, delegate, peers, configs | ✅ Already in Rust CLI (stub) |
| **retryMessage.ts** | `npx hardhat lz:oapp:solana:retry-message` | Manually retries a failed cross-chain message on Solana | ⚠️ **Optional** - Advanced recovery |

**Key Functions in `tasks/solana/index.ts`:**
- `deriveConnection(eid)` - Creates RPC connection + Umi + wallet
- `getSolanaDeployment(eid)` - Reads deployment file
- `saveSolanaDeployment()` - Writes deployment file
- `getSolanaOAppAddress()` - Gets Store PDA address
- `getAddressLookupTable()` - Gets ALT for transactions
- `addComputeUnitInstructions()` - Adds compute budget to txs

---

### **`tasks/evm/` - EVM-Specific Tasks**

| Task | Command | What It Does | CLI Equivalent Needed |
|------|---------|--------------|----------------------|
| **debug.ts** | `npx hardhat lz:oapp:evm:debug` | Reads and displays EVM contract state (owner, stored data) | ✅ Already in Rust CLI (stub) |

---

## 🎯 CRITICAL Functions You MUST Implement

These are **non-negotiable** for basic cross-chain functionality:

### **1. Initialize Store Account (Solana)**
```rust
// Equivalent: npx hardhat lz:oapp:solana:create --eid 40168 --program-id <ID>
cargo aori init --program-id <ID> --network testnet
```
**What it does:**
- Creates the Store PDA (`seeds = [b"Store"]`)
- Registers OApp with LayerZero Endpoint
- Saves deployment info to `deployments/solana-testnet/OApp.json`

**Implementation:**
- Use `anchor-client` to call `init_store` instruction
- Provide: admin (your wallet), endpoint program ID
- Return: Store PDA address

---

### **2. Initialize SendConfig/ReceiveConfig (Solana)**
```rust
// Equivalent: npx hardhat lz:oapp:solana:init-config --oapp-config layerzero.config.ts
cargo aori init-config --chain solana --remote-chains arbitrum,base
```
**What it does:**
- For each remote chain, creates SendConfig and ReceiveConfig PDAs
- Required by LayerZero Endpoint before sending messages
- One-time setup per pathway

**Implementation:**
- For each remote EID:
  - Call LayerZero Endpoint's `init_send_library` 
  - Call LayerZero Endpoint's `init_receive_library`
  - Call LayerZero Endpoint's `init_config` for ULN settings

---

### **3. Set Peer Address**
```rust
// Equivalent: Part of lz:oapp:wire
cargo aori config set-peer --chain solana --remote arbitrum --address 0x1234...
```
**What it does:**
- Creates/updates PeerConfig PDA for a remote chain
- Stores: peer address (32 bytes), enforced options

**Implementation:**
- Call your program's `set_peer_config` instruction
- Provide: remote EID, peer address (left-padded to 32 bytes)

---

### **4. Set Enforced Options**
```rust
// Equivalent: Part of lz:oapp:wire
cargo aori config set-enforced-options \
  --chain solana \
  --remote arbitrum \
  --gas 200000 \
  --msg-type 1
```
**What it does:**
- Sets enforced gas limits and execution options for cross-chain messages
- Ensures receiver has enough gas to process message

**Implementation:**
- Call your program's `set_peer_config` instruction with EnforcedOptions variant
- Encode options using LayerZero's Options format

---

### **5. Send Cross-Chain Message**
```rust
// Equivalent: npx hardhat lz:oapp:send
cargo aori send --from solana --to arbitrum --message "Hello"
```
**What it does:**
- Quotes fee
- Builds send instruction
- Submits transaction to Solana

**Implementation:**
- Call `quote_send` instruction (read-only)
- Call `send` instruction with fee payment
- Add compute budget instructions
- Sign and submit

---

### **6. Get Configuration (Read State)**
```rust
// Equivalent: npx hardhat lz:oapp:solana:debug
cargo aori debug --chain solana
```
**What it does:**
- Reads Store account
- Reads PeerConfig accounts
- Displays admin, peers, enforced options

**Implementation:**
- Fetch Store PDA
- Fetch PeerConfig PDAs for each remote chain
- Pretty-print results

---

## 🔍 Optional But Useful Functions

### **7. Wire All Chains** (Advanced)
```rust
cargo aori wire --config layerzero.config.ts
```
**What it does:**
- Automated setup for all chains in config file
- Combines: init-config + set-peer + set-enforced-options
- For Solana: Initializes configs, sets peers
- For EVM: Sets peers via contract calls

**Implementation:**
- Parse `layerzero.config.ts` (or create Rust config format)
- For each connection in mesh:
  - Initialize configs if needed
  - Set peer addresses
  - Set enforced options
  - Configure DVNs (advanced)

---

### **8. Get Full Config** (Debug Helper)
```rust
cargo aori config get --chain solana --remote arbitrum
```
**What it does:**
- Shows SendLibrary, ReceiveLibrary
- Shows ULN config (DVNs, confirmations, optional DVNs)
- Shows Executor config (maxMessageSize, executor address)

**Implementation:**
- Query LayerZero Endpoint for SendLibrary
- Query LayerZero Endpoint for ReceiveLibrary
- Read ULN config PDAs
- Read Executor config PDAs

---

### **9. Retry Failed Message** (Recovery)
```rust
cargo aori retry \
  --src-eid 40231 \
  --dst-eid 40168 \
  --nonce 123 \
  --guid 0x... \
  --message 0x...
```
**What it does:**
- Manually calls `lz_receive` on Solana
- Used when Executor fails to deliver message
- Requires: src EID, nonce, sender, GUID, message payload

**Implementation:**
- Use `@layerzerolabs/lz-solana-sdk-v2`'s `lzReceive` helper
- Or manually build lz_receive instruction with all params

---

## 📊 Comparison Matrix

| Functionality | TypeScript | Rust CLI Status | Priority |
|---------------|-----------|----------------|----------|
| **Initialize Store** | ✅ `lz:oapp:solana:create` | 🚧 Stub | 🔴 CRITICAL |
| **Initialize Configs** | ✅ `lz:oapp:solana:init-config` | ❌ Missing | 🔴 CRITICAL |
| **Set Peer** | ✅ `lz:oapp:wire` (part of) | 🚧 Stub | 🔴 CRITICAL |
| **Set Enforced Options** | ✅ `lz:oapp:wire` (part of) | ❌ Missing | 🔴 CRITICAL |
| **Send Message** | ✅ `lz:oapp:send` | 🚧 Stub | 🔴 CRITICAL |
| **Quote Fee** | ✅ Built into send | 🚧 Stub | 🔴 CRITICAL |
| **Debug State** | ✅ `lz:oapp:solana:debug` | 🚧 Stub | 🟡 Important |
| **Get Config** | ✅ `lz:oapp:config:get` | ❌ Missing | 🟢 Nice to have |
| **Wire All** | ✅ `lz:oapp:wire` | ❌ Missing | 🟡 Important |
| **Retry Message** | ✅ `lz:oapp:solana:retry-message` | ❌ Missing | 🟢 Advanced |
| **Get Owner** | ✅ SDK method | ❌ Missing | 🟢 Nice to have |
| **Get Delegate** | ✅ SDK method | ❌ Missing | 🟢 Nice to have |

---

## 🎯 Implementation Roadmap for Rust CLI

### **Phase 1: Core Functionality** (Must Have)
1. ✅ CLI structure and parsing (Done!)
2. ⬜ **Initialize Store** (`init` command)
3. ⬜ **Initialize Configs** (`init-config` command)
4. ⬜ **Set Peer** (`config set-peer` command)
5. ⬜ **Set Enforced Options** (`config set-enforced-options` command)
6. ⬜ **Quote + Send Message** (`send` command)

### **Phase 2: Debugging & Inspection** (Important)
7. ⬜ **Debug State** (`debug` command)
8. ⬜ **Get Peer** (`config get-peer` command)
9. ⬜ **Get Enforced Options** (`config get-enforced-options` command)

### **Phase 3: Advanced Features** (Nice to Have)
10. ⬜ **Wire All Chains** (`wire` command)
11. ⬜ **Get Full Config** (`config get` command)
12. ⬜ **Retry Message** (`retry` command)

### **Phase 4: Intent Settlement** (Aori-Specific)
13. ⬜ **Settle Intent** (`settle` command)
14. ⬜ **Cross-chain atomic swap logic**

---

## 🗑️ Safe to Delete After Implementation

Once you implement all **Phase 1 + Phase 2** functions, you can safely delete:

```bash
rm -rf lib/
rm -rf tasks/
rm -rf node_modules/
rm hardhat.config.ts
rm layerzero.config.ts  # Optional: keep if you want config format
rm package.json
rm pnpm-lock.yaml
rm tsconfig.json
```

**Keep:**
- `programs/` - Your Solana Anchor program
- `contracts/` - Your Forge/Solidity contracts
- `cli/` - Your new Rust CLI
- `.env` - Environment variables
- `foundry.toml`, `Anchor.toml`, `Cargo.toml`

---

## 🔑 Key Dependencies You'll Need

### **Rust Crates:**
```toml
anchor-client = { version = "0.31.1", features = ["async"] }
anchor-lang = "0.31.1"
solana-sdk = "1.18"  # Via anchor-client
solana-client = "1.18"  # Via anchor-client
alloy = "0.10"  # For EVM interactions
bs58 = "0.5"  # For Solana addresses
serde_json = "1.0"  # For config parsing
```

### **Key Concepts:**
1. **PDA Derivation** - Use anchor-client to derive PDAs
2. **Instruction Building** - Use anchor-client Program API
3. **Transaction Signing** - Load keypair, sign, submit
4. **LayerZero Integration** - May need to vendor some LZ SDK Rust code

---

## 📚 References

- **TypeScript wire task**: `tasks/common/wire.ts` (200+ lines of wiring logic)
- **Solana client**: `lib/client/myoapp.ts` (instruction builders)
- **SDK wrapper**: `lib/sdk.ts` (DevTools integration)
- **Task helpers**: `tasks/solana/index.ts` (connection, deployment utils)

---

## 💡 Pro Tips

1. **Start with Phase 1** - Core functionality gets you 80% there
2. **Test incrementally** - Implement one command at a time
3. **Reference TypeScript** - The TS code shows exact instruction parameters
4. **Use anchor-client examples** - The anchor docs have good examples
5. **Keep layerzero.config.ts format** - You can parse it from Rust if needed

---

**Bottom Line:** You need **6 core functions** (Phase 1) to match basic TypeScript functionality. Everything else is debugging/convenience.
