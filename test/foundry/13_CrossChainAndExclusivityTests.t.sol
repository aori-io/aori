// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * CrossChainAndWhitelistTests - Tests cross-chain functionality and solver whitelist features
 *
 * Test cases:
 * 1. testWhitelistEnforcement - Tests that only whitelisted solvers can perform operations
 * 2. testFullCrossChainFlowWithWhitelist - Tests the full cross-chain flow with deposit, fill, and settlement
 * 3. testCancellationByWhitelistedSolver - Tests that whitelisted solvers can cancel orders from source chain
 * 4. testNonWhitelistedSolverCannotCancel - Tests that non-whitelisted solvers cannot cancel orders
 * 5. testQuoteFeeCalculation - Tests the quote function for accurate fee estimation
 * 6. testCannotCancelAfterFill - Tests that cancellation is not possible after fill but before settlement
 * 7. testCannotFillAfterCancel - Tests that filling is not possible after an order has been cancelled
 * 8. testUnsupportedPayloadType - Tests handling of unsupported payload types in cross-chain messages
 *
 * This test file focuses on verifying cross-chain order flows and the proper enforcement of
 * solver whitelisting. It simulates cross-chain communication by using LayerZero's test helpers
 * and manually constructing the settlement and cancellation payloads.
 */
import {IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

/**
 * @title CrossChainAndWhitelistTests
 * @notice Tests for cross-chain behavior and whitelist-based solver system in the Aori contract
 */
contract CrossChainAndWhitelistTests is TestUtils {
    using OptionsBuilder for bytes;

    // A non-whitelisted solver address for testing whitelist restrictions
    address public nonWhitelistedSolver = address(0x300);
    uint256 private constant GAS_LIMIT = 200000;

    function setUp() public override {
        super.setUp();

        // Set up a non-whitelisted solver with output tokens for testing
        outputToken.mint(nonWhitelistedSolver, 1000e18);
    }

    /**
     * @notice Test whitelist-based solver restrictions
     * Only whitelisted solvers can perform operations
     */
    function testWhitelistEnforcement() public {
        vm.chainId(localEid);

        // Create a valid order
        IAori.Order memory order = createValidOrder();

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Non-whitelisted solver should fail to deposit
        vm.startPrank(nonWhitelistedSolver);
        vm.expectRevert("Invalid solver");
        localAori.deposit(order, signature);
        vm.stopPrank();

        // Whitelisted solver should be able to deposit
        vm.startPrank(solver);
        localAori.deposit(order, signature);
        vm.stopPrank();
    }

    /**
     * @notice Test the full cross-chain flow with whitelisted solver
     * The whitelisted solver deposits, fills, and settles an order
     */
    function testFullCrossChainFlowWithWhitelist() public {
        vm.chainId(localEid);

        // Create a valid order
        IAori.Order memory order = createValidOrder();

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Check locked balance
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount);

        // Switch to destination chain
        vm.chainId(remoteEid);

        // Warp to order start time
        vm.warp(order.startTime + 10);

        // Fill the order as the whitelisted solver
        vm.startPrank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        remoteAori.fill(order);

        // Prepare settlement
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 fee = remoteAori.quote(localEid, uint8(PayloadType.Settlement), options, false, localEid, solver);

        // Send settlement
        vm.deal(solver, fee);
        remoteAori.settle{value: fee}(localEid, solver, options);
        vm.stopPrank();

        // Switch back to source chain to simulate receiving the settlement
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");

        // Prepare the settlement payload
        uint16 fillCount = 1;
        bytes memory settlementPayload = new bytes(23 + uint256(fillCount) * 32);
        settlementPayload[0] = 0x00; // Settlement message type

        // Copy solver address
        bytes20 fillerBytes = bytes20(solver);
        for (uint256 i = 0; i < 20; i++) {
            settlementPayload[1 + i] = fillerBytes[i];
        }

        // Fill count (2 bytes)
        settlementPayload[21] = bytes1(uint8(uint16(fillCount) >> 8));
        settlementPayload[22] = bytes1(uint8(uint16(fillCount)));

        // Order hash
        bytes32 orderHash = localAori.hash(order);
        for (uint256 i = 0; i < 32; i++) {
            settlementPayload[23 + i] = orderHash[i];
        }

        // Simulate receipt of settlement message
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            settlementPayload,
            address(0),
            bytes("")
        );

        // Verify that funds were unlocked for the solver
        uint256 unlockedBalance = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(unlockedBalance, order.inputAmount);
    }

    /**
     * @notice Test cancellation by whitelisted solver
     */
    function testCancellationByWhitelistedSolver() public {
        vm.chainId(localEid);

        // Store user's initial token balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);

        // Create a valid SINGLE-CHAIN order (not cross-chain)
        IAori.Order memory order = createValidOrder();
        order.dstEid = localEid; // Make it single-chain to allow source chain cancellation

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Check locked balance
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount);

        // Advance time past order expiry
        vm.warp(order.endTime + 1);

        // Whitelisted solver cancels the order
        bytes32 orderHash = localAori.hash(order);
        vm.prank(solver);
        localAori.cancel(orderHash);

        // Verify tokens were transferred directly back to the offerer
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        
        // Verify locked balance is now 0
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        
        // Verify unlocked balance remains 0 (since tokens were transferred directly)
        uint256 unlockedBalance = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(unlockedBalance, 0, "Unlocked balance should remain 0 with direct transfer");
    }

    /**
     * @notice Test that non-whitelisted solver cannot cancel an order
     * Only whitelisted solvers can call cancel
     */
    function testNonWhitelistedSolverCannotCancel() public {
        vm.chainId(localEid);

        // Create a valid SINGLE-CHAIN order (not cross-chain)
        IAori.Order memory order = createValidOrder();
        order.dstEid = localEid; // Make it single-chain to allow source chain cancellation

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Advance time past order expiry 
        vm.warp(order.endTime + 1);

        // Non-whitelisted solver tries to cancel - should fail
        bytes32 orderHash = localAori.hash(order);
        
        // Place expectRevert directly before the call that should revert
        vm.prank(nonWhitelistedSolver);
        vm.expectRevert("Only solver or offerer (after expiry) can cancel");
        localAori.cancel(orderHash);
    }

    /**
     * @notice Test the quote function for accurate fee estimation
     */
    function testQuoteFeeCalculation() public view {
        // Create options for quoting
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        
        // Get a fee quote
        uint256 fee = localAori.quote(remoteEid, uint8(PayloadType.Settlement), options, false, localEid, solver);
        
        // The fee should be non-zero
        assertGt(fee, 0, "Fee should be greater than zero");
    }

    /**
     * @notice Test that cancellation is not possible on remote chain after fill but before settlement
     */
    function testCannotCancelAfterFill() public {
        vm.chainId(localEid);

        // Create a valid order
        IAori.Order memory order = createValidOrder();

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Switch to destination chain
        vm.chainId(remoteEid);

        // Warp to order start time
        vm.warp(order.startTime + 10);

        // Fill the order as the whitelisted solver
        vm.startPrank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        remoteAori.fill(order);
        vm.stopPrank();

        // Stay on remote chain where the fill happened
        // Try to cancel from the same chain where the fill occurred
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 fee = remoteAori.quote(localEid, uint8(PayloadType.Cancellation), options, false, localEid, userA);

        // Try to cancel after fill - should revert
        vm.deal(userA, fee);
        vm.prank(userA);
        bytes32 orderHash = localAori.hash(order);
        // Add a check to verify the order state is actually Filled
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Filled), "Order should be in filled state"
        );
        vm.expectRevert("Order not active");
        remoteAori.cancel(orderHash, order, defaultOptions());
    }

    /**
     * @notice Test that filling is not possible after an order has been cancelled
     */
    function testCannotFillAfterCancel() public {
        vm.chainId(localEid);

        // Create a valid order
        IAori.Order memory order = createValidOrder();

        // Sign and deposit the order
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Whitelisted solver deposits
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Switch to destination chain
        vm.chainId(remoteEid);

        // Warp to after order endTime so anyone can cancel
        vm.warp(order.endTime + 1);

        // Cancel the order from the destination chain
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 cancelFee = remoteAori.quote(localEid, uint8(PayloadType.Cancellation), options, false, localEid, userA);

        vm.deal(userA, cancelFee);
        vm.startPrank(userA);
        bytes32 orderHash = localAori.hash(order);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        vm.stopPrank();

        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint256(IAori.OrderStatus.Cancelled),
            "Order should be in cancelled state"
        );

        // Simulate receiving the cancellation message on source chain
        vm.chainId(localEid);
        bytes memory cancelPayload = abi.encodePacked(uint8(PayloadType.Cancellation), orderHash);
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-guid"),
            cancelPayload,
            address(0),
            bytes("")
        );

        // Switch back to destination chain
        vm.chainId(remoteEid);

        // Verify the order is in cancelled state
        // Warp to order start time
        vm.warp(order.startTime + 10);

        // Try to fill the cancelled order - should revert
        vm.startPrank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        vm.expectRevert("Order not active");
        remoteAori.fill(order);
        vm.stopPrank();
    }

    /**
     * @notice Test handling of unsupported payload types
     * Verifies that the contract properly rejects messages with invalid payload types
     */
    function testUnsupportedPayloadType() public {
        vm.chainId(localEid);

        // Create an invalid payload with an unsupported type (not 0 for settlement or 1 for cancellation)
        bytes memory invalidPayload = new bytes(33); // Same length as a cancellation payload
        invalidPayload[0] = 0x02; // Set unsupported payload type (2)
        
        // Fill the rest with some dummy data
        bytes32 dummyOrderHash = keccak256("dummy-order-hash");
        for (uint256 i = 0; i < 32; i++) {
            invalidPayload[1 + i] = dummyOrderHash[i];
        }

        // Simulate LayerZero message with invalid payload type
        bytes32 guid = keccak256("mock-guid-invalid-payload");
        vm.prank(address(endpoints[localEid]));
        // Use generic expectRevert without message since Solidity panics are difficult to match exactly
        vm.expectRevert();
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            invalidPayload,
            address(0),
            bytes("")
        );
    }
}
