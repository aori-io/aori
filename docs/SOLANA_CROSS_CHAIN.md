# Solana Cross-Chain: Spec + Implementation Reference

---

## Problem

Aori settles cross-chain intents using LayerZero. All on-chain types use Solidity's `address` (20 bytes). Solana public keys are 32 bytes (ed25519). We use **deterministic address derivation** to represent Solana pubkeys as 20-byte EVM addresses. Zero EVM contract changes.

---

## Address Derivation

`keccak256(solana_pubkey)[0..20]` — take the HIGH-order 20 bytes.

### Solidity

```solidity
function derive(bytes32 solanaPubkey) internal pure returns (address) {
    return address(bytes20(keccak256(abi.encodePacked(solanaPubkey))));
}
```

### Rust

```rust
use tiny_keccak::{Hasher, Keccak};

pub fn derive(solana_pubkey: &[u8; 32]) -> [u8; 20] {
    let mut hasher = Keccak::v256();
    hasher.update(solana_pubkey);
    let mut hash = [0u8; 32];
    hasher.finalize(&mut hash);
    let mut result = [0u8; 20];
    result.copy_from_slice(&hash[0..20]);
    result
}
```

### HIGH vs LOW bytes

```
Full hash: 634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef3172d36614d1f40b04cb8cf5

bytes20 (HIGH, correct):   bytes 0..19  → 634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef
uint160 (LOW, wrong):      bytes 12..31 → e7a4c6ffa4c650ef3172d36614d1f40b04cb8cf5
```

`bytes20()` truncates from the right (keeps left). `uint160(uint256())` truncates from the left (keeps right). Two different addresses. We use `bytes20()`.

### Properties

- **Deterministic**: same pubkey always produces the same derived address
- **Collision-resistant**: ~2^160 bits of entropy (same security as Ethereum addresses)
- **One-way**: cannot recover the Solana pubkey from the derived address
- **Infeasible to grind**: matching all 20 bytes requires ~2^160 attempts

### Reference Vector

```
pubkey:  7c9e73d4c71dae564d41f78d56439bb4ba87592f1234567890abcdef12345678
hash:    634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef3172d36614d1f40b04cb8cf5
derived: 634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef
```

### Safety (tested)

| Property | Verification |
|---|---|
| Never produces `address(0)` | Fuzz test (1000 random pubkeys) + explicit vectors |
| Never produces `NATIVE_TOKEN` (`0xEeee...eE`) | Fuzz test (1000 random pubkeys) + explicit vectors |
| Deterministic | Same input always gives same output |
| Collision-resistant | 5-key pairwise check + keccak256 properties |
| HIGH-order byte selection | Explicit test comparing `bytes20()` vs `uint160(uint256())` |

---

## Order Structs

Field order must match the Solidity struct declaration for ABI encoding parity.

### Solidity

```solidity
struct Order {
    uint128 inputAmount;
    uint128 outputAmount;
    address inputToken;
    uint32  startTime;
    uint32  endTime;
    uint32  srcEid;
    address outputToken;
    uint32  dstEid;
    address offerer;
    address recipient;
    Options options;
}

struct Options {
    uint16  feeMbps;
    uint16  slippageMbps;
    address feeRecipient;
    address srcSolver;
    address dstSolver;
}
```

### Rust

```rust
pub struct Order {
    pub input_amount: u128,
    pub output_amount: u128,
    pub input_token: [u8; 20],
    pub start_time: u32,
    pub end_time: u32,
    pub src_eid: u32,
    pub output_token: [u8; 20],
    pub dst_eid: u32,
    pub offerer: [u8; 20],
    pub recipient: [u8; 20],
    pub options: Options,
}

pub struct Options {
    pub fee_mbps: u16,
    pub slippage_mbps: u16,
    pub fee_recipient: [u8; 20],
    pub src_solver: [u8; 20],
    pub dst_solver: [u8; 20],
}
```

Address fields are `[u8; 20]`. Derived addresses from `derive()` go directly into these fields.

---

## ABI Encoding

`abi.encode(order)` produces 480 bytes (15 fields x 32 bytes). Each field left-padded (value in rightmost bytes of its 32-byte word). Nested `Options` encoded inline (not as a pointer).

### Solidity

```solidity
bytes memory encoded = abi.encode(order);  // 480 bytes
bytes32 orderId = keccak256(encoded);
```

### Rust

```rust
pub fn abi_encode_order(order: &Order) -> [u8; 480] {
    let mut buf = [0u8; 480];
    let mut offset = 0;

    write_u128(&mut buf, offset, order.input_amount);    offset += 32;
    write_u128(&mut buf, offset, order.output_amount);   offset += 32;
    write_address(&mut buf, offset, &order.input_token); offset += 32;
    write_u32(&mut buf, offset, order.start_time);       offset += 32;
    write_u32(&mut buf, offset, order.end_time);         offset += 32;
    write_u32(&mut buf, offset, order.src_eid);          offset += 32;
    write_address(&mut buf, offset, &order.output_token);offset += 32;
    write_u32(&mut buf, offset, order.dst_eid);          offset += 32;
    write_address(&mut buf, offset, &order.offerer);     offset += 32;
    write_address(&mut buf, offset, &order.recipient);   offset += 32;
    write_u16(&mut buf, offset, order.options.fee_mbps);          offset += 32;
    write_u16(&mut buf, offset, order.options.slippage_mbps);     offset += 32;
    write_address(&mut buf, offset, &order.options.fee_recipient);offset += 32;
    write_address(&mut buf, offset, &order.options.src_solver);   offset += 32;
    write_address(&mut buf, offset, &order.options.dst_solver);

    buf
}

pub fn order_id(order: &Order) -> [u8; 32] {
    let encoded = abi_encode_order(order);
    let mut hasher = Keccak::v256();
    hasher.update(&encoded);
    let mut hash = [0u8; 32];
    hasher.finalize(&mut hash);
    hash
}
```

### Encoding helpers

Each writes to the rightmost bytes of a 32-byte word:

```rust
fn write_u128(buf: &mut [u8], offset: usize, value: u128) {
    buf[offset + 16..offset + 32].copy_from_slice(&value.to_be_bytes());
}
fn write_u32(buf: &mut [u8], offset: usize, value: u32) {
    buf[offset + 28..offset + 32].copy_from_slice(&value.to_be_bytes());
}
fn write_u16(buf: &mut [u8], offset: usize, value: u16) {
    buf[offset + 30..offset + 32].copy_from_slice(&value.to_be_bytes());
}
fn write_address(buf: &mut [u8], offset: usize, addr: &[u8; 20]) {
    buf[offset + 12..offset + 32].copy_from_slice(addr);
}
```

### Encoding layout

```
Offset  Field            Type       Padding
  0     inputAmount      uint128    16 zero bytes + 16 value bytes
 32     outputAmount     uint128    16 zero bytes + 16 value bytes
 64     inputToken       address    12 zero bytes + 20 value bytes
 96     startTime        uint32     28 zero bytes + 4 value bytes
128     endTime          uint32     28 zero bytes + 4 value bytes
160     srcEid           uint32     28 zero bytes + 4 value bytes
192     outputToken      address    12 zero bytes + 20 value bytes
224     dstEid           uint32     28 zero bytes + 4 value bytes
256     offerer          address    12 zero bytes + 20 value bytes
288     recipient        address    12 zero bytes + 20 value bytes
320     feeMbps          uint16     30 zero bytes + 2 value bytes
352     slippageMbps     uint16     30 zero bytes + 2 value bytes
384     feeRecipient     address    12 zero bytes + 20 value bytes
416     srcSolver        address    12 zero bytes + 20 value bytes
448     dstSolver        address    12 zero bytes + 20 value bytes
---
480 bytes total
```

Field order follows the Solidity struct declaration order, NOT alphabetical. Options fields appended inline after Order fields.

---

## Per-Direction Field Rules

Source-side fields use native addresses. Destination-side fields use derived addresses.

### EVM -> Solana

| Field | Value | Why |
|---|---|---|
| `offerer` | Real EVM address | Signature verification + balance ops on EVM |
| `inputToken` | Real EVM address | Token transfer on EVM |
| `srcSolver` | Real EVM address | Solver auth on EVM (`msg.sender` check) |
| `feeRecipient` | **Real EVM address** | Fee accrues on source chain. **Derived = permanent fund loss** |
| `recipient` | `derive(solana_pubkey)` | Only used on Solana |
| `outputToken` | `derive(solana_mint)` | Only used on Solana |
| `dstSolver` | `derive(solana_solver)` | Solver auth on Solana |

### Solana -> EVM

| Field | Value | Why |
|---|---|---|
| `offerer` | `derive(solana_pubkey)` | Balance ops on Solana |
| `inputToken` | `derive(solana_mint)` | Token ops on Solana |
| `srcSolver` | `derive(solana_solver)` | Solver auth on Solana |
| `feeRecipient` | `derive(solana_pubkey)` | Fee accrues on Solana — OK |
| `recipient` | Real EVM address | Token transfer on EVM |
| `outputToken` | Real EVM address | Token transfer on EVM |
| `dstSolver` | Real EVM address | Solver auth on EVM |

### Which fields are used where

**Source chain operations** (deposit, settlement receive, source-chain cancel):
- `offerer` — balance key for locking/unlocking tokens
- `inputToken` — balance key and token transfer target
- `options.srcSolver` — solver authorization during deposit
- `options.feeRecipient` — fee accrual during settlement

**Destination chain operations** (fill, settle-send, cross-chain cancel):
- `outputToken` — token transfer during fill
- `recipient` — transfer target during fill
- `options.dstSolver` — solver authorization during fill

**Never used on-chain** (stored for hash identity only):
- On source chain: `outputToken`, `recipient`, `dstSolver`
- On destination chain: `offerer`, `inputToken`, `srcSolver`

### Critical: feeRecipient safety

If `feeRecipient` is a derived address on an EVM-source order, fees are permanently locked. No EVM private key can call `withdraw()`. The EVM contract cannot detect this — must be enforced by the SDK/solver.

---

## Cross-Chain Order Examples

### EVM -> Solana

#### Solidity

```solidity
Order memory order = Order({
    inputAmount: 1000e6,
    outputAmount: 999e6,
    inputToken: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,  // real USDC
    startTime: 1700000000,
    endTime: 1700003600,
    srcEid: 30101,                                              // Ethereum
    outputToken: derive(outputTokenPubkey),                     // derived
    dstEid: 30168,                                              // Solana
    offerer: 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa,       // real EVM
    recipient: derive(recipientPubkey),                         // derived
    options: Options({
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: 0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC, // real EVM
        srcSolver: 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd,   // real EVM
        dstSolver: derive(dstSolverPubkey)                        // derived
    })
});
```

#### Rust

```rust
let order = Order {
    input_amount: 1_000_000_000,
    output_amount: 999_000_000,
    input_token: hex_to_bytes20("a0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"),
    start_time: 1_700_000_000,
    end_time: 1_700_003_600,
    src_eid: 30101,
    output_token: derive(&output_token_pubkey),
    dst_eid: 30168,
    offerer: hex_to_bytes20("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
    recipient: derive(&recipient_pubkey),
    options: Options {
        fee_mbps: 50,
        slippage_mbps: 0,
        fee_recipient: hex_to_bytes20("cccccccccccccccccccccccccccccccccccccccc"),
        src_solver: hex_to_bytes20("dddddddddddddddddddddddddddddddddddddddd"),
        dst_solver: derive(&dst_solver_pubkey),
    },
};
```

**orderId:** `dba34ed4fdc13c266ebe4cbf18ef17b0451ecc370b008419b0d744d096afb9c1`

### Solana -> EVM

#### Solidity

```solidity
Order memory order = Order({
    inputAmount: 100e9,
    outputAmount: 1e18,
    inputToken: derive(inputTokenPubkey),                       // derived
    startTime: 1700000000,
    endTime: 1700003600,
    srcEid: 30168,                                              // Solana
    outputToken: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,   // real WETH
    dstEid: 30101,                                              // Ethereum
    offerer: derive(offererPubkey),                             // derived
    recipient: 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB,      // real EVM
    options: Options({
        feeMbps: 50,
        slippageMbps: 0,
        feeRecipient: derive(feeRecipientPubkey),                // derived
        srcSolver: derive(srcSolverPubkey),                      // derived
        dstSolver: 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd   // real EVM
    })
});
```

#### Rust

```rust
let order = Order {
    input_amount: 100_000_000_000,
    output_amount: 1_000_000_000_000_000_000,
    input_token: derive(&input_token_pubkey),
    start_time: 1_700_000_000,
    end_time: 1_700_003_600,
    src_eid: 30168,
    output_token: hex_to_bytes20("c02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"),
    dst_eid: 30101,
    offerer: derive(&offerer_pubkey),
    recipient: hex_to_bytes20("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
    options: Options {
        fee_mbps: 50,
        slippage_mbps: 0,
        fee_recipient: derive(&fee_recipient_pubkey),
        src_solver: derive(&src_solver_pubkey),
        dst_solver: hex_to_bytes20("dddddddddddddddddddddddddddddddddddddddd"),
    },
};
```

**orderId:** `341069bc8d4b3910f53793dba00264d24ef113e01f6cb2b23a03d3e5841ff4cb`

---

## EVM -> Solana Flow

### Step 1: Deposit on EVM

Solver calls `deposit(order, signature)`. No contract changes needed.

```
EVM contract:
1. validateDeposit() — checks offerer signature, srcSolver authorization
   - offerer is real EVM address (SignatureCheckerLib works)
   - srcSolver is real EVM address (msg.sender == srcSolver works)
2. safeTransferFrom(offerer, this, inputAmount) — real EVM token, real EVM address
3. balances[offerer][inputToken].locked += inputAmount
4. orders[orderId] = order (stores full order including derived addresses)
5. orderStatus[orderId] = Active
```

Derived addresses (recipient, dstSolver) are stored but never accessed during deposit.

### Step 2: Fill on Solana

```rust
fn fill(
    ctx: Context<Fill>,
    order: AoriOrder,
    real_recipient: Pubkey,
    real_output_mint: Pubkey,
) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));

    // Verify derived addresses match real ones
    require!(derive(&real_recipient) == order.recipient);
    require!(derive(&real_output_mint) == order.output_token);

    // Validate dstSolver authorization
    if order.options.dst_solver != ZERO_ADDR {
        require!(derive(&ctx.accounts.solver.key()) == order.options.dst_solver);
    }

    // Transfer SPL tokens: solver -> recipient
    token::transfer(solver_ata, recipient_ata, order.output_amount)?;

    order_status[order_id] = Filled;
    filler_fills.push(order_id);

    // Register real pubkeys in reverse lookup
    reverse_registry.register(order.recipient, real_recipient);
    reverse_registry.register(order.output_token, real_output_mint);

    Ok(())
}
```

The Solana program accepts real pubkeys as parameters and verifies `derive(real_pubkey) == derived_address` on-chain. Trustless.

### Step 3: Settlement (Solana -> EVM)

```rust
fn settle(ctx: Context<Settle>, src_eid: u32) -> Result<()> {
    let solver = ctx.accounts.solver.key();
    let fills = &filler_fills[src_eid][solver];

    // Look up solver's EVM address from solver registry
    let solver_evm_address = solver_registry.get_evm_address(&solver)?;

    let count = min(fills.len(), max_fills_per_settle);

    // Pack settlement payload (same format as EVM):
    // [0x00][solver_evm_addr: 20 bytes][count: 2 bytes][hashes: N * 32 bytes]
    let payload = pack_settlement(solver_evm_address, &fills[..count]);

    lz_send(src_eid, payload)?;
    Ok(())
}
```

### Step 4: EVM receives settlement

Standard `_lzReceive()` flow, unchanged:

```
EVM contract receives LZ message from Solana:
1. Unpacks: filler=0xSolverEVM, orderHashes=[hash1, hash2, ...]
2. For each orderId:
   a. Loads stored order
   b. Checks order.dstEid == senderEid (30168 == 30168)
   c. Deducts balances[offerer][inputToken].locked
   d. Credits balances[filler][inputToken].unlocked
   e. Credits balances[feeRecipient][inputToken].unlocked (fee)
3. Solver calls withdraw() to claim tokens
```

All balance operations use real EVM addresses. Derived addresses stored in the order are never touched.

---

## Solana -> EVM Flow

### Step 1: Deposit on Solana

```rust
fn deposit(
    ctx: Context<Deposit>,
    order: AoriOrder,
    real_offerer: Pubkey,
    real_input_mint: Pubkey,
    signature: Ed25519Signature,
) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));

    // Verify derivations
    require!(derive(&real_offerer) == order.offerer);
    require!(derive(&real_input_mint) == order.input_token);

    // Verify signature (ed25519, not EIP-712)
    verify_ed25519(real_offerer, order_id, signature)?;

    // Validate srcSolver
    if order.options.src_solver != ZERO_ADDR {
        require!(derive(&ctx.accounts.solver.key()) == order.options.src_solver);
    }

    // Transfer SPL tokens from offerer to vault
    token::transfer(offerer_ata, vault_ata, order.input_amount)?;

    orders[order_id] = order;
    order_status[order_id] = Active;

    // Register real pubkeys in reverse lookup
    reverse_registry.register(order.offerer, real_offerer);
    reverse_registry.register(order.input_token, real_input_mint);

    Ok(())
}
```

### Step 2: Fill on EVM

Solver calls `fill(order)` on EVM. Completely standard, no changes.

```
EVM contract:
1. validateFill() — dstSolver is real EVM address, msg.sender check works
2. safeTransferFromChecked(solver, recipient, outputAmount) — both real EVM
3. orderStatus[orderId] = Filled
4. srcEidToFillerFills[30168][solver].push(orderId)
```

`offerer` and `inputToken` are derived addresses in calldata — they contribute to orderId but are never read for balance/transfer ops.

### Step 3: Settlement (EVM -> Solana)

Standard `settle()` on EVM. Packs pending order hashes, sends LZ to Solana.

### Step 4: Solana receives settlement

```rust
fn lz_receive(payload: &[u8], sender_eid: u32) -> Result<()> {
    let (filler_evm_addr, order_hashes) = unpack_settlement(payload);

    // Map EVM filler address to Solana solver
    let solver_pubkey = solver_registry.get_solana_address(&filler_evm_addr)?;

    for order_id in order_hashes {
        let order = orders[order_id];
        require!(order.dst_eid == sender_eid);

        // Reverse-lookup real pubkeys from derived addresses
        let real_input_mint = reverse_registry.get(order.input_token)?;
        let real_offerer = reverse_registry.get(order.offerer)?;

        // Credit solver
        balances[real_offerer][real_input_mint].locked -= order.input_amount;
        balances[solver_pubkey][real_input_mint].unlocked += filler_amount;

        // Fee distribution
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

---

## Cancel Authorization

Cancellation happens from the **destination chain** (prevents race with settlement).

| Authority | EVM->SVM (cancel from Solana) | SVM->EVM (cancel from EVM) |
|---|---|---|
| Whitelisted solver | Yes, anytime | Yes, anytime |
| Offerer | No — real EVM address, can't prove on Solana | No — derived address, no EVM key matches |
| Recipient | Yes, after expiry | Yes, after expiry |

In both directions, the offerer cannot cancel from the destination chain. Accepted limitation.

```rust
// Cancel from Solana (EVM->SVM order)
fn cancel_cross_chain(ctx: Context<Cancel>, order: AoriOrder) -> Result<()> {
    let order_id = keccak256(abi_encode_order(&order));
    let sender = ctx.accounts.signer.key();

    let is_solver = is_allowed_solver(&sender);
    let is_recipient = derive(&sender) == order.recipient && clock::now() > order.end_time;
    require!(is_solver || is_recipient);

    order_status[order_id] = Cancelled;
    let payload = pack_cancellation(order_id);
    lz_send(order.src_eid, payload)?;

    Ok(())
}
```

---

## Registries

### Solver Registry

Maps Solana pubkey <-> EVM address for whitelisted solvers. Owner-managed.

```rust
/// PDA seeds: [b"SolverRegistry", solana_pubkey.as_ref()]
struct SolverRegistryEntry {
    pub solana_pubkey: Pubkey,
    pub evm_address: [u8; 20],
    pub bump: u8,
}
```

| Operation | Access | Used by |
|---|---|---|
| `register_solver(solana_pubkey, evm_address)` | Owner only | Admin setup |
| `remove_solver(solana_pubkey)` | Owner only | Admin management |
| `get_evm_address(solana_pubkey)` | Anyone | `settle()` — pack filler's EVM address into payload |
| `get_solana_address(evm_address)` | Anyone | `lz_receive()` — credit correct Solana solver |

### Reverse Lookup Registry

Maps derived 20-byte address -> real 32-byte Solana pubkey. One-way derivation means the program needs this to get real pubkeys for SPL token operations.

```rust
/// PDA seeds: [b"ReverseLookup", derived_address[0..20]]
struct ReverseLookupEntry {
    pub derived_address: [u8; 20],
    pub real_pubkey: Pubkey,
    pub bump: u8,
}
```

- **Write-once**: cannot overwrite (derivation is deterministic, one pubkey per derived address)
- **Verified on write**: checks `derive(real_pubkey) == derived_address` before storing
- **Populated during deposit and fill**: caller provides real pubkeys, program verifies and registers

| Operation | Entries registered |
|---|---|
| `deposit()` on Solana (SVM->EVM) | offerer, inputToken, feeRecipient (if non-zero) |
| `fill()` on Solana (EVM->SVM) | recipient, outputToken |

---

## LayerZero Integration

- Solana endpoint ID: **30168** (mainnet), 40168 (devnet)
- OApp pattern on Solana: CPI calls to LZ endpoint program (not inheritance)
- OApp address on Solana is a **Store PDA**, not the program address
- Reentrancy prevention: `Endpoint::clear` CPI before state mutation

Must implement: `init`, `lz_receive`, `lz_receive_types_v2`, `lz_receive_types_info`

### Payload formats

**Settlement:** `[0x00][filler_evm_addr: 20 bytes][count: 2 bytes][order_hashes: N x 32 bytes]`

**Cancellation:** `[0x01][order_hash: 32 bytes]`

### Solana transaction size limit

1,232 bytes total. Max settlement fills: 37 (1,207 byte payload). Practical limit with account overhead: 20-30 fills.

| Fills | Payload bytes | Fits? |
|---|---|---|
| 10 | 343 | Yes |
| 20 | 663 | Yes |
| 37 | 1,207 | Yes (max) |
| 38 | 1,239 | No |

### EVM configuration required

```solidity
aori.addSupportedChain(30168);
aori.setPeer(30168, bytes32(solanaProgramStorePDA));
```

---

## Balance Model

```rust
struct Balance {
    locked: u128,   // tokens in active orders
    unlocked: u128, // tokens available for withdrawal
}
// Keyed by: balances[user][token]
```

### Order lifecycle

```
Unknown -> [deposit] -> Active -> [fill] -> Filled -> [settle] -> Settled
                          |
                     [cancel] -> Cancelled
```

---

## Compute Budget

| Operation | Estimated CU |
|---|---|
| `keccak256(480 bytes)` (orderId) | ~580 |
| `derive(pubkey)` | ~130 |
| SPL token transfer (CPI) | ~4,000-6,000 |
| `Endpoint::clear` (LZ CPI) | ~10,000-15,000 |

| Instruction | Estimated CU | Default 200K? |
|---|---|---|
| `fill()` | ~50,000 | Yes |
| `deposit()` | ~40,000 | Yes |
| `settle()` (send LZ) | ~30,000 | Yes |
| `lz_receive()` (10 orders) | ~300,000 | No — needs `set_compute_unit_limit` |
| `lz_receive()` (30 orders) | ~900,000 | No — needs `set_compute_unit_limit` |

Max requestable: 1,400,000 CU. LZ executor handles this via `pre_execute` / `post_execute`.

---

## Reference Test Vectors

### Derivation

```
pubkey:  7c9e73d4c71dae564d41f78d56439bb4ba87592f1234567890abcdef12345678
derived: 634fdee3bdfa25a4d703f1f9e7a4c6ffa4c650ef
```

### Order IDs (all verified matching between Solidity and Rust)

| Order | orderId |
|---|---|
| Sample (all real EVM addresses) | `8ca06a511bea20a73aa61309a5bc9540bba7bc78116a6045e6aafc4ffbec498e` |
| EVM -> Solana | `dba34ed4fdc13c266ebe4cbf18ef17b0451ecc370b008419b0d744d096afb9c1` |
| Solana -> EVM | `341069bc8d4b3910f53793dba00264d24ef113e01f6cb2b23a03d3e5841ff4cb` |

---

## Existing Crate

`solana/crates/aori-derivation/` contains proven primitives:

```toml
[dependencies]
aori-derivation = { path = "../aori-derivation" }
```

Exports: `derive`, `abi_encode_order`, `order_id`, `Order`, `Options`

Dependencies: `tiny-keccak = { version = "2.0", features = ["keccak"] }`

---

## Test Locations (in the EVM repo)

| File | Contents |
|---|---|
| `test/foundry/SolanaDerivation.t.sol` | 11 Solidity tests: derivation, ABI encoding, payload sizes, cross-chain orders |
| `solana/crates/aori-derivation/src/derive.rs` | 6 Rust tests: derivation parity |
| `solana/crates/aori-derivation/src/abi_encode.rs` | 7 Rust tests: ABI encoding + cross-chain orderId parity |

---

## Limitations

1. **Offerer cannot cancel cross-chain orders** from destination chain (both directions)
2. **One-way derivation** — reverse lookup registry required on Solana
3. **feeRecipient safety is SDK-enforced** — misconfigured = permanent fund loss
4. **Solver must operate on both chains** — needs EVM address + Solana keypair, registered by admin
5. **Settlement batch size** — Solana-bound limited to ~20-30 fills per batch (1,232 byte tx limit)
