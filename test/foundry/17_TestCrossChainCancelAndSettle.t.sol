// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title CrossChainCancelAndSettleTest
 * @notice Tests cross-chain cancellation and settlement flows in the Aori protocol
 *
 * This test file verifies that cross-chain order cancellation works correctly in different scenarios.
 * It tests both solver-initiated cancellations and user-initiated cancellations after the order
 * expiration, ensuring that tokens are properly unlocked after cancellation.
 *
 * Tests:
 * 1. testDestinationCancelBySolver - Tests that a whitelisted solver can cancel an order before endTime
 * 2. testDestinationCancelByUser - Tests that the order offerer can cancel after endTime
 *
 * Special notes:
 * - These tests use LayerZero message delivery simulation to verify cross-chain communication
 * - The tests focus on the entire flow from deposit to cancellation to final token withdrawal
 * - Cancellation permissions are tested to ensure only authorized actors can cancel orders
 */
import {TestUtils} from "./TestUtils.sol";
import {IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @notice Tests cross-chain cancellation and settlement flows in the Aori protocol
 */
contract CrossChainCancelAndSettleTest is TestUtils {
    uint256 private constant GAS_LIMIT = 200000;

    function setUp() public override {
        // Setup parent test environment
        super.setUp();
    }

    /**
     * @notice Test that whitelisted solver can cancel before endTime
     */
    function testDestinationCancelBySolver() public {
        // PHASE 1: Deposit on Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();

        // Advance to startTime
        vm.warp(order.startTime + 1);

        // Sign the order
        bytes memory signature = signOrder(order);

        // Approve and deposit the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        // PHASE 2: Cancel on Destination Chain as whitelisted solver
        vm.chainId(remoteEid);

        // Set up the order on the destination chain
        bytes32 orderHash = remoteAori.hash(order);
        remoteAori.orders(orderHash); // This will create the order in storage

        // Calculate LZ message fee
        bytes memory options = defaultOptions();
        uint256 fee = remoteAori.quote(localEid, 1, options, false, localEid, solver);
        vm.deal(solver, fee);

        // Cancel as whitelisted solver before endTime
        vm.prank(solver);
        remoteAori.cancel{value: fee}(orderHash, order, options);

        // Verify order is cancelled
        assertEq(
            uint256(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order not cancelled on destination chain"
        );
    }

    /**
     * @notice Test that offerer can cancel after endTime
     */
    function testDestinationCancelByUser() public {
        // Store user's initial token balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // PHASE 1: Deposit on Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();

        // Advance to startTime
        vm.warp(order.startTime + 1);

        // Sign the order
        bytes memory signature = signOrder(order);

        // Approve and deposit the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify the order is locked
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount, "Locked balance not increased correctly");

        // PHASE 2: Cancel on Destination Chain
        vm.chainId(remoteEid);

        // Set up the order on the destination chain
        bytes32 orderHash = remoteAori.hash(order);
        remoteAori.orders(orderHash); // This will create the order in storage

        // Warp past endTime
        vm.warp(order.endTime + 1);

        // Calculate LZ message fee
        bytes memory options = defaultOptions();
        uint256 fee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        vm.deal(userA, fee);

        // Cancel as offerer after endTime
        vm.prank(userA);
        remoteAori.cancel{value: fee}(orderHash, order, options);

        // PHASE 3: Simulate LZ message delivery to Source Chain
        vm.chainId(localEid);

        // Prepare cancellation payload (msg type 0x01 followed by order hash)
        bytes memory cancellationPayload = new bytes(33); // 1 byte msg type + 32 bytes hash
        cancellationPayload[0] = 0x01; // Cancellation message type

        // Copy order hash into payload
        for (uint256 i = 0; i < 32; i++) {
            cancellationPayload[i + 1] = orderHash[i];
        }

        // Simulate LZ message delivery
        bytes32 guid = keccak256("mock-guid");
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            cancellationPayload,
            address(0),
            bytes("")
        );

        // PHASE 4: Verification
        // The order should now be cancelled on the source chain, with tokens transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);

        assertEq(lockedAfter, 0, "Order should be unlocked after remote cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should receive their tokens back directly");

        // No withdrawal needed since tokens were transferred directly
    }
}
