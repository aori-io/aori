// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Order, OrderStatus, Balance, SrcHook, DstHook } from "../../types/AoriTypes.sol";
import { AoriStorageData } from "../../storage/AoriStorage.sol";
import { PayloadUnpackUtils } from "../internal/PayloadUtils.sol";
import { ExecutionUtils } from "../internal/ExecutionUtils.sol";
import { ValidationUtils } from "../internal/ValidationUtils.sol";
import { BalanceUtils } from "../internal/BalanceUtils.sol";
import { TokenUtils } from "../internal/TokenUtils.sol";
import "../../types/AoriErrors.sol";

/**
 * @title AoriCoreLib
 * @notice External library containing core logic for the Aori protocol
 * @dev Functions are called via DELEGATECALL, running in Aori's storage context.
 *      Consolidates swap, settlement, hook execution, and deposit/fill logic.
 */
library AoriCoreLib {
    using SafeERC20 for IERC20;
    using BalanceUtils for Balance;
    using TokenUtils for address;
    using PayloadUnpackUtils for bytes;

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                          EVENTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Swap(bytes32 indexed orderId, Order order, uint256 amountReceived);
    event Settle(bytes32 indexed orderId);
    event SettleFailed(bytes32 indexed orderId);
    event SettlementFailed(bytes32 indexed orderId, uint32 expectedDstEid, uint32 actualSenderEid);
    event Fill(bytes32 indexed orderId, Order order);
    event Deposit(bytes32 indexed orderId, Order order, uint16 feeMbps);
    event Cancel(bytes32 indexed orderId);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    STORAGE ACCESSOR                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function _getAoriStorage() private pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      SWAP FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Core swap execution logic shared by all swap variants
     * @dev Executes hook, validates output, distributes tokens, updates state
     */
    function executeSwap(
        bytes32 orderId,
        Order calldata order,
        SrcHook calldata hook,
        address solver
    ) external returns (uint256 amountReceived) {
        AoriStorageData storage $ = _getAoriStorage();

        // Execute hook - converts input to output
        amountReceived = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, order.outputToken);

        if (amountReceived < order.outputAmount) {
            revert InsufficientSrcHookOutput(order.outputAmount, amountReceived);
        }

        // Calculate both fees
        uint128 protocolFee = uint128((uint256(order.outputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.outputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 recipientAmount = order.outputAmount - totalFee;
        uint256 surplus = amountReceived - order.outputAmount;

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

        // Surplus accrues to solver
        if (surplus > 0) {
            $.balances[solver][order.outputToken].unlocked += SafeCast.toUint128(surplus);
        }

        // Update state
        $.orders[orderId] = order;
        $.orderStatus[orderId] = OrderStatus.Settled;

        emit Swap(orderId, order, amountReceived);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   SETTLEMENT FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Handles settlement of filled orders - runs entire batch in one DELEGATECALL
     * @param payload The settlement payload containing order hashes and filler information
     * @param senderEid The source endpoint ID
     * @dev Keeps settleOrder logic private to avoid 100+ DELEGATECALLs per batch
     */
    function handleSettlement(
        bytes calldata payload,
        uint32 senderEid
    ) external {
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

            _settleOrder($, orderId, order, filler);
        }
    }

    /**
     * @notice Settles a single order by transferring tokens from offerer to filler
     * @dev Private function called from handleSettlement loop - avoids DELEGATECALL overhead
     */
    function _settleOrder(
        AoriStorageData storage $,
        bytes32 orderId,
        Order memory order,
        address filler
    ) private {
        if ($.orderStatus[orderId] != OrderStatus.Active) {
            return; // Skip non-active orders
        }

        // Calculate both fees
        uint128 protocolFee = uint128((uint256(order.inputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.inputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 fillerAmount = order.inputAmount - totalFee;

        address feeRecipient = order.options.feeRecipient == address(0) ? filler : order.options.feeRecipient;

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
            bool successAdditionalFee =
                additionalFee > 0 ? $.balances[feeRecipient][order.inputToken].increaseUnlockedNoRevert(additionalFee) : true;

            if (!successLock || !successFiller || !successAdditionalFee) {
                $.balances[order.offerer][order.inputToken] = offererBalanceCache;
                $.balances[filler][order.inputToken] = fillerBalanceCache;
                $.balances[feeRecipient][order.inputToken] = feeRecipientBalanceCache;
                emit SettleFailed(orderId);
                return;
            }
        }

        // Protocol fee - lazy accrual with overflow protection
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
        emit Settle(orderId);
    }

    /**
     * @notice Handles settlement of same-chain swaps with fee distribution
     */
    function settleSingleChainSwap(
        bytes32 orderId,
        Order memory order,
        address solver
    ) external {
        AoriStorageData storage $ = _getAoriStorage();

        // Calculate both fees
        uint128 protocolFee = uint128((uint256(order.inputAmount) * $.protocolFeeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 additionalFee = uint128((uint256(order.inputAmount) * order.options.feeMbps) / ValidationUtils.MBPS_DIVISOR);
        uint128 totalFee = protocolFee + additionalFee;
        uint128 solverAmount = order.inputAmount - totalFee;

        // Decrease offerer's locked balance
        $.balances[order.offerer][order.inputToken].locked -= order.inputAmount;

        // Credit solver (minus fees)
        $.balances[solver][order.inputToken].unlocked += solverAmount;

        // Protocol fee - lazy accrual
        if (protocolFee > 0) {
            $.pendingProtocolFees[order.inputToken] += protocolFee;
        }

        // Additional fee accrues to feeRecipient
        if (additionalFee > 0) {
            address feeRecipient = order.options.feeRecipient == address(0) ? solver : order.options.feeRecipient;
            $.balances[feeRecipient][order.inputToken].unlocked += additionalFee;
        }

        $.orderStatus[orderId] = OrderStatus.Settled;
        emit Fill(orderId, order);
        emit Settle(orderId);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  HOOK EXEC FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Executes a source hook to convert input tokens to preferred token
     */
    function executeSrcHook(
        Order calldata order,
        SrcHook calldata hook,
        function(address) external view returns (bool) isAllowedHook
    ) external returns (uint256 amountReceived, address tokenReceived) {
        ValidationUtils.validateHook(hook.hookAddress, isAllowedHook);

        if (order.inputToken.isNativeToken()) {
            (bool success,) = payable(hook.hookAddress).call{ value: order.inputAmount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(order.inputToken).safeTransferFrom(order.offerer, hook.hookAddress, order.inputAmount);
        }

        amountReceived = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, hook.preferredToken);

        if (amountReceived < hook.minPreferredTokenAmountOut) {
            revert InsufficientSrcHookOutput(hook.minPreferredTokenAmountOut, amountReceived);
        }
        tokenReceived = hook.preferredToken;
    }

    /**
     * @notice Executes a destination hook and handles token conversion
     */
    function executeDstHook(
        Order calldata order,
        DstHook calldata hook,
        uint256 msgValue,
        address sender,
        function(address) external view returns (bool) isAllowedHook
    ) external returns (uint256 balChg) {
        ValidationUtils.validateHook(hook.hookAddress, isAllowedHook);

        if (hook.preferredDstInputAmount > 0) {
            hook.preferredToken.validateMsgValue(hook.preferredDstInputAmount, msgValue);
            hook.preferredToken.safeTransferFrom(sender, hook.hookAddress, hook.preferredDstInputAmount);
        } else {
            if (msgValue != 0) revert UnexpectedNativeTokens();
        }

        balChg = ExecutionUtils.observeBalChg(hook.hookAddress, hook.instructions, order.outputToken);
        if (balChg < order.outputAmount) revert InsufficientDstHookOutput(order.outputAmount, balChg);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  DEPOSIT/FILL FUNCTIONS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Posts a deposit and updates the order status
     */
    function postDeposit(
        address depositToken,
        uint256 depositAmount,
        Order calldata order,
        bytes32 orderId
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        $.balances[order.offerer][depositToken].lock(SafeCast.toUint128(depositAmount));
        $.orderStatus[orderId] = OrderStatus.Active;
        $.orders[orderId] = order;
        $.orders[orderId].inputToken = depositToken;
        $.orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

        emit Deposit(orderId, order, order.options.feeMbps);
    }

    /**
     * @notice Processes an order after successful filling
     */
    function postFill(
        bytes32 orderId,
        Order calldata order,
        address filler,
        uint32 srcEid
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        $.orderStatus[orderId] = OrderStatus.Filled;
        $.srcEidToFillerFills[srcEid][filler].push(orderId);
        emit Fill(orderId, order);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CANCEL FUNCTIONS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Cancels an order and returns tokens to offerer
     * @dev Externalized - cancellations are rare compared to deposits/fills
     */
    function cancelOrder(
        bytes32 orderId
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        if ($.orderStatus[orderId] != OrderStatus.Active) revert CanOnlyCancelActiveOrders();

        Order memory order = $.orders[orderId];
        uint128 amountToReturn = order.inputAmount;
        address tokenAddress = order.inputToken;
        address recipient = order.offerer;

        // Validate contract has sufficient tokens
        tokenAddress.validateSufficientBalance(amountToReturn);

        // Update state first
        $.orderStatus[orderId] = OrderStatus.Cancelled;
        $.balances[recipient][tokenAddress].locked -= amountToReturn;

        // Transfer tokens back to offerer
        tokenAddress.safeTransfer(recipient, amountToReturn);
        emit Cancel(orderId);
    }
}
