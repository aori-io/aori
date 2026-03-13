# Event Standardization Plan

## Goal

Standardize event schemas and emitted values so that a single PnL formula works across every order type — atomic srcHook swaps, no-hook fills, and dstHook fills — without conditional branching on order type.

## Uniform Solver PnL Formula

```
settleToken   = (Deposit.srcHookTokenOut != address(0)) ? Deposit.srcHookTokenOut : order.inputToken

solverSurplus = (slippageMbps == 0 && Fill.fillAmountOut > order.outputAmount)
                ? (Fill.fillAmountOut − order.outputAmount)
                : 0

Solver PnL    = Settle.solverUnlockedAmount  (in settleToken)
              − Fill.fillAmount              (in Fill.fillToken)
              + solverSurplus                (in order.outputToken)
```

## Changes

### 1. Rename Fill Event Fields

**File:** `contracts/interfaces/IAori.sol`

```solidity
// Before
event Fill(
    bytes32 indexed orderId,
    address indexed dstHookTokenIn,
    uint256 dstHookAmountIn,
    uint256 dstHookAmountOut
);

// After
event Fill(
    bytes32 indexed orderId,
    address indexed fillToken,
    uint256 fillAmount,
    uint256 fillAmountOut
);
```

Updated natspec:
- `fillToken` — The token the solver spent to fill the order (address(0) if atomic swap, no solver cost)
- `fillAmount` — The amount the solver spent to fill (0 if atomic swap)
- `fillAmountOut` — The amount of outputToken produced by hook conversion (0 if direct transfer, no hook)

### 2. Change Fill Values for No-Hook Fill Paths

Emit the solver's actual cost instead of zeros when filling without a dstHook.

**File:** `contracts/Aori.sol` — `fill(Order calldata order)` (no-hook fill)

```solidity
// Before (single-chain)
AoriSettleLib.settleSingleChainSwap(orderId, order, msg.sender, address(0), 0, 0);

// After (single-chain)
AoriSettleLib.settleSingleChainSwap(orderId, order, msg.sender, order.outputToken, order.outputAmount, 0);

// Before (cross-chain)
_postFill(orderId, order, address(0), 0, 0);

// After (cross-chain)
_postFill(orderId, order, order.outputToken, order.outputAmount, 0);
```

### 3. Rename Internal Function Parameters

**File:** `contracts/Aori.sol` — `_postFill`

```solidity
// Before
function _postFill(bytes32 orderId, Order calldata order, address dstHookTokenIn, uint256 dstHookAmountIn, uint256 dstHookAmountOut)

// After
function _postFill(bytes32 orderId, Order calldata order, address fillToken, uint256 fillAmount, uint256 fillAmountOut)
```

**File:** `contracts/lib/AoriSettleLib.sol` — `settleSingleChainSwap`

```solidity
// Before
function settleSingleChainSwap(bytes32 orderId, Order memory order, address solver, address dstHookTokenIn, uint256 dstHookAmountIn, uint256 dstHookAmountOut)

// After
function settleSingleChainSwap(bytes32 orderId, Order memory order, address solver, address fillToken, uint256 fillAmount, uint256 fillAmountOut)
```

### 4. Already Completed

`_distributeOutputs` in `AoriAtomicSwapLib.sol` now emits `order.outputToken` instead of `hook.preferredToken` in the Deposit event (auditor finding 3.2).

### 5. Update Tests

Test files with `expectEmit` on Fill that need updating:

| File | Change |
|---|---|
| `SC_NativeToERC20NoHook.t.sol` | `Fill(orderId, address(0), 0, 0)` → `Fill(orderId, outputToken, outputAmount, 0)` |
| `34_NativeTokenTests.t.sol` | Update no-hook fill assertions similarly |
| `SC_ERC20ToNativeDstHook.t.sol` | Values unchanged (dstHook fill), just verify field semantics |
| `SC_ERC20ToNativeHook.t.sol` | Unchanged (atomic, stays zeros) |
| `SC_ERC20ToNativeSrcHook.t.sol` | Unchanged (atomic, stays zeros) |

## No Changes Needed

- **Deposit event** — `srcHookTokenOut` / `srcHookAmountOut` names and values are already accurate across all paths
- **Settle event** — `solverUnlockedAmount` accurately describes what gets credited to the solver in every scenario (net proceeds in non-atomic, surplus in atomic)

## Resulting Fill Values Per Scenario

| Scenario | fillToken | fillAmount | fillAmountOut |
|---|---|---|---|
| Atomic (srcHook) | `address(0)` | `0` | `0` |
| No hook fill | `outputToken` | `outputAmount` | `0` |
| DstHook fill | `hook.preferredToken` | `hook.preferredDstInputAmount` | `amountReceived` |

## Example Trades

Common parameters: `inputToken = USDC, outputToken = WETH, inputAmount = 1000, outputAmount = 0.5, protocolFeeMbps = 100, feeMbps = 200, slippageMbps = 0`

### Atomic SrcHook Swap

Hook converts 1000 USDC → 0.52 WETH.

```
Deposit(orderId, order, WETH, 0.52)
Fill(orderId, address(0), 0, 0)
Settle(orderId, solver, 0.02, 0.0005, F, 0.001)

PnL = 0.02 − 0 + 0 = 0.02 WETH ✓
```

### No-Hook Fill

Solver transfers 0.5 WETH to recipient. Receives 997 USDC from settlement.

```
Deposit(orderId, order, address(0), 0)
Fill(orderId, WETH, 0.5, 0)
Settle(orderId, solver, 997, 1, F, 2)

PnL = 997 USDC − 0.5 WETH + 0 = 997 USDC − 0.5 WETH ✓
```

### DstHook Fill

Solver sends 900 DAI to hook. Hook produces 0.52 WETH. Solver receives 997 USDC + 0.02 WETH surplus.

```
Deposit(orderId, order, address(0), 0)
Fill(orderId, DAI, 900, 0.52)
Settle(orderId, solver, 997, 1, F, 2)

PnL = 997 USDC − 900 DAI + (0.52 − 0.5) WETH = 997 USDC − 900 DAI + 0.02 WETH ✓
```
