// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OApp, Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Pausable } from "@openzeppelin/contracts/utils/Pausable.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { EIP712 } from "solady/src/utils/EIP712.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { IAori } from "./IAori.sol";
import "./AoriUtils.sol";

/**                            @@@@@@@@@@@@                                              
                             @@         @@@@@@                     @@@@@                  
                             @@           @@@@@                    @@@@@                  
                             @@@                                                          
                               @@@@                                                       
                                 @@@@@                                                   
                                     @@@@@                                                
       @@@@@@@@@    @@@@          @@@@@@@@@@    @@@@@@    @@@@@@@  @@@@@                  
     @@@@      @@   @@@@      @@@@       @@@@@@@   @@@@ @@    @@@   @@@@                  
    @@@@         @ @@@@     @@@@          @@@@@@   @@@@        @@   @@@@                  
   @@@@@         @@@@@@   @@@@@            @@@@@@  @@@@         @   @@@@                  
   @@@@@          @@@@    @@@@@   @    @    @@@@@  @@@@             @@@@                  
   @@@@@          @@@@   @@@@@@   @@@@@@    @@@@@  @@@@             @@@@                  
   @@@@@         @@@@@   @@@@@@   @    @    @@@@@  @@@@             @@@@                  
   @@@@@         @@@@     @@@@@             @@@@   @@@@             @@@@                  
    @@@@        @@@@@@    @@@@@@           @@@@    @@@@             @@@@                  
     @@@@      @@@@  @@@@@@ @@@@@         @@@      @@@@             @@@@   @@             
       @@@@@@@@@     @@@@@     @@@@@@@@@@@         @@@@               @@@@@
 */
/**
 * @title Aori  
 * @dev version 0.3.1 
 * @notice Aori is a trust-minimized omnichain intent settlement protocol.
 * Connecting users and solvers from any chain to any chain,
 * facilitating peer to peer exchange from any token to any token.
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
    using NativeTokenUtils for address;
    
    constructor(
        address _endpoint, // LayerZero endpoint address
        address _owner, // Contract owner address
        uint32 _eid, // Endpoint ID for this chain
        uint16 _maxFillsPerSettle // Maximum number of fills per settlement
    ) OApp(_endpoint, _owner) Ownable(_owner) EIP712() {
        ENDPOINT_ID = _eid;
        MAX_FILLS_PER_SETTLE = _maxFillsPerSettle;
        require(_owner != address(0), "Set owner");
        isSupportedChain[_eid] = true;
    }

    /**
     * @notice Allows the contract to receive native tokens
     * @dev Required for native token operations including hook interactions
     */
    receive() external payable {
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
    
    // Tracks supported chains by their endpoint IDs
    mapping(uint32 => bool) public isSupportedChain;

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
    * @notice Adds a single chain to the supported chains list
    * @param eid The endpoint ID of the chain to add
    * @dev Only callable by the contract owner
    */
    function addSupportedChain(uint32 eid) external onlyOwner {
        isSupportedChain[eid] = true;
        emit ChainSupported(eid);
    }

    /**
    * @notice Adds multiple chains to the supported chains list
    * @param eids Array of endpoint IDs of the chains to add
    * @return results Array of booleans indicating which EIDs were successfully added
    * @dev Only callable by the contract owner
    */
    function addSupportedChains(uint32[] calldata eids) external onlyOwner returns (bool[] memory results) {
        uint256 length = eids.length;
        results = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            isSupportedChain[eids[i]] = true;
            emit ChainSupported(eids[i]);
            results[i] = true;
        }
        return results;
    }

    /**
     * @notice Removes a supported chain by its endpoint ID
     * @param eid The endpoint ID of the chain to remove
     * @dev Only callable by the contract owner
     */
    function removeSupportedChain(uint32 eid) external onlyOwner {
        isSupportedChain[eid] = false;
        emit ChainRemoved(eid);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EMERGENCY FUNCTIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
    * @notice Emergency function to cancel an order, bypassing normal restrictions
    * @dev Only callable by the contract owner. Always transfers tokens to maintain accounting consistency.
    * @param orderId The hash of the order to cancel
    * @param recipient The address to send tokens to
    */
    function emergencyCancel(bytes32 orderId, address recipient) external onlyOwner {
        require(orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");
        require(recipient != address(0), "Invalid recipient address");
        
        Order memory order = orders[orderId];
        require(order.srcEid == ENDPOINT_ID, "Emergency cancel only allowed on source chain");
        
        address tokenAddress = order.inputToken;
        uint128 amountToReturn = uint128(order.inputAmount);
        
        // Validate sufficient balance
        tokenAddress.validateSufficientBalance(amountToReturn);
        
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        bool success = balances[order.offerer][tokenAddress].decreaseLockedNoRevert(amountToReturn);
        require(success, "Failed to decrease locked balance");
        
        // Transfer tokens to recipient
        tokenAddress.safeTransfer(recipient, amountToReturn);
        
        emit Cancel(orderId);
        emit Withdraw(recipient, tokenAddress, amountToReturn);
    }
 
    /**
     * @notice Emergency function to extract tokens or ether from the contract
     * @dev Only callable by the contract owner. Does not update user balances - use for direct contract withdrawals.
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
            token.safeTransfer(owner(), amount);
        }
    }

    /**
     * @notice Emergency function to extract tokens from a specific user's balance while maintaining accounting consistency
     * @dev Only callable by the contract owner. Updates user balances to maintain internal accounting state.
     * @param token The token address to withdraw
     * @param amount The amount of tokens to withdraw
     * @param user The user address whose balance to withdraw from
     * @param isLocked Whether to withdraw from locked (true) or unlocked (false) balance
     * @param recipient The address to send the withdrawn tokens to
     */
    function emergencyWithdraw(
        address token, 
        uint256 amount, 
        address user, 
        bool isLocked,
        address recipient
    ) external onlyOwner {
        require(amount > 0, "Amount must be greater than zero");
        require(user != address(0), "Invalid user address");
        require(recipient != address(0), "Invalid recipient address");
        
        if (isLocked) {
            bool success = balances[user][token].decreaseLockedNoRevert(uint128(amount));
            require(success, "Failed to decrease locked balance");
        } else {
            uint256 unlockedBalance = balances[user][token].unlocked;
            require(unlockedBalance >= amount, "Insufficient unlocked balance");
            balances[user][token].unlocked = uint128(unlockedBalance - amount);
        }
        
        // Validate sufficient balance and transfer
        token.validateSufficientBalance(amount);
        token.safeTransfer(recipient, amount);
        
        emit Withdraw(user, token, amount);
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
     * @dev Takes tokens from offerer (not the caller) via transferFrom after signature verification
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     */
    function deposit(
        Order calldata order,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlySolver {
        require(!order.inputToken.isNativeToken(), "Use depositNative for native tokens");
        
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus,
            this.isSupportedChain
        );
        IERC20(order.inputToken).safeTransferFrom(order.offerer, address(this), order.inputAmount);
        _postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /**
     * @notice Deposits tokens to the contract with a hook call
     * @dev Executes a hook call for token conversion before deposit processing
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     * @param hook The pre-hook configuration
     */
    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata hook
    ) external nonReentrant whenNotPaused onlySolver {
        require(hook.isSome(), "Missing hook");
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus,
            this.isSupportedChain
        );

        // Execute hook and handle single-chain or cross-chain logic
        (uint256 amountReceived, address tokenReceived) = 
            _executeSrcHook(order, hook);
        
        emit SrcHookExecuted(orderId, tokenReceived, amountReceived);
        
        if (order.isSingleChainSwap()) {
            // Save the order details
            orders[orderId] = order;
            
            // Update order status directly 
            orderStatus[orderId] = IAori.OrderStatus.Settled;
            emit Settle(orderId);
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
        if (order.inputToken.isNativeToken()) {
            require(msg.value == order.inputAmount, "Incorrect native amount");
            (bool success, ) = payable(hook.hookAddress).call{value: order.inputAmount}("");
            require(success, "Native transfer to hook failed");
        } else {
            IERC20(order.inputToken).safeTransferFrom(
                order.offerer,
                hook.hookAddress,
                order.inputAmount
            );
        }
        
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
            
            // Handle token distribution for single-chain swaps here
            // 1. Transfer agreed amount to recipient
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);
            
            // 2. Return any surplus to the solver
            uint256 surplus = amountReceived - order.outputAmount;
            if (surplus > 0) {
                order.outputToken.safeTransfer(msg.sender, surplus);
            }
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
        balances[order.offerer][depositToken].lock(SafeCast.toUint128(depositAmount));
        orderStatus[orderId] = IAori.OrderStatus.Active;
        orders[orderId] = order;
        orders[orderId].inputToken = depositToken;
        orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

        emit Deposit(orderId, order);
    }

    /**
     * @notice Deposits native tokens to the contract without a hook call
     * @dev User calls this directly and sends their own ETH via msg.value
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     * @param signature The user's EIP712 signature over the order
     */
    function depositNative(
        Order calldata order,
        bytes calldata signature
    ) external payable nonReentrant whenNotPaused {
        require(order.inputToken.isNativeToken(), "Order must specify native token");
        require(msg.value == order.inputAmount, "Incorrect native amount");
        require(msg.sender == order.offerer, "Only offerer can deposit native tokens");
        
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus,
            this.isSupportedChain
        );
        
        _postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             FILL                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fills an order by transferring output tokens from the filler
     * @dev Uses safeTransferFrom to move tokens directly from solver to recipient
     * @param order The order details to fill
     */
    function fill(Order calldata order) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        
        // Handle native or ERC20 output
        if (order.outputToken.isNativeToken()) {
            // For native tokens, solver must send exact amount via msg.value
            require(msg.value == order.outputAmount, "Incorrect native amount sent");
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);
        } else {
            // For ERC20 tokens, ensure no native tokens were sent
            require(msg.value == 0, "No native tokens should be sent for ERC20 fills");
            IERC20(order.outputToken).safeTransferFrom(msg.sender, order.recipient, order.outputAmount);
        }

        // single-chain swap path
        if (order.isSingleChainSwap()) {
            // Use simplified settlement without hook flag since we know it's a direct fill
            _settleSingleChainSwap(orderId, order, msg.sender);
            return;
        }

        // Cross-chain swap path
        _postFill(orderId, order);
    }

    /**
     * @notice Fills an order by converting preferred tokens from the filler to output tokens   
     * @dev Utilizes a hook contract to perform the token conversion
     * @param order The order details to fill
     * @param hook The solver data including hook configuration
     */
    function fill(
        Order calldata order,
        IAori.DstHook calldata hook
    ) external payable nonReentrant whenNotPaused onlySolver {

        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        uint256 amountReceived = _executeDstHook(order, hook);

        emit DstHookExecuted(orderId, hook.preferredToken, amountReceived);

        uint256 surplus = amountReceived - order.outputAmount;

        // Handle native or ERC20 output with surplus
        if (order.outputToken.isNativeToken()) {
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);
            
            if (surplus > 0) {
                order.outputToken.safeTransfer(msg.sender, surplus);
            }
        } else {
            IERC20(order.outputToken).safeTransfer(order.recipient, order.outputAmount);
            
            if (surplus > 0) {
                IERC20(order.outputToken).safeTransfer(msg.sender, surplus);
            }
        }

        // Handle settlement based on chain type
        if (order.isSingleChainSwap()) {
            // For single-chain swaps, settle immediately with proper balance accounting
            _settleSingleChainSwap(orderId, order, msg.sender);
        } else {
            // For cross-chain swaps, use normal fill processing
            _postFill(orderId, order);
        }
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
        if (msg.value > 0) {
            // Native token input
            (bool success, ) = payable(hook.hookAddress).call{value: msg.value}("");
            require(success, "Native transfer to hook failed");
        } else if (hook.preferedDstInputAmount > 0) {
            // ERC20 or native token input
            if (hook.preferredToken.isNativeToken()) {
                require(msg.value == hook.preferedDstInputAmount, "Incorrect native amount for preferred token");
                (bool success, ) = payable(hook.hookAddress).call{value: hook.preferedDstInputAmount}("");
                require(success, "Native transfer to hook failed");
            } else {
                IERC20(hook.preferredToken).safeTransferFrom(
                    msg.sender,
                    hook.hookAddress,
                    hook.preferedDstInputAmount
                );
            }
        }

        balChg = ExecutionUtils.observeBalChg(
            hook.hookAddress,
            hook.instructions,
            order.outputToken
        );
        require(balChg >= order.outputAmount, "Hook must provide at least the expected output amount");
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
    /*                            SETTLE                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Settles filled orders by batching order hashes into a payload and sending through LayerZero
     * @dev Requires ETH to be sent for LayerZero fees
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

        MessagingReceipt memory receipt = _lzSend(srcEid, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
        emit SettleSent(srcEid, filler, payload, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
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
     * @param senderEid The source endpoint ID
     * @dev Skips orders that were filled on the wrong chain and emits an event
     */
    function _handleSettlement(bytes calldata payload, uint32 senderEid) internal {
        payload.validateSettlementLen();
        (address filler, uint16 fillCount) = payload.unpackSettlementHeader();
        payload.validateSettlementLen(fillCount);

        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            Order memory order = orders[orderId];
            
            if (order.dstEid != senderEid) {
                emit settlementFailed(
                    orderId, 
                    order.dstEid, 
                    senderEid, 
                    "Eid mismatch"
                );
                continue; 
            }
            
            _settleOrder(orderId, filler);
        }
    }

    /**
     * @notice Handles settlement of same-chain swaps without hooks
     * @dev Performs immediate settlement without cross-chain messaging for same-chain orders
     * @param orderId The unique identifier for the order
     * @param order The order details
     * @param solver The address of the solver
     */
    function _settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver
    ) internal {
        // Capture initial balance state for validation
        uint128 initialOffererLocked = balances[order.offerer][order.inputToken].locked;
        uint128 initialSolverUnlocked = balances[solver][order.inputToken].unlocked;
        
        // Move tokens from offerer's locked balance to solver's unlocked balance
        if (balances[order.offerer][order.inputToken].locked >= order.inputAmount) {
            bool successLock = balances[order.offerer][order.inputToken].decreaseLockedNoRevert(
                uint128(order.inputAmount)
            );
            
            bool successUnlock = balances[solver][order.inputToken].increaseUnlockedNoRevert(
                uint128(order.inputAmount)
            );
            
            require(successLock && successUnlock, "Balance operation failed");
        }
        
        // Validate balance transfer
        uint128 finalOffererLocked = balances[order.offerer][order.inputToken].locked;
        uint128 finalSolverUnlocked = balances[solver][order.inputToken].unlocked;

        balances[order.offerer][order.inputToken].validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            uint128(order.inputAmount)
        );

        // Order is immediately settled
        orderStatus[orderId] = IAori.OrderStatus.Settled;
        emit Settle(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                            CANCEL                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Allows cancellation of single-chain orders from the source chain
     * @dev Cross-chain orders must be cancelled from the destination chain to prevent race conditions.
     * Cancellation is permitted for:
     *      1. Whitelisted solvers (for any active single-chain order)
     *      2. Order offerers (for their own expired single-chain orders)
     * @param orderId The hash of the order to cancel
     */
    function cancel(bytes32 orderId) external whenNotPaused {
        Order memory order = orders[orderId];
        
        order.validateSourceChainCancel(
            orderId,
            ENDPOINT_ID,
            this.orderStatus,
            msg.sender,
            this.isAllowedSolver
        );
        
        _cancel(orderId);
    }

    /**
     * @notice Cancels a cross-chain order from the destination chain by sending a cancellation message to the source chain
     * @dev This is the required method for cancelling cross-chain orders to prevent race conditions with settlement.
     * Requires ETH to be sent for LayerZero fees. Cancellation is permitted for:
     *      1. Whitelisted solvers (anytime before settlement)
     *      2. Order offerers (after expiry)
     *      3. Order recipients (after expiry)
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
        MessagingReceipt memory receipt = __lzSend(orderToCancel.srcEid, payload, extraOptions);
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        emit CancelSent(orderId, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
    }

    /**
     * @notice Internal function to cancel an order and update balances
     * @param orderId The hash of the order to cancel
     */
    function _cancel(bytes32 orderId) internal {
        require(orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");
        
        // Get order details and amount before changing state
        Order memory order = orders[orderId];
        uint128 amountToReturn = uint128(order.inputAmount);
        address tokenAddress = order.inputToken;
        address recipient = order.offerer;
        
        // Validate contract has sufficient tokens before any state changes
        tokenAddress.validateSufficientBalance(amountToReturn);
        
        // Update state first (checks-effects)
        orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        
        // Decrease locked balance
        bool success = balances[recipient][tokenAddress].decreaseLockedNoRevert(amountToReturn);
        require(success, "Failed to decrease locked balance");
        
        // Transfer tokens directly to offerer (interactions)
        tokenAddress.safeTransfer(recipient, amountToReturn);
        
        // Emit the Cancel event from IAori interface
        emit Cancel(orderId);
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
     * @param amount The amount to withdraw (use 0 to withdraw full balance)
     */
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused {
        address holder = msg.sender;
        uint256 unlockedBalance = balances[holder][token].unlocked;
        require(unlockedBalance > 0, "Non-zero balance required");
        
        if (amount == 0) {
            amount = unlockedBalance;
        } else {
            require(unlockedBalance >= amount, "Insufficient unlocked balance");
        }
        
        // Validate sufficient contract balance and transfer
        token.validateSufficientBalance(amount);
        token.safeTransfer(holder, amount);
        
        balances[holder][token].unlocked = uint128(unlockedBalance - amount);
        emit Withdraw(holder, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   LAYERZERO FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Sends a message through LayerZero
     * @dev Captures and returns the MessagingReceipt for event emission
     * @param eId The destination endpoint ID
     * @param payload The message payload
     * @param extraOptions Additional options
     * @return receipt The messaging receipt containing transaction details (guid, nonce, fee)
     */
    function __lzSend(
        uint32 eId, 
        bytes memory payload, 
        bytes calldata extraOptions
    ) internal returns (MessagingReceipt memory receipt) {
        return _lzSend(eId, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
    }

    /**
     * @notice Handles incoming LayerZero messages for order settlement and cancellation
     * @dev Processes settlement and cancellation payloads
     * @param payload The message payload containing order hashes and filler information
     */
    function _lzReceive(
        Origin calldata origin,
        bytes32,
        bytes calldata payload,
        address,
        bytes calldata
    ) internal override whenNotPaused {
        require(payload.length > 0, "Empty payload");
        
        // Pass the sender chain's endpoint ID
        _recvPayload(payload, origin.srcEid);
    }

    /**
     * @notice Processes incoming LayerZero messages based on the payload type
     * @param payload The message payload containing order hashes and filler information
     */
    function _recvPayload(bytes calldata payload, uint32 srcEid) internal {
        PayloadType msgType = payload.getType();
        if (msgType == PayloadType.Cancellation) {
            _handleCancellation(payload);
        } else if (msgType == PayloadType.Settlement) {
            _handleSettlement(payload, srcEid);
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
        return ("Aori", "0.3.0");
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
