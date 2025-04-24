// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "solady/src/utils/EIP712.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { IAori } from "./IAori.sol";
import "./AoriUtils.sol";

/**
 *•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*
 * @title Aori
 * @notice Aori implements a trust-minimized cross-chain intent settlement protocol
 * It enables users to deposit tokens on a source chain with signed intent parameters,
 * which solvers can fulfill on destination chains. The contract manages the full intent
 * lifecycle through secure token custody, EIP-712 signature verification, and LayerZero
 * messaging for cross-chain settlement. This architecture ensures that user intents are
 * executed precisely according to their signed parameters while maintaining security
 * through comprehensive validation and state management across the blockchain ecosystem.
 *•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*
 */

contract Aori is IAori, OApp, ReentrancyGuard, Pausable, EIP712 {
    using PayloadPackUtils for bytes32[];
    using PayloadUnpackUtils for bytes;
    using PayloadSizeUtils for uint8;
    using HookUtils for SrcHook;
    using HookUtils for DstHook;
    using SafeERC20 for IERC20;
    using BalanceUtils for Balance;
    using ValidationUtils for IAori.Order;

    constructor(
        address _endpoint, // LayerZero endpoint address
        address _owner, // Contract owner address
        uint32 _eid, // Endpoint ID for this chain
        uint16 _maxFillsPerSettle // Maximum number of fills per settlement
    ) OApp(_endpoint, _owner) Ownable(_owner) EIP712() {
        ENDPOINT_ID = _eid;
        MAX_FILLS_PER_SETTLE = _maxFillsPerSettle;
        require(_owner != address(0), "Set owner");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         SRC STATE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // Unique identifier for this endpoint in the LayerZero network
    uint32 public immutable ENDPOINT_ID;

    // Tracks locked and unlocked balances for each user and token
    mapping(address => mapping(address => Balance)) private balances;

    // Stores orders by their unique hash
    mapping(bytes32 => Order) public orders;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         DST STATE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      OWNER FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Pauses all contract operations
     * @dev Only callable by the contract owner
     */
    function pause() external onlyOwner {
        _pause();
    }

    /**
     * @notice Unpauses all contract operations
     * @dev Only callable by the contract owner
     */
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
    function emergencyWithdraw(address token, uint256 amount) external onlyOwner {
        uint256 etherBalance = address(this).balance;
        if (etherBalance > 0) {
            (bool success, ) = payable(owner()).call{ value: etherBalance }("");
            require(success, "Ether withdrawal failed");
        }
        if (amount > 0) {
            IERC20(token).safeTransfer(owner(), amount);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Modifier to ensure the caller is a whitelisted solver
     * @dev Only allows whitelisted solvers to proceed
     */
    modifier onlySolver() {
        require(isAllowedSolver[msg.sender], "Invalid solver");
        _;
    }

    /**
     * @notice Modifier to ensure the caller is a whitelisted hook address
     * @dev Only allows whitelisted hook addresses to proceed
     * @param hookAddress The address of the hook to check
     */
    modifier allowedHookAddress(address hookAddress) {
        require(isAllowedHook[hookAddress], "Invalid hook address");
        _;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          DEPOSIT                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deposits tokens to the contract without a hook call
     * @dev Supports both direct deposits and hook-based token conversion
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     */
    function deposit(
        Order calldata order,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus
        );
        IERC20(order.inputToken).safeTransferFrom(order.offerer, address(this), order.inputAmount);
        _postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /**
     * @notice Deposits tokens to the contract with a hook call
     * @dev This function executes a hook call before depositing the tokens
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     * @param hook The pre-hook configuration
     */
    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata hook
    ) external payable nonReentrant whenNotPaused onlySolver {
        require(hook.isSome(), "Missing hook");
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus
        );

        // Execute hook and handle single-chain or cross-chain logic
        (uint256 amountReceived, address tokenReceived) = 
            _executeSrcHook(order, hook);
        
        if (order.isSingleChainSwap()) {
            // Save the order details
            orders[orderId] = order;
            
            // Settle the order immediately for single-chain swaps
            _settleSingleChainSwap(orderId, order, msg.sender, amountReceived);
        } else {
            // Process the cross-chain deposit
            _postDeposit(tokenReceived, amountReceived, order, orderId);
        }
    }

    /**
     * @notice Executes a source hook and returns the balance change
     * @param order The order details
     * @param hook The source hook configuration
     * @return amountReceived The amount of tokens received from the hook
     * @return tokenReceived The token address that was received
     */
    function _executeSrcHook(
        Order calldata order,
        SrcHook calldata hook
    ) internal allowedHookAddress(hook.hookAddress) returns (
        uint256 amountReceived,
        address tokenReceived
    ) {
        // Transfer input tokens to the hook
        IERC20(order.inputToken).safeTransferFrom(
            order.offerer,
            hook.hookAddress,
            order.inputAmount
        );
        
        if (order.isSingleChainSwap()) {
            // For single-chain swaps, observe balance changes in the output token
            amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                order.outputToken
            );
            
            // Ensure sufficient output was received
            require(amountReceived >= order.outputAmount, "Insufficient output from hook");
            
            // Set token received to the output token
            tokenReceived = order.outputToken;
        } else {
            // For cross-chain swaps, observe balance changes in the preferred token
            amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                hook.preferredToken
            );
            
            // Ensure sufficient preferred tokens were received
            require(amountReceived >= hook.minPreferedTokenAmountOut, "Insufficient output from hook");
            
            // Set token received to the preferred token
            tokenReceived = hook.preferredToken;
        }
    }

    /**
     * @notice Posts a deposit and updates the order status
     * @param depositToken The token address to deposit
     * @param depositAmount The amount of tokens to deposit
     * @param order The order details
     * @param orderId The unique identifier for the order
     */
    function _postDeposit(
        address depositToken,
        uint256 depositAmount,
        Order calldata order,
        bytes32 orderId
    ) internal {
        balances[order.offerer][depositToken].lock(uint128(depositAmount));
        orderStatus[orderId] = IAori.OrderStatus.Active;
        orders[orderId] = order;
        orders[orderId].inputToken = depositToken;
        orders[orderId].inputAmount = uint128(depositAmount);

        emit Deposit(orderId, order);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             FILL                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fills an order by transferring tokens from the filler
     * @dev Supports both direct fills and hook-based token conversion
     * @param order The order details to fill
     */
    function fill(Order calldata order) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        IERC20(order.outputToken).safeTransferFrom(msg.sender, order.recipient, order.outputAmount);

        // single-chain swap path
        if (order.isSingleChainSwap()) {
            uint256 amountReceived = order.outputAmount;
            _settleSingleChainSwap(orderId, order, msg.sender, amountReceived);
            return;
        }

        // Cross-chain swap path
        _postFill(orderId, order);
    }

    /**
     * @notice Fills an order by transferring tokens from the filler
     * @dev Supports both direct fills and hook-based token conversion
     * @param order The order details to fill
     * @param hook The solver data including hook configuration
     */
    function fill(
        Order calldata order,
        IAori.DstHook calldata hook
    ) external payable nonReentrant whenNotPaused onlySolver {
        // For single-chain swaps, this function should never be called
        require(!order.isSingleChainSwap(), "Use fill() without hook for single-chain swaps");

        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        uint256 amountReceived = _executeDstHook(order, hook);

        IERC20(order.outputToken).safeTransfer(order.recipient, amountReceived);
        _postFill(orderId, order);
    }

    /**
     * @notice Executes a destination hook and handles token conversion
     * @param order The order details
     * @param hook The destination hook configuration
     * @return balChg The balance change observed from the hook execution
     */
    function _executeDstHook(
        Order calldata order,
        IAori.DstHook calldata hook
    ) internal allowedHookAddress(hook.hookAddress) returns (uint256 balChg) {
        if (msg.value == 0 && hook.preferedDstInputAmount > 0) {
            IERC20(hook.preferredToken).safeTransferFrom(
                msg.sender,
                hook.hookAddress,
                hook.preferedDstInputAmount
            );
        }

        balChg = ExecutionUtils.observeBalChg(
            hook.hookAddress,
            hook.instructions,
            order.outputToken
        );
        require(balChg >= order.outputAmount, "Hook must provide at least the expected output amount");

        uint256 solverReturnAmt = balChg - order.outputAmount;
        if (solverReturnAmt > 0) {
            IERC20(order.outputToken).safeTransfer(msg.sender, solverReturnAmt);
        }
    }

    /**
     * @notice Processes an order after successful filling
     * @param orderId The unique identifier for the order
     * @param order The order details that were filled
     */
    function _postFill(bytes32 orderId, Order calldata order) internal {
        orderStatus[orderId] = IAori.OrderStatus.Filled;
        srcEidToFillerFills[order.srcEid][msg.sender].push(orderId);
        emit Fill(orderId, order);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*             DEPOSIT AND FILL (Single-chain-swap)           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deposits and immediately fills a single-chain swap order in a single transaction
     * @dev Only for single-chain swaps, combines deposit and fill steps
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     */
    function depositAndFill(
        Order calldata order,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused onlySolver {
        // This function is only for single-chain swaps
        require(order.isSingleChainSwap(), "Only for single-chain swaps");
        bytes32 orderId = order.validateDepositAndFill(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus
        );
        // Transfer input token from offerer to this contract
        IERC20(order.inputToken).safeTransferFrom(order.offerer, address(this), order.inputAmount);
        
        // Transfer output token from solver to recipient
        IERC20(order.outputToken).safeTransferFrom(msg.sender, order.recipient, order.outputAmount);
        
        // Credit the input token directly to the solver's unlocked balance
        balances[msg.sender][order.inputToken].increaseUnlockedNoRevert(uint128(order.inputAmount));
        
        // Order is immediately settled
        orderStatus[orderId] = IAori.OrderStatus.Settled;
        orders[orderId] = order;
        
        // Emit event
        emit Settle(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            SETTLE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Settles filled orders by batching order hashes into a payload and sending through LayerZero
     * @param srcEid The source endpoint ID
     * @param filler The filler address
     * @param extraOptions Additional LayerZero options
     */
    function settle(
        uint32 srcEid,
        address filler,
        bytes calldata extraOptions
    ) external payable nonReentrant whenNotPaused onlySolver {
        bytes32[] storage arr = srcEidToFillerFills[srcEid][filler];
        uint256 arrLength = arr.length;
        require(arrLength > 0, "No orders provided");

        uint16 fillCount = uint16(
            arrLength < MAX_FILLS_PER_SETTLE ? arrLength : MAX_FILLS_PER_SETTLE
        );
        bytes memory payload = arr.packSettlement(filler, fillCount);

        _lzSend(srcEid, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
        emit SettleSent(srcEid, filler, payload);
    }

    /**
     * @notice Settles a single order and updates balances
     * @param orderId The hash of the order to settle
     * @param filler The filler address
     */
    function _settleOrder(bytes32 orderId, address filler) internal {
        if (orderStatus[orderId] != IAori.OrderStatus.Active) {
            return; // Any reverts are skipped
        }
        // Update balances: move from locked to unlocked
        Order memory order = orders[orderId];
        bool successLock = balances[order.offerer][order.inputToken].decreaseLockedNoRevert(
            uint128(order.inputAmount)
        );
        bool successUnlock = balances[filler][order.inputToken].increaseUnlockedNoRevert(
            uint128(order.inputAmount)
        );

        if (!successLock || !successUnlock) {
            return; // Any reverts are skipped
        }
        orderStatus[orderId] = IAori.OrderStatus.Settled;

        emit Settle(orderId);
    }

    /**
     * @notice Handles settlement of filled orders
     * @param payload The settlement payload containing order hashes and filler information
     */
    function _handleSettlement(bytes calldata payload) internal {
        payload.validateSettlementLen();
        (address filler, uint16 fillCount) = payload.unpackSettlementHeader();
        payload.validateSettlementLen(fillCount);

        // Handle with care: If a single order fails the whole batch will revert
        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            _settleOrder(orderId, filler);
        }
    }

    /**
     * @notice Handles settlement of same-chain swaps
     * @dev Performs immediate settlement without cross-chain messaging for same-chain orders
     * @param orderId The unique identifier for the order
     * @param order The order details
     * @param solver The address of the solver
     * @param amountReceived The actual output amount (may be more than order.outputAmount)
     */
    function _settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver,
        uint256 amountReceived
    ) internal {
        // Capture initial balance state for validation
        uint128 initialOffererLocked = balances[order.offerer][order.inputToken].locked;
        uint128 initialSolverUnlocked = balances[solver][order.inputToken].unlocked;

        // Transfer the output token to the recipient
        IERC20(order.outputToken).safeTransfer(order.recipient, order.outputAmount);

        // Return any surplus to the solver
        uint256 surplus = amountReceived - order.outputAmount;
        if (surplus > 0) {
            IERC20(order.outputToken).safeTransfer(solver, surplus);
        }

        if (balances[order.offerer][order.inputToken].locked >= order.inputAmount) {
            // Unlock the tokens from offerer's balance
            balances[order.offerer][order.inputToken].decreaseLockedNoRevert(
                uint128(order.inputAmount)
            );

            // Credit the tokens directly to the solver's unlocked balance
            balances[solver][order.inputToken].increaseUnlockedNoRevert(uint128(order.inputAmount));
        }

        // Order is immediately settled
        orderStatus[orderId] = IAori.OrderStatus.Settled;

        // Emit event
        emit Settle(orderId);

        // Sanity check: Validate balance consistency using the utility library
        uint128 finalOffererLocked = balances[order.offerer][order.inputToken].locked;
        uint128 finalSolverUnlocked = balances[solver][order.inputToken].unlocked;

        balances[order.offerer][order.inputToken].validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            uint128(order.inputAmount)
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            CANCEL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allows whitelisted solvers to cancel an order from the source chain
     * @param orderId The hash of the order to cancel
     */
    function cancel(bytes32 orderId) external whenNotPaused {
        require(
            isAllowedSolver[msg.sender],
            "Only whitelisted solver can cancel from the source chain"
        );
        _cancel(orderId);
    }

    /**
     * @notice Cancels an order from the destination chain by sending a cancellation message to the source chain
     * @dev Before endTime, only whitelisted solvers can cancel. After endTime, either solver or offerer can cancel
     * @param orderId The hash of the order to cancel
     * @param orderToCancel The order details to cancel
     * @param extraOptions Additional LayerZero options
     */
    function cancel(
        bytes32 orderId,
        Order calldata orderToCancel,
        bytes calldata extraOptions
    ) external payable nonReentrant whenNotPaused {
        require(hash(orderToCancel) == orderId, "Submitted order data doesn't match orderId");

        
        orderToCancel.validateCancel(
            orderId,
            ENDPOINT_ID,
            this.orderStatus,
            msg.sender,
            this.isAllowedSolver
        );
        bytes memory payload = PayloadPackUtils.packCancellation(orderId);
        __lzSend(orderToCancel.srcEid, payload, extraOptions);
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        emit CancelSent(orderId);
    }

    /**
     * @notice Internal function to cancel an order and update balances
     * @param orderId The hash of the order to cancel
     */
    function _cancel(bytes32 orderId) internal {
        require(orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;

        Order memory order = orders[orderId];
        balances[order.offerer][order.inputToken].unlock(uint128(order.inputAmount));

        emit CancelSent(orderId);
    }

    /**
     * @notice Handles cancellation payload from source chain
     * @param payload The cancellation payload containing the order hash
     */
    function _handleCancellation(bytes calldata payload) internal {
        payload.validateCancellationLen();
        bytes32 orderId = payload.unpackCancellation();
        _cancel(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          WITHDRAW                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allows users to withdraw their unlocked token balances
     * @param token The token address to withdraw
     */
    function withdraw(address token) external nonReentrant whenNotPaused {
        address holder = msg.sender;
        uint256 amount = balances[holder][token].unlocked;
        require(amount > 0, "Non-zero balance required");
        IERC20(token).safeTransfer(holder, amount);
        balances[holder][token].unlocked = 0;
        emit Withdraw(holder, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   LAYERZERO FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Sends a message through LayerZero
     * @param eId The destination endpoint ID
     * @param payload The message payload
     * @param extraOptions Additional options
     */
    function __lzSend(
        uint32 eId, 
        bytes memory payload, 
        bytes calldata extraOptions
        ) internal {
        _lzSend(eId, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    /**
     * @notice Handles incoming LayerZero messages for order settlement and cancellation
     * @dev Processes settlement and cancellation payloads
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
        _recvPayload(payload);
    }

    /**
     * @notice Processes incoming LayerZero messages based on the payload type
     * @param payload The message payload containing order hashes and filler information
     */
    function _recvPayload(bytes calldata payload) internal {
        PayloadType msgType = payload.getType();
        if (msgType == PayloadType.Cancellation) {
            _handleCancellation(payload);
        } else if (msgType == PayloadType.Settlement) {
            _handleSettlement(payload);
        } else {
            revert("Unsupported payload type");
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               EIP-712/HASHING HELPER FUNCTIONS             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @dev Returns the domain name and version for EIP712.
     */
    function _domainNameAndVersion()
        internal
        pure
        override
        returns (string memory name, string memory version)
    {
        return ("Aori", "1");
    }

    /**
     * @dev EIP712 typehash for order struct
     */
    bytes32 private constant _ORDER_TYPEHASH =
        keccak256(
            "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

    /**
     * @dev Returns the EIP712 digest for the given order
     * @param order The order details
     * @return The computed digest
     */
    function _hashOrder712(Order calldata order) internal view returns (bytes32) {
        return
            _hashTypedDataSansChainId(
                keccak256(
                    abi.encode(
                        _ORDER_TYPEHASH,
                        order.inputAmount,
                        order.outputAmount,
                        order.inputToken,
                        order.outputToken,
                        order.startTime,
                        order.endTime,
                        order.srcEid,
                        order.dstEid,
                        order.offerer,
                        order.recipient
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       VIEW FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

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
        // Calculate payload size using the library function
        uint256 fillsLength = srcEidToFillerFills[_srcEid][_filler].length;
        uint256 payloadSize = PayloadSizeUtils.calculatePayloadSize(
            _msgType,
            fillsLength,
            MAX_FILLS_PER_SETTLE
        );

        // Get the quote from LayerZero
        MessagingFee memory messagingFee = _quote(
            _dstEid,
            new bytes(payloadSize),
            _options,
            _payInLzToken
        );

        return messagingFee.nativeFee;
    }
}
