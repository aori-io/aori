// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { OAppUpgradeable, Origin, MessagingFee, MessagingReceipt } from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import { PayloadType, PayloadUtils } from "./libraries/internal/PayloadUtils.sol";
import { ReentrancyGuardUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import { PausableUpgradeable } from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { ValidationUtils } from "./libraries/internal/ValidationUtils.sol";
import { ExecutionUtils } from "./libraries/internal/ExecutionUtils.sol";
import { AoriStorage, AoriStorageData } from "./storage/AoriStorage.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { BalanceUtils } from "./libraries/internal/BalanceUtils.sol";
import { AoriAdminLib } from "./libraries/external/AoriAdminLib.sol";
import { AoriCancelLib } from "./libraries/external/AoriCancelLib.sol";
import { TokenUtils } from "./libraries/internal/TokenUtils.sol";
import { Permit2Lib } from "./libraries/internal/Permit2Lib.sol";
import { EIP712 } from "solady/src/utils/EIP712.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { IAori } from "./interfaces/IAori.sol";
import "./types/AoriErrors.sol";
import "./types/AoriTypes.sol";


/**
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
 * @dev version 0.3.2
 * @notice Aori is a trust-minimized omnichain intent settlement protocol.
 * Connecting users and solvers from any chain to any chain,
 * facilitating peer to peer exchange from any token to any token.
 */

contract Aori is IAori, AoriStorage, OAppUpgradeable, ReentrancyGuardUpgradeable, PausableUpgradeable, UUPSUpgradeable, EIP712 {
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
    /*                       STORAGE GAP                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @dev Storage gap for future upgrades. When adding new variables,
    ///      shrink the gap accordingly (e.g., add 2 variables → uint256[48]).
    uint256[50] private __gap;

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
        if (_owner == address(0)) revert InvalidOwner();
        __Ownable_init(_owner);
        __OApp_init(_owner);
        __ReentrancyGuard_init();
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
    /* forgefmt: disable-next-item */
    function isSupportedChain(uint32 eid) public view returns (bool) { return _getAoriStorage().isSupportedChain[eid]; }
    /* forgefmt: disable-next-item */
    function orderStatus(bytes32 orderId) public view returns (OrderStatus) { return _getAoriStorage().orderStatus[orderId]; }
    /* forgefmt: disable-next-item */
    function isAllowedHook(address hook) public view returns (bool) { return _getAoriStorage().isAllowedHook[hook]; }
    /* forgefmt: disable-next-item */
    function isAllowedSolver(address solver) public view returns (bool) { return _getAoriStorage().isAllowedSolver[solver]; }

    // Storage read helpers for AoriLens - enables external view contract without adding bytecode
    /* forgefmt: disable-next-item */
    function readStorage(bytes32 slot) external view returns (bytes32 value) { assembly { value := sload(slot) } }
    /* forgefmt: disable-next-item */
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

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    ADMIN FUNCTIONS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // NOTE: Simple management functions are kept inline rather than delegating to AoriAdminLib.
    // This is intentional: the DELEGATECALL overhead for these one-liners exceeds the inline bytecode,
    // so keeping them here actually saves contract size. Complex functions use the library.

    /// @notice Add a hook to the whitelist
    /* forgefmt: disable-next-item */
    function addAllowedHook(address hook) external onlyOwner { _getAoriStorage().isAllowedHook[hook] = true; emit HookAdded(hook); }
    /// @notice Remove a hook from the whitelist
    /* forgefmt: disable-next-item */
    function removeAllowedHook(address hook) external onlyOwner { _getAoriStorage().isAllowedHook[hook] = false; emit HookRemoved(hook); }
    /// @notice Add a solver to the whitelist
    /* forgefmt: disable-next-item */
    function addAllowedSolver(address solver) external onlyOwner { _getAoriStorage().isAllowedSolver[solver] = true; emit SolverAdded(solver); }
    /// @notice Remove a solver from the whitelist
    /* forgefmt: disable-next-item */
    function removeAllowedSolver(address solver) external onlyOwner { _getAoriStorage().isAllowedSolver[solver] = false; emit SolverRemoved(solver); }
    /// @notice Add a chain to the supported chains list
    /* forgefmt: disable-next-item */
    function addSupportedChain(uint32 eid) external onlyOwner { _getAoriStorage().isSupportedChain[eid] = true; emit ChainSupported(eid); }
    /// @notice Remove a chain from the supported chains list
    /* forgefmt: disable-next-item */
    function removeSupportedChain(uint32 eid) external onlyOwner { _getAoriStorage().isSupportedChain[eid] = false; emit ChainRemoved(eid); }

    // Complex administrative functions delegated to AoriAdminLib to save bytecode

    /// @notice Emergency function to cancel an order and return funds to recipient
    /* forgefmt: disable-next-item */
    function emergencyCancel(bytes32 orderId, address recipient) external onlyOwner { AoriAdminLib.emergencyCancel(orderId, recipient, ENDPOINT_ID); }
    /// @notice Emergency function to withdraw tokens from the contract
    /* forgefmt: disable-next-item */
    function emergencyWithdraw(address token, uint256 amount, address recipient) external onlyOwner { AoriAdminLib.emergencyWithdraw(token, amount, recipient); }
    /// @notice Emergency function to withdraw tokens from a user's balance
    /* forgefmt: disable-next-item */
    function emergencyWithdrawFromUser(address token, uint256 amount, address user, bool isLocked, address recipient) external onlyOwner { AoriAdminLib.emergencyWithdrawFromUser(token, amount, user, isLocked, recipient); }
    /// @notice Claims accumulated protocol fees for a token (permissionless)
    /* forgefmt: disable-next-item */
    function claimProtocolFees(address token) external nonReentrant { AoriAdminLib.claimProtocolFees(token); }


    // Protocol fee admin functions delegated to AoriAdminLib
    /* forgefmt: disable-next-item */
    function setProtocolFee(uint16 feeMbps) external onlyOwner { AoriAdminLib.setProtocolFee(feeMbps); }
    /* forgefmt: disable-next-item */
    function setProtocolTreasury(address treasury) external onlyOwner { AoriAdminLib.setProtocolTreasury(treasury); }
    /* forgefmt: disable-next-item */
    function getProtocolConfig() external view returns (uint16 feeMbps, address treasury) { return AoriAdminLib.getProtocolConfig(); }
    /* forgefmt: disable-next-item */
    function getPendingProtocolFees(address token) external view returns (uint256) { return AoriAdminLib.getPendingProtocolFees(token); }
    /* forgefmt: disable-next-item */
    function setMaxFee(uint16 maxFeeMbps) external onlyOwner { AoriAdminLib.setMaxFee(maxFeeMbps); }
    /* forgefmt: disable-next-item */
    function getMaxFee() external view returns (uint16) { return AoriAdminLib.getMaxFee(); }
    /* forgefmt: disable-next-item */
    function setMaxFillsPerSettle(uint16 maxFills) external onlyOwner { AoriAdminLib.setMaxFillsPerSettle(maxFills); }
    /* forgefmt: disable-next-item */
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
    function deposit(
        Order calldata order,
        bytes calldata signature
    ) external nonReentrant whenNotPaused onlySolver {
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();

        bytes32 orderId = order.validateDeposit(signature, _hashOrder712(order), ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);

        IERC20(order.inputToken).safeTransferFrom(order.offerer, address(this), order.inputAmount);
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

        bytes32 orderId = order.validateDeposit(signature, _hashOrder712(order), ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer input tokens to hook
        IERC20(order.inputToken).safeTransferFrom(order.offerer, hook.hookAddress, order.inputAmount);

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            _executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived = ExecutionUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
        }
    }

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

    /**
     * @notice Deposits native tokens to the contract without a hook call
     * @dev User calls this directly and sends their own ETH via msg.value.
     * @param order The order details (must specify NATIVE_TOKEN as inputToken)
     */
    /* forgefmt: disable-next-item */
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
    function depositNative(
        Order calldata order,
        SrcHook calldata hook
    ) external payable nonReentrant whenNotPaused {
        order.validateNativeDeposit(msg.value, msg.sender);
        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Send native tokens to hook
        (bool success,) = payable(hook.hookAddress).call{ value: order.inputAmount }("");
        if (!success) revert NativeTransferFailed();

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            _executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived = ExecutionUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
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
        if (order.inputToken.isNativeToken()) revert UseDepositNativeForNativeTokens();
        if (block.timestamp > deadline) revert Permit2SignatureExpired();

        bytes32 orderId = order.validateDepositNoSig(ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus, this.isSupportedChain);

        Permit2Lib.executeTransfer(order, address(this), nonce, deadline, signature);

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
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer tokens to hook via Permit2
        Permit2Lib.executeTransfer(order, hook.hookAddress, nonce, deadline, signature);

        if (order.isSingleChainSwap()) {
            // Atomic path: execute swap with slippage + fee logic
            address solver = order.options.solver == address(0) ? msg.sender : order.options.solver;
            _executeSwap(orderId, order, hook, solver);
        } else {
            // Non-atomic path: convert to preferredToken, lock for settlement
            uint256 amountReceived = ExecutionUtils.executeHook(hook.hookAddress, hook.instructions, hook.preferredToken, hook.minPreferredTokenAmountOut);

            _postDeposit(hook.preferredToken, amountReceived, order, orderId, hook.preferredToken, amountReceived);
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         ATOMIC SWAP                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Core swap execution logic shared by all swap variants
     * @dev Executes hook, validates output, distributes tokens, updates state
     * @param orderId The computed order hash
     * @param order The order details
     * @param hook The source hook for token conversion
     * @param solver The solver address (for surplus distribution)
     * @return amountReceived The amount of output tokens received from hook
     */
    function _executeSwap(
        bytes32 orderId,
        Order calldata order,
        SrcHook calldata hook,
        address solver
    ) internal returns (uint256 amountReceived) {
        AoriStorageData storage $ = _getAoriStorage();

        // Calculate minimum acceptable output (returns outputAmount when slippageMbps = 0)
        uint256 minOutput = (uint256(order.outputAmount) * (ValidationUtils.MBPS_DIVISOR - order.options.slippageMbps)) / ValidationUtils.MBPS_DIVISOR;

        // Execute hook - converts input to output, validates minOutput
        amountReceived = ExecutionUtils.executeHook(hook.hookAddress, hook.instructions, order.outputToken, minOutput);

        // Fee basis: if slippageMbps > 0, recipient captures surplus so fee on actual; otherwise fee on signed amount
        uint256 feeBasis = order.options.slippageMbps > 0 ? amountReceived : order.outputAmount;

        // Fee calculations use uint128 - safe because fee validations ensure totalFee <= feeBasis
        uint128 protocolFee = uint128((feeBasis * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((feeBasis * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 recipientAmount = SafeCast.toUint128(feeBasis) - totalFee;

        // Surplus: if slippageMbps = 0, solver gets surplus; if > 0, recipient already received it via feeBasis
        uint256 surplus = order.options.slippageMbps > 0 ? 0 : amountReceived - order.outputAmount;

        // Recipient gets output minus fees (immediate transfer)
        order.outputToken.safeTransfer(order.recipient, recipientAmount);

        // Protocol fee - lazy accrual with overflow protection
        if (protocolFee > 0) {
            uint256 current = $.pendingProtocolFees[order.outputToken];
            unchecked {
                uint256 newAmount = current + protocolFee;
                if (newAmount >= current) {
                    $.pendingProtocolFees[order.outputToken] = newAmount;
                }
            }
        }

        // Additional fee accrues to feeRecipient (or solver if address(0))
        if (additionalFee > 0) {
            address actualFeeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
            $.balances[actualFeeRecipient][order.outputToken].unlocked += additionalFee;
        }

        // Surplus accrues to solver (only when slippageMbps = 0)
        if (surplus > 0) {
            $.balances[solver][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }

        // Update state
        $.orders[orderId] = order;
        $.orderStatus[orderId] = OrderStatus.Settled;

        // Emit events - srcHook converted inputToken to outputToken
        emit Deposit(orderId, order, hook.preferredToken, amountReceived);
        emit Fill(orderId, address(0), 0, 0);
        emit Settle(
            orderId, 
            solver, 
            SafeCast.toUint128(surplus), 
            protocolFee, 
            order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient, 
            additionalFee
        );
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
    /* forgefmt: disable-next-item */
    function fill(Order calldata order) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(msg.sender, ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus);

        // Validate payment method matches output token type
        order.outputToken.validateMsgValue(order.outputAmount, msg.value);

        // Update contract state
        if (order.isSingleChainSwap()) {
            _settleSingleChainSwap(orderId, order, msg.sender, address(0), 0, 0);
        } else {
            _postFill(orderId, order, address(0), 0, 0);
        }

        // Transfer tokens to recipient
        order.outputToken.safeTransferFrom(msg.sender, order.recipient, order.outputAmount);
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
        DstHook calldata hook
    ) external payable nonReentrant whenNotPaused onlySolver {
        bytes32 orderId = order.validateFill(msg.sender, ENDPOINT_ID, _getAoriStorage().maxFeeMbps, this.orderStatus);
        ValidationUtils.validateHook(hook.hookAddress, this.isAllowedHook);

        // Transfer preferred tokens to hook
        if (hook.preferredDstInputAmount > 0) {
            hook.preferredToken.validateMsgValue(hook.preferredDstInputAmount, msg.value);
            hook.preferredToken.safeTransferFrom(msg.sender, hook.hookAddress, hook.preferredDstInputAmount);
        } else {
            if (msg.value != 0) revert UnexpectedNativeTokens();
        }

        // Calculate minimum acceptable output (returns outputAmount when slippageMbps = 0)
        uint256 minOutput = (uint256(order.outputAmount) * (ValidationUtils.MBPS_DIVISOR - order.options.slippageMbps)) / ValidationUtils.MBPS_DIVISOR;

        // Execute hook to convert preferred tokens to output tokens, validates minOutput
        uint256 amountReceived = ExecutionUtils.executeHook(hook.hookAddress, hook.instructions, order.outputToken, minOutput);

        // Update contract state
        if (order.isSingleChainSwap()) {
            _settleSingleChainSwap(orderId, order, msg.sender, hook.preferredToken, hook.preferredDstInputAmount, amountReceived);
        } else {
            _postFill(orderId, order, hook.preferredToken, hook.preferredDstInputAmount, amountReceived);
        }

        // Determine who gets surplus: slippageMbps > 0 → recipient, slippageMbps = 0 → solver
        uint256 recipientAmount = order.options.slippageMbps > 0 ? amountReceived : order.outputAmount;
        order.outputToken.safeTransfer(order.recipient, recipientAmount);

        // Surplus to solver only when slippageMbps = 0
        if (order.options.slippageMbps == 0 && amountReceived > order.outputAmount) {
            uint256 surplus = amountReceived - order.outputAmount;
            _getAoriStorage().balances[msg.sender][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }
    }

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
    function settle(
        uint32 srcEid,
        address filler,
        bytes calldata extraOptions
    ) external payable nonReentrant whenNotPaused onlySolver {
        AoriStorageData storage $ = _getAoriStorage();
        bytes32[] storage arr = $.srcEidToFillerFills[srcEid][filler];
        uint256 arrLength = arr.length;
        if (arrLength == 0) revert NoOrdersProvided();

        uint16 fillCount = uint16(arrLength < $.maxFillsPerSettle ? arrLength : $.maxFillsPerSettle);
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
    function _settleOrder(
        bytes32 orderId,
        address filler
    ) internal {
        AoriStorageData storage $ = _getAoriStorage();
        if ($.orderStatus[orderId] != OrderStatus.Active) {
            return; // Skip non-active orders
        }

        Order memory order = $.orders[orderId];

        // Calculate both fees (order.inputAmount is the locked amount, already correct for srcHook)
        // Fee calculations use uint128 - safe because fee validations ensure totalFee <= inputAmount
        uint128 protocolFee = uint128((uint256(order.inputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.inputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 fillerAmount = order.inputAmount - totalFee;

        address feeRecipient = order.options.feeRecipient == address(0) 
            ? filler 
            : order.options.feeRecipient;

        // Cache original balances for potential rollback
        Balance memory offererBalanceCache = $.balances[order.offerer][order.inputToken];
        Balance memory fillerBalanceCache = $.balances[filler][order.inputToken];

        // Attempt atomic balance transfer with soft-fail for batch safety
        bool successLock = $.balances[order.offerer][order.inputToken].decreaseLockedNoRevert(order.inputAmount);
        
        if (feeRecipient == filler) {
            // Optimized path: single write for filler + additionalFee combined
            uint128 totalToFiller = fillerAmount + additionalFee;
            bool successFiller = $.balances[filler][order.inputToken].increaseUnlockedNoRevert(totalToFiller);
            
            if (!successLock || !successFiller) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                emit SettleFailed(orderId);
                return;
            }
        } else {
            // Separate feeRecipient: need to cache and handle separately
            Balance memory feeRecipientBalanceCache = $.balances[feeRecipient][order.inputToken];
            bool successFiller = $.balances[filler][order.inputToken].increaseUnlockedNoRevert(fillerAmount);
            bool successAdditionalFee = additionalFee > 0 
                ? $.balances[feeRecipient][order.inputToken].increaseUnlockedNoRevert(additionalFee)
                : true;

            if (!successLock || !successFiller || !successAdditionalFee) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                $.balances[feeRecipient][order.inputToken] = feeRecipientBalanceCache;
                emit SettleFailed(orderId);
                return;
            }
        }

        // Protocol fee - lazy accrual with overflow protection (no rollback needed, only written on success)
        if (protocolFee > 0) {
            uint256 current = $.pendingProtocolFees[order.inputToken];
            unchecked {
                uint256 newAmount = current + protocolFee;
                if (newAmount >= current) {
                    $.pendingProtocolFees[order.inputToken] = newAmount;
                }
            }
        }

        $.orderStatus[orderId] = OrderStatus.Settled;
        emit Settle(orderId, filler, fillerAmount, protocolFee, feeRecipient, additionalFee);
    }

    /**
     * @notice Handles settlement of filled orders
     * @param payload The settlement payload containing order hashes and filler information
     * @param senderEid The source endpoint ID
     * @dev Skips orders that were filled on the wrong chain and emits an event
     */
    function _handleSettlement(
        bytes calldata payload,
        uint32 senderEid
    ) internal {
        payload.validateSettlementLen();
        (address filler, uint16 fillCount) = payload.unpackSettlementHeader();
        payload.validateSettlementLen(fillCount);

        AoriStorageData storage $ = _getAoriStorage();
        for (uint256 i = 0; i < fillCount; ++i) {
            bytes32 orderId = payload.unpackSettlementBodyAt(i);
            Order memory order = $.orders[orderId];

            if (order.dstEid != senderEid) {
                emit SettlementFailed(orderId, order.dstEid, senderEid);
                continue;
            }

            _settleOrder(orderId, filler);
        }
    }

    /**
     * @notice Handles settlement of same-chain swaps with fee distribution
     * @dev Performs atomic settlement within the same transaction for same-chain orders.
     *      Moves tokens from offerer's locked balance to solver's unlocked balance minus fee.
     *      Fee accrues to feeRecipient's unlocked balance.
     * @param orderId The unique identifier for the order
     * @param order The order details
     * @param solver The address of the solver who filled the order
     * @param dstHookTokenIn The token used in dstHook (address(0) if no hook)
     * @param dstHookAmountIn The amount sent to dstHook (0 if no hook)
     * @param dstHookAmountOut The amount received from dstHook (0 if no hook)
     */
    function _settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver,
        address dstHookTokenIn,
        uint256 dstHookAmountIn,
        uint256 dstHookAmountOut
    ) internal {
        AoriStorageData storage $ = _getAoriStorage();

        // Calculate both fees (order.inputAmount is the locked amount, already correct for srcHook)
        // Fee calculations use uint128 - safe because fee validations ensure totalFee <= inputAmount
        uint128 protocolFee = uint128((uint256(order.inputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.inputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 solverAmount = order.inputAmount - totalFee;

        // Decrease offerer's locked balance
        $.balances[order.offerer][order.inputToken].locked -= order.inputAmount;

        // Credit solver (minus fees)
        $.balances[solver][order.inputToken].unlocked += solverAmount;

        // Protocol fee - lazy accrual (direct += ok here, single operation can revert)
        if (protocolFee > 0) {
            $.pendingProtocolFees[order.inputToken] += protocolFee;
        }

        // Additional fee accrues to feeRecipient
        address feeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
        if (additionalFee > 0) {
            $.balances[feeRecipient][order.inputToken].unlocked += additionalFee;
        }

        $.orderStatus[orderId] = OrderStatus.Settled;
        emit Fill(orderId, dstHookTokenIn, dstHookAmountIn, dstHookAmountOut);
        emit Settle(orderId, solver, solverAmount, protocolFee, feeRecipient, additionalFee);
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
    /* forgefmt: disable-next-item */
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

    /**
     * @notice Handles cancellation payload from LayerZero
     * @param payload The cancellation payload containing the order hash
     */
    /* forgefmt: disable-next-item */
    function _handleCancellation(bytes calldata payload) internal {
        AoriCancelLib.handleCancellation(payload);
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
    /* forgefmt: disable-next-item */
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
        if (payload.length == 0) revert EmptyPayload();

        // Pass the sender chain's endpoint ID
        _recvPayload(payload, origin.srcEid);
    }

    /**
     * @notice Processes incoming LayerZero messages based on the payload type
     * @param payload The message payload containing order hashes and filler information
     */
    function _recvPayload(
        bytes calldata payload,
        uint32 srcEid
    ) internal {
        PayloadType msgType = payload.getType();
        if (msgType == PayloadType.Cancellation) {
            _handleCancellation(payload);
        } else if (msgType == PayloadType.Settlement) {
            _handleSettlement(payload, srcEid);
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
        return ("Aori", "0.3.2");
    }

    /**
     * @dev Returns the EIP712 digest for the given order with nested Options
     * @dev Reuses Permit2Lib.hashOrder to avoid duplicating typehash constants and hash functions
     * @param order The order details
     * @return The computed digest
     */
    /* forgefmt: disable-next-item */
    function _hashOrder712(Order calldata order) internal view returns (bytes32) {
        return _hashTypedDataSansChainId(Permit2Lib.hashOrder(order));
    }

    /**
     * @notice Computes the hash of an order
     * @param order The order to hash
     * @return The computed hash
     */
    /* forgefmt: disable-next-item */
    function hash(Order calldata order) public pure returns (bytes32) { return keccak256(abi.encode(order)); }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     UUPS UPGRADEABILITY                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Only callable by the contract owner
     * @param newImplementation The address of the new implementation
     */
    /* forgefmt: disable-next-item */
    function _authorizeUpgrade(address newImplementation) internal override onlyOwner { }
}
