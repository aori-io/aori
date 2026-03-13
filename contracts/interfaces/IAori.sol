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
     * @notice Emitted when a solver fills an order
     * @param orderId The unique hash identifying the order
     * @param fillToken The token the solver spent to fill (address(0) if atomic swap, no solver cost)
     * @param fillAmount The amount the solver spent to fill (0 if atomic swap)
     * @param fillAmountOut The amount of outputToken produced by hook conversion (0 if direct transfer, no hook)
     */
    event Fill(
        bytes32 indexed orderId, 
        address indexed fillToken, 
        uint256 fillAmount, 
        uint256 fillAmountOut
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
    /*                      VIEW FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function quote(
        uint32 _dstEid,
        uint8 _msgType,
        bytes calldata _options,
        bool _payInLzToken,
        uint32 _srcEid,
        address _filler
    ) external view returns (MessagingFee memory);

    function isSupportedChain(uint32 eid) external view returns (bool);

    function orderStatus(bytes32 orderId) external view returns (OrderStatus);

    function isAllowedHook(address hook) external view returns (bool);

    function isAllowedSolver(address solver) external view returns (bool);

    function readStorage(bytes32 slot) external view returns (bytes32 value);

    function readStorageArray(bytes32 slot) external view returns (uint256 length);

    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury);

    function getPendingProtocolFees(address token) external view returns (uint256 amount);

    function getMaxFee() external view returns (uint16 maxFeeMbps);

    function getMaxFillsPerSettle() external view returns (uint16);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        SRC FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deposit(Order calldata order, bytes calldata signature) external;

    function deposit(Order calldata order, bytes calldata signature, SrcHook calldata data) external;

    function depositNative(
        Order calldata order,
        SrcHook calldata srcHook,
        bytes calldata quoteSignature
    ) external payable;

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

    function cancel(bytes32 orderId) external;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        DST FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function fill(Order calldata order) external payable;

    function fill(Order calldata order, DstHook calldata hook) external payable;

    function settle(uint32 srcEid, address filler, bytes calldata extraOptions) external payable;

    function cancel(bytes32 orderId, Order calldata orderToCancel, bytes calldata extraOptions) external payable;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     ADMIN FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function pause() external;

    function unpause() external;

    function addAllowedHook(address hook) external;

    function removeAllowedHook(address hook) external;

    function addAllowedSolver(address solver) external;

    function removeAllowedSolver(address solver) external;

    function addSupportedChain(uint32 eid) external;

    function removeSupportedChain(uint32 eid) external;

    function emergencyCancel(bytes32 orderId, address recipient) external;

    function emergencyWithdraw(address token, uint256 amount, address recipient) external;

    function emergencyWithdrawFromBalance(address token, uint256 amount, address user, bool isLocked, address recipient) external;

    function claimProtocolFees(address token) external;

    function setProtocolFee(uint16 feeMbps) external;

    function setProtocolTreasury(address treasury) external;

    function setMaxFee(uint16 maxFeeMbps) external;

    function setMaxFillsPerSettle(uint16 maxFills) external;
}
