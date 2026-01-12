// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Order, OrderStatus, SrcHook, DstHook } from "../types/AoriTypes.sol";

interface IAori {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          SRC EVENTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Deposit(bytes32 indexed orderId, Order order);
    event Cancel(bytes32 indexed orderId);
    event Settle(bytes32 indexed orderId);
    event Withdraw(address indexed holder, address indexed token, uint256 amount);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CHAIN MANAGEMENT EVENTS                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event ChainSupported(uint32 indexed eid);
    event ChainRemoved(uint32 indexed eid);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN EVENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);
    event SolverAdded(address indexed solver);
    event SolverRemoved(address indexed solver);
    event MaxFillsPerSettleUpdated(uint16 oldValue, uint16 newValue);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          DST EVENTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Fill(bytes32 indexed orderId, Order order);

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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        SRC FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function deposit(
        Order calldata order,
        bytes calldata signature
    ) external;

    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata data
    ) external;

    /* forgefmt: disable-next-item */
    function depositNative(Order calldata order) external payable;

    function depositNative(
        Order calldata order,
        SrcHook calldata hook
    ) external payable;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PERMIT2 FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deposit using Permit2 SignatureTransfer with witness
     * @dev User signs a single Permit2 message that includes the order as witness data.
     *      This binds the token transfer authorization to the specific order parameters.
     * @param order The order to deposit (also serves as witness data in the signature)
     * @param nonce Permit2 nonce for replay protection
     * @param deadline Signature expiration timestamp
     * @param signature User's signature over PermitWitnessTransferFrom
     */
    function depositWithPermit2(
        Order calldata order,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    /**
     * @notice Deposit using Permit2 with source hook for token conversion
     * @dev Tokens are transferred directly to the hook via Permit2, then hook converts them.
     * @param order The order to deposit (witness data)
     * @param hook Source hook for token conversion
     * @param nonce Permit2 nonce for replay protection
     * @param deadline Signature expiration timestamp
     * @param signature User's Permit2 signature
     */
    function depositWithPermit2(
        Order calldata order,
        SrcHook calldata hook,
        uint256 nonce,
        uint256 deadline,
        bytes calldata signature
    ) external;

    function withdraw(
        address token,
        uint256 amount
    ) external;

    /* forgefmt: disable-next-item */
    function cancel(bytes32 orderId) external;

    event SettlementFailed(bytes32 indexed orderId, uint32 expectedEid, uint32 submittedEid, string reason);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        DST FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /* forgefmt: disable-next-item */
    function fill(Order calldata order) external payable;

    function fill(
        Order calldata order,
        DstHook calldata hook
    ) external payable;

    function settle(
        uint32 srcEid,
        address filler,
        bytes calldata extraOptions
    ) external payable;

    function cancel(
        bytes32 orderId,
        Order calldata orderToCancel,
        bytes calldata extraOptions
    ) external payable;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        UTILITY FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /* forgefmt: disable-next-item */
    function hash(Order calldata order) external pure returns (bytes32);

    // Note: View functions (orders, getLockedBalances, getUnlockedBalances, quote, srcEidToFillerFills)
    // have been moved to AoriLens.sol for bytecode optimization

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        HOOK EVENTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when a source hook is executed during deposit
     * @param orderId The hash of the order being processed
     * @param tokenIn The input token sent to the hook (order.inputToken)
     * @param tokenOut The output token received from the hook (outputToken or preferredToken)
     * @param amountIn The input amount sent to the hook (order.inputAmount)
     * @param amountOut The amount of tokens received from hook execution
     */
    event SrcHookExecuted(bytes32 indexed orderId, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    /**
     * @notice Emitted when a destination hook is executed during fill
     * @param orderId The hash of the order being processed
     * @param tokenIn The input token sent to the hook (hook.preferredToken)
     * @param tokenOut The output token received from the hook (order.outputToken)
     * @param amountIn The input amount sent to the hook (hook.preferredDstInputAmount)
     * @param amountOut The amount of output tokens received from hook execution
     */
    event DstHookExecuted(bytes32 indexed orderId, address indexed tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    HEALTH CHECK EVENTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // TODO: Remove health check events and functions before production deployment

    /**
     * @notice Emitted when a ping is sent to a remote chain
     * @param dstEid The destination endpoint ID
     * @param guid The unique identifier of the LayerZero message
     * @param nonce The nonce of the LayerZero message
     * @param fee The fee paid for the LayerZero message
     */
    event PingSent(uint32 indexed dstEid, bytes32 guid, uint64 nonce, uint256 fee);

    /**
     * @notice Emitted when a ping is received from a remote chain
     * @param srcEid The source endpoint ID that sent the ping
     */
    event PingReceived(uint32 indexed srcEid);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   HEALTH CHECK FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Send a ping to a remote chain to verify cross-chain connectivity
     * @dev Useful for deployment verification and health checks
     * @param dstEid The destination endpoint ID to ping
     * @param extraOptions LayerZero messaging options
     */
    function ping(uint32 dstEid, bytes calldata extraOptions) external payable;

    /**
     * @notice Quote the fee for sending a ping
     * @param dstEid The destination endpoint ID
     * @param extraOptions LayerZero messaging options
     * @param payInLzToken Whether to pay in LZ token
     * @return fee The estimated messaging fee
     */
    function quotePing(uint32 dstEid, bytes calldata extraOptions, bool payInLzToken) external view returns (MessagingFee memory fee);
}
