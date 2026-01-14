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
     * @notice Validates SrcHook struct fields
     * @param hook The SrcHook to validate
     * @param isAllowedHook Function to check hook whitelist
     * @param isAllowedSolver Function to check solver whitelist
     */
    function validateSrcHook(
        SrcHook calldata hook,
        function(address) external view returns (bool) isAllowedHook,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        if (hook.hookAddress == address(0)) revert MissingHook();
        if (!isAllowedHook(hook.hookAddress)) revert InvalidHookAddress();
        if (hook.solver == address(0)) revert SolverRequiredInHook();
        if (!isAllowedSolver(hook.solver)) revert InvalidSolverInHook();
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
        if (hook.hookAddress == address(0)) revert MissingHook();
        if (!isAllowedHook(hook.hookAddress)) revert InvalidHookAddress();
    }
}
