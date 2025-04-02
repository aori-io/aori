// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import "@aori/lib/AoriUtils.sol";

contract BalanceUtilsTest is Test {
    Balance private balance;

    function setUp() public {
        // Initialize balance with 0 values
        balance.locked = 0;
        balance.unlocked = 0;
    }

    function testLock() public {
        uint128 initialLocked = balance.getLocked();
        uint128 amountToLock = 100;

        balance.lock(amountToLock);

        assertEq(balance.getLocked(), initialLocked + amountToLock);
        assertEq(balance.getUnlocked(), 0, "Unlocked amount should not change");
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_LockMax() public {
        uint128 maxUint128 = type(uint128).max;

        balance.lock(maxUint128);
        assertEq(balance.getLocked(), maxUint128);

        // Overflow
        vm.expectRevert();
        balance.lock(1);
    }

    // Test the unlock function
    function testUnlock() public {
        uint128 amountToLock = 100;
        uint128 amountToUnlock = 60;

        balance.lock(amountToLock);
        balance.unlock(amountToUnlock);

        assertEq(balance.getLocked(), amountToLock - amountToUnlock);
        assertEq(balance.getUnlocked(), amountToUnlock);
    }

    /// forge-config: default.allow_internal_expect_revert = true
    function testRevert_UnlockInsufficientBalance() public {
        uint128 amountToLock = 50;
        uint128 amountToUnlock = 100;

        balance.lock(amountToLock);

        vm.expectRevert(bytes("Insufficient locked balance"));
        balance.unlock(amountToUnlock);
    }

    function testUnlockAll() public {
        uint128 amountToLock = 500;

        balance.lock(amountToLock);
        uint128 unlocked = balance.unlockAll();

        assertEq(unlocked, amountToLock);
        assertEq(balance.getLocked(), 0, "Wrong locked amount");
        assertEq(balance.getUnlocked(), amountToLock, "Wrong unlocked amount");
    }

    function testDecreaseLockedNoRevert() public {
        uint128 amountToLock = 100;
        uint128 amountToDecrease = 60;

        balance.lock(amountToLock);
        bool success = balance.decreaseLockedNoRevert(amountToDecrease);

        assertTrue(success);
        assertEq(balance.getLocked(), amountToLock - amountToDecrease);
    }

    function testDecreaseLockedNoRevertUnderflow() public {
        uint128 amountToLock = 50;
        uint128 amountToDecrease = 100;

        balance.lock(amountToLock);
        bool success = balance.decreaseLockedNoRevert(amountToDecrease);

        assertFalse(success);
        assertEq(balance.getLocked(), amountToLock, "Balance should not change on failure");
    }

    function testIncreaseUnlockedNoRevert() public {
        uint128 amountToIncrease = 100;

        bool success = balance.increaseUnlockedNoRevert(amountToIncrease);

        assertTrue(success);
        assertEq(balance.getUnlocked(), amountToIncrease);
    }

    function testIncreaseUnlockedNoRevertOverflow() public {
        uint128 maxUint128 = type(uint128).max;

        balance.increaseUnlockedNoRevert(maxUint128);
        bool success = balance.increaseUnlockedNoRevert(1);

        assertFalse(success);
        assertEq(balance.getUnlocked(), maxUint128, "Balance should not change on failure");
    }

    function testComplexSequence() public {
        // Initial lock
        balance.lock(500);
        assertEq(balance.getLocked(), 500);

        // Partial unlock
        balance.unlock(200);
        assertEq(balance.getLocked(), 300);
        assertEq(balance.getUnlocked(), 200);

        // Lock more
        balance.lock(700);
        assertEq(balance.getLocked(), 1000);

        // Unlock all
        uint128 unlockedAmount = balance.unlockAll();
        assertEq(unlockedAmount, 1000);
        assertEq(balance.getLocked(), 0);
        assertEq(balance.getUnlocked(), 1200);

        // Test no-revert functions
        bool success = balance.decreaseLockedNoRevert(100);
        assertFalse(success);

        success = balance.increaseUnlockedNoRevert(300);
        assertTrue(success);
        assertEq(balance.getUnlocked(), 1500);
    }

    function testGasUsage() public {
        uint256 gasBefore;
        uint256 gasAfter;

        // Measure gas for regular assignments
        Balance storage regularBalance = balance;
        gasBefore = gasleft();
        regularBalance.locked = 100;
        regularBalance.unlocked = 200;
        gasAfter = gasleft();
        uint256 regularGas = gasBefore - gasAfter;

        // Reset
        balance.storeBalance(0, 0);

        // Measure gas for optimized storage
        gasBefore = gasleft();
        balance.storeBalance(100, 200);
        gasAfter = gasleft();
        uint256 optimizedGas = gasBefore - gasAfter;

        console.log("Regular storage gas:", regularGas);
        console.log("Optimized storage gas:", optimizedGas);

        assertTrue(optimizedGas <= regularGas, "Optimized storage should use less gas");
    }
}
