![aori-contracts banner](https://github.com/aori-io/.github-private/blob/main/assets/private/aori-contracts.png)

# Aori Contracts

Aori is designed to securely facilitate performant cross chain trading, with trust minimized settlement. To accomplish this, Aori uses a combination of off-chain infrastucture, on-chain settlement contracts, and Layer Zero messaging.

Solvers can expose a simple API to ingest and process orderflow directly to their trading system. The Aori smart contracts ensure that the user's intents are satisfied by the Solver on the destination chain according to the parameters of an intent on the source chain, signed by the user.

## Core Contract Components

### Order

The Aori contract revolves around a central `Order` struct that contains all parameters needed to fulfill a user's cross-chain intent:

```solidity
struct Order {
    uint128 inputAmount;      // Amount of tokens to be sent
    uint128 outputAmount;     // Amount of tokens to be received
    address inputToken;       // Token address on source chain
    address outputToken;      // Token address on destination chain
    uint32 startTime;         // When the order becomes valid
    uint32 endTime;           // When the order expires
    uint32 srcEid;            // Source chain endpoint ID
    uint32 dstEid;            // Destination chain endpoint ID
    address offerer;          // User who created the order
    address recipient;        // Address to receive output tokens
}
```

### Order Lifecycle

An order moves through various status states as it progresses through the settlement process:

```mermaid
flowchart LR
    Unknown -->|deposit| Active
    Active -->|fill| Filled
    Active -->|cancel| Cancelled
    Filled -->|settle| Settled
    Cancelled --> End
    Settled --> End
```

## Cross Chain Architecture

 The Aori protocol consists of paired smart contracts deployed on different blockchains, enabling secure cross-chain intent settlement through LayerZero's messaging infrastructure.

```mermaid
sequenceDiagram
    actor User
    actor Solver
    participant AoriSrc as Aori (Source)
    participant LZ as LayerZero
    participant AoriDst as Aori (Destination)

    %% Order Fill Flow
    User->>Solver: Signed Order
    Solver->>AoriSrc: deposit()
    User-->>AoriSrc: Locks user tokens
    Solver->>AoriDst: fill()
    AoriDst-->>User: Transfers tokens to recipient
    Solver->>AoriDst: settle()
    AoriDst->>LZ: _lzSend
    LZ-->>AoriSrc: _lzReceive
    Note over AoriSrc: Credit Solver
    Solver->>AoriSrc: withdraw()
    AoriSrc-->>Solver: Transfer tokens to solver
```

#### Deposit & Fill Process

- 1. User signs an order with EIP-712 signature
- 2. Solver submits the order and signature to source chain
- 3. Tokens are locked in the source chain contract
- 4. Solver fulfills the order on the destination chain
- 5. Tokens are transferred to the recipient on destination chain
- 6. Settlement message is sent back to source chain
- 7. Source chain transfers locked tokens to solver

#### Cancellation Process

Aori supports two types of cancellation:

- 1. Source Cancellation: Solvers can cancel directly on source chain
- 2. Destination Cancellation: After expiry, users or solvers can cancel from destination chain, which sends a message to source chain and confirms the order has not been filled.

```mermaid
sequenceDiagram
    actor User
    actor Solver
    participant AoriSrc as Aori (Source)
    participant LZ as LayerZero
    participant AoriDst as Aori (Destination)

    %% Cancellation Flow
    note right of User: Cancellation Flow
    User->>AoriDst: cancel
    AoriDst->>LZ: _lzSend
    LZ-->>AoriSrc: _lzReceive
    Note over AoriSrc: Unlock tokens
    User->>AoriSrc: withdraw()
    AoriSrc-->>User: Transfer tokens to user
```

#### Settlement Process

- 1. Fill Recording: When orders are filled on destination chain, they're stored in the solver's fill array.
- 2. Batch Settlement: Solvers can batch up to MAX_FILLS_PER_SETTLE orders for efficient processing.
- 3. Cross-Chain Message: A settlement payload containing filler address and order hashes is sent via LayerZero.
- 4. Source Chain Processing: The source chain:
- 5. Validates orders are in Active state
- 6. Transfers tokens from locked to unlocked state for the solver
- 7. Marks orders as Settled
- 8. Skips problematic orders without reverting the entire batch
- 9. Events: Emits Settle events for successful settlements.

This design ensures efficient, secure settlement while gracefully handling partial failures.

## Single-Chain Swap Architecture

Single-chain swap orders are also supported by Aori.sol. These orders bypass the complex cross-chain messaging and offer efficient peer to peer settlement. The contract supports three main fulfillment paths for single-chain swaps:

#### Immediate Fulfillment via `depositAndFill`

```mermaid
sequenceDiagram
    actor User
    actor Solver
    participant Aori as Aori Contract

    User->>Solver: Signed Order
    Solver->>Aori: depositAndFill(order, signature)
    User-->>Aori: Input tokens locked
    Solver-->>Aori: Output tokens provided
    Aori-->>User: Output tokens transferred to recipient
    Aori-->>Solver: Input tokens credited (unlocked)
```

In this atomic flow:
1. Solver calls `depositAndFill()` with the user's signed order
2. Input tokens are transferred from the user to the contract
3. Output tokens are transferred from the solver to the recipient
4. Input tokens are immediately credited to the solver (unlocked balance)
5. Order is marked as Settled in a single transaction

This is the most gas-efficient path but requires the solver to already have the output tokens.

#### Delayed Fulfillment via deposit then fill

```mermaid
sequenceDiagram
    actor User
    actor Solver
    participant Aori as Aori Contract
    participant LiqSrc as Liquidity Source

    User->>Solver: Signed Order
    Solver->>Aori: deposit(order, signature)
    User-->>Aori: Input tokens locked
    Note over Solver: Time delay (sourcing liquidity)
    LiqSrc->>Solver: Output tokens provided
    Solver->>Aori: fill(order)
    Aori-->>User: Output tokens transferred to recipient
    Aori-->>Solver: Input tokens credited (unlocked)
```

In this two-step flow:
1. Solver first calls `deposit()` with the user's signed order
2. Input tokens are transferred from the user and locked in the contract
3. Order is marked as Active
4. Later, when the solver has sourced the output tokens (from a DEX or other liquidity source)
5. Solver calls `fill()` with the same order
6. Output tokens are transferred from the solver to the recipient
7. Order is immediately settled, and input tokens are credited to the solver

This pattern gives solvers flexibility to lock in the user's intent first, then source the output tokens before completing the trade. The settlement happens immediately after the fill call without needing cross-chain messaging.

#### Deposit with Hook Path

The contract also supports a hook-based deposit mechanism for single-chain swaps:

```mermaid
sequenceDiagram
    actor User
    actor Solver
    participant Aori as Aori Contract
    participant Hook as DEX Hook

    User->>Solver: Signed Order
    Solver->>Aori: deposit(order, signature, hook)
    User-->>Aori: Input tokens transferred
    Aori->>Hook: Input tokens + execute hook
    Hook-->>Aori: Output tokens returned
    Aori-->>User: Output tokens to recipient
    Aori-->>Solver: Input tokens credited
```

In this path:
1. Solver calls `deposit()` with the user's order, signature, and hook configuration
2. Input tokens are transferred directly to the hook contract
3. The hook executes (e.g., performs a swap on a DEX)
4. Output tokens are returned to the Aori contract
5. Output tokens are transferred to the recipient
6. Settlement happens immediately, crediting the input amount to the solver

This pattern enables advanced liquidity sourcing directly within the transaction.

---

# Developers

## Getting Started

#### Installing dependencies

```bash
pnpm install
```

#### Compiling your contracts

```bash
forge build
```

#### Running tests

```bash
forge test
```

#### Running Aori Contracts cli
```bash
pnpm run aori
```

## Deploying Contracts

Set up deployer wallet/account:

- Rename `.env.example` -> `.env`
- Choose your preferred means of setting up your deployer wallet/account:

```
MNEMONIC="test test test test test test test test test test test junk"
or...
PRIVATE_KEY="0xabc...def"
```

To deploy your contracts to your desired blockchains, run the following command in your project's folder:

```bash
npx hardhat lz:deploy
```

More information about available CLI arguments can be found using the `--help` flag:

```bash
npx hardhat lz:deploy --help
```

## Configuring Contracts

Wire your deployed contracts by running:

```bash
npx hardhat lz:oapp:wire --oapp-config layerzero.config.ts
```

## Coverage Report

See code test coverage

```bash
forge coverage --report --ir-minimum
```

## License

MIT
