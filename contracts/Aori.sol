// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @@@@@@@@
 * Aori.sol v0.0.1:                        @@@@@@@@@@@@@@@@                                             
 * ----------------                      @@@@@@@@@@@@@@@@@@@@@@                             @@@@        
 * @title Aori                        @@@             @@@@@@@@                           @@@@@@@
 * @notice                            @@@@              @@@@@@@                          @@@@@@@
 *                                        @@@@@               @@                             @@         
 *                                          @@@@@@@                                                                                                           
 *                                           @@@@@@@@@                                                 
 *         @@@@@@@                             @@@@@@@@@@        @@@@@         @@@@@@        @@@@      
 *      @@@@@@@@@@@@@     @@@@@@           @@@@@@@@@@@@@@@@    @@@@@@@@@     @@@@@@@@@   @@@@@@@@      
 *    @@@@@@@    @@@@@   @@@@@@@        @@@@@@@@@@@@@@@@@@@@@ @@@@@@@@@@@ @@@@@@@@@@@@@@@@@@@@@@@      
 *   @@@@@@        @@@@  @@@@@@       @@@@@@@@       @@@@@@@@@@@   @@@@@@@@@@@    @@@@@   @@@@@@@      
 * @@@@@@@           @@@@@@@@@@    @@@@@@@              @@@@@@@@@  @@@@@@           @@@@  @@@@@@@      
 * @@@@@@@            @@@@@@@@    @@@@@@@                @@@@@@@@  @@@@@@           @@@   @@@@@@@      
 * @@@@@@@            @@@@@@@@   @@@@@@@@    @      @@   @@@@@@@@@ @@@@@@            @@    @@@@@@      
 * @@@@@@@             @@@@@@    @@@@@@@@    @@@  @@@@    @@@@@@@@ @@@@@@                  @@@@@@      
 * @@@@@@@            @@@@@@     @@@@@@@     @@@@@@@@@    @@@@@@@@ @@@@@@                  @@@@@@      
 * @@@@@@@            @@@@@@     @@@@@@@@    @@@@@@@@@    @@@@@@@  @@@@@@                  @@@@@@      
 * @@@@@@@           @@@@@@@     @@@@@@@@    @      @@    @@@@@@@  @@@@@@                  @@@@@@       
 *  @@@@@@          @@@@@@@@      @@@@@@@@               @@@@@@    @@@@@@                  @@@@@@    @@
 *  @@@@@@@        @@@@@@@@@@    @@@@@@@@@@             @@@@@@     @@@@@@                  @@@@@@    @@
 *   @@@@@@@      @@@@@@@ @@@@@@@@@ @@@@@@@@@         @@@@@@@      @@@@@@                  @@@@@@   @@ 
 *     @@@@@@@@@@@@@@@@    @@@@@@@@   @@@@@@@@@@@@@@@@@@@@         @@@@@@                  @@@@@@@@@@@ 
 *       @@@@@@@@@@@@      @@@@@@@       @@@@@@@@@@@@@@            @@@@@@                   @@@@@@@@
 */
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {EIP712} from "solady/src/utils/EIP712.sol";
import {ECDSA} from "solady/src/utils/ECDSA.sol";
import {IAori} from "./interfaces/IAori.sol";
import "./lib/AoriUtils.sol";

contract Aori is IAori, OApp, ReentrancyGuard, Pausable, EIP712 {
    using PayloadPackUtils for bytes32[];
    using PayloadUnpackUtils for bytes;
    using HookUtils for SrcHook;
    using HookUtils for DstHook;
    using SafeERC20 for IERC20;

    // ====================================================
    // ================= COMMON STATE =====================
    // ====================================================

    // Unique identifier for this endpoint in the LayerZero network
    uint32 public immutable ENDPOINT_ID;

    // ====================================================
    // ================= AORISRC STATE ====================
    // ====================================================

    // Tracks locked and unlocked balances for each user and token
    mapping(address => mapping(address => Balance)) private balances;

    // Stores orders by their unique hash
    mapping(bytes32 => Order) public orders;

    // ====================================================
    // ================= AORIDST STATE ====================
    // ====================================================

    // Maximum number of fills that can be included in a single settlement
    uint16 public immutable MAX_FILLS_PER_SETTLE;

    // Tracks the current status of each order
    mapping(bytes32 => IAori.OrderStatus) public orderStatus;

    // Tracks whitelisted hook addresses for token conversion
    mapping(address => bool) public isAllowedHook;

    // Tracks whitelisted solver addresses
    mapping(address => bool) public isAllowedSolver;

    // Maps source endpoint and maker to an array of order hashes filled by a filler
    mapping(uint32 => mapping(address => bytes32[])) public srcEidToFillerFills;

    // EIP712 typehash for order struct
    bytes32 private constant _ORDER_TYPEHASH = keccak256(
        "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
    );

    modifier onlySolver() {
        require(isAllowedSolver[msg.sender], "Invalid solver");
        _;
    }

    // ====================================================
    // =================== CONSTRUCTOR ====================
    // ====================================================
    /**
     * @notice Initializes the Aori contract with LayerZero endpoint and configuration
     * @param _endpoint The LayerZero endpoint address
     * @param _owner The contract owner address
     * @param _eid The endpoint ID for this chain
     * @param _maxFillsPerSettle Maximum number of fills per settlement
     */
    constructor(address _endpoint, address _owner, uint32 _eid, uint16 _maxFillsPerSettle)
        OApp(_endpoint, _owner)
        Ownable(_owner)
        EIP712()
    {
        ENDPOINT_ID = _eid;
        MAX_FILLS_PER_SETTLE = _maxFillsPerSettle;
    }

    // ====================================================
    // ================== OWNER FUNCTIONS ===============
    // ====================================================

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Adds a hook address to the whitelist
     * @param hook The address of the hook to whitelist
     * @dev Only callable by the contract owner
     */
    function addAllowedHook(address hook) external onlyOwner {
        isAllowedHook[hook] = true;
    }

    /**
     * @notice Removes a hook address from the whitelist
     * @param hook The address of the hook to remove
     * @dev Only callable by the contract owner
     */
    function removeAllowedHook(address hook) external onlyOwner {
        isAllowedHook[hook] = false;
    }

    /**
     * @notice Adds a solver address to the whitelist
     * @param solver The address of the solver to whitelist
     * @dev Only callable by the contract owner
     */
    function addAllowedSolver(address solver) external onlyOwner {
        isAllowedSolver[solver] = true;
    }

    /**
     * @notice Removes a solver address from the whitelist
     * @param solver The address of the solver to remove
     * @dev Only callable by the contract owner
     */
    function removeAllowedSolver(address solver) external onlyOwner {
        isAllowedSolver[solver] = false;
    }

    /**
     * @notice Emergency function to extract tokens or ether from the contract
     * @dev Only callable by the contract owner
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     */
    // todo: tokens specified but not for native
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        uint256 etherBalance = address(this).balance;
        if (etherBalance > 0) {
            (bool success,) = payable(owner()).call{value: etherBalance}("");
            require(success, "Ether withdrawal failed");
        }
        if (amount > 0) {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    // ====================================================
    // ================== AORISRC FUNCTIONS ===============
    // ====================================================

    /**
     * @notice Deposits tokens to the contract for filling on another chain
     * @dev Supports both direct deposits and hook-based token conversion
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     */
    function deposit(Order calldata order, bytes calldata signature)
        external
        payable
        nonReentrant
        whenNotPaused
        onlySolver
    {
        bytes32 orderId = preDeposit(order, signature);
        IERC20(order.inputToken).safeTransferFrom(order.offerer, address(this), order.inputAmount);
        postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /**
     * @notice Deposits tokens to the contract for filling on another chain
     * @dev Supports both direct deposits and hook-based token conversion
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     * @param hook The pre-hook configuration
     */
    function deposit(Order calldata order, bytes calldata signature, SrcHook calldata hook)
        external
        payable
        nonReentrant
        whenNotPaused
        onlySolver
    {
        require(hook.isSome(), "Missing hook");
        bytes32 orderId = preDeposit(order, signature);
        uint256 amountOut = executeSrcHook(order, hook);
        postDeposit(hook.preferredToken, amountOut, order, orderId);
    }

    function preDeposit(Order calldata order, bytes calldata signature) internal view returns (bytes32 orderId) {
        orderId = hash(order);
        require(orderStatus[orderId] == OrderStatus.Unknown, "Order already exists");
        validateOrderSig(order, signature);
        validateDeposit(order);
    }

    function postDeposit(address depositToken, uint256 depositAmount, Order calldata order, bytes32 orderId) internal {
        balances[order.offerer][depositToken].lock(uint128(depositAmount)); // todo: rm cast when Order is changed
        orderStatus[orderId] = IAori.OrderStatus.Active;
        // todo: optimize
        orders[orderId] = order;
        orders[orderId].inputToken = depositToken;
        orders[orderId].inputAmount = uint128(depositAmount);

        emit Deposit(orderId, order);
    }

    function executeSrcHook(Order calldata order, SrcHook calldata hook) internal returns (uint256 balChg) {
        require(isAllowedHook[hook.hookAddress], "Invalid hook address");
        IERC20(order.inputToken).safeTransferFrom(order.offerer, hook.hookAddress, order.inputAmount);
        balChg = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, hook.preferredToken);
        require(balChg >= hook.minPreferedTokenAmountOut, "Insufficient output from hook");
    }

    /**
     * @notice Cancels an order from the destination chain by sending a cancellation message to the source chain
     * @dev Before endTime, only whitelisted solvers can cancel. After endTime, either solver or offerer can cancel
     * @param orderId The hash of the order to cancel
     * @param orderToCancel The order details to cancel
     * @param extraOptions Additional LayerZero options
     */
    function dstCancel(bytes32 orderId, Order calldata orderToCancel, bytes calldata extraOptions)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        validatedCancellation(orderId, orderToCancel);
        bytes memory payload = PayloadPackUtils.packCancellation(orderId);
        __lzSend(orderToCancel.srcEid, payload, extraOptions);
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        // emit Cancel(orderId, orderToCancel);
    }

    function validatedCancellation(bytes32 orderId, Order calldata orderToCancel) internal view {
        require(orderToCancel.dstEid == ENDPOINT_ID, "Not on destination chain");
        require(orderStatus[orderId] == IAori.OrderStatus.Unknown, "Order not active");
        require(
            (isAllowedSolver[msg.sender])
                || (msg.sender == orderToCancel.offerer && block.timestamp > orderToCancel.endTime),
            "Only whitelisted solver or offerer(after expiry) can cancel"
        );
    }

    function __lzSend(uint32 eId, bytes memory payload, bytes calldata extraOptions) internal {
        _lzSend(eId, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    /**
     * @notice Allows whitelisted solvers to cancel an order from the source chain
     * @param orderId The hash of the order to cancel
     */
    function srcCancel(bytes32 orderId) external whenNotPaused {
        require(isAllowedSolver[msg.sender], "Only whitelisted solver can cancel from the source chain");
        _cancel(orderId);
    }

    /**
     * @notice Internal function to cancel an order and update balances
     * @param orderId The hash of the order to cancel
     */
    function _cancel(bytes32 orderId) internal {
        require(orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;

        Order memory order = orders[orderId];
        balances[order.offerer][order.inputToken].unlock(uint128(order.inputAmount)); // todo: rm cast when Order is changed

        emit Cancel(orderId, order);
    }

    /**
     * @notice Handles incoming LayerZero messages for order settlement and cancellation
     * @dev Processes both read responses and settlement payloads
     * @param payload The message payload containing order hashes and filler information
     */
    function _lzReceive(
        Origin calldata, // origin
        bytes32, // guid
        bytes calldata payload,
        address, // executor
        bytes calldata
    ) internal override whenNotPaused {
        require(payload.length > 0, "Empty payload");
        recvPayload(payload);
    }

    function recvPayload(bytes calldata payload) internal {
        payload.getType();
        PayloadType msgType = payload.getType();
        if (msgType == PayloadType.Cancellation) {
            handleCancellation(payload);
        } else if (msgType == PayloadType.Settlement) {
            handleSettlement(payload);
        } else {
            revert("Unsupported payload type");
        }
    }

    function handleCancellation(bytes calldata payload) internal {
        payload.validateCancellationLen();
        bytes32 orderId = payload.unpackCancellation();
        _cancel(orderId);
    }

    function handleSettlement(bytes calldata payload) internal {
        payload.validateSettlementLen();
        (address filler, uint16 fillCount) = payload.unpackSettlementHeader();
        payload.validateSettlementLen(fillCount);

        // Handle with care: If a single order fails the whole batch will revert
        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            settleOrder(orderId, filler);
        }
    }

    function settleOrder(bytes32 orderId, address filler) internal {
        if (orderStatus[orderId] != IAori.OrderStatus.Active) {
            return; // Any reverts are skipped
        }
        // Update balances: move from locked to unlocked
        Order memory order = orders[orderId];
        bool successLock = balances[order.offerer][order.inputToken].decreaseLockedNoRevert(uint128(order.inputAmount)); // todo: rm cast when Order is changed
        bool successUnlock = balances[filler][order.inputToken].increaseUnlockedNoRevert(uint128(order.inputAmount));

        if (!successLock || !successUnlock) {
            return; // Any reverts are skipped
        }
        orderStatus[orderId] = IAori.OrderStatus.Settled;

        emit Settle(orderId, order);
    }

    /**
     * @notice Allows users to withdraw their unlocked token balances
     * @param token The token address to withdraw
     */
    function withdraw(address token) external nonReentrant whenNotPaused {
        address holder = msg.sender;
        uint256 amount = balances[holder][token].unlocked;
        require(amount > 0, "Non-zero balance required");
        balances[holder][token].unlocked = 0;
        IERC20(token).safeTransfer(holder, amount);

        emit Withdraw(holder, token, amount);
    }

    // ====================================================
    // ================= AORIDST FUNCTIONS ================
    // ====================================================

    /**
     * @notice Fills an order by transferring tokens from the filler
     * @dev Supports both direct fills and hook-based token conversion
     * @param order The order details to fill
     */
    function fill(Order calldata order) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = preFill(order);
        IERC20(order.outputToken).safeTransferFrom(msg.sender, order.recipient, order.outputAmount);
        postFill(orderId, order);
    }

    /**
     * @notice Fills an order by transferring tokens from the filler
     * @dev Supports both direct fills and hook-based token conversion
     * @param order The order details to fill
     * @param hook The solver data including hook configuration
     */
    function fill(Order calldata order, IAori.DstHook calldata hook)
        external
        payable
        nonReentrant
        whenNotPaused
        onlySolver
    {
        bytes32 orderId = preFill(order);
        uint256 sendAmt = executeDstHook(order, hook);
        IERC20(order.outputToken).safeTransfer(order.recipient, sendAmt);
        postFill(orderId, order);
    }

    function executeDstHook(Order calldata order, IAori.DstHook calldata hook) internal returns (uint256 balChg) {
        require(isAllowedHook[hook.hookAddress], "Invalid hook address");

        // todo: it should be expected solvers do this themselves
        // todo: why do we support native here but not anywhere else?
        // Transfer preferred token to a hook
        if (msg.value == 0 && hook.preferedDstInputAmount > 0) {
            IERC20(hook.preferredToken).safeTransferFrom(msg.sender, hook.hookAddress, hook.preferedDstInputAmount);
        }

        balChg = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, order.outputToken);
        require(balChg >= order.outputAmount, "Must provide at least the expected output amount");

        uint256 solverReturnAmt = balChg - order.outputAmount;
        if (solverReturnAmt > 0) {
            IERC20(order.outputToken).safeTransfer(msg.sender, solverReturnAmt);
        }
    }

    function preFill(Order calldata order) internal view returns (bytes32 orderId) {
        validateFill(order);
        deadlineCheck(order);
        orderId = hash(order);
    }

    function postFill(bytes32 orderId, Order calldata order) internal {
        orderStatus[orderId] = IAori.OrderStatus.Filled;
        srcEidToFillerFills[order.srcEid][msg.sender].push(orderId);
        emit Fill(orderId, order);
    }

    /**
     * @notice Settles filled orders by batching order hashes into a payload and sending through LayerZero
     * @param srcEid The source endpoint ID
     * @param filler The filler address
     * @param extraOptions Additional LayerZero options
     */
    function settle(uint32 srcEid, address filler, bytes calldata extraOptions)
        external
        payable
        nonReentrant
        whenNotPaused
    {
        bytes32[] storage arr = srcEidToFillerFills[srcEid][filler];
        uint256 arrLength = arr.length;
        require(arrLength > 0, "No orders provided");

        uint16 fillCount = uint16(arrLength < MAX_FILLS_PER_SETTLE ? arrLength : MAX_FILLS_PER_SETTLE);
        bytes memory payload = arr.packSettlement(filler, fillCount);

        _lzSend(srcEid, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
        emit SettleSent(srcEid, filler, payload);
    }

    /**
     * @notice Returns a fee quote for sending a message through LayerZero
     * @param _dstEid Destination endpoint ID
     * @param _msgType Message type (0 for settlement, 1 for cancellation)
     * @param _options Execution options
     * @param _payInLzToken Whether to pay fee in LayerZero token
     * @param _srcEid Source endpoint ID (for settle operations)
     * @param _filler Filler address (for settle operations)
     * @return fee The messaging fee in native currency
     */
    function quote(
        uint32 _dstEid,
        uint8 _msgType,
        bytes calldata _options,
        bool _payInLzToken,
        uint32 _srcEid,
        address _filler
    ) public view returns (uint256 fee) {
        uint256 payloadSize;
        if (_msgType == uint8(PayloadType.Cancellation)) {
            payloadSize = CANCELLATION_PAYLOAD_SIZE;
        } else if (_msgType == uint8(PayloadType.Settlement)) {
            uint256 fillsLength = srcEidToFillerFills[_srcEid][_filler].length;
            uint16 fillCount = uint16(fillsLength < MAX_FILLS_PER_SETTLE ? fillsLength : MAX_FILLS_PER_SETTLE);
            payloadSize = settlementPayloadSize(fillCount);
        } else {
            revert("Invalid message type");
        }
        MessagingFee memory messagingFee = _quote(_dstEid, new bytes(payloadSize), _options, _payInLzToken);
        return messagingFee.nativeFee;
    }

    // ====================================================
    // ============= VALIDATION FUNCTIONS =================
    // ====================================================

    function validateOrderSig(Order calldata order, bytes calldata signature) internal view {
        bytes32 digest = _hashOrder712(order);
        address recovered = ECDSA.recover(digest, signature);
        require(recovered == order.offerer, "InvalidSignature");
    }

    /**
     * @notice Validates order parameters for deposit
     * @param order The order to validate
     */
    // todo: Some checks may be removed + this doesnt check the modified params from hook
    function validateDeposit(IAori.Order calldata order) internal view {
        require(order.offerer != address(0), "Invalid offerer");
        require(order.recipient != address(0), "Invalid recipient");
        require(order.endTime > block.timestamp, "Invalid end time");
        require(order.startTime < order.endTime, "Invalid start & end time");
        require(order.endTime > order.startTime, "Invalid end time");
        require(order.inputAmount > 0, "Invalid input amount");
        require(order.outputAmount > 0, "Invalid output amount");
        require(order.inputToken != address(0) && order.outputToken != address(0), "Invalid token");
        require(order.srcEid == ENDPOINT_ID, "Chain mismatch");
    }

    /**
     * @notice Validates order parameters for fill
     * @param order The order to validate
     */
    function validateFill(IAori.Order calldata order) internal view {
        require(order.offerer != address(0), "Invalid offerer");
        require(order.recipient != address(0), "Invalid recipient");
        require(block.timestamp >= order.startTime, "Order not started");
        require(order.endTime > order.startTime, "Invalid end time");
        require(order.inputAmount > 0, "Invalid input amount");
        require(order.outputAmount > 0, "Invalid output amount");
        require(order.inputToken != address(0) && order.outputToken != address(0), "Invalid token");
        require(order.dstEid == ENDPOINT_ID, "Chain mismatch");
        require(orderStatus[hash(order)] == IAori.OrderStatus.Unknown, "Order not active");
    }

    /**
     * @notice Checks if an order has expired
     * @param order The order to check
     */
    function deadlineCheck(IAori.Order calldata order) internal view {
        require(block.timestamp <= order.endTime, "Order has expired");
    }

    // ====================================================
    // =============== HELPER FUNCTIONS ===================
    // ====================================================
    /**
     * @dev Returns the domain name and version for EIP712.
     */
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("Aori", "1");
    }
    /**
     * @dev Returns the EIP712 digest for the given order
     * @param order The order details
     * @return The computed digest
     */

    function _hashOrder712(Order calldata order) internal view returns (bytes32) {
        return _hashTypedDataSansChainId(
            keccak256(
                abi.encode(
                    _ORDER_TYPEHASH,
                    order.offerer,
                    order.recipient,
                    order.inputToken,
                    order.outputToken,
                    order.inputAmount,
                    order.outputAmount,
                    order.startTime,
                    order.endTime,
                    order.srcEid,
                    order.dstEid
                )
            )
        );
    }

    /**
     * @notice Computes the hash of an order
     * @param order The order to hash
     * @return The computed hash
     */
    function hash(IAori.Order calldata order) public pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    // ====================================================
    // ================= VIEW FUNCTIONS ===================
    // ====================================================

    /**
     * @notice Returns the locked balance for a user and token
     * @param offerer The user address
     * @param token The token address
     * @return The locked balance amount
     */
    function getLockedBalances(address offerer, address token) external view returns (uint256) {
        return balances[offerer][token].locked;
    }

    /**
     * @notice Returns the unlocked balance for a user and token
     * @param offerer The user address
     * @param token The token address
     * @return The unlocked balance amount
     */
    function getUnlockedBalances(address offerer, address token) external view returns (uint256) {
        return balances[offerer][token].unlocked;
    }
}
