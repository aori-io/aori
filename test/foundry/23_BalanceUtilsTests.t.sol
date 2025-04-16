// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "./TestUtils.sol";
import "../../contracts/AoriUtils.sol";

// Test contract to expose internal functions from BalanceUtils library
contract BalanceWrapper {
    using BalanceUtils for Balance;
    
    Balance public balance;
    
    // Direct functions that map to BalanceUtils functions
    function lock(uint128 amount) external {
        balance.lock(amount);
    }
    
    function unlock(uint128 amount) external {
        balance.unlock(amount);
    }
    
    function decreaseLockedNoRevert(uint128 amount) external returns (bool) {
        return balance.decreaseLockedNoRevert(amount);
    }
    
    function increaseUnlockedNoRevert(uint128 amount) external returns (bool) {
        return balance.increaseUnlockedNoRevert(amount);
    }
    
    function unlockAll() external returns (uint128) {
        return balance.unlockAll();
    }
    
    function getUnlocked() external view returns (uint128) {
        return balance.getUnlocked();
    }
    
    function getLocked() external view returns (uint128) {
        return balance.getLocked();
    }
    
    // Expose assembly functions for testing
    function loadBalance() external view returns (uint128 locked, uint128 unlocked) {
        return balance.loadBalance();
    }
    
    function storeBalance(uint128 locked, uint128 unlocked) external {
        balance.storeBalance(locked, unlocked);
    }
    
    // Helper functions to test specific scenarios
    function setRawBalance(uint128 locked, uint128 unlocked) external {
        balance.locked = locked;
        balance.unlocked = unlocked;
    }
    
    // Direct slot access for assembly verification
    function getRawSlotValue() external view returns (bytes32) {
        bytes32 result;
        assembly {
            result := sload(balance.slot)
        }
        return result;
    }
    
    // Add functions to test balance validation
    function validateBalanceTransfer(
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) external view returns (bool) {
        return balance.validateBalanceTransfer(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
    }
    
    function validateBalanceTransferOrRevert(
        uint128 initialOffererLocked,
        uint128 finalOffererLocked,
        uint128 initialSolverUnlocked,
        uint128 finalSolverUnlocked,
        uint128 transferAmount
    ) external view {
        balance.validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
    }
}

/**
 * @title BalanceUtilsTest
 * @notice Test suite for the BalanceUtils library in AoriUtils.sol
 * @dev Focuses on testing all Balance struct operations including assembly functions
 */
contract BalanceUtilsTest is Test {
    // Test state
    BalanceWrapper public wrapper;
    
    // Constants for edge cases
    uint128 constant MAX_UINT128 = type(uint128).max;
    
    function setUp() public {
        wrapper = new BalanceWrapper();
    }
    
    /**********************************/
    /*      Basic Function Tests      */
    /**********************************/
    
    /// @dev Tests the lock function with a normal amount
    /// @notice Covers lines 34-35 in AoriUtils.sol
    function test_lock_normalAmount() public {
        // Arrange
        uint128 amount = 100;
        
        // Act
        wrapper.lock(amount);
        
        // Assert
        assertEq(wrapper.getLocked(), amount);
    }
    
    /// @dev Tests the lock function with a zero amount
    /// @notice Covers lines 34-35 in AoriUtils.sol
    function test_lock_zeroAmount() public {
        // Arrange
        uint128 amount = 0;
        
        // Act
        wrapper.lock(amount);
        
        // Assert
        assertEq(wrapper.getLocked(), 0);
    }
    
    /// @dev Tests the lock function with the maximum uint128 value
    /// @notice Covers lines 34-35 in AoriUtils.sol
    function test_lock_maxAmount() public {
        // Arrange
        uint128 amount = MAX_UINT128;
        
        // Act
        wrapper.lock(amount);
        
        // Assert
        assertEq(wrapper.getLocked(), MAX_UINT128);
    }
    
    /// @dev Tests that lock function correctly increases existing locked balance
    /// @notice Covers lines 34-35 in AoriUtils.sol
    function test_lock_increasesExistingBalance() public {
        // Arrange
        wrapper.setRawBalance(100, 200);
        uint128 additionalAmount = 50;
        
        // Act
        wrapper.lock(additionalAmount);
        
        // Assert
        assertEq(wrapper.getLocked(), 150);
        assertEq(wrapper.getUnlocked(), 200); // Unlocked should remain unchanged
    }
    
    /// @dev Tests that lock function correctly handles overflow
    /// @notice Covers lines 34-35 in AoriUtils.sol
    function test_lock_overflow() public {
        // Arrange
        wrapper.setRawBalance(MAX_UINT128, 200);
        uint128 additionalAmount = 1;
        
        // Act & Assert
        vm.expectRevert(); // Should overflow and revert
        wrapper.lock(additionalAmount);
    }
    
    /// @dev Tests the unlock function with a normal amount
    /// @notice Covers lines 44-52 in AoriUtils.sol
    function test_unlock_normalAmount() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 unlockAmount = 30;
        
        // Act
        wrapper.unlock(unlockAmount);
        
        // Assert
        assertEq(wrapper.getLocked(), 70);
        assertEq(wrapper.getUnlocked(), 80);
    }
    
    /// @dev Tests the unlock function with the entire locked amount
    /// @notice Covers lines 44-52 in AoriUtils.sol
    function test_unlock_entireAmount() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 unlockAmount = 100;
        
        // Act
        wrapper.unlock(unlockAmount);
        
        // Assert
        assertEq(wrapper.getLocked(), 0);
        assertEq(wrapper.getUnlocked(), 150);
    }
    
    /// @dev Tests that unlock function reverts when trying to unlock more than locked
    /// @notice Covers lines 44-52 in AoriUtils.sol, specifically the require statement
    function test_unlock_insufficientLocked() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 unlockAmount = 101;
        
        // Act & Assert
        vm.expectRevert("Insufficient locked balance");
        wrapper.unlock(unlockAmount);
    }
    
    /// @dev Tests the decreaseLockedNoRevert function with normal amount
    /// @notice Covers lines 62-74 in AoriUtils.sol
    function test_decreaseLockedNoRevert_normalAmount() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 decreaseAmount = 30;
        
        // Act
        bool success = wrapper.decreaseLockedNoRevert(decreaseAmount);
        
        // Assert
        assertTrue(success);
        assertEq(wrapper.getLocked(), 70);
        assertEq(wrapper.getUnlocked(), 50); // Unlocked should remain unchanged
    }
    
    /// @dev Tests the decreaseLockedNoRevert function with underflow
    /// @notice Covers lines 62-74 in AoriUtils.sol, specifically the underflow branch
    function test_decreaseLockedNoRevert_underflow() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 decreaseAmount = 101;
        
        // Act
        bool success = wrapper.decreaseLockedNoRevert(decreaseAmount);
        
        // Assert
        assertFalse(success);
        assertEq(wrapper.getLocked(), 100); // Should remain unchanged
        assertEq(wrapper.getUnlocked(), 50); // Should remain unchanged
    }
    
    /// @dev Tests the increaseUnlockedNoRevert function with normal amount
    /// @notice Covers lines 84-96 in AoriUtils.sol
    function test_increaseUnlockedNoRevert_normalAmount() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        uint128 increaseAmount = 30;
        
        // Act
        bool success = wrapper.increaseUnlockedNoRevert(increaseAmount);
        
        // Assert
        assertTrue(success);
        assertEq(wrapper.getLocked(), 100); // Locked should remain unchanged
        assertEq(wrapper.getUnlocked(), 80);
    }
    
    /// @dev Tests the increaseUnlockedNoRevert function with overflow
    /// @notice Covers lines 84-96 in AoriUtils.sol, specifically the overflow branch
    function test_increaseUnlockedNoRevert_overflow() public {
        // Arrange
        wrapper.setRawBalance(100, MAX_UINT128);
        uint128 increaseAmount = 1;
        
        // Act
        bool success = wrapper.increaseUnlockedNoRevert(increaseAmount);
        
        // Assert
        assertFalse(success);
        assertEq(wrapper.getLocked(), 100); // Should remain unchanged
        assertEq(wrapper.getUnlocked(), MAX_UINT128); // Should remain unchanged
    }
    
    /// @dev Tests the unlockAll function
    /// @notice Covers lines 105-111 in AoriUtils.sol
    function test_unlockAll() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        
        // Act
        uint128 unlockedAmount = wrapper.unlockAll();
        
        // Assert
        assertEq(unlockedAmount, 100);
        assertEq(wrapper.getLocked(), 0);
        assertEq(wrapper.getUnlocked(), 150);
    }
    
    /// @dev Tests the unlockAll function with zero locked amount
    /// @notice Covers lines 105-111 in AoriUtils.sol
    function test_unlockAll_zeroLocked() public {
        // Arrange
        wrapper.setRawBalance(0, 50);
        
        // Act
        uint128 unlockedAmount = wrapper.unlockAll();
        
        // Assert
        assertEq(unlockedAmount, 0);
        assertEq(wrapper.getLocked(), 0);
        assertEq(wrapper.getUnlocked(), 50);
    }
    
    /// @dev Tests the getUnlocked function
    /// @notice Covers lines 119-120 in AoriUtils.sol
    function test_getUnlocked() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        
        // Act
        uint128 unlocked = wrapper.getUnlocked();
        
        // Assert
        assertEq(unlocked, 50);
    }
    
    /// @dev Tests the getLocked function
    /// @notice Covers lines 128-129 in AoriUtils.sol
    function test_getLocked() public {
        // Arrange
        wrapper.setRawBalance(100, 50);
        
        // Act
        uint128 locked = wrapper.getLocked();
        
        // Assert
        assertEq(locked, 100);
    }
    
    /**********************************/
    /*      Assembly Function Tests   */
    /**********************************/
    
    /// @dev Tests the loadBalance assembly function
    /// @notice Covers lines 139-145 in AoriUtils.sol
    function test_loadBalance() public {
        // Arrange
        wrapper.setRawBalance(123, 456);
        
        // Act
        (uint128 locked, uint128 unlocked) = wrapper.loadBalance();
        
        // Assert
        assertEq(locked, 123);
        assertEq(unlocked, 456);
    }
    
    /// @dev Tests the loadBalance assembly function with max values
    /// @notice Covers lines 139-145 in AoriUtils.sol
    function test_loadBalance_maxValues() public {
        // Arrange
        wrapper.setRawBalance(MAX_UINT128, MAX_UINT128);
        
        // Act
        (uint128 locked, uint128 unlocked) = wrapper.loadBalance();
        
        // Assert
        assertEq(locked, MAX_UINT128);
        assertEq(unlocked, MAX_UINT128);
    }
    
    /// @dev Tests the storeBalance assembly function
    /// @notice Covers lines 156-158 in AoriUtils.sol
    function test_storeBalance() public {
        // Arrange
        uint128 newLocked = 789;
        uint128 newUnlocked = 1011;
        
        // Act
        wrapper.storeBalance(newLocked, newUnlocked);
        
        // Assert
        assertEq(wrapper.getLocked(), 789);
        assertEq(wrapper.getUnlocked(), 1011);
    }
    
    /// @dev Tests the storeBalance assembly function with max values
    /// @notice Covers lines 156-158 in AoriUtils.sol
    function test_storeBalance_maxValues() public {
        // Arrange
        uint128 newLocked = MAX_UINT128;
        uint128 newUnlocked = MAX_UINT128;
        
        // Act
        wrapper.storeBalance(newLocked, newUnlocked);
        
        // Assert
        assertEq(wrapper.getLocked(), MAX_UINT128);
        assertEq(wrapper.getUnlocked(), MAX_UINT128);
    }
    
    /// @dev Tests the raw slot packing in storeBalance assembly function
    /// @notice Covers lines 156-158 in AoriUtils.sol, verifying the exact storage layout
    function test_storeBalance_slotPacking() public {
        // Arrange
        uint128 newLocked = 0x1234;
        uint128 newUnlocked = 0x5678;
        
        // Act
        wrapper.storeBalance(newLocked, newUnlocked);
        
        // Assert - verify the exact storage layout
        bytes32 rawSlot = wrapper.getRawSlotValue();
        bytes32 expected = bytes32(uint256(uint256(0x5678) << 128 | uint256(0x1234)));
        assertEq(rawSlot, expected);
    }
    
    /**********************************/
    /*    Balance Validation Tests    */
    /**********************************/
    
    /// @dev Tests validateBalanceTransfer with correct values
    function test_validateBalanceTransfer_valid() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 70;
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 80;
        uint128 transferAmount = 30;
        
        // Act
        bool success = wrapper.validateBalanceTransfer(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
        
        // Assert
        assertTrue(success);
    }
    
    /// @dev Tests validateBalanceTransfer with incorrect offerer locked change
    function test_validateBalanceTransfer_invalidOffererChange() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 60; // Should be 70 for a 30 token transfer
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 80;
        uint128 transferAmount = 30;
        
        // Act
        bool success = wrapper.validateBalanceTransfer(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
        
        // Assert
        assertFalse(success);
    }
    
    /// @dev Tests validateBalanceTransfer with incorrect solver unlocked change
    function test_validateBalanceTransfer_invalidSolverChange() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 70;
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 85; // Should be 80 for a 30 token transfer
        uint128 transferAmount = 30;
        
        // Act
        bool success = wrapper.validateBalanceTransfer(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
        
        // Assert
        assertFalse(success);
    }
    
    /// @dev Tests validateBalanceTransferOrRevert with correct values
    function test_validateBalanceTransferOrRevert_valid() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 70;
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 80;
        uint128 transferAmount = 30;
        
        // Act & Assert - should not revert
        wrapper.validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
    }
    
    /// @dev Tests validateBalanceTransferOrRevert with incorrect offerer locked change
    function test_validateBalanceTransferOrRevert_invalidOffererChange() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 60; // Should be 70 for a 30 token transfer
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 80;
        uint128 transferAmount = 30;
        
        // Act & Assert - should revert with expected message
        vm.expectRevert("Inconsistent offerer balance");
        wrapper.validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
    }
    
    /// @dev Tests validateBalanceTransferOrRevert with incorrect solver unlocked change
    function test_validateBalanceTransferOrRevert_invalidSolverChange() public {
        // Arrange
        uint128 initialOffererLocked = 100;
        uint128 finalOffererLocked = 70;
        uint128 initialSolverUnlocked = 50;
        uint128 finalSolverUnlocked = 85; // Should be 80 for a 30 token transfer
        uint128 transferAmount = 30;
        
        // Act & Assert - should revert with expected message
        vm.expectRevert("Inconsistent solver balance");
        wrapper.validateBalanceTransferOrRevert(
            initialOffererLocked,
            finalOffererLocked,
            initialSolverUnlocked,
            finalSolverUnlocked,
            transferAmount
        );
    }
    
    /// @dev Tests validateBalanceTransferOrRevert with edge case values
    function test_validateBalanceTransferOrRevert_edgeCases() public {
        // Test with zero transfer amount
        wrapper.validateBalanceTransferOrRevert(
            100,
            100,
            50,
            50,
            0
        );
        
        // Test with maximum values
        wrapper.validateBalanceTransferOrRevert(
            MAX_UINT128,
            MAX_UINT128 - 1,
            0,
            1,
            1
        );
    }
    
    /**********************************/
    /*      Integration Tests         */
    /**********************************/
    
    /// @dev Tests that lock + unlock work correctly together
    function test_integration_lockAndUnlock() public {
        // Arrange - start with empty balance
        
        // Act
        wrapper.lock(100);
        wrapper.unlock(30);
        wrapper.lock(50);
        wrapper.unlock(120);
        
        // Assert
        assertEq(wrapper.getLocked(), 0);
        assertEq(wrapper.getUnlocked(), 150);
    }
    
    /// @dev Tests a complex sequence of operations to ensure all functions work together
    function test_integration_complexSequence() public {
        // Initial state
        wrapper.storeBalance(200, 100);
        
        // Operation sequence
        wrapper.lock(50);                    // locked = 250, unlocked = 100
        wrapper.unlock(100);                 // locked = 150, unlocked = 200
        bool decreaseSuccess = wrapper.decreaseLockedNoRevert(200); // Should fail
        assertFalse(decreaseSuccess);        // locked = 150, unlocked = 200 (unchanged)
        decreaseSuccess = wrapper.decreaseLockedNoRevert(50); // Should succeed
        assertTrue(decreaseSuccess);         // locked = 100, unlocked = 200
        bool increaseSuccess = wrapper.increaseUnlockedNoRevert(700); // Should succeed
        assertTrue(increaseSuccess);         // locked = 100, unlocked = 900
        uint128 unlocked = wrapper.unlockAll(); // Should unlock 100
        assertEq(unlocked, 100);             // locked = 0, unlocked = 1000
        
        // Final state verification
        (uint128 finalLocked, uint128 finalUnlocked) = wrapper.loadBalance();
        assertEq(finalLocked, 0);
        assertEq(finalUnlocked, 1000);
    }
    
    /// @dev Tests the integration of the new validation functions with balance operations
    function test_integration_balanceOperationsWithValidation() public {
        // Perform balance operations
        wrapper.setRawBalance(100, 50);
        
        // Initial values
        uint128 initialOffererLocked = 100;
        uint128 initialSolverUnlocked = 50;
        
        // Simulate a transfer of 30 tokens
        bool decreaseSuccess = wrapper.decreaseLockedNoRevert(30);
        assertTrue(decreaseSuccess);
        
        // Set the solver's balance
        wrapper.setRawBalance(70, 80);
        
        // Verify using the validation function
        bool isValid = wrapper.validateBalanceTransfer(
            initialOffererLocked,
            70,  // Final offerer locked
            initialSolverUnlocked,
            80,  // Final solver unlocked
            30   // Transfer amount
        );
        
        assertTrue(isValid);
    }
}