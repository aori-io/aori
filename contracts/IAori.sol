// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IAori {
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
    /*                             ORDER                          */
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
        uint256 minPreferedTokenAmountOut;
        bytes instructions;
    }

    struct DstHook {
        address hookAddress;
        address preferredToken;
        bytes instructions;
        uint256 preferedDstInputAmount;
    }

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

    function deposit(Order calldata order, bytes calldata signature) external;

    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata data
    ) external;

    function depositNative(Order calldata order, bytes calldata signature) external payable;

    function withdraw(address token, uint256 amount) external;

    function cancel(bytes32 orderId) external;

    event settlementFailed(bytes32 indexed orderId, uint32 expectedEid, uint32 submittedEid, string reason);


    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        DST FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function fill(Order calldata order) external payable;

    function fill(Order calldata order, DstHook calldata hook) external payable;

    function settle(uint32 srcEid, address filler, bytes calldata extraOptions) external payable;

    function cancel(
        bytes32 orderId,
        Order calldata orderToCancel,
        bytes calldata extraOptions
    ) external payable;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        UTILITY FUNCTIONS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function hash(Order calldata order) external pure returns (bytes32);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function getLockedBalances(address offerer, address token) external view returns (uint256);

    function getUnlockedBalances(address offerer, address token) external view returns (uint256);

    function quote(
        uint32 _dstEid,
        uint8 _msgType,
        bytes calldata _options,
        bool _payInLzToken,
        uint32 _srcEid,
        address _filler
    ) external view returns (uint256 fee);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        HOOK EVENTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Emitted when a source hook is executed during deposit
     * @param orderId The hash of the order being processed
     * @param preferredToken The token address that was received from the hook
     * @param amountReceived The amount of tokens received from hook execution
     */
    event SrcHookExecuted(bytes32 indexed orderId, address indexed preferredToken, uint256 amountReceived);

    /**
     * @notice Emitted when a destination hook is executed during fill
     * @param orderId The hash of the order being processed
     * @param preferredToken The token address that was converted by the hook
     * @param amountReceived The amount of output tokens received from hook execution
     */
    event DstHookExecuted(bytes32 indexed orderId, address indexed preferredToken, uint256 amountReceived);
}