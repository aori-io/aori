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
     * @notice Executes an external call and measures the resulting token balance change
     * @dev Useful for hook operations that convert tokens
     * @param target The target contract address to call
     * @param data The calldata to send to the target
     * @param observedToken The token address to observe balance changes for
     * @return The balance change (positive if tokens increased, reverts if decreased)
     */
    function observeBalChg(
        address target,
        bytes calldata data,
        address observedToken
    ) internal returns (uint256) {
        uint256 balBefore = TokenUtils.balanceOf(observedToken, address(this));
        (bool success,) = target.call(data);
        if (!success) revert HookCallFailed();
        uint256 balAfter = TokenUtils.balanceOf(observedToken, address(this));

        // Prevent underflow and provide clear error message
        if (balAfter < balBefore) revert HookDecreasedContractBalance();

        return balAfter - balBefore;
    }
}
