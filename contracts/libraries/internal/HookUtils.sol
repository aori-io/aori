// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { SrcHook, DstHook } from "../../types/AoriTypes.sol";
import "../../types/AoriErrors.sol";

/**
 * @notice Library for hook-related utility functions
 * @dev Provides helper functions for working with SrcHook and DstHook structs
 */
library HookUtils {
    /**
     * @notice Validates a hook address is non-zero and whitelisted
     * @param hookAddress The hook address to validate
     * @param isAllowedHook Function to check hook whitelist
     */
    function _validateHook(
        address hookAddress,
        function(address) external view returns (bool) isAllowedHook
    ) private view {
        if (hookAddress == address(0)) revert MissingHook();
        if (!isAllowedHook(hookAddress)) revert InvalidHookAddress();
    }

    /**
     * @notice Validates SrcHook struct fields
     * @param hook The SrcHook to validate
     * @param isAllowedHook Function to check hook whitelist
     */
    function validateSrcHook(
        SrcHook calldata hook,
        function(address) external view returns (bool) isAllowedHook
    ) internal view {
        _validateHook(hook.hookAddress, isAllowedHook);
    }

    /**
     * @notice Validates DstHook struct fields
     * @param hook The DstHook to validate
     * @param isAllowedHook Function to check hook whitelist
     */
    function validateDstHook(
        DstHook calldata hook,
        function(address) external view returns (bool) isAllowedHook
    ) internal view {
        _validateHook(hook.hookAddress, isAllowedHook);
    }
}
