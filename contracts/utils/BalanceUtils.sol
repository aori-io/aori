// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Balance } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";

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
    function decreaseLockedNoRevert(Balance storage balance, uint128 amount) internal returns (bool success) {
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
    function increaseUnlockedNoRevert(Balance storage balance, uint128 amount) internal returns (bool success) {
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
     * @notice Adds to a uint256 mapping accumulator without reverting on overflow
     * @dev Used for pendingProtocolFees in batch settlement soft-fail paths
     * @param map The mapping to update
     * @param key The mapping key
     * @param amount The amount to add
     * @return success Whether the operation was successful (false on overflow)
     */
    function addNoRevert(mapping(address => uint256) storage map, address key, uint256 amount) internal returns (bool success) {
        uint256 current = map[key];
        unchecked {
            uint256 newAmount = current + amount;
            if (newAmount < current) return false;
            map[key] = newAmount;
        }
        return true;
    }
}
