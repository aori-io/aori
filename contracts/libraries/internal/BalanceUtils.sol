// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Balance } from "../../types/AoriTypes.sol";
import "../../types/AoriErrors.sol";

/**
 * @notice Utility library for managing token balances
 * @dev Provides functions for locking, unlocking, and managing token balances
 * with optimized storage operations
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
     * @notice Unlocks a specified amount of tokens from locked to unlocked state
     * @dev Decreases locked balance and increases unlocked balance
     * @param balance The Balance struct reference
     * @param amount The amount to unlock
     */
    function unlock(
        Balance storage balance,
        uint128 amount
    ) internal {
        (uint128 locked, uint128 unlocked) = loadBalance(balance);
        if (locked < amount) revert LockedBalanceDecreaseFailed(amount, locked);
        unchecked {
            locked -= amount;
        }
        unlocked += amount;

        storeBalance(balance, locked, unlocked);
    }

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
     * @notice Unlocks all locked tokens into the unlocked balance
     * @dev Moves the entire locked balance to unlocked
     * @param balance The Balance struct reference
     * @return amount The amount that was unlocked
     */
    /* forgefmt: disable-next-item */
    function unlockAll(Balance storage balance) internal returns (uint128 amount) {
        (uint128 locked, uint128 unlocked) = loadBalance(balance);
        amount = locked;
        unlocked += amount;
        locked = 0;

        storeBalance(balance, locked, unlocked);
    }

    /**
     * @notice Gets the unlocked balance amount
     * @param balance The Balance struct reference
     * @return The unlocked balance amount
     */
    /* forgefmt: disable-next-item */
    function getUnlocked(Balance storage balance) internal view returns (uint128) { return balance.unlocked; }

    /**
     * @notice Gets the locked balance amount
     * @param balance The Balance struct reference
     * @return The locked balance amount
     */
    /* forgefmt: disable-next-item */
    function getLocked(Balance storage balance) internal view returns (uint128) { return balance.locked; }

    /**
     * @notice Load balance values using optimized storage operations
     * @dev Uses assembly to read both values in a single storage read
     * @param balance The Balance struct reference
     * @return locked The locked balance
     * @return unlocked The unlocked balance
     */
    /* forgefmt: disable-next-item */
    function loadBalance(Balance storage balance) internal view returns (uint128 locked, uint128 unlocked) {
        assembly {
            let fullSlot := sload(balance.slot)
            unlocked := shr(128, fullSlot)
            locked := fullSlot
        }
    }

    /**
     * @notice Store balance values using optimized storage operations
     * @dev Uses assembly to write both values in a single storage write
     * @param balance The Balance struct reference
     * @param locked The locked balance to store
     * @param unlocked The unlocked balance to store
     */
    function storeBalance(
        Balance storage balance,
        uint128 locked,
        uint128 unlocked
    ) internal {
        assembly {
            sstore(balance.slot, or(shl(128, unlocked), locked))
        }
    }

    /**
     * @notice Validates a decrease in locked balance with a corresponding increase in unlocked balance
     * @dev Verifies that the token accounting was performed correctly during transfer operations
     * @param _balance The Balance struct reference (not used, but needed for extension method pattern)
     * @param initialOffererLocked The offerer's initial locked balance
     * @param finalOffererLocked The offerer's final locked balance
     * @param initialSolverUnlocked The solver's initial unlocked balance
     * @param finalSolverUnlocked The solver's final unlocked balance
     * @param transferAmount The amount that should have been transferred
     * @return success Whether the validation was successful
     */
    function validateBalanceTransfer(
        Balance storage _balance,
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) internal pure returns (bool success) {
        // Verify offerer's locked balance decreased by exactly the transfer amount
        if (initialOffererLocked != finalOffererLocked + transferAmount) {
            return false;
        }

        // Verify solver's unlocked balance increased by exactly the transfer amount
        if (finalSolverUnlocked != initialSolverUnlocked + transferAmount) {
            return false;
        }

        return true;
    }

    /**
     * @notice Validates a decrease in locked balance with a corresponding increase in unlocked balance with revert
     * @dev Same as validateBalanceTransfer but reverts with custom error messages if validation fails
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
