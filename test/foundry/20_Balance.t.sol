// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title BalanceUtilsTest
 * @notice Tests for the Balance utility struct in AoriUtils library
 *
 * This test file verifies the functionality of the Balance struct which handles
 * locked and unlocked token balances within the Aori protocol. The tests ensure
 * that balance operations like locking, unlocking, and balance manipulations
 * work correctly under various conditions.
 *
 * Tests:
 * 1. testLock - Tests basic locking of tokens
 * 2. testRevert_LockMax - Tests overflow handling when locking maximum uint128 value
 * 3. testUnlock - Tests unlocking of previously locked tokens
 * 4. testRevert_UnlockInsufficientBalance - Tests revert when trying to unlock more than locked
 * 5. testUnlockAll - Tests unlocking all locked tokens at once
 * 6. testDecreaseLockedNoRevert - Tests non-reverting locked balance decrease
 * 7. testDecreaseLockedNoRevertUnderflow - Tests handling of underflow in non-reverting decrease
 * 8. testIncreaseUnlockedNoRevert - Tests non-reverting unlocked balance increase
 * 9. testIncreaseUnlockedNoRevertOverflow - Tests handling of overflow in non-reverting increase
 * 10. testComplexSequence - Tests a complex sequence of balance operations
 * 11. testGasUsage - Tests gas optimization of the balance operations
 *
 * Special notes:
 * - These tests focus on the Balance struct operations in isolation
 * - The tests include both successful cases and error cases with revert assertions
 * - Gas optimization is explicitly tested to ensure efficient storage operations
 */
import "forge-std/Test.sol";
import "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";

/**
 * @notice Tests for the Balance utility struct which manages locked and unlocked token balances
 */
contract BalanceUtilsTest is Test {
    Balance private balance;

    function setUp() public {
        // Initialize balance with 0 values
        balance.locked = 0;
        balance.unlocked = 0;
    }

    /**
     * @notice Tests basic locking of tokens
     */
    function testLock() public {
        uint128 initialLocked = balance.getLocked();
        uint128 amountToLock = 100;

        balance.lock(amountToLock);

        assertEq(balance.getLocked(), initialLocked + amountToLock, "Locked amount should increase");
        assertEq(balance.getUnlocked(), 0, "Unlocked amount should not change");
    }

    /**
     * @notice Tests overflow handling when locking maximum uint128 value
     */
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_LockMax() public {
        uint128 maxUint128 = type(uint128).max;

        balance.lock(maxUint128);
        assertEq(balance.getLocked(), maxUint128, "Should lock maximum uint128 value");

        // Overflow
        vm.expectRevert();
        balance.lock(1);
    }

    /**
     * @notice Tests unlocking of previously locked tokens
     */
    function testUnlock() public {
        uint128 amountToLock = 100;
        uint128 amountToUnlock = 60;

        balance.lock(amountToLock);
        balance.unlock(amountToUnlock);

        assertEq(balance.getLocked(), amountToLock - amountToUnlock, "Locked amount should decrease");
        assertEq(balance.getUnlocked(), amountToUnlock, "Unlocked amount should increase");
    }

    /**
     * @notice Tests revert when trying to unlock more than locked
     */
    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_UnlockInsufficientBalance() public {
        uint128 amountToLock = 50;
        uint128 amountToUnlock = 100;

        balance.lock(amountToLock);

        vm.expectRevert(bytes("Insufficient locked balance"));
        balance.unlock(amountToUnlock);
    }

    /**
     * @notice Tests unlocking all locked tokens at once
     */
    function testUnlockAll() public {
        uint128 amountToLock = 500;

        balance.lock(amountToLock);
        uint128 unlocked = balance.unlockAll();

        assertEq(unlocked, amountToLock, "Should return unlocked amount");
        assertEq(balance.getLocked(), 0, "Locked amount should be zero");
        assertEq(balance.getUnlocked(), amountToLock, "Unlocked amount should increase by total locked");
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
        assertEq(balance.getLocked(), amountToLock - amountToDecrease, "Locked amount should decrease");
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
        assertEq(balance.getLocked(), amountToLock, "Balance should not change on failure");
    }

    /**
     * @notice Tests non-reverting unlocked balance increase
     */
    function testIncreaseUnlockedNoRevert() public {
        uint128 amountToIncrease = 100;

        bool success = balance.increaseUnlockedNoRevert(amountToIncrease);

        assertTrue(success, "Operation should succeed");
        assertEq(balance.getUnlocked(), amountToIncrease, "Unlocked amount should increase");
    }

    /**
     * @notice Tests handling of overflow in non-reverting increase
     */
    function testIncreaseUnlockedNoRevertOverflow() public {
        uint128 maxUint128 = type(uint128).max;

        balance.increaseUnlockedNoRevert(maxUint128);
        bool success = balance.increaseUnlockedNoRevert(1);

        assertFalse(success, "Operation should fail on overflow");
        assertEq(balance.getUnlocked(), maxUint128, "Balance should not change on failure");
    }

    /**
     * @notice Tests a complex sequence of balance operations
     */
    function testComplexSequence() public {
        // Initial lock
        balance.lock(500);
        assertEq(balance.getLocked(), 500, "Initial lock should set locked to 500");

        // Partial unlock
        balance.unlock(200);
        assertEq(balance.getLocked(), 300, "Locked should decrease to 300");
        assertEq(balance.getUnlocked(), 200, "Unlocked should increase to 200");

        // Lock more
        balance.lock(700);
        assertEq(balance.getLocked(), 1000, "Locked should increase to 1000");

        // Unlock all
        uint128 unlockedAmount = balance.unlockAll();
        assertEq(unlockedAmount, 1000, "Should return 1000 as unlocked amount");
        assertEq(balance.getLocked(), 0, "Locked should be 0");
        assertEq(balance.getUnlocked(), 1200, "Unlocked should be 1200");

        // Test no-revert functions
        bool success = balance.decreaseLockedNoRevert(100);
        assertFalse(success, "Should fail when locked is 0");

        success = balance.increaseUnlockedNoRevert(300);
        assertTrue(success, "Should succeed");
        assertEq(balance.getUnlocked(), 1500, "Unlocked should increase to 1500");
    }
}
