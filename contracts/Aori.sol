// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import {OAppUpgradeable, Origin, MessagingFee, MessagingReceipt} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { PayloadType, PayloadUtils } from "./utils/PayloadUtils.sol";
import { PayloadType, PayloadUtils } from "./utils/PayloadUtils.sol";
import { AoriStorage, AoriStorageData } from "./AoriStorage.sol";
import { AoriAtomicSwapLib } from "./lib/AoriAtomicSwapLib.sol";
import { ValidationUtils } from "./utils/ValidationUtils.sol";
import { BalanceUtils } from "./utils/BalanceUtils.sol";
import { AoriCancelLib } from "./lib/AoriCancelLib.sol";
import { AoriSettleLib } from "./lib/AoriSettleLib.sol";
import { AoriAdminLib } from "./lib/AoriAdminLib.sol";
import { EIP712 } from "solady/src/utils/EIP712.sol";
import { TokenUtils } from "./utils/TokenUtils.sol";
import { Permit2Lib } from "./utils/Permit2Lib.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { HookUtils } from "./utils/HookUtils.sol";
import { IAori } from "./interfaces/IAori.sol";
import "./types/AoriErrors.sol";
import "./types/AoriTypes.sol";

/*
 *                                @@@@@@@@@@@
 *                              @@         @@@@@@                     @@@@@
 *                              @@           @@@@@                    @@@@@
 *                              @@@
 *                                @@@@
 *                                  @@@@@
 *                                      @@@@@
 *        @@@@@@@@@    @@@@          @@@@@@@@@@    @@@@@@    @@@@@@@  @@@@@
 *      @@@@      @@   @@@@      @@@@       @@@@@@@   @@@@ @@    @@@   @@@@
 *     @@@@         @ @@@@     @@@@          @@@@@@   @@@@        @@   @@@@
 *    @@@@@         @@@@@@   @@@@@            @@@@@@  @@@@         @   @@@@
 *    @@@@@          @@@@    @@@@@   @    @    @@@@@  @@@@             @@@@
 *    @@@@@          @@@@   @@@@@@   @@@@@@    @@@@@  @@@@             @@@@
 *    @@@@@         @@@@@   @@@@@@   @    @    @@@@@  @@@@             @@@@
 *    @@@@@         @@@@     @@@@@             @@@@   @@@@             @@@@
 *     @@@@        @@@@@@    @@@@@@           @@@@    @@@@             @@@@
 *      @@@@      @@@@  @@@@@@ @@@@@         @@@      @@@@             @@@@   @@
 *        @@@@@@@@@     @@@@@     @@@@@@@@@@@         @@@@               @@@@@
 */
/**
 * @title Aori
 * @dev version 0.4.0
 * @notice Aori is a trust-minimized omnichain intent settlement protocol.
 * Connecting users and solvers from any chain to any chain,
 * facilitating peer to peer exchange from any token to any token.
 */
contract Aori is IAori, AoriStorage, OAppUpgradeable, PausableUpgradeable, UUPSUpgradeable, EIP712 {
    using PayloadUtils for bytes32[];
    using PayloadUtils for bytes;
    using SafeERC20 for IERC20;
    using BalanceUtils for Balance;
    using ValidationUtils for Order;
    using TokenUtils for address;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    IMMUTABLE STATE                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Unique identifier for this endpoint in the LayerZero network
    uint32 public immutable ENDPOINT_ID;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  REENTRANCY GUARD (EIP-1153)                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Transient storage slot for reentrancy guard. Uses EIP-1153 (TSTORE/TLOAD)
    ///      which is cleared after each transaction. ~100 gas vs ~5000 gas for SSTORE.
    uint256 private constant _REENTRANCY_GUARD_SLOT = 0x929eee149b4bd21268;

    modifier nonReentrant() {
        assembly {
            if tload(_REENTRANCY_GUARD_SLOT) {
                mstore(0, 0x3ee5aeb5) // ReentrancyGuardReentrantCall()
                revert(0x1c, 0x04)
            }
            tstore(_REENTRANCY_GUARD_SLOT, 1)
        }
        _;
        assembly {
            tstore(_REENTRANCY_GUARD_SLOT, 0)
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       STORAGE GAP                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Storage gap for future upgrades. When adding new variables,
    ///      shrink the gap accordingly (e.g., add 2 variables → uint256[48]).
    uint256[50] private __gap;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 CONSTRUCTOR & INITIALIZER                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor(address _endpoint, uint32 _eid) OAppUpgradeable(_endpoint) {
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
        if (_owner == address(0)) revert InvalidOwner();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        __Pausable_init();
        __UUPSUpgradeable_init();

        AoriStorageData storage $ = _getAoriStorage();
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

        $.maxFeeMbps = 1000; // Default 1% max additional fee
        $.protocolTreasury = _owner; // Default to owner, can be changed later
    }

    /**
     * @notice Allows the contract to receive native tokens
     * @dev Required for native token operations including hook interactions
     */
    receive() external payable { }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     VIEW FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // These view functions are used internally via function pointers - DO NOT REMOVE
    
    /// @notice Returns whether a given LayerZero endpoint ID is a supported chain
    function isSupportedChain(uint32 eid) public view returns (bool) { return _getAoriStorage().isSupportedChain[eid]; }
    
    /// @notice Returns the current status of an order by its hash
    function orderStatus(bytes32 orderId) public view returns (OrderStatus) { return _getAoriStorage().orderStatus[orderId]; }
    
    /// @notice Returns whether a hook contract is whitelisted
    function isAllowedHook(address hook) public view returns (bool) { return _getAoriStorage().isAllowedHook[hook]; }
    
    /// @notice Returns whether a solver address is whitelisted
    function isAllowedSolver(address solver) public view returns (bool) { return _getAoriStorage().isAllowedSolver[solver]; }
    
    /// @notice Reads a raw storage slot value (for off-chain introspection)
    function readStorage(bytes32 slot) external view returns (bytes32 value) { assembly { value := sload(slot) } }
    
    /// @notice Reads the length of a dynamic array at a given storage slot
    function readStorageArray(bytes32 slot) external view returns (uint256 length) { assembly { length := sload(slot) } }

    /// @notice Quote LayerZero messaging fee (kept in Aori.sol because it needs OApp's _quote)
    function quote(
        uint32 _dstEid,
        uint8 _msgType,
        bytes calldata _options,
        bool _payInLzToken,
        uint32 _srcEid,
        address _filler
    ) external view returns (MessagingFee memory) {
        AoriStorageData storage $ = _getAoriStorage();
        uint256 fillsLength = $.srcEidToFillerFills[_srcEid][_filler].length;
        uint256 payloadSize = PayloadUtils.calculatePayloadSize(_msgType, fillsLength, $.maxFillsPerSettle);
        return _quote(_dstEid, new bytes(payloadSize), _options, _payInLzToken);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      ADMIN FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Pauses all contract operations
    function pause() external onlyOwner { _pause(); }

    /// @notice Add a hook to the whitelist
    function unpause() external onlyOwner { _unpause(); }

    /// @notice Add a hook to the whitelist
    function addAllowedHook(address hook) external onlyOwner { _getAoriStorage().isAllowedHook[hook] = true; emit HookAdded(hook); }
    
    /// @notice Remove a hook from the whitelist
    function removeAllowedHook(address hook) external onlyOwner { _getAoriStorage().isAllowedHook[hook] = false; emit HookRemoved(hook); }
    
    /// @notice Add a solver to the whitelist
    function addAllowedSolver(address solver) external onlyOwner { _getAoriStorage().isAllowedSolver[solver] = true; emit SolverAdded(solver); }
    
    /// @notice Remove a solver from the whitelist
    function removeAllowedSolver(address solver) external onlyOwner { _getAoriStorage().isAllowedSolver[solver] = false; emit SolverRemoved(solver); }
    
    /// @notice Add a chain to the supported chains list
    function addSupportedChain(uint32 eid) external onlyOwner { _getAoriStorage().isSupportedChain[eid] = true; emit ChainSupported(eid); }
    
    /// @notice Remove a chain from the supported chains list
    function removeSupportedChain(uint32 eid) external onlyOwner { _getAoriStorage().isSupportedChain[eid] = false; emit ChainRemoved(eid); }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ADMIN LIB FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/
    // Complex administrative functions delegated to AoriAdminLib

    /// @notice Emergency function to cancel an order and return funds to recipient
    function emergencyCancel(bytes32 orderId, address recipient) external onlyOwner { AoriAdminLib.emergencyCancel(orderId, recipient, ENDPOINT_ID); }
    
    /// @notice Emergency function to withdraw tokens from the contract
    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyOwner { AoriAdminLib.emergencyWithdraw(token, amount, recipient); }
    
    /// @notice Emergency function to withdraw tokens from a user's balance
    function emergencyWithdrawFromBalance(address token, uint256 amount, address user, bool isLocked, address recipient) external onlyOwner { AoriAdminLib.emergencyWithdrawFromBalance(token, amount, user, isLocked, recipient); }
    
    /// @notice Claims accumulated protocol fees for a token (permissionless)
    function claimProtocolFees(address token) external nonReentrant { AoriAdminLib.claimProtocolFees(token); }

    /// @notice Sets the protocol fee in millibasis points (cross-validated with maxFeeMbps)
    function setProtocolFee(uint16 feeMbps) external onlyOwner { AoriAdminLib.setProtocolFee(feeMbps); }

    /// @notice Sets the protocol treasury address that receives protocol fees
    function setProtocolTreasury(address treasury) external onlyOwner { AoriAdminLib.setProtocolTreasury(treasury); }

    /// @notice Returns the current protocol fee and treasury address
    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury) { return AoriAdminLib.getProtocolConfig(); }

    /// @notice Returns the accumulated unclaimed protocol fees for a given token
    function getPendingProtocolFees(address token) external view returns (uint256) { return AoriAdminLib.getPendingProtocolFees(token); }

    /// @notice Sets the maximum allowed additional fee in millibasis points (cross-validated with protocolFeeMbps)
    function setMaxFee(uint16 maxFeeMbps) external onlyOwner { AoriAdminLib.setMaxFee(maxFeeMbps); }

    /// @notice Returns the current maximum allowed additional fee
    function getMaxFee() external view returns (uint16) { return AoriAdminLib.getMaxFee(); }

    /// @notice Sets the maximum number of fills processed per settlement batch
    function setMaxFillsPerSettle(uint16 maxFills) external onlyOwner { AoriAdminLib.setMaxFillsPerSettle(maxFills); }

    /// @notice Returns the current maximum fills per settlement batch
    function getMaxFillsPerSettle() external view returns (uint16) { return AoriAdminLib.getMaxFillsPerSettle(); }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         MODIFIERS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Modifier to ensure the caller is a whitelisted solver
     * @dev Only allows whitelisted solvers to proceed
     */
    modifier onlySolver() {
        if (!_getAoriStorage().isAllowedSolver[msg.sender]) revert InvalidSolver();
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
    function deposit(Order calldata order, bytes calldata signature) external nonReentrant whenNotPaused onlySolver {
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();

        bytes32 orderId = order.validateDeposit(
            signature, _hashOrder712(order), ENDPOINT_ID, _getAoriStorage().maxFeeMbps, msg.sender, this.orderStatus, this.isSupportedChain
        );

        order.inputToken.safeTransferFromChecked(order.offerer, address(this), order.inputAmount);
        _postDeposit(order.inputToken, order.inputAmount, order, orderId, address(0), 0);
    }

    /**
     * @notice Deposits tokens to the contract with a hook call for token conversion
     * @dev Handles both single-chain atomic swaps and cross-chain deposits with hook.
     *      Single-chain: executes swap immediately with fee distribution.
     *      Cross-chain: converts to preferred token and locks for later settlement.
     * @param order The order details
     * @param signature The user's EIP712 signature over the order
     * @param hook The pre-hook configuration for token conversion
     */
    function deposit(
        Order calldata order,
        bytes calldata signature,
        SrcHook calldata hook
    ) external nonReentrant whenNotPaused onlySolver {
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();

        bytes32 orderId = order.validateDeposit(
            signature, _hashOrder712(order), ENDPOINT_ID, _getAoriStorage().maxFeeMbps, msg.sender, this.orderStatus, this.isSupportedChain
        );
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer input tokens to hook
        IERC20(order.inputToken).safeTransferFrom(order.offerer, hook.hookAddress, order.inputAmount);

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            AoriAtomicSwapLib.executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived =
                HookUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       NATIVE DEPOSIT                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Deposits native tokens to the contract without a hook call
     * @dev User calls this directly and sends their own ETH via msg.value.
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     */
    function depositNative(Order calldata order) external payable nonReentrant whenNotPaused {
        order.validateNativeDeposit(msg.value, msg.sender);

        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        _postDeposit(order.inputToken, order.inputAmount, order, orderId, address(0), 0);
    }

    /**
     * @notice Deposits native tokens to the contract with a hook call for token conversion
     * @dev Handles both single-chain atomic swaps and cross-chain deposits with hook.
     *      User calls this directly and sends their own ETH via msg.value.
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     * @param hook The pre-hook configuration for token conversion
     */
    function depositNative(Order calldata order, SrcHook calldata hook) external payable nonReentrant whenNotPaused {
        order.validateNativeDeposit(msg.value, msg.sender);
        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Send native tokens to hook
        (bool success,) = payable(hook.hookAddress).call{ value: order.inputAmount }("");
        if (!success) revert NativeTransferFailed();

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            AoriAtomicSwapLib.executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived =
                HookUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       PERMIT2 DEPOSIT                      */
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
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();
        if (block.timestamp > deadline) revert Permit2SignatureExpired();

        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        ValidationUtils.validateSolverAuthorization(order, msg.sender);

        uint256 balBefore = IERC20(order.inputToken).balanceOf(address(this));
        Permit2Lib.executeTransfer(order, address(this), nonce, deadline, signature);
        if (IERC20(order.inputToken).balanceOf(address(this)) - balBefore < order.inputAmount) revert TransferAmountMismatch();

        _postDeposit(order.inputToken, order.inputAmount, order, orderId, address(0), 0);
    }

    /**
     * @notice Deposits tokens using Permit2 with source hook for token conversion
     * @dev Handles both single-chain atomic swaps and cross-chain deposits with hook.
     *      Tokens are transferred directly to the hook via Permit2.
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
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();
        if (block.timestamp > deadline) revert Permit2SignatureExpired();

        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        ValidationUtils.validateSolverAuthorization(order, msg.sender);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer tokens to hook via Permit2
        Permit2Lib.executeTransfer(order, hook.hookAddress, nonce, deadline, signature);

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            AoriAtomicSwapLib.executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived =
                HookUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      DEPOSIT UTILS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Posts a deposit and updates the order status
     * @param depositToken The token address to deposit
     * @param depositAmount The amount of tokens to deposit
     * @param order The order details
     * @param orderId The unique identifier for the order
     * @param srcHookTokenOut The token received from srcHook (address(0) if no hook)
     * @param srcHookAmountOut The amount received from srcHook (0 if no hook)
     */
    function _postDeposit(
        address depositToken,
        uint256 depositAmount,
        Order calldata order,
        bytes32 orderId,
        address srcHookTokenOut,
        uint256 srcHookAmountOut
    ) internal {
        AoriStorageData storage $ = _getAoriStorage();
        $.balances[order.offerer][depositToken].lock(SafeCast.toUint128(depositAmount));
        $.orderStatus[orderId] = OrderStatus.Active;
        $.orders[orderId] = order;
        $.orders[orderId].inputToken = depositToken;
        $.orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

        emit Deposit(orderId, order, srcHookTokenOut, srcHookAmountOut);
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
        bytes32 orderId = order.validateFill(msg.sender, ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus);

        // Validate payment method matches output token type
        order.outputToken.validateMsgValue(order.outputAmount, msg.value);

        // Update contract state
        if (order.isSingleChainSwap()) {
            AoriSettleLib.settleSingleChainSwap(orderId, order, msg.sender, address(0), 0, 0);
        } else {
            _postFill(orderId, order, address(0), 0, 0);
        }

        // Transfer tokens to recipient
        order.outputToken.safeTransferFromChecked(msg.sender, order.recipient, order.outputAmount);
    }

    /**
     * @notice Fills an order by converting preferred tokens to output tokens via hook
     * @dev Uses a hook contract to convert solver's preferred tokens into the required output tokens.
     *      Any surplus from the conversion is returned to the solver.
     * @param order The order details to fill
     * @param hook The hook configuration for token conversion
     */
    function fill(Order calldata order, DstHook calldata hook) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(msg.sender, ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer preferred tokens to hook
        if (hook.preferredDstInputAmount > 0) {
            hook.preferredToken.validateMsgValue(hook.preferredDstInputAmount, msg.value);
            hook.preferredToken.safeTransferFrom(msg.sender, hook.hookAddress, hook.preferredDstInputAmount);
        } else {
            if (msg.value != 0) revert UnexpectedNativeTokens();
        }

        uint256 minOutput = order.calculateMinOutput();

        // Execute hook to convert preferred tokens to output tokens, validates minOutput
        uint256 amountReceived = HookUtils.executeHook(hook.hookAddress, hook.instructions, order.outputToken, minOutput);

        // Update contract state
        if (order.isSingleChainSwap()) {
            AoriSettleLib.settleSingleChainSwap(
                orderId, order, msg.sender, hook.preferredToken, hook.preferredDstInputAmount, amountReceived
            );
        } else {
            _postFill(orderId, order, hook.preferredToken, hook.preferredDstInputAmount, amountReceived);
        }

        // Determine who gets surplus: slippageMbps > 0 → recipient, slippageMbps = 0 → solver
        uint256 recipientAmount = order.options.slippageMbps > 0 ? amountReceived : order.outputAmount;
        order.outputToken.safeTransferChecked(order.recipient, recipientAmount);

        // Surplus to solver only when slippageMbps = 0
        if (order.options.slippageMbps == 0 && amountReceived > order.outputAmount) {
            uint256 surplus = amountReceived - order.outputAmount;
            _getAoriStorage().balances[msg.sender][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        FILL UTILS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Processes an order after successful filling
     * @param orderId The unique identifier for the order
     * @param order The order details that were filled
     * @param dstHookTokenIn The token used in dstHook (address(0) if no hook)
     * @param dstHookAmountIn The amount sent to dstHook (0 if no hook)
     * @param dstHookAmountOut The amount received from dstHook (0 if no hook)
     */
    function _postFill(
        bytes32 orderId,
        Order calldata order,
        address dstHookTokenIn,
        uint256 dstHookAmountIn,
        uint256 dstHookAmountOut
    ) internal {
        AoriStorageData storage $ = _getAoriStorage();
        $.orderStatus[orderId] = OrderStatus.Filled;
        $.srcEidToFillerFills[order.srcEid][msg.sender].push(orderId);
        emit Fill(orderId, dstHookTokenIn, dstHookAmountIn, dstHookAmountOut);
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
    function settle(uint32 srcEid, address filler, bytes calldata extraOptions) external payable nonReentrant whenNotPaused onlySolver {
        AoriStorageData storage $ = _getAoriStorage();
        bytes32[] storage arr = $.srcEidToFillerFills[srcEid][filler];
        uint256 arrLength = arr.length;
        if (arrLength == 0) revert NoOrdersProvided();

        uint16 fillCount = uint16(arrLength < $.maxFillsPerSettle ? arrLength : $.maxFillsPerSettle);
        bytes memory payload = arr.packSettlement(filler, fillCount);

        MessagingReceipt memory receipt = _lzSend(srcEid, payload, extraOptions, MessagingFee(msg.value, 0), payable(msg.sender));
        emit SettleSent(srcEid, filler, payload, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
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
        AoriCancelLib.cancelSingleChain(orderId, ENDPOINT_ID, msg.sender, this.orderStatus, this.isAllowedSolver);
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
        bytes memory payload = AoriCancelLib.validateAndPrepareCrossChainCancel(
            orderId, orderToCancel, ENDPOINT_ID, msg.sender, this.orderStatus, this.isAllowedSolver
        );
        MessagingReceipt memory receipt = __lzSend(orderToCancel.srcEid, payload, extraOptions);
        emit CancelSent(orderId, receipt.guid, receipt.nonce, receipt.fee.nativeFee);
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
        AoriAdminLib.withdraw(token, amount, msg.sender);
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
    function __lzSend(uint32 eId, bytes memory payload, bytes calldata extraOptions) internal returns (MessagingReceipt memory receipt) {
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
    ) internal override nonReentrant whenNotPaused {
        if (payload.length == 0) revert EmptyPayload();

        PayloadType msgType = payload.getType();
        if (msgType == PayloadType.Cancellation) {
            AoriCancelLib.handleCancellation(payload, origin.srcEid);
        } else if (msgType == PayloadType.Settlement) {
            AoriSettleLib.handleSettlement(payload, origin.srcEid);
        } else {
            revert InvalidMessageType();
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               EIP-712/HASHING HELPER FUNCTIONS             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @dev Returns the domain name and version for EIP712.
     */
    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        return ("Aori", "0.4.0");
    }

    /**
     * @dev Returns the EIP712 digest for the given order with nested Options
     * @dev Reuses Permit2Lib.hashOrder to avoid duplicating typehash constants and hash functions
     * @param order The order details
     * @return The computed digest
     */
    function _hashOrder712(Order calldata order) internal view returns (bytes32) {
        return _hashTypedDataSansChainId(Permit2Lib.hashOrder(order));
    }

    /**
     * @notice Computes the hash of an order
     * @param order The order to hash
     * @return The computed hash
     */
    function hash(Order calldata order) public pure returns (bytes32) { return keccak256(abi.encode(order)); }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     UUPS UPGRADEABILITY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by the contract owner
     * @param newImplementation The address of the new implementation
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
