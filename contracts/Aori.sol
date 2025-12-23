// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppUpgradeable, Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { EIP712 } from "solady/src/utils/EIP712.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { IAori } from "./IAori.sol";
import "./AoriUtils.sol";
import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { Permit2Lib } from "./libraries/Permit2Lib.sol";

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
 * @dev version 0.3.2
 * @notice Aori is a trust-minimized omnichain intent settlement protocol.
 * Connecting users and solvers from any chain to any chain,
 * facilitating peer to peer exchange from any token to any token.
 */

contract Aori is IAori, OAppUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, EIP712 {
    using PayloadPackUtils for bytes32[];
    using PayloadUnpackUtils for bytes;
    using PayloadSizeUtils for uint8;
    using HookUtils for SrcHook;
    using HookUtils for DstHook;
    using SafeERC20 for IERC20;
    using BalanceUtils for Balance;
    using ValidationUtils for IAori.Order;
    using NativeTokenUtils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ERC-7201 STORAGE                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:storage-location erc7201:aori.storage.v1
    struct AoriStorage {
        // SRC STATE
        mapping(address => mapping(address => Balance)) balances;
        mapping(bytes32 => Order) orders;
        mapping(uint32 => bool) isSupportedChain;
        // DST STATE
        uint16 maxFillsPerSettle;
        mapping(bytes32 => IAori.OrderStatus) orderStatus;
        mapping(address => bool) isAllowedHook;
        mapping(address => bool) isAllowedSolver;
        mapping(uint32 => mapping(address => bytes32[])) srcEidToFillerFills;
    }

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x7c3e0d4c5a2b8f9e1d6c0a3b7e4f2d8a9c5b1e3f7d0a6c9b2e5f8d1a4c7b0e00;

    function _getAoriStorage() internal pure returns (AoriStorage storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    IMMUTABLE STATE                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // Unique identifier for this endpoint in the LayerZero network
    uint32 public immutable ENDPOINT_ID;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 CONSTRUCTOR & INITIALIZER                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(
        address _endpoint,
        uint32 _eid
    ) OAppUpgradeable(_endpoint) {
        ENDPOINT_ID = _eid;
        _disableInitializers();
    }

    function initialize(
        address _owner,
        uint16 _maxFillsPerSettle,
        address[] calldata _initialSolvers,
        address[] calldata _initialHooks,
        uint32[] calldata _supportedChains
    ) external initializer {
        require(_owner != address(0), "Set owner");
        __Ownable_init(_owner);
        __OApp_init(_owner);
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        AoriStorage storage $ = _getAoriStorage();
        $.maxFillsPerSettle = _maxFillsPerSettle;
        $.isSupportedChain[ENDPOINT_ID] = true;

        for (uint256 i = 0; i < _initialSolvers.length; i++) {
            $.isAllowedSolver[_initialSolvers[i]] = true;
        }
        for (uint256 i = 0; i < _initialHooks.length; i++) {
            $.isAllowedHook[_initialHooks[i]] = true;
        }
        for (uint256 i = 0; i < _supportedChains.length; i++) {
            $.isSupportedChain[_supportedChains[i]] = true;
        }
    }

    /**
     * @notice Allows the contract to receive native tokens
     * @dev Required for native token operations including hook interactions
     */
    receive() external payable {
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   STORAGE ACCESSORS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function orders(bytes32 orderId) public view returns (
        uint128, uint128, address, address, uint32, uint32, uint32, uint32, address, address
    ) {
        Order memory order = _getAoriStorage().orders[orderId];
        return (
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
        );
    }

    function isSupportedChain(uint32 eid) public view returns (bool) {
        return _getAoriStorage().isSupportedChain[eid];
    }

    function MAX_FILLS_PER_SETTLE() public view returns (uint16) {
        return _getAoriStorage().maxFillsPerSettle;
    }

    function orderStatus(bytes32 orderId) public view returns (IAori.OrderStatus) {
        return _getAoriStorage().orderStatus[orderId];
    }

    function isAllowedHook(address hook) public view returns (bool) {
        return _getAoriStorage().isAllowedHook[hook];
    }

    function isAllowedSolver(address solver) public view returns (bool) {
        return _getAoriStorage().isAllowedSolver[solver];
    }

    function srcEidToFillerFills(uint32 srcEid, address filler, uint256 index) public view returns (bytes32) {
        return _getAoriStorage().srcEidToFillerFills[srcEid][filler][index];
    }

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
        _getAoriStorage().isAllowedHook[hook] = true;
    }

    /**
     * @notice Removes a hook address from the whitelist
     * @param hook The address of the hook to remove
     * @dev Only callable by the contract owner
     */
    function removeAllowedHook(address hook) external onlyOwner {
        _getAoriStorage().isAllowedHook[hook] = false;
    }

    /**
     * @notice Adds a solver address to the whitelist
     * @param solver The address of the solver to whitelist
     * @dev Only callable by the contract owner
     */
    function addAllowedSolver(address solver) external onlyOwner {
        _getAoriStorage().isAllowedSolver[solver] = true;
    }

    /**
     * @notice Removes a solver address from the whitelist
     * @param solver The address of the solver to remove
     * @dev Only callable by the contract owner
     */
    function removeAllowedSolver(address solver) external onlyOwner {
        _getAoriStorage().isAllowedSolver[solver] = false;
    }

    /**
    * @notice Adds a single chain to the supported chains list
    * @param eid The endpoint ID of the chain to add
    * @dev Only callable by the contract owner
    */
    function addSupportedChain(uint32 eid) external onlyOwner {
        _getAoriStorage().isSupportedChain[eid] = true;
        emit ChainSupported(eid);
    }

    /**
    * @notice Adds multiple chains to the supported chains list
    * @param eids Array of endpoint IDs of the chains to add
    * @return results Array of booleans indicating which EIDs were successfully added
    * @dev Only callable by the contract owner
    */
    function addSupportedChains(uint32[] calldata eids) external onlyOwner returns (bool[] memory results) {
        AoriStorage storage $ = _getAoriStorage();
        uint256 length = eids.length;
        results = new bool[](length);
        for (uint256 i = 0; i < length; i++) {
            $.isSupportedChain[eids[i]] = true;
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
        _getAoriStorage().isSupportedChain[eid] = false;
        emit ChainRemoved(eid);
    }

    /**
     * @notice Updates the maximum number of fills per settlement
     * @param _maxFillsPerSettle The new maximum fills per settle value
     * @dev Only callable by the contract owner
     */
    function setMaxFillsPerSettle(uint16 _maxFillsPerSettle) external onlyOwner {
        require(_maxFillsPerSettle > 0, "Max fills must be > 0");
        _getAoriStorage().maxFillsPerSettle = _maxFillsPerSettle;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EMERGENCY FUNCTIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
    * @notice Emergency function to cancel an order, bypassing normal restrictions
    * @dev Only callable by the contract owner. Always transfers tokens to maintain accounting consistency.
    *      WARNING: This bypasses normal validation and should only be used in emergency situations.
    * @param orderId The hash of the order to cancel
    * @param recipient The address to send tokens to (can be different from offerer)
    */
    function emergencyCancel(bytes32 orderId, address recipient) external onlyOwner {
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");
        require(recipient != address(0), "Invalid recipient address");
        Order memory order = $.orders[orderId];
        require(order.srcEid == ENDPOINT_ID, "Emergency cancel only allowed on source chain");
        address tokenAddress = order.inputToken;
        uint128 amountToReturn = order.inputAmount;
        // Validate sufficient balance
        tokenAddress.validateSufficientBalance(amountToReturn);
        $.orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        bool success = $.balances[order.offerer][tokenAddress].decreaseLockedNoRevert(amountToReturn);
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

        AoriStorage storage $ = _getAoriStorage();
        if (isLocked) {
            bool success = $.balances[user][token].decreaseLockedNoRevert(uint128(amount));
            require(success, "Failed to decrease locked balance");
        } else {
            uint256 unlockedBalance = $.balances[user][token].unlocked;
            require(unlockedBalance >= amount, "Insufficient unlocked balance");
            $.balances[user][token].unlocked = uint128(unlockedBalance - amount);
        }

        // Validate sufficient balance and transfer
        token.validateSufficientBalance(amount);
        token.safeTransfer(recipient, amount);

        emit Withdraw(user, token, amount);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Modifier to ensure the caller is a whitelisted solver
     * @dev Only allows whitelisted solvers to proceed
     */
    modifier onlySolver() {
        require(_getAoriStorage().isAllowedSolver[msg.sender], "Invalid solver");
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
     * @notice Deposits tokens to the contract with a hook call for token conversion
     * @dev Executes a hook call for token conversion before deposit processing.
     *      For single-chain swaps, immediately settles and transfers tokens to recipient.
     *      For cross-chain swaps, locks converted tokens for later settlement.
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     * @param hook The pre-hook configuration for token conversion
     */
    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata hook
    ) external nonReentrant whenNotPaused onlySolver {
        require(!order.inputToken.isNativeToken(), "Use depositNative for native tokens");
        bytes32 orderId = order.validateDeposit(
            signature,
            _hashOrder712(order),
            ENDPOINT_ID,
            this.orderStatus,
            this.isSupportedChain
        );

        // Execute hook to convert input tokens to preferred/output tokens
        (uint256 amountReceived, address tokenReceived) = 
            _executeSrcHook(order, hook);
        
        emit SrcHookExecuted(orderId, tokenReceived, amountReceived);

        if (order.isSingleChainSwap()) {
            // Single-chain: immediate settlement (tokens already transferred to recipient)
            AoriStorage storage $ = _getAoriStorage();
            $.orders[orderId] = order;
            $.orderStatus[orderId] = IAori.OrderStatus.Settled;
            emit Settle(orderId);
        } else {
            // Cross-chain: lock converted tokens for later settlement
            _postDeposit(tokenReceived, amountReceived, order, orderId);
        }
    }

    /**
     * @notice Executes a source hook to convert input tokens and handle distribution
     * @dev Sends input tokens (native or ERC20) to hook, executes conversion, and handles token distribution.
     *      For single-chain swaps: converts to output token and immediately distributes.
     *      For cross-chain swaps: converts to preferred token for later cross-chain transfer.
     * @param order The order details
     * @param hook The source hook configuration
     * @return amountReceived The amount of tokens received from the hook
     * @return tokenReceived The token address that was received
     */
    function _executeSrcHook(
        Order calldata order,
        SrcHook calldata hook
    ) internal returns (
        uint256 amountReceived,
        address tokenReceived
    ) {
        // Validate hook struct upfront
        hook.validateSrcHook(
            this.isAllowedHook,
            this.isAllowedSolver
        );

        // Send input tokens to hook for conversion
        if (order.inputToken.isNativeToken()) {
            // Native tokens already received via msg.value, send to hook
            (bool success, ) = payable(hook.hookAddress).call{value: order.inputAmount}("");
            require(success, "Native transfer to hook failed");
        } else {
            // Pull ERC20 tokens from offerer to hook
            IERC20(order.inputToken).safeTransferFrom(
                order.offerer,
                hook.hookAddress,
                order.inputAmount
            );
        }
        
        if (order.isSingleChainSwap()) {
            // Single-chain: convert to final output token and distribute immediately
            amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                order.outputToken
            );
            
            require(amountReceived >= order.outputAmount, "Insufficient output from hook");
            tokenReceived = order.outputToken;
            
            // Distribute tokens: exact amount to recipient, surplus to solver
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);
            
            uint256 surplus = amountReceived - order.outputAmount;
            if (surplus > 0) {
                order.outputToken.safeTransfer(hook.solver, surplus);
            }
        } else {
            // Cross-chain: convert to preferred token for cross-chain transfer
            amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                hook.preferredToken
            );
            
            require(amountReceived >= hook.minPreferedTokenAmountOut, "Insufficient output from hook");
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
        AoriStorage storage $ = _getAoriStorage();
        $.balances[order.offerer][depositToken].lock(SafeCast.toUint128(depositAmount));
        $.orderStatus[orderId] = IAori.OrderStatus.Active;
        $.orders[orderId] = order;
        $.orders[orderId].inputToken = depositToken;
        $.orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

        emit Deposit(orderId, order);
    }

    /**
     * @notice Deposits native tokens to the contract without a hook call
     * @dev User calls this directly and sends their own ETH via msg.value.
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     */
    function depositNative(
        Order calldata order
    ) external payable nonReentrant whenNotPaused {
        require(order.inputToken.isNativeToken(), "Order must specify native token");
        require(msg.value == order.inputAmount, "Incorrect native amount");
        require(msg.sender == order.offerer, "Only offerer can deposit native tokens");

        // Calculate order ID and validate uniqueness
        bytes32 orderId = hash(order);
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Unknown, "Order already exists");
        require($.isSupportedChain[order.dstEid], "Destination chain not supported");
        require(order.srcEid == ENDPOINT_ID, "Chain mismatch");

        // Use validation utility for common order parameter checks
        ValidationUtils.validateCommonOrderParams(order);

        _postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /**
     * @notice Deposits native tokens to the contract with a hook call for token conversion
     * @dev User calls this directly and sends their own ETH via msg.value.
     *      Executes a hook call for token conversion before deposit processing.
     *      For single-chain swaps, immediately settles and transfers tokens to recipient.
     *      For cross-chain swaps, locks converted tokens for later settlement.
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     * @param hook The pre-hook configuration for token conversion
     */
    function depositNative(
        Order calldata order,
        SrcHook calldata hook
    ) external payable nonReentrant whenNotPaused {
        require(order.inputToken.isNativeToken(), "Order must specify native token");
        require(msg.value == order.inputAmount, "Incorrect native amount");
        require(msg.sender == order.offerer, "Only offerer can deposit native tokens");

        // Calculate order ID and validate uniqueness
        bytes32 orderId = hash(order);
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Unknown, "Order already exists");
        require($.isSupportedChain[order.dstEid], "Destination chain not supported");
        require(order.srcEid == ENDPOINT_ID, "Chain mismatch");

        // Use validation utility for common order parameter checks
        ValidationUtils.validateCommonOrderParams(order);

        // Execute hook to convert native tokens to preferred/output tokens
        (uint256 amountReceived, address tokenReceived) =
            _executeSrcHook(order, hook);

        emit SrcHookExecuted(orderId, tokenReceived, amountReceived);

        if (order.isSingleChainSwap()) {
            // Single-chain: immediate settlement (tokens already transferred to recipient)
            $.orders[orderId] = order;
            $.orderStatus[orderId] = IAori.OrderStatus.Settled;
            emit Settle(orderId);
        } else {
            // Cross-chain: lock converted tokens for later settlement
            _postDeposit(tokenReceived, amountReceived, order, orderId);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    PERMIT2 DEPOSITS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deposits tokens using Permit2 SignatureTransfer with witness
     * @dev User signs a single Permit2 message that includes the order as witness data.
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
    ) external nonReentrant whenNotPaused onlySolver {
        require(!order.inputToken.isNativeToken(), "Use depositNative for native tokens");
        require(block.timestamp <= deadline, "Permit2 signature expired");

        bytes32 orderId = hash(order);
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Unknown, "Order already exists");
        require($.isSupportedChain[order.dstEid], "Destination chain not supported");
        require(order.srcEid == ENDPOINT_ID, "Chain mismatch");

        ValidationUtils.validateCommonOrderParams(order);

        // Build Permit2 structs
        ISignatureTransfer.PermitTransferFrom memory permit = Permit2Lib.buildPermit(
            order, nonce, deadline
        );
        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            Permit2Lib.buildTransferDetails(address(this), order.inputAmount);

        bytes32 witness = Permit2Lib.hashOrder(order);

        // Execute Permit2 transfer - this verifies the signature
        // The user signed over: token, amount, nonce, deadline, spender (this contract), AND the order
        ISignatureTransfer(Permit2Lib.PERMIT2).permitWitnessTransferFrom(
            permit,
            transferDetails,
            order.offerer,
            witness,
            Permit2Lib.WITNESS_TYPE_STRING,
            signature
        );

        _postDeposit(order.inputToken, order.inputAmount, order, orderId);
    }

    /**
     * @notice Deposits tokens using Permit2 with source hook for token conversion
     * @dev Tokens are transferred directly to the hook via Permit2, then hook converts them.
     *      For single-chain swaps, immediately settles and transfers tokens to recipient.
     *      For cross-chain swaps, locks converted tokens for later settlement.
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
    ) external nonReentrant whenNotPaused onlySolver {
        require(!order.inputToken.isNativeToken(), "Use depositNative for native tokens");
        require(block.timestamp <= deadline, "Permit2 signature expired");

        bytes32 orderId = hash(order);
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Unknown, "Order already exists");
        require($.isSupportedChain[order.dstEid], "Destination chain not supported");
        require(order.srcEid == ENDPOINT_ID, "Chain mismatch");

        ValidationUtils.validateCommonOrderParams(order);

        hook.validateSrcHook(this.isAllowedHook, this.isAllowedSolver);

        // Build Permit2 structs - transfer directly to hook
        ISignatureTransfer.PermitTransferFrom memory permit = Permit2Lib.buildPermit(
            order, nonce, deadline
        );
        ISignatureTransfer.SignatureTransferDetails memory transferDetails =
            Permit2Lib.buildTransferDetails(hook.hookAddress, order.inputAmount);

        bytes32 witness = Permit2Lib.hashOrder(order);

        // Transfer tokens to hook via Permit2
        ISignatureTransfer(Permit2Lib.PERMIT2).permitWitnessTransferFrom(
            permit,
            transferDetails,
            order.offerer,
            witness,
            Permit2Lib.WITNESS_TYPE_STRING,
            signature
        );

        // Execute hook conversion (tokens already at hook address)
        if (order.isSingleChainSwap()) {
            // Single-chain: convert to final output token and distribute immediately
            uint256 amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                order.outputToken
            );

            require(amountReceived >= order.outputAmount, "Insufficient output from hook");

            // Distribute tokens: exact amount to recipient, surplus to solver
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);

            uint256 surplus = amountReceived - order.outputAmount;
            if (surplus > 0) {
                order.outputToken.safeTransfer(hook.solver, surplus);
            }

            emit SrcHookExecuted(orderId, order.outputToken, amountReceived);

            // Single-chain: immediate settlement
            $.orders[orderId] = order;
            $.orderStatus[orderId] = IAori.OrderStatus.Settled;
            emit Settle(orderId);
        } else {
            // Cross-chain: convert to preferred token for cross-chain transfer
            uint256 amountReceived = ExecutionUtils.observeBalChg(
                hook.hookAddress,
                hook.instructions,
                hook.preferredToken
            );

            require(amountReceived >= hook.minPreferedTokenAmountOut, "Insufficient output from hook");

            emit SrcHookExecuted(orderId, hook.preferredToken, amountReceived);

            // Cross-chain: lock converted tokens for later settlement
            _postDeposit(hook.preferredToken, amountReceived, order, orderId);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                             FILL                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fills an order by transferring output tokens from the filler to recipient
     * @dev For single-chain orders: settles immediately with internal balance transfers.
     *      For cross-chain orders: marks as filled and queues for later settlement.
     * @param order The order details to fill
     */
    function fill(Order calldata order) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        
        // Validate payment method matches output token type
        if (order.outputToken.isNativeToken()) {
            require(msg.value == order.outputAmount, "Incorrect native amount sent");
        } else {
            require(msg.value == 0, "No native tokens should be sent for ERC20 fills");
        }

        // Update contract state
        if (order.isSingleChainSwap()) {
            _settleSingleChainSwap(orderId, order, msg.sender);
        } else {
            _postFill(orderId, order);
        }

        // Transfer tokens to recipient
        if (order.outputToken.isNativeToken()) {
            order.outputToken.safeTransfer(order.recipient, order.outputAmount);
        } else {
            IERC20(order.outputToken).safeTransferFrom(msg.sender, order.recipient, order.outputAmount);
        }
    }

    /**
     * @notice Fills an order by converting preferred tokens to output tokens via hook
     * @dev Uses a hook contract to convert solver's preferred tokens into the required output tokens.
     *      Any surplus from the conversion is returned to the solver.
     * @param order The order details to fill
     * @param hook The hook configuration for token conversion
     */
    function fill(
        Order calldata order,
        IAori.DstHook calldata hook
    ) external payable nonReentrant whenNotPaused onlySolver {

        bytes32 orderId = order.validateFill(
            ENDPOINT_ID,
            this.orderStatus
        );
        
        // Execute hook to convert preferred tokens to output tokens
        uint256 amountReceived = _executeDstHook(order, hook);
        emit DstHookExecuted(orderId, hook.preferredToken, amountReceived);

        uint256 surplus = amountReceived - order.outputAmount;

        // Update contract state
        if (order.isSingleChainSwap()) {
            _settleSingleChainSwap(orderId, order, msg.sender);
        } else {
            _postFill(orderId, order);
        }

        // Transfer tokens: exact amount to recipient, surplus to solver
        order.outputToken.safeTransfer(order.recipient, order.outputAmount);
        if (surplus > 0) {
            order.outputToken.safeTransfer(msg.sender, surplus);
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
    ) internal returns (uint256 balChg) {
        // Validate hook struct upfront
        hook.validateDstHook(this.isAllowedHook);

        if (hook.preferedDstInputAmount > 0) {
            if (hook.preferredToken.isNativeToken()) {
                require(msg.value == hook.preferedDstInputAmount, "Incorrect native amount for preferred token");
                (bool success, ) = payable(hook.hookAddress).call{value: hook.preferedDstInputAmount}("");
                require(success, "Native transfer to hook failed");
            } else {
                // ERC20 token input - no native tokens should be sent
                require(msg.value == 0, "No native tokens should be sent for ERC20 preferred token");
                IERC20(hook.preferredToken).safeTransferFrom(
                    msg.sender,
                    hook.hookAddress,
                    hook.preferedDstInputAmount
                );
            }
        } else {
            // Hook expects no input tokens - ensure no ETH was mistakenly sent
            require(msg.value == 0, "No native tokens expected");
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
        AoriStorage storage $ = _getAoriStorage();
        $.orderStatus[orderId] = IAori.OrderStatus.Filled;
        $.srcEidToFillerFills[order.srcEid][msg.sender].push(orderId);
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
        AoriStorage storage $ = _getAoriStorage();
        bytes32[] storage arr = $.srcEidToFillerFills[srcEid][filler];
        uint256 arrLength = arr.length;
        require(arrLength > 0, "No orders provided");

        uint16 fillCount = uint16(
            arrLength < $.maxFillsPerSettle ? arrLength : $.maxFillsPerSettle
        );
        bytes memory payload = arr.packSettlement(filler, fillCount);

        MessagingReceipt memory receipt = _lzSend(srcEid, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
        emit SettleSent(srcEid, filler, payload, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
    }

    /**
     * @notice Settles a single order by transferring tokens from offerer to filler
     * @dev Moves tokens from offerer's locked balance to filler's unlocked balance.
     *      Uses cache-and-restore pattern to ensure true atomicity - if any step fails, 
     *      all balance changes are reverted to prevent accounting inconsistencies.
     * @param orderId The hash of the order to settle
     * @param filler The filler address who will receive the tokens
     */
    function _settleOrder(bytes32 orderId, address filler) internal {
        AoriStorage storage $ = _getAoriStorage();
        if ($.orderStatus[orderId] != IAori.OrderStatus.Active) {
            return; // Skip non-active orders
        }

        Order memory order = $.orders[orderId];

        // Cache original balances for potential rollback
        Balance memory offererBalanceCache = $.balances[order.offerer][order.inputToken];
        Balance memory fillerBalanceCache = $.balances[filler][order.inputToken];

        // Attempt atomic balance transfer
        bool successLock = $.balances[order.offerer][order.inputToken].decreaseLockedNoRevert(
            order.inputAmount
        );
        bool successUnlock = $.balances[filler][order.inputToken].increaseUnlockedNoRevert(
            order.inputAmount
        );

        // If either operation failed, restore original balances to maintain atomicity
        if (!successLock || !successUnlock) {
            $.balances[order.offerer][order.inputToken] = offererBalanceCache;
            $.balances[filler][order.inputToken] = fillerBalanceCache;
            return; // Exit with no state changes
        }

        $.orderStatus[orderId] = IAori.OrderStatus.Settled;
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

        AoriStorage storage $ = _getAoriStorage();
        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            Order memory order = $.orders[orderId];

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
     * @notice Handles settlement of same-chain swaps with immediate token transfer
     * @dev Performs atomic settlement within the same transaction for same-chain orders.
     *      Moves tokens from offerer's locked balance to solver's unlocked balance.
     *      Includes comprehensive validation to ensure balance consistency.
     * @param orderId The unique identifier for the order
     * @param order The order details
     * @param solver The address of the solver who filled the order
     */
    function _settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver
    ) internal {
        AoriStorage storage $ = _getAoriStorage();
        // Capture initial state for validation
        uint128 initialOffererLocked = $.balances[order.offerer][order.inputToken].locked;
        uint128 initialSolverUnlocked = $.balances[solver][order.inputToken].unlocked;

        // Atomic balance transfer: locked → unlocked
        if ($.balances[order.offerer][order.inputToken].locked >= order.inputAmount) {
            bool successLock = $.balances[order.offerer][order.inputToken].decreaseLockedNoRevert(
                order.inputAmount
            );

            bool successUnlock = $.balances[solver][order.inputToken].increaseUnlockedNoRevert(
                order.inputAmount
            );

            require(successLock && successUnlock, "Balance operation failed");
        }

        // Verify the transfer was executed correctly
        uint128 finalOffererLocked = $.balances[order.offerer][order.inputToken].locked;
        uint128 finalSolverUnlocked = $.balances[solver][order.inputToken].unlocked;

        $.balances[order.offerer][order.inputToken].validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            order.inputAmount
        );

        $.orderStatus[orderId] = IAori.OrderStatus.Settled;
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
    function cancel(bytes32 orderId) external nonReentrant whenNotPaused {
        Order memory order = _getAoriStorage().orders[orderId];

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

        _getAoriStorage().orderStatus[orderId] = IAori.OrderStatus.Cancelled;

        bytes memory payload = PayloadPackUtils.packCancellation(orderId);
        MessagingReceipt memory receipt = __lzSend(orderToCancel.srcEid, payload, extraOptions);
        emit CancelSent(orderId, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
    }

    /**
     * @notice Internal function to cancel an order and return tokens to offerer
     * @dev Updates order status, decreases locked balance, and transfers tokens back.
     * @param orderId The hash of the order to cancel
     */
    function _cancel(bytes32 orderId) internal {
        AoriStorage storage $ = _getAoriStorage();
        require($.orderStatus[orderId] == IAori.OrderStatus.Active, "Can only cancel active orders");

        Order memory order = $.orders[orderId];
        uint128 amountToReturn = order.inputAmount;
        address tokenAddress = order.inputToken;
        address recipient = order.offerer;

        // Validate contract has sufficient tokens
        tokenAddress.validateSufficientBalance(amountToReturn);

        // Update state first
        $.orderStatus[orderId] = IAori.OrderStatus.Cancelled;
        bool success = $.balances[recipient][tokenAddress].decreaseLockedNoRevert(amountToReturn);
        require(success, "Failed to decrease locked balance");

        // Transfer tokens back to offerer
        tokenAddress.safeTransfer(recipient, amountToReturn);
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
     * @dev Only unlocked balances can be withdrawn. Locked balances are reserved for active orders.
     * @param token The token address to withdraw
     * @param amount The amount to withdraw (use 0 to withdraw full balance)
     */
    function withdraw(address token, uint256 amount) external nonReentrant whenNotPaused {
        address holder = msg.sender;
        AoriStorage storage $ = _getAoriStorage();
        uint256 unlockedBalance = $.balances[holder][token].unlocked;
        require(unlockedBalance > 0, "Non-zero balance required");

        // Default to full balance if amount is 0
        if (amount == 0) {
            amount = unlockedBalance;
        } else {
            require(unlockedBalance >= amount, "Insufficient unlocked balance");
        }

        token.validateSufficientBalance(amount);

        // Update balance
        $.balances[holder][token].unlocked = uint128(unlockedBalance - amount);

        // Transfer tokens to user
        token.safeTransfer(holder, amount);
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
        return ("Aori", "0.3.2");
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
        return _getAoriStorage().balances[offerer][token].locked;
    }

    /**
     * @notice Returns the unlocked balance for a user and token
     * @param offerer The user address
     * @param token The token address
     * @return The unlocked balance amount
     */
    function getUnlockedBalances(address offerer, address token) external view returns (uint256) {
        return _getAoriStorage().balances[offerer][token].unlocked;
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
    ) public view returns (MessagingFee memory) {
        AoriStorage storage $ = _getAoriStorage();
        // Calculate payload size using the library function
        uint256 fillsLength = $.srcEidToFillerFills[_srcEid][_filler].length;
        uint256 payloadSize = PayloadSizeUtils.calculatePayloadSize(
            _msgType,
            fillsLength,
            $.maxFillsPerSettle
        );

        // Get the quote from LayerZero
        MessagingFee memory messagingFee = _quote(
            _dstEid,
            new bytes(payloadSize),
            _options,
            _payInLzToken
        );

        return messagingFee;
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     UUPS UPGRADEABILITY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by the contract owner
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner {}

    /**
     * @dev Storage gap for future upgrades
     */
    uint256[50] private __gap;
}
