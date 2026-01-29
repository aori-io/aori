// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../../types/AoriErrors.sol";
import { TokenUtils } from "./TokenUtils.sol";

/**
 * @notice Library for executing external calls and observing token balance changes
 * @dev Used for hook execution and token conversion operations
 */
library ExecutionUtils {
    /**
     * @notice Executes a hook call, measures token balance change, and validates minimum output
     * @dev Reverts with SlippageExceeded if balance change is below minAmount
     * @param target The hook contract address to call
     * @param data The calldata (hook instructions) to send to the target
     * @param outputToken The token address to observe balance changes for
     * @param minAmount Minimum acceptable output (reverts if below)
     * @return amountReceived The amount of tokens received from hook execution
     */
    function executeHook(
        address target,
        bytes calldata data,
        address outputToken,
        uint256 minAmount
    ) internal returns (uint256 amountReceived) {
        uint256 balBefore = TokenUtils.balanceOf(outputToken, address(this));
        (bool success,) = target.call(data);
        if (!success) revert HookCallFailed();
        uint256 balAfter = TokenUtils.balanceOf(outputToken, address(this));

        // Prevent underflow and provide clear error message
        if (balAfter < balBefore) revert HookDecreasedContractBalance();

        amountReceived = balAfter - balBefore;
        if (amountReceived < minAmount) revert SlippageExceeded(minAmount, amountReceived);
    }
}
