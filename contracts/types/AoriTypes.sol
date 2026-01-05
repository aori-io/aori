// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           STATUS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

enum OrderStatus {
    Unknown, // Order not found
    Active, // Order deposited but not filled
    Filled, // Pending settlement
    Cancelled, // Order cancelled
    Settled // Order settled
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            ORDER                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

struct Order {
    uint128 inputAmount;
    uint128 outputAmount;
    address inputToken;
    address outputToken;
    uint32 startTime;
    uint32 endTime;
    uint32 srcEid;
    uint32 dstEid;
    address offerer;
    address recipient;
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                            HOOKS                           */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

struct SrcHook {
    address hookAddress;
    address preferredToken;
    uint256 minPreferredTokenAmountOut;
    bytes instructions;
    address solver;
}

struct DstHook {
    address hookAddress;
    address preferredToken;
    bytes instructions;
    uint256 preferredDstInputAmount;
}

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                           BALANCE                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Balance struct for tracking locked and unlocked token amounts
/// @dev Uses uint128 for both values to pack them into a single storage slot
struct Balance {
    uint128 locked; // Tokens locked in active orders
    uint128 unlocked; // Tokens available for withdrawal
}
