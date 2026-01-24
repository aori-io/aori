// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Balance } from "../../types/AoriTypes.sol";
import "../../types/AoriErrors.sol";

/**
 * @notice Utility library for managing token balances
 * @dev Provides functions for locking, unlocking, and managing token balances
 */
library BalanceUtils {
    /**
     * @notice Locks a specified amount of tokens
     * @dev Increases the locked balance by the specified amount
     * @param balance The Balance struct reference
     * @param amount The amount to lock
     */
    /* forgefmt: disable-next-item */
    function lock(Balance storage balance, uint128 amount) internal { balance.locked += amount; }

    /**
     * @notice Decreases locked balance without reverting on underflow
     * @dev Safe version that returns false instead of reverting on underflow
     * @param balance The Balance struct reference
     * @param amount The amount to decrease
     * @return success Whether the operation was successful
     */
    function decreaseLockedNoRevert(
        Balance storage balance,
        uint128 amount
    ) internal returns (bool success) {
        uint128 locked = balance.locked;
        unchecked {
            uint128 newLocked = locked - amount;
            if (newLocked > locked) {
                return false; // Underflow
            }
            balance.locked = newLocked;
        }
        return true;
    }

    /**
     * @notice Increases unlocked balance without reverting on overflow
     * @dev Safe version that returns false instead of reverting on overflow
     * @param balance The Balance struct reference
     * @param amount The amount to increase
     * @return success Whether the operation was successful
     */
    function increaseUnlockedNoRevert(
        Balance storage balance,
        uint128 amount
    ) internal returns (bool success) {
        uint128 unlocked = balance.unlocked;
        unchecked {
            uint128 newUnlocked = unlocked + amount;
            if (newUnlocked < unlocked) {
                return false; // Overflow
            }
            balance.unlocked = newUnlocked;
        }
        return true;
    }

    /**
     * @notice Validates a decrease in locked balance with a corresponding increase in unlocked balance with revert
     * @dev Verifies that the token accounting was performed correctly during transfer operations
     * @param _balance The Balance struct reference (not used, but needed for extension method pattern)
     * @param initialOffererLocked The offerer's initial locked balance
     * @param finalOffererLocked The offerer's final locked balance
     * @param initialSolverUnlocked The solver's initial unlocked balance
     * @param finalSolverUnlocked The solver's final unlocked balance
     * @param transferAmount The amount that should have been transferred
     */
    function validateBalanceTransferOrRevert(
        Balance storage _balance,
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) internal pure {
        // Verify offerer's locked balance decreased by exactly the transfer amount
        uint128 expectedOffererLocked = finalOffererLocked + transferAmount;
        if (initialOffererLocked != expectedOffererLocked) {
            revert BalanceInconsistency(initialOffererLocked, expectedOffererLocked);
        }

        // Verify solver's unlocked balance increased by exactly the transfer amount
        uint128 expectedSolverUnlocked = initialSolverUnlocked + transferAmount;
        if (finalSolverUnlocked != expectedSolverUnlocked) {
            revert BalanceInconsistency(expectedSolverUnlocked, finalSolverUnlocked);
        }
    }
}
