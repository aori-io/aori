// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "./TestUtils.sol";

/**
 * @title DepositAndFillTest
 * @notice Test suite for the depositAndFill function in Aori contract
 *
 * This test file verifies the functionality of the depositAndFill function which
 * allows single-chain swaps to be executed in a single atomic transaction. It tests
 * successful execution, failure conditions, balance updates, and integration with
 * other contract components.
 *
 * Tests:
 * 1. testDepositAndFillSuccess - Tests basic successful execution of depositAndFill
 * 2. testDepositAndFillWithExactAmounts - Tests depositAndFill with exact token amounts
 * 3. testDepositAndFillReversionForCrossChainOrder - Tests reversion when used for cross-chain order
 * 4. testDepositAndFillSignatureValidation - Tests signature validation during depositAndFill
 * 5. testDepositAndFillOrderStatusTransition - Tests proper order status transitions
 * 6. testDepositAndFillEventEmission - Tests correct event emission
 * 7. testDepositAndFillBalanceUpdates - Tests accurate balance updates after execution
 * 8. testDepositAndFillWithPreviouslyUsedOrder - Tests prevention of order reuse
 * 9. testDepositAndFillPermissions - Tests solver permissions requirement
 * 10. testDepositAndFillWhenPaused - Tests behavior when contract is paused
 */
contract DepositAndFillTest is Test, TestUtils {
    // Main test state variables are inherited from TestUtils
    uint256 private nonWhitelistedUserPrivKey = 0xCAFE;
    address private nonWhitelistedUser;
    
    function setUp() public override {
        super.setUp();
        
        // Set up additional test user
        nonWhitelistedUser = vm.addr(nonWhitelistedUserPrivKey);
        
        // Mint tokens for the test user
        inputToken.mint(nonWhitelistedUser, 1000e18);
        outputToken.mint(nonWhitelistedUser, 1000e18);
    }
    
    /**********************************/
    /*        Success Cases           */
    /**********************************/
    
    /// @notice Tests a basic successful depositAndFill operation with standard parameters
    function testDepositAndFillSuccess() public {
        // Prepare the test scenario
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // Prepare approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Record initial balances
        uint256 initialUserAInputBalance = inputToken.balanceOf(userA);
        uint256 initialUserAOutputBalance = outputToken.balanceOf(userA);
        uint256 initialSolverInputBalance = inputToken.balanceOf(solver);
        uint256 initialSolverOutputBalance = outputToken.balanceOf(solver);
        
        // Execute depositAndFill
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
        
        // Verify final balances
        uint256 finalUserAInputBalance = inputToken.balanceOf(userA);
        uint256 finalUserAOutputBalance = outputToken.balanceOf(userA);
        uint256 finalSolverInputBalance = inputToken.balanceOf(solver);
        uint256 finalSolverOutputBalance = outputToken.balanceOf(solver);
        
        // Assert token transfers
        assertEq(initialUserAInputBalance - finalUserAInputBalance, order.inputAmount, "User input balance incorrect");
        assertEq(finalUserAOutputBalance - initialUserAOutputBalance, order.outputAmount, "User output balance incorrect");
        assertEq(finalSolverInputBalance, initialSolverInputBalance, "Solver input balance should not change directly");
        assertEq(initialSolverOutputBalance - finalSolverOutputBalance, order.outputAmount, "Solver output balance incorrect");
        
        // Assert contract's internal balance state
        uint256 solverUnlockedBalance = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(solverUnlockedBalance, order.inputAmount, "Solver unlocked balance incorrect");
        
        // Verify order status
        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Settled), "Order status should be Settled");
    }
    
    /// @notice Tests depositAndFill with exact token amounts (no dust or rounding)
    function testDepositAndFillWithExactAmounts() public {
        // Create an order with exact, round amounts
        IAori.Order memory order = createValidSingleChainOrder();
        order.inputAmount = 1000 * 10**18; // Exact 1000 tokens
        order.outputAmount = 500 * 10**18; // Exact 500 tokens
        
        bytes memory signature = signOrder(order);
        
        // Record initial balances
        uint256 initialUserAInputBalance = inputToken.balanceOf(userA);
        uint256 initialUserAOutputBalance = outputToken.balanceOf(userA);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Execute depositAndFill
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
        
        // Verify final balances are exactly as expected
        assertEq(inputToken.balanceOf(userA), initialUserAInputBalance - order.inputAmount, "User A input balance incorrect");
        assertEq(outputToken.balanceOf(userA), initialUserAOutputBalance + order.outputAmount, "User A output balance incorrect");
        
        // Verify solver's unlocked balance
        uint256 solverUnlockedBalance = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(solverUnlockedBalance, order.inputAmount, "Solver unlocked balance incorrect");
    }
    
    /**********************************/
    /*        Failure Cases           */
    /**********************************/
    
    /// @notice Tests that depositAndFill reverts when used with a cross-chain order
    function testDepositAndFillReversionForCrossChainOrder() public {
        // Create a cross-chain order
        IAori.Order memory order = createValidSingleChainOrder();
        order.dstEid = remoteEid; // Different from srcEid for cross-chain
        
        bytes memory signature = signOrder(order);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Execute depositAndFill - should revert
        vm.prank(solver);
        vm.expectRevert("Only for single-chain swaps");
        localAori.depositAndFill(order, signature);
    }
    
    /// @notice Tests that depositAndFill validates signatures properly
    function testDepositAndFillSignatureValidation() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        
        // Create an invalid signature (signed by wrong account)
        bytes memory invalidSignature = signOrder(order, nonWhitelistedUserPrivKey);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Execute depositAndFill with invalid signature - should revert
        vm.prank(solver);
        vm.expectRevert("InvalidSignature");
        localAori.depositAndFill(order, invalidSignature);
    }
    
    /// @notice Tests that an order can't be used more than once with depositAndFill
    function testDepositAndFillWithPreviouslyUsedOrder() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // Set up approvals for multiple uses
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount * 2);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount * 2);
        
        // First depositAndFill should succeed
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
        
        // Second depositAndFill with same order should fail
        vm.prank(solver);
        vm.expectRevert("Order already exists");
        localAori.depositAndFill(order, signature);
    }
    
    /// @notice Tests that depositAndFill enforces solver permissions
    function testDepositAndFillPermissions() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(nonWhitelistedUser); // non-whitelisted user
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Try depositAndFill from non-solver - should revert
        vm.prank(nonWhitelistedUser);
        vm.expectRevert("Invalid solver");
        localAori.depositAndFill(order, signature);
    }
    
    /// @notice Tests that depositAndFill is blocked when contract is paused
    function testDepositAndFillWhenPaused() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Pause the contract
        vm.prank(address(this)); // owner from TestUtils setup
        localAori.pause();
        
        // Try depositAndFill while paused - should revert
        vm.prank(solver);
        // Instead of expecting a specific string, we'll just expect any revert
        // since OpenZeppelin's newer versions use custom errors like EnforcedPause()
        vm.expectRevert();
        localAori.depositAndFill(order, signature);
        
        // Unpause and verify it works now
        vm.prank(address(this)); // owner from TestUtils setup
        localAori.unpause();
        
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
    }
    
    /**********************************/
    /*        Behavioral Tests        */
    /**********************************/
    
    /// @notice Tests the proper order status transition in depositAndFill
    function testDepositAndFillOrderStatusTransition() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        bytes32 orderHash = localAori.hash(order);
        
        // Verify initial status
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Unknown), "Initial order status should be Unknown");
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Execute depositAndFill
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
        
        // Verify final status - jumps directly from Unknown to Settled
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Settled), "Final order status should be Settled");
    }
    
    /// @notice Tests correct event emission during depositAndFill
    function testDepositAndFillEventEmission() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        bytes32 orderHash = localAori.hash(order);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Execute depositAndFill and check for event
        vm.prank(solver);
        vm.expectEmit(true, false, false, false);
        emit IAori.Settle(orderHash);
        localAori.depositAndFill(order, signature);
    }
    
    /// @notice Tests accurate balance updates after depositAndFill execution
    function testDepositAndFillBalanceUpdates() public {
        // Create a valid order
        IAori.Order memory order = createValidSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // Set up approvals
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        outputToken.approve(address(localAori), order.outputAmount);
        
        // Record balances before operation
        uint256 initialOffererLocked = localAori.getLockedBalances(userA, address(inputToken));
        uint256 initialOffererUnlocked = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 initialSolverLocked = localAori.getLockedBalances(solver, address(inputToken));
        uint256 initialSolverUnlocked = localAori.getUnlockedBalances(solver, address(inputToken));
        
        // Execute depositAndFill
        vm.prank(solver);
        localAori.depositAndFill(order, signature);
        
        // Verify balance changes
        // 1. Offerer balances shouldn't change in contract (tokens go from wallet, not contract)
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), initialOffererLocked, "Offerer locked balance should be unchanged");
        assertEq(localAori.getUnlockedBalances(userA, address(inputToken)), initialOffererUnlocked, "Offerer unlocked balance should be unchanged");
        
        // 2. Solver's unlocked balance should increase, locked balance unchanged
        assertEq(localAori.getLockedBalances(solver, address(inputToken)), initialSolverLocked, "Solver's locked balance should be unchanged");
        assertEq(
            localAori.getUnlockedBalances(solver, address(inputToken)), 
            initialSolverUnlocked + order.inputAmount, 
            "Solver's unlocked balance should increase by input amount"
        );
    }
    
    /**********************************/
    /*         Helper Functions       */
    /**********************************/
    
    /// @notice Creates a valid order for single-chain swap
    function createValidSingleChainOrder() internal view returns (IAori.Order memory) {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: localEid // Same as srcEid for single-chain swap
        });
        
        return order;
    }
}
