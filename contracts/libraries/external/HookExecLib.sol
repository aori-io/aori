// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { Order, SrcHook, DstHook } from "../../types/AoriTypes.sol";
import { ExecutionUtils } from "../internal/ExecutionUtils.sol";
import { ValidationUtils } from "../internal/ValidationUtils.sol";
import { TokenUtils } from "../internal/TokenUtils.sol";
import "../../types/AoriErrors.sol";

/**
 * @title HookExecLib
 * @notice External library for hook execution logic
 * @dev Functions are called via DELEGATECALL
 */
library HookExecLib {
    using SafeERC20 for IERC20;
    using TokenUtils for address;

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
}
