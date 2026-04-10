// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import "../types/AoriErrors.sol";
import { TokenUtils } from "./TokenUtils.sol";

/**
 * @title HookUtils
 * @notice Internal library for executing hooks and observing token balance changes
 * @dev Used for srcHook and dstHook execution in deposits and fills
 */
library HookUtils {
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
        uint256 minAmount,
        uint256 value
    ) internal returns (uint256 amountReceived) {
        uint256 balBefore = TokenUtils.balanceOf(outputToken, address(this));
        (bool success, bytes memory reason) = target.call{ value: value }(data);
        if (!success) revert HookCallFailed(reason);
        uint256 balAfter = TokenUtils.balanceOf(outputToken, address(this));

        if (balAfter < balBefore) revert HookDecreasedContractBalance();

        amountReceived = balAfter - balBefore;
        if (amountReceived < minAmount) revert SlippageExceeded(minAmount, amountReceived);
    }
}
