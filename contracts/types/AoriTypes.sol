// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            ORDER                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

struct Order {
    uint128 inputAmount;
    uint128 outputAmount;
    address inputToken;
    uint32 startTime;
    uint32 endTime;
    uint32 srcEid;
    address outputToken;
    uint32 dstEid;
    address offerer;
    address recipient;
    Options options;
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          OPTIONS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

struct Options {
    uint16 feeMbps;       // Fee in millibasis points (1000 = 1%)
    uint16 slippageMbps;  // 0 = limit order, >0 = market order
    address feeRecipient; // Who receives the fee (address(0) = solver)
    address srcSolver;    // Authorized solver on source chain (address(0) = any whitelisted)
    address dstSolver;    // Authorized solver on destination chain (address(0) = any whitelisted)
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           STATUS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

enum OrderStatus {
    Unknown,     // Order not found
    Active,      // Order deposited but not filled
    Filled,      // Pending settlement
    Cancelled,   // Order cancelled
    Settled      // Order settled

}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            HOOKS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

struct SrcHook {
    address hookAddress;                // hook address
    address preferredToken;             // tokenOut
    uint256 minPreferredTokenAmountOut; // amountOut
    bytes instructions;                 // call
}

struct DstHook {
    address hookAddress;               // hook address
    address preferredToken;            // tokenIn
    bytes instructions;                // call
    uint256 preferredDstInputAmount;   // amountIn
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           BALANCE                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Balance struct for tracking locked and unlocked token amounts
/// @dev Uses uint128 for both values to pack them into a single storage slot
struct Balance {
    uint128 locked;    // Tokens locked in active orders
    uint128 unlocked;  // Tokens available for withdrawal
}
    