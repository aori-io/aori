// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Order, OrderStatus, SrcHook, DstHook } from "../types/AoriTypes.sol";

interface IAori {
    
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        ORDER EVENTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when tokens are deposited and an order is created
     * @param orderId The unique hash identifying the order
     * @param order The full order struct
     * @param srcHookTokenOut The token received from the source hook (address(0) if no hook)
     * @param srcHookAmountOut The amount received from the source hook (0 if no hook)
     */
    event Deposit(
        bytes32 indexed orderId, 
        Order order, 
        address indexed srcHookTokenOut, 
        uint256 srcHookAmountOut
    );

    /**
     * @notice Emitted when a solver fills an order on the destination chain
     * @param orderId The unique hash identifying the order
     * @param dstHookTokenIn The token sent to the destination hook (address(0) if no hook)
     * @param dstHookAmountIn The amount sent to the destination hook (0 if no hook)
     * @param dstHookAmountOut The amount of output tokens received from the hook (0 if no hook)
     */
    event Fill(
        bytes32 indexed orderId, 
        address indexed dstHookTokenIn, 
        uint256 dstHookAmountIn, 
        uint256 dstHookAmountOut
    );

    /**
     * @notice Emitted when an order is settled and the solver's locked funds are released
     * @param orderId The unique hash identifying the order
     * @param solver The solver who filled the order
     * @param solverUnlockedAmount The amount unlocked to the solver after fees
     * @param protocolFee The protocol fee deducted
     * @param feeRecipient The recipient of the additional fee
     * @param additionalFee The additional fee deducted (routed to feeRecipient or solver)
     */
    event Settle(
        bytes32 indexed orderId,
        address indexed solver,
        uint256 solverUnlockedAmount,
        uint256 protocolFee,
        address feeRecipient,
        uint256 additionalFee
    );

    /**
     * @notice Emitted when a settlement soft-fails due to an invalid order state
     * @param orderId The unique hash identifying the order that failed to settle
     */
    event SettleFailed(
        bytes32 indexed orderId
    );

    /**
     * @notice Emitted when an order is cancelled and locked funds are returned
     * @param orderId The unique hash identifying the cancelled order
     */
    event Cancel(bytes32 indexed orderId);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN EVENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when a user or admin withdraws tokens from the contract
     * @param holder The address whose balance was withdrawn from
     * @param token The token withdrawn
     * @param amount The amount withdrawn
     */
    event Withdraw(address indexed holder, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a hook contract is added to the whitelist
     * @param hook The address of the hook added
     */
    event HookAdded(address indexed hook);

    /**
     * @notice Emitted when a hook contract is removed from the whitelist
     * @param hook The address of the hook removed
     */
    event HookRemoved(address indexed hook);

    /**
     * @notice Emitted when a solver is added to the whitelist
     * @param solver The address of the solver added
     */
    event SolverAdded(address indexed solver);

    /**
     * @notice Emitted when a solver is removed from the whitelist
     * @param solver The address of the solver removed
     */
    event SolverRemoved(address indexed solver);

    /**
     * @notice Emitted when the maximum fills per settlement batch is updated
     * @param newValue The new maximum fills per settle
     */
    event MaxFillsPerSettleSet(uint16 newValue);

    /**
     * @notice Emitted when a chain is added to the supported chains list
     * @param eid The LayerZero endpoint ID of the chain added
     */
    event ChainSupported(uint32 indexed eid);

    /**
     * @notice Emitted when a chain is removed from the supported chains list
     * @param eid The LayerZero endpoint ID of the chain removed
     */
    event ChainRemoved(uint32 indexed eid);

    /**
     * @notice Emitted when protocol fee is updated
     * @param feeMbps New protocol fee in millibasis points
     */
    event ProtocolFeeUpdated(uint16 feeMbps);

    /**
     * @notice Emitted when protocol treasury is updated
     * @param treasury New treasury address
     */
    event ProtocolTreasuryUpdated(address indexed treasury);

    /**
     * @notice Emitted when maximum additional fee is updated
     * @param maxFeeMbps New maximum fee in millibasis points
     */
    event MaxFeeUpdated(uint16 maxFeeMbps);

    /**
     * @notice Emitted when accumulated protocol fees are claimed
     * @param token The token that was claimed
     * @param amount The amount claimed
     * @param treasury The treasury address that received the funds
     */
    event ProtocolFeesClaimed(address indexed token, uint256 amount, address indexed treasury);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          LZ EVENTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when an order is cancelled from the destination chain
     * @dev Contains MessagingReceipt data for cross-chain tracking
     * @param orderId The hash of the cancelled order
     * @param guid The unique identifier of the LayerZero message
     * @param nonce The nonce of the LayerZero message
     * @param fee The fee paid for the LayerZero message
     */
    event CancelSent(bytes32 indexed orderId, bytes32 guid, uint64 nonce, uint256 fee);

    /**
     * @notice Emitted when orders are settled from the destination chain
     * @dev Contains MessagingReceipt data for cross-chain tracking
     * @param srcEid The source endpoint ID
     * @param filler The address of the filler
     * @param payload The settlement payload
     * @param guid The unique identifier of the LayerZero message
     * @param nonce The nonce of the LayerZero message
     * @param fee The fee paid for the LayerZero message
     */
    event SettleSent(uint32 indexed srcEid, address indexed filler, bytes payload, bytes32 guid, uint64 nonce, uint256 fee);

    /**
     * @notice Emitted when a settlement fails due to a source chain mismatch
     * @param orderId The unique hash identifying the order
     * @param expectedEid The expected source endpoint ID from the order
     * @param submittedEid The actual source endpoint ID from the settlement message
     */
    event SettlementFailed(bytes32 indexed orderId, uint32 expectedEid, uint32 submittedEid);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SWAP EVENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when an atomic single-chain swap is executed
     * @param orderId The unique order identifier
     * @param order The order details
     * @param amountReceived The amount of output tokens received from hook
     */
    event Swap(bytes32 indexed orderId, Order order, uint256 amountReceived);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        SRC FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deposit(Order calldata order, bytes calldata signature) external;

    function deposit(Order calldata order, bytes calldata signature, SrcHook calldata data) external;
    
    function depositNative(Order calldata order) external payable;

    function depositNative(Order calldata order, SrcHook calldata hook) external payable;

    function depositWithPermit2(
        Order calldata order, 
        uint256 nonce, 
        uint256 deadline, 
        bytes calldata signature
    ) external;

    function depositWithPermit2(
        Order calldata order,
        SrcHook calldata hook,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    function withdraw(address token, uint256 amount) external;

    /* forgefmt: disable-next-item */
    function cancel(bytes32 orderId) external;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        DST FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /* forgefmt: disable-next-item */
    function fill(Order calldata order) external payable;

    function fill(Order calldata order, DstHook calldata hook) external payable;

    function settle(uint32 srcEid, address filler, bytes calldata extraOptions) external payable;

    function cancel(bytes32 orderId, Order calldata orderToCancel, bytes calldata extraOptions) external payable;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        UTILITY FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /* forgefmt: disable-next-item */
    function hash(Order calldata order) external pure returns (bytes32);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PROTOCOL FEE FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Returns the current protocol fee configuration
     * @return feeMbps Protocol fee in millibasis points
     * @return treasury Address receiving protocol fees
     */
    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury);

    /**
     * @notice Returns pending protocol fees for a token
     * @param token The token to check
     * @return amount The pending fee amount
     */
    function getPendingProtocolFees(
        address token
    ) external view returns (uint256 amount);

    /**
     * @notice Sets the protocol fee (admin only, no cap)
     * @param feeMbps Fee in millibasis points
     */
    function setProtocolFee(
        uint16 feeMbps
    ) external;

    /**
     * @notice Sets the protocol treasury address (admin only)
     * @param treasury Address to receive protocol fees
     */
    function setProtocolTreasury(
        address treasury
    ) external;

    /**
     * @notice Claims accumulated protocol fees for a token (permissionless)
     * @param token The token to claim fees for
     */
    function claimProtocolFees(
        address token
    ) external;

    /**
     * @notice Sets the maximum allowed additional fee (admin only)
     * @param maxFeeMbps Maximum fee in millibasis points
     */
    function setMaxFee(
        uint16 maxFeeMbps
    ) external;

    /**
     * @notice Returns the current maximum allowed additional fee
     * @return maxFeeMbps Maximum fee in millibasis points
     */
    function getMaxFee() external view returns (uint16 maxFeeMbps);
}
