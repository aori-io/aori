# Solana Cross-Chain Support: Technical Specification

## Problem

Aori settles cross-chain intents using LayerZero. All on-chain types use Solidity's `address` (20 bytes). Solana public keys are 32 bytes (ed25519). To support EVM↔Solana bidirectional flows, we need a way to reference Solana identities in EVM order structs and vice versa.

This spec presents two approaches:
- **Approach A**: Deterministic address derivation (zero EVM contract changes) — **recommended**
- **Approach B**: Migrate `address` fields to `bytes32` (contract-level change)

---

## Current Architecture

### Order Struct (after srcSolver/dstSolver split)

```solidity
struct Order {
    uint128 inputAmount;
    uint128 outputAmount;
    address inputToken;       // token on source chain
    uint32 startTime;
    uint32 endTime;
    uint32 srcEid;            // LayerZero source endpoint ID
    address outputToken;      // token on destination chain
    uint32 dstEid;            // LayerZero destination endpoint ID
    address offerer;          // user who created the order
    address recipient;        // receives output tokens on destination
    Options options;
}

struct Options {
    uint16 feeMbps;
    uint16 slippageMbps;
    address feeRecipient;     // receives additional fee (address(0) = solver)
    address srcSolver;        // authorized solver on source chain
    address dstSolver;        // authorized solver on destination chain
}
```

### Order ID

The order ID is `keccak256(abi.encode(order))`. This deterministic hash is used on both source and destination chains to identify the same order. Both chains must compute the same hash from the same order data.

### Which Fields Are Used Where

Not every field is used on every chain. This matters because fields that the EVM contract never reads for a given direction don't need to be "real" EVM addresses:

**Source chain operations** (deposit, settlement receive, source-chain cancel):
- `offerer` — balance key for locking/unlocking tokens
- `inputToken` — balance key and token transfer target
- `options.srcSolver` — solver authorization during deposit
- `options.feeRecipient` — fee accrual during settlement
- `srcEid` — chain validation

**Destination chain operations** (fill, settle-send, cross-chain cancel):
- `outputToken` — token transfer during fill
- `recipient` — transfer target during fill
- `options.dstSolver` — solver authorization during fill
- `dstEid` — chain validation

**Never used on-chain** (stored for hash identity only):
- On source chain: `outputToken`, `recipient`, `dstSolver` are stored but never read for balance/transfer ops
- On destination chain: `offerer`, `inputToken`, `srcSolver` appear in calldata for hash computation but are never used for balance/transfer ops

---

## Approach A: Deterministic Address Derivation

### Core Idea

Represent 32-byte Solana public keys as deterministic 20-byte EVM addresses. Both chains agree on the derivation function. The EVM contracts do not change at all.

### Derivation Function

```solidity
// Solana pubkey (32 bytes) → EVM address (20 bytes)
function derive(bytes32 solanaPubkey) pure returns (address) {
    return address(bytes20(keccak256(abi.encodePacked(solanaPubkey))));
}
```

On Solana (Rust):
```rust
fn derive(pubkey: &Pubkey) -> [u8; 20] {
    let hash = keccak256(pubkey.as_ref());
    hash[0..20].try_into().unwrap()
}
```

**Byte ordering**: `bytes20(keccak256(...))` takes the **high-order (first) 20 bytes** of the hash. The Rust equivalent `hash[0..20]` also takes the first 20 bytes. Do NOT use `address(uint160(uint256(keccak256(...))))` — that takes the **low-order (last) 20 bytes** and will produce a different address.

Properties:
- **Deterministic**: same pubkey always produces the same derived address
- **Collision-resistant**: ~2^160 bits of entropy (same security as Ethereum addresses)
- **One-way**: cannot recover the Solana pubkey from the derived address
- **Verifiable**: given the real pubkey, anyone can verify `derive(pubkey) == derivedAddr`

### Verified Test Vector

```
Input (Solana pubkey):  0x7c9e73d4c71dae564d41f78d56439bb4ba87592f1234567890abcdef12345678
keccak256 hash:         0x634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef3172d36614d1f40b04cb8cf5
Derived (HIGH bytes20): 0x634FDEe3bDfA25a4d703F1F9E7a4c6fFa4C650ef  ← correct
Wrong   (LOW uint160):  0xe7a4C6Ffa4c650ef3172D36614D1f40b04Cb8cf5  ← DO NOT USE
```

Test: `test/foundry/SolanaDerivation.t.sol::test_derivation_byte_ordering`

### EVM→Solana Flow

A user on Ethereum wants to send USDC and receive USDC on Solana.

**Order construction** (off-chain, by solver SDK):

```javascript
const order = {
    inputAmount: 1000e6,                          // 1000 USDC
    outputAmount: 999e6,                           // 999 USDC (after spread)
    inputToken: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48", // EVM USDC
    startTime: now,
    endTime: now + 3600,
    srcEid: 30101,                                 // Ethereum
    dstEid: 30168,                                 // Solana
    offerer: "0xUserEVMAddress",                   // real EVM address
    recipient: derive(solanaUserPubkey),            // derived 20-byte
    options: {
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: "0xFeeRecipientEVM",         // MUST be real EVM (see Critical Safety Invariant)
        srcSolver: "0xSolverEVM",                  // real EVM (validated on EVM)
        dstSolver: derive(solverSolanaPubkey),      // derived (validated on Solana)
    }
};

// User signs via EIP-712 — derived addresses are just regular address values
const signature = signTypedData(order);
```

**Step 1: Deposit on EVM**

Solver calls `deposit(order, signature)` on the EVM Aori contract. No contract changes needed.

```
EVM contract executes:
1. validateDeposit() — checks offerer signature, srcSolver authorization
   - offerer is real EVM address ✓ (SignatureCheckerLib works)
   - srcSolver is real EVM address ✓ (msg.sender == srcSolver works)
2. safeTransferFrom(offerer, this, inputAmount) — real EVM token, real EVM address ✓
3. $.balances[offerer][inputToken].locked += inputAmount — real EVM keys ✓
4. $.orders[orderId] = order — stores full order including derived addresses
5. $.orderStatus[orderId] = Active
```

The derived addresses (recipient, dstSolver) are stored in the order but never accessed during deposit.

**Step 2: Fill on Solana**

The solver calls `fill()` on the Solana Aori program. This does NOT touch the EVM contract.

```rust
// Solana program
fn fill(
    ctx: Context<Fill>,
    order: AoriOrder,               // order with derived addresses
    real_recipient: Pubkey,          // actual Solana recipient
    real_output_mint: Pubkey,        // actual SPL token mint
) -> Result<()> {
    // 1. Compute orderId identically to EVM
    let order_id = keccak256(abi_encode_order(&order));

    // 2. Verify derived addresses match the real ones
    require!(derive(&real_recipient) == order.recipient, "recipient mismatch");
    require!(derive(&real_output_mint) == order.output_token, "token mismatch");

    // 3. Validate order
    require!(order.dst_eid == SOLANA_EID, "wrong chain");
    require!(order_status[order_id] == Unknown, "already processed");

    // 4. Validate dstSolver authorization
    if order.options.dst_solver != ZERO_ADDR {
        require!(derive(&ctx.accounts.solver.key()) == order.options.dst_solver, "unauthorized");
    }

    // 5. Transfer SPL tokens: solver → recipient
    let cpi_ctx = CpiContext::new(token_program, Transfer {
        from: solver_token_account,
        to: recipient_token_account,
        authority: solver,
    });
    token::transfer(cpi_ctx, order.output_amount)?;

    // 6. Record fill
    order_status[order_id] = Filled;
    filler_fills.push(order_id);

    // 7. Register real pubkeys in reverse lookup (for settlement)
    reverse_registry.register(order.recipient, real_recipient);
    reverse_registry.register(order.output_token, real_output_mint);

    Ok(())
}
```

Key point: the Solana program accepts the real Solana pubkeys as separate parameters and **verifies** they match the derived addresses in the order. This is trustless — the derivation is checked on-chain.

**Step 3: Settlement (Solana → EVM)**

The solver calls `settle()` on the Solana program to send an LZ message to EVM.

```rust
// Solana program
fn settle(
    ctx: Context<Settle>,
    src_eid: u32,                    // EVM source chain endpoint
) -> Result<()> {
    let solver = ctx.accounts.solver.key();
    let fills = &filler_fills[src_eid][solver];
    require!(!fills.is_empty(), "no fills");

    // Look up this solver's registered EVM address from the solver registry
    let solver_evm_address = solver_registry.get_evm_address(&solver)?;

    let count = min(fills.len(), max_fills_per_settle);

    // Pack settlement payload (same format as EVM):
    // [0x00][solver_evm_addr: 20 bytes][count: 2 bytes][hashes: N * 32 bytes]
    let payload = pack_settlement(solver_evm_address, &fills[..count]);

    // Send via LayerZero to EVM source chain
    lz_send(src_eid, payload)?;

    // Remove settled fills from array
    // ...

    Ok(())
}
```

The solver's EVM address is looked up from the solver registry (see Solver Registry section). The EVM contract credits `$.balances[filler][inputToken]` using this address.

**Step 4: EVM receives settlement**

Standard `_lzReceive()` flow, completely unchanged:

```
EVM contract receives LZ message from Solana:
1. handleSettlement(payload, senderEid=30168)
2. Unpacks: filler=0xSolverEVM, orderHashes=[hash1, hash2, ...]
3. For each orderId:
   a. Loads stored order: $.orders[orderId]
   b. Checks order.dstEid == senderEid (30168 == 30168) ✓
   c. Deducts $.balances[offerer][inputToken].locked
   d. Credits $.balances[filler][inputToken].unlocked
   e. Credits $.balances[feeRecipient][inputToken].unlocked (fee)
4. Solver calls withdraw() on EVM to claim tokens
```

All balance operations use `offerer` (real EVM), `inputToken` (real EVM), `filler` (real EVM), `feeRecipient` (real EVM). The derived addresses stored in the order are never touched.

### Solana→EVM Flow

A Solana user wants to send SOL and receive ETH on Ethereum.

**Order construction** (off-chain):

```javascript
const order = {
    inputAmount: 100e9,                            // 100 SOL (lamports)
    outputAmount: 1e18,                            // 1 ETH (wei)
    inputToken: derive(nativeSolMint),              // derived
    startTime: now,
    endTime: now + 3600,
    srcEid: 30168,                                 // Solana
    dstEid: 30101,                                 // Ethereum
    offerer: derive(solanaUserPubkey),              // derived
    recipient: "0xRecipientEVM",                   // real EVM address
    options: {
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: derive(feeRecipientSolana),  // derived (fee accrues on Solana)
        srcSolver: derive(solverSolanaPubkey),      // derived (validated on Solana)
        dstSolver: "0xSolverEVM",                  // real EVM (validated on EVM)
    }
};
```

**Step 1: Deposit on Solana**

```rust
// Solana program
fn deposit(
    ctx: Context<Deposit>,
    order: AoriOrder,
    real_offerer: Pubkey,
    real_input_mint: Pubkey,
    signature: Ed25519Signature,     // offerer's signature over order
) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));

    // Verify derivations
    require!(derive(&real_offerer) == order.offerer);
    require!(derive(&real_input_mint) == order.input_token);

    // Verify signature (ed25519 on Solana, not EIP-712)
    verify_ed25519(real_offerer, order_id, signature)?;

    // Validate srcSolver
    if order.options.src_solver != ZERO_ADDR {
        require!(derive(&ctx.accounts.solver.key()) == order.options.src_solver);
    }

    // Transfer SPL tokens from offerer to program vault
    token::transfer(offerer_ata → vault_ata, order.input_amount)?;

    // Store order and mark active
    orders[order_id] = order;
    order_status[order_id] = Active;

    // Register real pubkeys in reverse lookup (for settlement receive)
    reverse_registry.register(order.offerer, real_offerer);
    reverse_registry.register(order.input_token, real_input_mint);
    if order.options.fee_recipient != ZERO_ADDR {
        // feeRecipient pubkey must be provided as additional parameter
        reverse_registry.register(order.options.fee_recipient, real_fee_recipient);
    }

    Ok(())
}
```

**Step 2: Fill on EVM**

Solver calls `fill(order)` on the EVM Aori contract. Completely standard, no changes.

```
EVM contract executes:
1. validateFill() — checks dstSolver authorization
   - dstSolver is real EVM address ✓ (msg.sender == dstSolver works)
   - order.dstEid == ENDPOINT_ID ✓
   - orderStatus(orderId) == Unknown ✓ (cross-chain, never seen on EVM)
2. outputToken.validateMsgValue(outputAmount, msg.value) — real EVM token ✓
3. outputToken.safeTransferFromChecked(solver, recipient, outputAmount) — both real EVM ✓
4. $.orderStatus[orderId] = Filled
5. $.srcEidToFillerFills[srcEid=30168][solver].push(orderId)
```

`offerer` and `inputToken` are derived addresses in calldata — they contribute to the orderId hash but the contract never reads them for balance/transfer ops.

**Step 3: Settlement (EVM → Solana)**

Solver calls `settle(srcEid=30168, filler, extraOptions)` on EVM. Standard flow:

```
EVM contract:
1. Packs pending order hashes into settlement payload
2. _lzSend(30168, payload, extraOptions) — sends to Solana
```

The payload contains `filler` as a 20-byte EVM address.

**Step 4: Solana receives settlement**

```rust
// Solana program receives LZ message from EVM
fn lz_receive(payload: &[u8], sender_eid: u32) -> Result<()> {
    let (filler_evm_addr, order_hashes) = unpack_settlement(payload);

    // Map EVM filler address to Solana solver via the solver registry
    let solver_pubkey = solver_registry.get_solana_address(&filler_evm_addr)?;

    for order_id in order_hashes {
        let order = orders[order_id];

        // Verify the settlement came from the right chain
        require!(order.dst_eid == sender_eid);

        // Reverse-lookup real pubkeys from derived addresses
        let real_input_mint = reverse_registry.get(order.input_token)?;
        let real_offerer = reverse_registry.get(order.offerer)?;

        // Credit solver: unlock input tokens to solver's vault
        balances[real_offerer][real_input_mint].locked -= order.input_amount;
        balances[solver_pubkey][real_input_mint].unlocked += filler_amount;

        // Fee distribution to feeRecipient (Solana address)
        if additional_fee > 0 {
            let real_fee_recipient = if order.options.fee_recipient == ZERO_ADDR {
                solver_pubkey
            } else {
                reverse_registry.get(order.options.fee_recipient)?
            };
            balances[real_fee_recipient][real_input_mint].unlocked += additional_fee;
        }

        order_status[order_id] = Settled;
    }

    Ok(())
}
```

### Cross-Chain Cancel

#### Cancel authorization by direction

Cancellation of cross-chain orders must happen from the **destination chain** (to prevent race conditions with settlement). The available cancel authorities depend on the order direction:

| Authority | EVM→SVM (cancel from Solana) | SVM→EVM (cancel from EVM) |
|-----------|------------------------------|---------------------------|
| **Whitelisted solver** | Yes, anytime | Yes, anytime |
| **Offerer** | **No** — offerer is a real EVM address; `derive(anySolanaPubkey)` will never match it | **No** — offerer is a derived address; no EVM private key corresponds to it |
| **Recipient** | Yes, after expiry — recipient is `derive(solanaUserPubkey)`, and the Solana user can prove `derive(theirKey) == order.recipient` | Yes, after expiry — recipient is a real EVM address |

**In both directions, the offerer cannot cancel from the destination chain.** This is an accepted protocol limitation. The offerer must rely on:
1. A whitelisted solver to cancel on their behalf (anytime), or
2. The recipient to cancel after order expiry

This limitation exists because derivation is one-way: no account on the destination chain can prove it "is" the offerer from the source chain.

**EVM→Solana order, cancelled from Solana (destination):**

```rust
// Solana program — cancel from destination
fn cancel_cross_chain(
    ctx: Context<Cancel>,
    order: AoriOrder,
) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));

    // Authorization: solver (anytime) or recipient (after expiry)
    let sender = ctx.accounts.signer.key();
    let is_solver = is_allowed_solver(&sender);
    let is_recipient = derive(&sender) == order.recipient && clock::now() > order.end_time;
    require!(is_solver || is_recipient, "unauthorized");

    // Mark cancelled on Solana
    order_status[order_id] = Cancelled;

    // Send LZ cancel message to EVM source chain
    let payload = pack_cancellation(order_id);
    lz_send(order.src_eid, payload)?;

    Ok(())
}
```

EVM receives the cancel via `_lzReceive()` → `handleCancellation()`. Standard flow: validates `orderDstEid == srcEid`, cancels order, returns locked tokens to offerer (real EVM address).

**Solana→EVM order, cancelled from EVM (destination):**

```
EVM contract — cancel(orderId, order, extraOptions):
1. validateCancel():
   - isAllowedSolver(sender)? → solver can cancel anytime ✓
   - sender == order.offerer? → offerer is derived, no EVM account matches ✗
   - sender == order.recipient? → recipient is real EVM address ✓ (after expiry)
2. Packs cancellation payload, sends LZ to Solana
```

---

### Critical Safety Invariant: feeRecipient

**If `feeRecipient` is set to a derived (non-EVM) address for an order where the source chain is EVM, the fee is permanently lost.**

Settlement fees accrue on the **source chain**. For EVM→SVM orders, the source chain is EVM. The settlement code executes:
```solidity
$.balances[feeRecipient][inputToken].unlocked += additionalFee;
```

If `feeRecipient` is a derived address (from a Solana pubkey), no EVM private key can call `withdraw()` for that balance. The tokens are locked forever.

**This invariant is NOT enforced by the protocol** — the EVM contract cannot distinguish derived addresses from real ones. It MUST be enforced by the solver SDK:

| Source chain | feeRecipient constraint |
|--------------|------------------------|
| **EVM** (EVM→SVM orders) | **MUST be a real EVM address** or `address(0)` (defaults to solver) |
| **Solana** (SVM→EVM orders) | Can be a derived Solana address — fee accrues on Solana where the program handles distribution |

The solver SDK MUST validate this before constructing orders. A misconfigured feeRecipient results in **unrecoverable fund loss**.

---

### Per-Direction Field Constraints

| Field | EVM→SVM | SVM→EVM | Why |
|-------|---------|---------|-----|
| `offerer` | Real EVM | Derived | EVM deposit uses it for balance ops and signature verification |
| `inputToken` | Real EVM | Derived | EVM deposit uses it for token transfers |
| `outputToken` | Derived | Real EVM | EVM fill uses it for token transfers |
| `recipient` | Derived | Real EVM | EVM fill uses it for token transfers |
| `srcSolver` | Real EVM | Derived | Validated on source chain (EVM for EVM→SVM) |
| `dstSolver` | Derived | Real EVM | Validated on destination chain (EVM for SVM→EVM) |
| `feeRecipient` | **Real EVM** (critical) | Derived | Settlement fee accrues on source chain — see Critical Safety Invariant |

**Rule**: If a field is used for balance operations, token transfers, or cryptographic verification on EVM, it must be a real EVM address. Fields only used on Solana can be derived addresses on EVM.

---

### ABI Encoding Specification (Cross-Chain Hash Parity)

The orderId `keccak256(abi.encode(order))` must be computed identically on both chains. This is the single most likely source of integration bugs.

#### Verified Layout

`abi.encode(order)` produces **480 bytes** (15 fields × 32 bytes each). Nested structs are encoded inline (not as tuple pointers) when all fields are value types.

```
Offset  Field                    Type       Encoding
──────  ─────────────────────    ────       ────────────────────────────────────────
  0     order.inputAmount        uint128    left-padded to 32 bytes
 32     order.outputAmount       uint128    left-padded to 32 bytes
 64     order.inputToken         address    left-padded to 32 bytes (12 zero bytes + 20 byte addr)
 96     order.startTime          uint32     left-padded to 32 bytes
128     order.endTime            uint32     left-padded to 32 bytes
160     order.srcEid             uint32     left-padded to 32 bytes
192     order.outputToken        address    left-padded to 32 bytes
224     order.dstEid             uint32     left-padded to 32 bytes
256     order.offerer            address    left-padded to 32 bytes
288     order.recipient          address    left-padded to 32 bytes
320     options.feeMbps          uint16     left-padded to 32 bytes
352     options.slippageMbps     uint16     left-padded to 32 bytes
384     options.feeRecipient     address    left-padded to 32 bytes
416     options.srcSolver        address    left-padded to 32 bytes
448     options.dstSolver        address    left-padded to 32 bytes
──────
480 bytes total
```

**Critical**: Field order follows the Solidity struct declaration order, NOT alphabetical order. The Options fields are appended inline after the Order fields.

**"Left-padded"** means the value occupies the rightmost bytes of the 32-byte word. For `address` types: `0x000000000000000000000000<20-byte-address>`. For derived addresses, the same padding applies — the 20-byte derived address is left-padded with 12 zero bytes.

#### Reference Test Vector

Using a sample order (from `test/foundry/SolanaDerivation.t.sol::test_abi_encode_order_layout`):

```
inputAmount:  1000000000 (1000e6)
outputAmount: 999000000  (999e6)
inputToken:   0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48
startTime:    1700000000
endTime:      1700003600
srcEid:       30101
outputToken:  0x1234567890AbcdEF1234567890aBcdef12345678
dstEid:       30168
offerer:      0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa
recipient:    0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB
feeMbps:      50
slippageMbps: 0
feeRecipient: 0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC
srcSolver:    0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd
dstSolver:    0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE

orderId: 0x8ca06a511bea20a73aa61309a5bc9540bba7bc78116a6045e6aafc4ffbec498e
```

The Solana program must produce this exact orderId for the same inputs.

---

### Solver Registry (Solana)

The solver registry maps between Solana pubkeys and EVM addresses for whitelisted solvers. It is **owner-managed** — the protocol admin registers both addresses when adding a solver.

#### Design

```rust
/// PDA seeds: [b"SolverRegistry", solana_pubkey.as_ref()]
struct SolverRegistryEntry {
    pub solana_pubkey: Pubkey,
    pub evm_address: [u8; 20],
    pub bump: u8,
}
```

#### Operations

| Operation | Access | Description |
|-----------|--------|-------------|
| `register_solver(solana_pubkey, evm_address)` | Owner only | Creates a bidirectional mapping. Validates entry doesn't already exist. |
| `remove_solver(solana_pubkey)` | Owner only | Removes the mapping. |
| `get_evm_address(solana_pubkey) → [u8; 20]` | Anyone (view) | Used by `settle()` to pack the filler's EVM address into the payload. |
| `get_solana_address(evm_address) → Pubkey` | Anyone (view) | Used by `lz_receive()` to credit the correct Solana solver when receiving settlement from EVM. |

#### Trust Model

Since solvers are already whitelisted by the protocol owner (via `addAllowedSolver` on EVM), extending this trust to include the Solana↔EVM address mapping is natural. The owner adds both addresses simultaneously on both chains. No self-registration is needed and no bidirectional attestation is required.

The EVM-side `addAllowedSolver` remains unchanged. On the Solana side, solver whitelisting and address mapping are combined into a single admin operation.

---

### Reverse Lookup Registry (Solana)

The reverse lookup registry maps derived 20-byte addresses back to real 32-byte Solana pubkeys. This is required because derivation is one-way (keccak256), but the Solana program needs real pubkeys for SPL token operations and balance accounting.

#### Design

```rust
/// PDA seeds: [b"ReverseLookup", derived_address[0..20]]
struct ReverseLookupEntry {
    pub derived_address: [u8; 20],
    pub real_pubkey: Pubkey,
    pub bump: u8,
}
```

#### Properties

- **Write-once**: Once a derived→pubkey mapping is registered, it cannot be overwritten. The derivation is deterministic — a given derived address maps to exactly one pubkey.
- **Verified on write**: Registration checks `derive(real_pubkey) == derived_address` before storing. This prevents anyone from registering a fake mapping.
- **Populated during deposit and fill**: When a Solana user deposits or a solver fills, they provide real pubkeys as instruction parameters. The program verifies derivation and registers the mapping atomically.
- **Rent paid by caller**: The account creation rent (~0.002 SOL per entry) is paid by the transaction signer (depositor or solver).

#### When Entries Are Created

| Operation | Entries registered |
|-----------|--------------------|
| `deposit()` on Solana (SVM→EVM) | `offerer`, `inputToken`, `feeRecipient` (if non-zero) |
| `fill()` on Solana (EVM→SVM) | `recipient`, `outputToken` |

All derived addresses in the order that will be needed for later settlement operations must be registered by the time settlement occurs.

---

### LayerZero Solana Integration

#### Endpoint Status

LayerZero V2 is live on Solana (Mainnet Beta). Endpoint ID: **30168** (mainnet), 40168 (devnet).

#### OApp Architecture on Solana

The Solana OApp pattern differs fundamentally from EVM:

| Aspect | EVM | Solana |
|--------|-----|--------|
| Language | Solidity | Rust (Anchor v0.31.1) |
| Pattern | Inheritance (`OAppUpgradeable`) | CPI calls to LZ endpoint program |
| OApp address | Contract address | **Store PDA** (not the program address) |
| Receive handler | `_lzReceive()` override | `lz_receive` instruction |
| Account discovery | Not needed | Required via `lz_receive_types_v2` |
| Reentrancy prevention | Modifier | `Endpoint::clear` CPI before state mutation |
| Compose | Same transaction | Separate transaction |

The Solana program must implement:
1. **`init`** — Initialize Store PDA, register with LZ endpoint
2. **`lz_receive`** — Handle incoming messages (settlement, cancellation)
3. **`lz_receive_types_v2`** — Return required accounts for `lz_receive` (enables executor to build transactions)
4. **`lz_receive_types_info`** — Return version info for forward compatibility

#### Payload Size Constraints

**Solana transaction limit: 1,232 bytes** (IPv6 MTU - 48 bytes). This constrains settlement payload sizes.

Settlement payload format: `1 byte type + 20 bytes filler + 2 bytes count + N × 32 bytes hashes`

| Fills | Payload size | Fits in 1,232 bytes? |
|-------|-------------|---------------------|
| 10 | 343 bytes | Yes |
| 20 | 663 bytes | Yes |
| 37 | 1,207 bytes | Yes (max safe) |
| 38 | 1,239 bytes | **No** |

**Maximum fills for Solana-bound settlement: 37** (payload alone). In practice, the effective limit is lower because the transaction must also include account references, signatures, and CPI overhead. With Address Lookup Tables (ALTs) reducing account key sizes, **20-30 fills per settlement is a realistic target**.

The Solana program should enforce its own `max_fills_per_settle` independently from the EVM value. For EVM→Solana settlements (where Solana receives), the EVM contract's `maxFillsPerSettle` should be configured to respect this limit for Solana-bound messages, or the Solana `lz_receive` handler should process only the first N fills and ignore the rest.

**Future**: SIMD-0296 proposes increasing Solana's transaction limit to 4,000 bytes, which would raise the fill limit to ~124. Timeline: Agave 4.1, not yet live.

Test: `test/foundry/SolanaDerivation.t.sol::test_settlement_payload_sizes`

#### EVM Configuration Required

Before EVM↔Solana orders can flow, each EVM Aori deployment needs:
```solidity
// Add Solana as supported chain
aori.addSupportedChain(30168);

// Set Solana program's Store PDA as peer (note: PDA, not program address)
aori.setPeer(30168, bytes32(solanaProgramStorePDA));
```

---

### Compute Budget on Solana

Keccak256 on Solana costs approximately **100 CU base + ~1 CU per byte** via the `sol_keccak256` syscall. Key operations:

| Operation | Estimated CU | Notes |
|-----------|-------------|-------|
| `keccak256(abi_encode(order))` | ~580 CU | 480-byte input |
| `derive(pubkey)` | ~130 CU | 32-byte input |
| SPL token transfer (CPI) | ~4,000-6,000 CU | Varies by token program |
| `Endpoint::clear` (LZ CPI) | ~10,000-15,000 CU | Estimate |

**Per-operation estimates:**

| Solana instruction | Estimated CU | Within default 200K? |
|-------------------|-------------|---------------------|
| `fill()` | ~50,000 CU | Yes |
| `deposit()` | ~40,000 CU | Yes |
| `settle()` (send LZ) | ~30,000 CU | Yes |
| `lz_receive()` (10 orders) | ~300,000 CU | No — requires `set_compute_unit_limit` |
| `lz_receive()` (30 orders) | ~900,000 CU | No — requires `set_compute_unit_limit` |

Settlement receive needs a compute budget increase (max requestable: 1,400,000 CU). The LZ executor handles this via `pre_execute` / `post_execute` instructions.

---

### What Needs to Be Built

| Component | Effort | Description |
|-----------|--------|-------------|
| Solana program | Large | Full Aori logic: deposit, fill, settle, cancel, balance management, LZ OApp integration via Anchor |
| LZ OApp integration (Solana) | Large | Anchor program implementing LZ V2 OApp interface: `init`, `lz_receive`, `lz_receive_types_v2`, peer config, executor setup |
| ABI encoding library (Solana) | Medium | Must produce **byte-identical** encoding to Solidity's `abi.encode` for Order struct (480 bytes, see ABI Encoding Specification) |
| Address derivation lib | Small | `derive()` function, shared between Solana program and solver SDK |
| Solver SDK | Medium | Order construction with derived addresses, per-direction field rules, feeRecipient safety validation |
| Solver registry (Solana) | Small | Owner-managed mapping: Solana pubkey ↔ EVM address (see Solver Registry section) |
| Reverse lookup registry (Solana) | Small | Write-once PDA mapping: derived address → real pubkey (see Reverse Lookup Registry section) |
| Cross-chain hash verification tests | Small | Construct same orders on both chains, assert identical orderId. **Must pass before any integration testing.** |
| EVM configuration | Small | `addSupportedChain(30168)` + `setPeer(30168, storePDA)` on all EVM deployments |
| Indexer updates | Small | Resolve derived addresses to real Solana addresses for display |

### EVM Contract Changes

**None.** The existing contracts handle this without modification.

### Limitations

1. **Offerer cannot cancel cross-chain orders**: In both directions (EVM→SVM and SVM→EVM), the offerer cannot cancel from the destination chain. Only whitelisted solvers (anytime) or the recipient (after expiry) can cancel. See Cancel Authorization section.
2. **One-way derivation**: Cannot recover Solana pubkey from derived address. Solana program needs a reverse lookup registry populated during deposit/fill operations.
3. **feeRecipient safety is SDK-enforced**: A misconfigured feeRecipient (derived address on an EVM-source order) causes permanent fund loss. The EVM contract cannot detect this. See Critical Safety Invariant section.
4. **AoriLens display**: Shows derived addresses for Solana entities. Off-chain tools must resolve via the reverse lookup registry or indexer.
5. **Solver must operate on both chains**: The solver needs an EVM address (for settlement crediting) and a Solana keypair (for filling on Solana). Both are registered by the protocol owner.
6. **Off-chain complexity**: Order construction must follow per-direction rules for which fields are real vs derived. The solver SDK encapsulates this.
7. **Settlement batch size**: Solana-bound settlements are limited to ~20-30 fills per batch due to Solana's 1,232-byte transaction limit (vs potentially higher limits on EVM-to-EVM).
8. **Payload size on Solana**: The 1,232-byte Solana transaction limit constrains max settlement payload. Account overhead further reduces available space. Use Address Lookup Tables (ALTs) to maximize payload room.

---

## Approach B: bytes32 Migration

### Core Idea

Change all 7 `address` fields in Order and Options to `bytes32`. Solana pubkeys are stored natively. EVM addresses are zero-extended to 32 bytes. The EVM contract casts `bytes32 → address` wherever it needs to interact with EVM-specific operations (token transfers, balance lookups, signature verification).

### Struct Changes

```solidity
// contracts/types/AoriTypes.sol

struct Order {
    uint128 inputAmount;    // ─┐ Slot 0
    uint128 outputAmount;   // ─┘
    bytes32 inputToken;     //   Slot 1
    bytes32 outputToken;    //   Slot 2
    uint32 startTime;       // ─┐
    uint32 endTime;         //  │ Slot 3
    uint32 srcEid;          //  │
    uint32 dstEid;          // ─┘
    bytes32 offerer;        //   Slot 4
    bytes32 recipient;      //   Slot 5
    Options options;        //   Slots 6-9
}

struct Options {
    uint16 feeMbps;         // ─┐ Slot 6
    uint16 slippageMbps;    // ─┘
    bytes32 feeRecipient;   //   Slot 7
    bytes32 srcSolver;      //   Slot 8
    bytes32 dstSolver;      //   Slot 9
}
```

Storage: 10 slots (was 8). The increase comes from `address` (20 bytes, packable) becoming `bytes32` (32 bytes, full slot each).

SrcHook and DstHook keep `address` types — hooks are always EVM contracts.

### Cast Helper Functions

```solidity
// contracts/utils/TokenUtils.sol (file scope, not inside the library)

function toAddress(bytes32 b) pure returns (address) {
    return address(uint160(uint256(b)));
}

function toBytes32(address a) pure returns (bytes32) {
    return bytes32(uint256(uint160(a)));
}
```

EVM addresses stored as bytes32 are zero-extended: `0x000000000000000000000000A0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48`. `toAddress()` extracts the lower 20 bytes. `toBytes32()` left-pads with zeros.

For Solana pubkeys, the full 32 bytes are stored. `toAddress()` on a Solana pubkey returns a truncated (meaningless) address — this should only be called on fields known to be EVM addresses.

### EVM→Solana Flow

**Order construction** (off-chain):

```javascript
const order = {
    inputAmount: 1000e6,
    outputAmount: 999e6,
    inputToken: toBytes32("0xA0b86991..."),        // EVM USDC, zero-extended
    startTime: now,
    endTime: now + 3600,
    srcEid: 30101,
    dstEid: 30168,
    offerer: toBytes32("0xUserEVM"),                // EVM address, zero-extended
    recipient: solanaUserPubkey,                    // raw 32-byte Solana pubkey
    options: {
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: toBytes32("0xFeeRecipient"),  // EVM address
        srcSolver: toBytes32("0xSolverEVM"),        // EVM address
        dstSolver: solverSolanaPubkey,              // raw 32-byte Solana pubkey
    }
};
```

**Step 1: Deposit on EVM**

The EVM contract casts bytes32 → address wherever it needs real addresses:

```solidity
// contracts/Aori.sol — deposit() with bytes32 fields

function deposit(Order calldata order, bytes calldata signature) external ... {
    // Cast inputToken for native token check
    if (toAddress(order.inputToken).isNativeToken()) revert UseDepositNativeForNativeTokens();

    bytes32 orderId = order.validateDeposit(
        signature, _hashOrder712(order), ENDPOINT_ID,
        _getAoriStorage().maxFeeMbps, msg.sender,
        this.orderStatus, this.isSupportedChain
    );

    // Cast inputToken and offerer for token transfer
    toAddress(order.inputToken).safeTransferFromChecked(
        toAddress(order.offerer), address(this), order.inputAmount
    );

    _postDeposit(toAddress(order.inputToken), order.inputAmount, order, orderId, address(0), 0);
}
```

```solidity
// contracts/utils/ValidationUtils.sol — validateDeposit() with bytes32 fields

function validateDeposit(...) internal view returns (bytes32 orderId) {
    orderId = keccak256(abi.encode(order));
    if (orderStatus(orderId) != OrderStatus.Unknown) revert OrderAlreadyExists();
    if (!isSupportedChain(order.dstEid)) revert DestinationChainNotSupported(order.dstEid);

    // Cast offerer for signature verification (EIP-712 uses EVM address)
    if (!SignatureCheckerLib.isValidSignatureNowCalldata(
        toAddress(order.offerer), digest, signature
    )) {
        revert InvalidSignature();
    }

    // Cast srcSolver for authorization — compare as bytes32
    if (order.options.srcSolver != bytes32(0) && toBytes32(solver) != order.options.srcSolver) {
        revert UnauthorizedSolver();
    }

    validateCommonOrderParams(order, maxFeeMbps);
}
```

```solidity
// contracts/utils/ValidationUtils.sol — zero-checks use bytes32(0)

function validateCommonOrderParams(Order calldata order, uint16 maxFeeMbps) internal view {
    if (order.offerer == bytes32(0)) revert InvalidOfferer();
    if (order.recipient == bytes32(0)) revert InvalidRecipient();
    if (order.inputToken == bytes32(0) || order.outputToken == bytes32(0)) revert InvalidToken();
    // ... time and amount checks unchanged
}
```

```solidity
// contracts/Aori.sol — _postDeposit stores order, casts for balance ops

function _postDeposit(
    address depositToken,    // always a real EVM address
    uint256 depositAmount,
    Order calldata order,
    bytes32 orderId,
    address srcHookTokenOut,
    uint256 srcHookAmountOut
) internal {
    AoriStorageData storage $ = _getAoriStorage();

    // Cast offerer for balance mapping key
    $.balances[toAddress(order.offerer)][depositToken].lock(SafeCast.toUint128(depositAmount));
    $.orderStatus[orderId] = OrderStatus.Active;
    $.orders[orderId] = order;

    // If hook converted tokens, update stored order with the actual deposit token
    $.orders[orderId].inputToken = toBytes32(depositToken);
    $.orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

    emit Deposit(orderId, order, srcHookTokenOut, srcHookAmountOut);
}
```

**Step 2: Fill on Solana**

The Solana program reads bytes32 fields directly — no derivation needed:

```rust
// Solana program — fill with native bytes32 fields
fn fill(
    ctx: Context<Fill>,
    order: AoriOrder,    // bytes32 fields contain real Solana pubkeys
) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));

    require!(order.dst_eid == SOLANA_EID);
    require!(order_status[order_id] == Unknown);

    // dstSolver authorization — direct comparison, no derivation
    if order.options.dst_solver != ZERO_BYTES32 {
        let solver_bytes32 = pubkey_to_bytes32(&ctx.accounts.solver.key());
        require!(solver_bytes32 == order.options.dst_solver, "unauthorized");
    }

    // recipient and outputToken are real Solana pubkeys — use directly
    let recipient = Pubkey::new_from_array(order.recipient);
    let output_mint = Pubkey::new_from_array(order.output_token);

    // Transfer SPL tokens
    token::transfer(solver_ata → recipient_ata, order.output_amount)?;

    order_status[order_id] = Filled;
    filler_fills.push(order_id);

    Ok(())
}
```

No derivation, no registry, no verification step. The Solana pubkeys are stored directly in the order.

**Step 3–4: Settlement**

Same as Approach A — the settlement payload format doesn't change (filler is still 20-byte EVM address in the payload). The EVM settlement path casts stored order fields:

```solidity
// contracts/lib/AoriSettleLib.sol — _settleOrder with bytes32 fields

function _settleOrder(AoriStorageData storage $, bytes32 orderId, Order memory order, address filler) internal {
    // Cast offerer and inputToken for balance operations
    address offererAddr = toAddress(order.offerer);
    address inputTokenAddr = toAddress(order.inputToken);

    (uint128 protocolFee, uint128 additionalFee, uint128 fillerAmount) =
        ValidationUtils.calculateFees(order.inputAmount, $.protocolFeeMbps, order.options.feeMbps);

    // Cast feeRecipient
    address feeRecipient = order.options.feeRecipient == bytes32(0)
        ? filler
        : toAddress(order.options.feeRecipient);

    $.balances[offererAddr][inputTokenAddr].locked -= order.inputAmount;
    $.balances[filler][inputTokenAddr].unlocked += fillerAmount;

    if (protocolFee > 0) {
        $.pendingProtocolFees[inputTokenAddr] += protocolFee;
    }
    if (additionalFee > 0) {
        $.balances[feeRecipient][inputTokenAddr].unlocked += additionalFee;
    }

    $.orderStatus[orderId] = OrderStatus.Settled;
}
```

### Solana→EVM Flow

**Order construction**:

```javascript
const order = {
    inputAmount: 100e9,
    outputAmount: 1e18,
    inputToken: solanaSolMintPubkey,                // raw 32-byte Solana pubkey
    startTime: now,
    endTime: now + 3600,
    srcEid: 30168,                                  // Solana
    dstEid: 30101,                                  // Ethereum
    offerer: solanaUserPubkey,                       // raw 32-byte Solana pubkey
    recipient: toBytes32("0xRecipientEVM"),          // EVM address, zero-extended
    options: {
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: solanaFeeRecipientPubkey,      // Solana pubkey (fee on Solana)
        srcSolver: solverSolanaPubkey,               // validated on Solana
        dstSolver: toBytes32("0xSolverEVM"),         // validated on EVM
    }
};
```

**Fill on EVM**:

```solidity
// contracts/Aori.sol — fill() with bytes32 fields

function fill(Order calldata order) external payable ... {
    bytes32 orderId = order.validateFill(
        msg.sender, ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus
    );

    // Cast outputToken for msg.value validation
    toAddress(order.outputToken).validateMsgValue(order.outputAmount, msg.value);

    if (order.isSingleChainSwap()) {
        AoriSettleLib.settleSingleChainSwap(orderId, order, msg.sender, address(0), 0, 0);
    } else {
        _postFill(orderId, order, address(0), 0, 0);
    }

    // Cast outputToken and recipient for token transfer
    toAddress(order.outputToken).safeTransferFromChecked(
        msg.sender, toAddress(order.recipient), order.outputAmount
    );
}
```

In `validateFill`, dstSolver authorization compares bytes32 directly:

```solidity
// toBytes32(solver) converts msg.sender to bytes32 for comparison
if (order.options.dstSolver != bytes32(0) && toBytes32(solver) != order.options.dstSolver) {
    revert UnauthorizedSolver();
}
```

For SVM→EVM orders, `dstSolver` is `toBytes32(0xSolverEVM)` — the comparison works because `toBytes32(msg.sender) == toBytes32(0xSolverEVM)`.

### Cancel with bytes32

```solidity
// contracts/utils/ValidationUtils.sol — validateCancel with bytes32 fields

function validateCancel(...) internal view {
    if (order.dstEid != endpointId) revert NotOnDestinationChain();
    OrderStatus status = orderStatus(orderId);
    if (status != OrderStatus.Unknown) revert OrderAlreadyProcessed(status);

    // Compare sender as bytes32
    if (
        !isAllowedSolver(sender)
        && !(toBytes32(sender) == order.offerer && block.timestamp > order.endTime)
        && !(toBytes32(sender) == order.recipient && block.timestamp > order.endTime)
    ) {
        revert UnauthorizedCancel();
    }
}
```

For EVM→SVM orders cancelled from Solana: the Solana program handles cancel and sends LZ message to EVM. EVM `handleCancellation` only needs the orderId, not the offerer/recipient.

For SVM→EVM orders cancelled from EVM: `toBytes32(sender) == order.offerer` will never match (offerer is a Solana pubkey, no EVM account can produce it). But `toBytes32(sender) == order.recipient` works if recipient is an EVM address. Same limitation as Approach A.

### EIP-712 and Permit2 Changes

All typehash strings change from `address` to `bytes32`:

```solidity
// contracts/utils/Permit2Lib.sol

bytes32 internal constant OPTIONS_TYPEHASH = keccak256(
    "Options(uint16 feeMbps,uint16 slippageMbps,bytes32 feeRecipient,bytes32 srcSolver,bytes32 dstSolver)"
);

bytes32 internal constant ORDER_TYPEHASH = keccak256(
    "Order(uint128 inputAmount,uint128 outputAmount,bytes32 inputToken,bytes32 outputToken,"
    "uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,"
    "bytes32 offerer,bytes32 recipient,"
    "Options options)"
    "Options(uint16 feeMbps,uint16 slippageMbps,bytes32 feeRecipient,bytes32 srcSolver,bytes32 dstSolver)"
);

// hashOrder encodes fields in new struct order
function hashOrder(Order calldata order) internal pure returns (bytes32) {
    return keccak256(
        abi.encode(
            ORDER_TYPEHASH,
            order.inputAmount,
            order.outputAmount,
            order.inputToken,
            order.outputToken,
            order.startTime,
            order.endTime,
            order.srcEid,
            order.dstEid,
            order.offerer,
            order.recipient,
            hashOptions(order.options)
        )
    );
}

// buildPermit must cast inputToken for Permit2's TokenPermissions (always address)
function buildPermit(Order calldata order, uint256 nonce, uint256 deadline)
    internal pure returns (ISignatureTransfer.PermitTransferFrom memory permit)
{
    permit = ISignatureTransfer.PermitTransferFrom({
        permitted: ISignatureTransfer.TokenPermissions({
            token: toAddress(order.inputToken),  // Permit2 requires address
            amount: order.inputAmount
        }),
        nonce: nonce,
        deadline: deadline
    });
}

// executeTransfer casts offerer for Permit2 caller
function executeTransfer(Order calldata order, address to, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
    ISignatureTransfer(PERMIT2).permitWitnessTransferFrom(
        buildPermit(order, nonce, deadline),
        buildTransferDetails(to, order.inputAmount),
        toAddress(order.offerer),    // Permit2 requires address
        hashOrder(order),
        WITNESS_TYPE_STRING,
        signature
    );
}
```

This is a **breaking change** for all off-chain signers. The typehash changes mean existing EIP-712 signatures are invalid. Frontend signing code must update:

```typescript
// Updated frontend types
const ORDER_WITNESS_TYPES = {
    Order: [
        { name: "inputAmount", type: "uint128" },
        { name: "outputAmount", type: "uint128" },
        { name: "inputToken", type: "bytes32" },      // was address
        { name: "outputToken", type: "bytes32" },      // was address
        { name: "startTime", type: "uint32" },
        { name: "endTime", type: "uint32" },
        { name: "srcEid", type: "uint32" },
        { name: "dstEid", type: "uint32" },
        { name: "offerer", type: "bytes32" },          // was address
        { name: "recipient", type: "bytes32" },        // was address
    ],
};
```

### AoriLens Rewrite

The `orders()` function must read 10 storage slots instead of 8, with the new layout:

```solidity
function orders(bytes32 orderId) external view returns (Order memory order) {
    bytes32 baseSlot = keccak256(abi.encode(orderId, uint256(AORI_STORAGE_SLOT) + ORDERS_OFFSET));

    bytes32 slot0 = aori.readStorage(baseSlot);
    bytes32 slot1 = aori.readStorage(bytes32(uint256(baseSlot) + 1));
    bytes32 slot2 = aori.readStorage(bytes32(uint256(baseSlot) + 2));
    bytes32 slot3 = aori.readStorage(bytes32(uint256(baseSlot) + 3));
    bytes32 slot4 = aori.readStorage(bytes32(uint256(baseSlot) + 4));
    bytes32 slot5 = aori.readStorage(bytes32(uint256(baseSlot) + 5));
    bytes32 slot6 = aori.readStorage(bytes32(uint256(baseSlot) + 6));
    bytes32 slot7 = aori.readStorage(bytes32(uint256(baseSlot) + 7));
    bytes32 slot8 = aori.readStorage(bytes32(uint256(baseSlot) + 8));
    bytes32 slot9 = aori.readStorage(bytes32(uint256(baseSlot) + 9));

    // Slot 0: inputAmount (lower 128) | outputAmount (upper 128)
    order.inputAmount = uint128(uint256(slot0));
    order.outputAmount = uint128(uint256(slot0) >> 128);

    // Slots 1-2: full bytes32 fields
    order.inputToken = slot1;
    order.outputToken = slot2;

    // Slot 3: startTime(32) | endTime(32) | srcEid(32) | dstEid(32)
    order.startTime = uint32(uint256(slot3));
    order.endTime = uint32(uint256(slot3) >> 32);
    order.srcEid = uint32(uint256(slot3) >> 64);
    order.dstEid = uint32(uint256(slot3) >> 96);

    // Slots 4-5: full bytes32 fields
    order.offerer = slot4;
    order.recipient = slot5;

    // Slot 6: feeMbps (lower 16) | slippageMbps (bits 16-31)
    order.options.feeMbps = uint16(uint256(slot6));
    order.options.slippageMbps = uint16(uint256(slot6) >> 16);

    // Slots 7-9: full bytes32 fields
    order.options.feeRecipient = slot7;
    order.options.srcSolver = slot8;
    order.options.dstSolver = slot9;
}
```

### Files Changed

| File | Change |
|------|--------|
| `contracts/types/AoriTypes.sol` | Order and Options structs: 7 fields address → bytes32, reorder |
| `contracts/utils/TokenUtils.sol` | Add `toAddress()` and `toBytes32()` free functions |
| `contracts/utils/Permit2Lib.sol` | All typehashes, hash functions, buildPermit/executeTransfer casts |
| `contracts/utils/ValidationUtils.sol` | Zero-checks → bytes32(0), all address comparisons use casts |
| `contracts/Aori.sol` | ~15 cast sites for balance ops, token transfers, solver resolution |
| `contracts/lib/AoriSettleLib.sol` | Cast offerer, inputToken, feeRecipient for balance ops |
| `contracts/lib/AoriCancelLib.sol` | Cast inputToken, offerer in _cancelOrder |
| `contracts/lib/AoriAtomicSwapLib.sol` | Cast outputToken, recipient, feeRecipient |
| `contracts/lib/AoriAdminLib.sol` | Cast inputToken, offerer in emergencyCancel |
| `contracts/AoriLens.sol` | Rewrite orders() for 10-slot layout, update balance getters |
| `contracts/interfaces/IAori.sol` | Events unchanged (use explicit address params at emit sites) |
| `test/foundry/*.t.sol` | 30+ files: wrap address literals with toBytes32() |
| `test/foundry/TestUtils.sol` | Update helpers, EIP-712 type strings |

### Bytecode Size Risk

Aori.sol is currently 24,501 / 24,576 bytes (75 byte margin). Each `toAddress()` call adds ~13 bytes of bytecode. With ~15 cast sites in Aori.sol alone, this will likely exceed the limit.

Mitigation (**required** — not deferrable):
- Move fill() variants to `AoriFillLib.sol` (external library via delegatecall)
- Same pattern as existing AoriSettleLib/AoriCancelLib

### Limitations

1. **EIP-712 breaking change**: All typehashes change. Existing signatures invalid.
2. **Offerer can't cancel from destination**: Same as Approach A — no account on the destination chain can prove it "is" the source-chain offerer.
3. **Storage cost**: 10 slots per order vs 8 (25% increase in order storage gas).
4. **Bytecode pressure**: Exceeds 24KB limit, requiring fill() to be moved to external library.
5. **Order hash breaking change**: Struct field reorder means all existing order hashes change.

---

## Comparison

| Dimension | Approach A (Derivation) | Approach B (bytes32) |
|-----------|------------------------|---------------------|
| **EVM contract changes** | None | ~15 files, significant refactor |
| **Storage slots per order** | 8 (unchanged) | 10 (+25%) |
| **Bytecode risk** | None | Exceeds 24KB, requires fill() extraction |
| **On-chain representation** | Derived 20-byte address (opaque) | Native 32-byte pubkey (transparent) |
| **Solana program complexity** | Higher (derivation verification, reverse lookup registry) | Lower (reads bytes32 directly) |
| **Off-chain complexity** | Higher (derivation in SDK, per-direction rules) | Lower (uniform bytes32 everywhere) |
| **EIP-712 breaking** | No | Yes |
| **Order hash compatibility** | Unchanged (same abi.encode output) | Broken (struct reorder changes all hashes) |
| **AoriLens display** | Derived addresses (needs resolver) | Native pubkeys (self-describing) |
| **Trustlessness** | Equivalent (derivation verified on-chain on Solana) | Equivalent |
| **Cancel limitation** | Offerer can't cancel from destination chain | Same |
| **Solana fill simplicity** | Needs real pubkey params + derivation check | Direct — reads pubkey from order |
| **Future non-EVM chains** | Each chain implements derivation | Native support, no derivation needed |
| **Deployment risk** | Zero — ship immediately | Coordinated upgrade across 8+ chains |
