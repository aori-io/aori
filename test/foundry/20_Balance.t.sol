// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title BalanceUtilsTest
 * @notice Tests for the Balance utility struct in BalanceUtils library
 */
import "forge-std/Test.sol";
import { BalanceUtils } from "../../contracts/utils/BalanceUtils.sol";
import "../../contracts/types/AoriErrors.sol";
import { Balance } from "../../contracts/types/AoriTypes.sol";

contract BalanceUtilsTest is Test {
    using BalanceUtils for Balance;

    Balance private balance;

    function setUp() public {
        balance.locked = 0;
        balance.unlocked = 0;
    }

    /**
     * @notice Tests basic locking of tokens
     */
    function testLock() public {
        uint128 initialLocked = balance.locked;
        uint128 amountToLock = 100;

        balance.lock(amountToLock);

        assertEq(balance.locked, initialLocked + amountToLock, "Locked amount should increase");
        assertEq(balance.unlocked, 0, "Unlocked amount should not change");
    }

    /**
     * @notice Tests overflow handling when locking maximum uint128 value
     */
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_LockMax() public {
        uint128 maxUint128 = type(uint128).max;

        balance.lock(maxUint128);
        assertEq(balance.locked, maxUint128, "Should lock maximum uint128 value");

        // Overflow
        vm.expectRevert();
        balance.lock(1);
    }

    /**
     * @notice Tests non-reverting locked balance decrease
     */
    function testDecreaseLockedNoRevert() public {
        uint128 amountToLock = 100;
        uint128 amountToDecrease = 60;

        balance.lock(amountToLock);
        bool success = balance.decreaseLockedNoRevert(amountToDecrease);

        assertTrue(success, "Operation should succeed");
        assertEq(balance.locked, amountToLock - amountToDecrease, "Locked amount should decrease");
    }

    /**
     * @notice Tests handling of underflow in non-reverting decrease
     */
    function testDecreaseLockedNoRevertUnderflow() public {
        uint128 amountToLock = 50;
        uint128 amountToDecrease = 100;

        balance.lock(amountToLock);
        bool success = balance.decreaseLockedNoRevert(amountToDecrease);

        assertFalse(success, "Operation should fail on underflow");
        assertEq(balance.locked, amountToLock, "Balance should not change on failure");
    }

    /**
     * @notice Tests non-reverting unlocked balance increase
     */
    function testIncreaseUnlockedNoRevert() public {
        uint128 amountToIncrease = 100;

        bool success = balance.increaseUnlockedNoRevert(amountToIncrease);

        assertTrue(success, "Operation should succeed");
        assertEq(balance.unlocked, amountToIncrease, "Unlocked amount should increase");
    }

    /**
     * @notice Tests handling of overflow in non-reverting increase
     */
    function testIncreaseUnlockedNoRevertOverflow() public {
        uint128 maxUint128 = type(uint128).max;

        balance.increaseUnlockedNoRevert(maxUint128);
        bool success = balance.increaseUnlockedNoRevert(1);

        assertFalse(success, "Operation should fail on overflow");
        assertEq(balance.unlocked, maxUint128, "Balance should not change on failure");
    }

    /**
     * @notice Tests a sequence of balance operations
     */
    function testBalanceOperations() public {
        // Lock tokens
        balance.lock(500);
        assertEq(balance.locked, 500, "Initial lock should set locked to 500");

        // Decrease locked
        bool success = balance.decreaseLockedNoRevert(200);
        assertTrue(success, "Decrease should succeed");
        assertEq(balance.locked, 300, "Locked should decrease to 300");

        // Increase unlocked
        success = balance.increaseUnlockedNoRevert(200);
        assertTrue(success, "Increase should succeed");
        assertEq(balance.unlocked, 200, "Unlocked should increase to 200");

        // Lock more
        balance.lock(700);
        assertEq(balance.locked, 1000, "Locked should increase to 1000");

        // Test no-revert functions
        success = balance.decreaseLockedNoRevert(1000);
        assertTrue(success, "Should succeed");
        assertEq(balance.locked, 0, "Locked should be 0");

        success = balance.increaseUnlockedNoRevert(300);
        assertTrue(success, "Should succeed");
        assertEq(balance.unlocked, 500, "Unlocked should increase to 500");

        // Test underflow protection (balance.locked is now 0)
        success = balance.decreaseLockedNoRevert(2000);
        assertFalse(success, "Should fail when trying to decrease more than locked");
        assertEq(balance.locked, 0, "Locked should remain unchanged");
    }
}
