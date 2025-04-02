// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * ExtremeOrderParametersTest - Tests extreme edge cases for order parameters in the Aori contract
 *
 * Test cases:
 * 1. testMaxValueOrder - Tests orders with the largest possible token amounts (type(uint128).max)
 * 2. testMinValueOrder - Tests orders with the smallest possible non-zero token amounts (1)
 * 3. testShortDurationOrder - Tests orders with extremely short duration (1 second window)
 * 4. testLongDurationOrder - Tests orders with the maximum possible time window (type(uint32).max)
 * 5. testWhitelistEnforcement - Tests that only whitelisted solvers can perform operations
 *
 * This test file focuses on verifying that the Aori contract correctly handles extreme parameter values,
 * such as maximum/minimum token amounts and time windows, while maintaining proper whitelist enforcement.
 * These edge cases are important to test the robustness of the contract's validation logic.
 */
import {IAori} from "../../contracts/IAori.sol";
import "./TestUtils.sol";

/**
 * @title ExtremeOrderParametersTest
 * @notice Tests for extreme edge cases in order parameters for the Aori contract
 * These tests verify that the contract handles various extreme parameter values correctly
 * while maintaining proper whitelist-based solver restrictions.
 */
contract ExtremeOrderParametersTest is TestUtils {
    function setUp() public override {
        super.setUp();

        // Mint tokens with large amounts to test extreme scenarios
        inputToken.mint(userA, type(uint128).max);
        outputToken.mint(solver, type(uint128).max);
    }

    /**
     * @notice Test order with maximum possible amounts
     * Verifies that the contract can handle orders with the largest possible token amounts
     * while maintaining proper whitelist-based solver restrictions
     */
    function testMaxValueOrder() public {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: type(uint128).max, // Very large input amount
            outputAmount: type(uint128).max, // Very large output amount
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits the order
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify that the locked balance increased correctly
        assertEq(
            localAori.getLockedBalances(userA, address(inputToken)),
            order.inputAmount,
            "Locked balance incorrect after deposit"
        );

        // Test fill with max values
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order);

        // Verify that the fill worked correctly with large amounts
        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive correct output amount");
    }

    /**
     * @notice Test order with minimum possible non-zero amounts
     * Verifies that the contract can handle orders with the smallest possible non-zero token amounts
     * while maintaining proper whitelist-based solver restrictions
     */
    function testMinValueOrder() public {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1, // Minimum possible non-zero amount
            outputAmount: 1, // Minimum possible non-zero amount
            startTime: uint32(uint32(block.timestamp)),
            endTime: uint32(uint32(block.timestamp) + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits the order
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Test fill with minimum values
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order);

        // Verify that the fill worked correctly with small amounts
        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive correct output amount");
    }

    /**
     * @notice Test order with extremely short duration (immediate start and short end time)
     * Verifies that the contract correctly handles orders with minimal time windows
     * while maintaining proper whitelist-based solver restrictions
     */
    function testShortDurationOrder() public {
        vm.warp(1000); // Set a starting time

        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: 1000, // Exactly current timestamp
            endTime: 1001, // Just 1 second duration
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits the order
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Test fill with precise timing
        vm.chainId(remoteEid);

        // Exactly at start time, should work (no need to test too early case)
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order);

        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive correct output amount");
    }

    /**
     * @notice Test order with extremely long duration (maximum possible time)
     * Verifies that the contract correctly handles orders with maximum possible time windows
     * while maintaining proper whitelist-based solver restrictions
     */
    function testLongDurationOrder() public {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: type(uint32).max, // Maximum possible end time
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits the order
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Test fill with large time gap
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10000 days); // Warp very far into the future

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order);

        // Order should still be fillable due to the long duration
        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive correct output amount");
    }

    /**
     * @notice Test whitelist-based solver restrictions
     * Verifies that only whitelisted solvers can perform operations and that
     * removing a solver from the whitelist prevents it from performing operations
     */
    function testWhitelistEnforcement() public {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(uint32(block.timestamp)),
            endTime: uint32(uint32(block.timestamp) + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Remove solver from whitelist temporarily to test restrictions
        localAori.removeAllowedSolver(solver);

        // Non-whitelisted solver should fail to deposit
        vm.prank(solver);
        vm.expectRevert("Invalid solver");
        localAori.deposit(order, signature);

        // Add solver back to whitelist
        localAori.addAllowedSolver(solver);

        // Whitelisted solver should be able to deposit
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Test fill with whitelist enforcement
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);

        // Remove solver from whitelist temporarily to test restrictions
        remoteAori.removeAllowedSolver(solver);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert("Invalid solver");
        remoteAori.fill(order);

        // Add solver back to whitelist
        remoteAori.addAllowedSolver(solver);

        // Whitelisted solver should be able to fill
        vm.prank(solver);
        remoteAori.fill(order);

        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive correct output amount");
    }
}
