// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Order, OrderStatus, SrcHook, DstHook } from "../types/AoriTypes.sol";

interface IAori {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        ORDER EVENTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Deposit(
        bytes32 indexed orderId, 
        Order order,
        address indexed srcHookTokenOut,
        uint256 srcHookAmountOut
    );

    event Fill(
        bytes32 indexed orderId, 
        address indexed dstHookTokenIn,
        uint256 dstHookAmountIn,
        uint256 dstHookAmountOut
    );

    event Settle(
        bytes32 indexed orderId,
        address indexed solver,
        uint256 solverUnlockedAmount,
        uint256 protocolFee,
        address feeRecipient,
        uint256 additionalFee
    );

    event SettleFailed(bytes32 indexed orderId);

    event Cancel(bytes32 indexed orderId);


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN EVENTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    
    event Withdraw(address indexed holder, address indexed token, uint256 amount);
    event HookAdded(address indexed hook);
    event HookRemoved(address indexed hook);
    event SolverAdded(address indexed solver);
    event SolverRemoved(address indexed solver);
    event MaxFillsPerSettleSet(uint16 newValue);
    event ChainSupported(uint32 indexed eid);
    event ChainRemoved(uint32 indexed eid);

    /// @notice Emitted when protocol fee is updated
    /// @param feeMbps New protocol fee in millibasis points
    event ProtocolFeeUpdated(uint16 feeMbps);

    /// @notice Emitted when protocol treasury is updated
    /// @param treasury New treasury address
    event ProtocolTreasuryUpdated(address indexed treasury);

    /// @notice Emitted when maximum additional fee is updated
    /// @param maxFeeMbps New maximum fee in millibasis points
    event MaxFeeUpdated(uint16 maxFeeMbps);

    /// @notice Emitted when accumulated protocol fees are claimed
    /// @param token The token that was claimed
    /// @param amount The amount claimed
    /// @param treasury The treasury address that received the funds
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

    event SettlementFailed(bytes32 indexed orderId, uint32 expectedEid, uint32 submittedEid);

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


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       SWAP FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when an atomic single-chain swap is executed
     * @param orderId The unique order identifier
     * @param order The order details
     * @param amountReceived The amount of output tokens received from hook
     */
    event Swap(bytes32 indexed orderId, Order order, uint256 amountReceived);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PROTOCOL FEE FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Returns the current protocol fee configuration
    /// @return feeMbps Protocol fee in millibasis points
    /// @return treasury Address receiving protocol fees
    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury);

    /// @notice Returns pending protocol fees for a token
    /// @param token The token to check
    /// @return amount The pending fee amount
    function getPendingProtocolFees(address token) external view returns (uint256 amount);

    /// @notice Sets the protocol fee (admin only, no cap)
    /// @param feeMbps Fee in millibasis points
    function setProtocolFee(uint16 feeMbps) external;

    /// @notice Sets the protocol treasury address (admin only)
    /// @param treasury Address to receive protocol fees
    function setProtocolTreasury(address treasury) external;

    /// @notice Claims accumulated protocol fees for a token (permissionless)
    /// @param token The token to claim fees for
    function claimProtocolFees(address token) external;

    /// @notice Sets the maximum allowed additional fee (admin only)
    /// @param maxFeeMbps Maximum fee in millibasis points
    function setMaxFee(uint16 maxFeeMbps) external;

    /// @notice Returns the current maximum allowed additional fee
    /// @return maxFeeMbps Maximum fee in millibasis points
    function getMaxFee() external view returns (uint16 maxFeeMbps);
}
