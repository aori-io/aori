// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * ValidationFailuresTest - Tests various validation failure conditions in the Aori contract
 *
 * Test cases:
 * 1. testRevertFillZeroOutputAmount - Tests that fill reverts when trying to fill an order with zero output amount
 * 2. testRevertFillZeroInputAmount - Tests that fill reverts when trying to fill an order with zero input amount
 * 3. testRevertFillInvalidChainID - Tests that fill reverts when trying to fill an order with invalid chain IDs
 * 4. testRevertFillWhitelistCheck - Tests that fill reverts when the solver is not whitelisted
 * 5. testRevertFillDeadlineCheck - Tests that fill reverts when trying to fill an order after its deadline
 * 6. testRevertFillBeforeStart - Tests that fill reverts when trying to fill an order before its start time
 * 7. testRevertFillDuplicate - Tests that fill reverts when trying to fill the same order twice
 * 8. testRevertFillWithFailingHook - Tests that fill reverts when trying to use a hook that fails
 *
 * This test file focuses specifically on validation failures in the fill function of the Aori contract,
 * testing various edge cases and invalid input conditions.
 */
import {IAori} from "../../contracts/IAori.sol";
import {FailingHook} from "../Mock/FailHook.sol";
import "./TestUtils.sol";

/**
 * @title ValidationFailuresTest
 * @notice Tests various validation failures in the Aori contract
 */
contract ValidationFailuresTest is TestUtils {
    FailingHook public failingHook;

    function setUp() public override {
        super.setUp();

        // Deploy failing hook
        failingHook = new FailingHook();

        // Whitelist the failing hook in both Aori instances
        localAori.addAllowedHook(address(failingHook));
        remoteAori.addAllowedHook(address(failingHook));
    }

    /**
     * @notice Test that fill reverts when trying to fill an order with zero output amount
     */
    function testRevertFillZeroOutputAmount() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();
        // Make sure the order can pass time validation by setting it to active
        vm.warp(order.startTime + 1);
        order.outputAmount = 0; // Invalid output amount

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Invalid output amount"));
        remoteAori.fill(order);
    }

    /**
     * @notice Test that fill reverts when trying to fill an order with zero input amount
     */
    function testRevertFillZeroInputAmount() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();
        // Make sure the order can pass time validation by setting it to active
        vm.warp(order.startTime + 1);
        order.inputAmount = 0; // Invalid input amount

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Invalid input amount"));
        remoteAori.fill(order);
    }

    /**
     * @notice Test that fill reverts when trying to fill an order with invalid chain IDs
     */
    function testRevertFillInvalidChainID() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();
        // Make sure the order can pass time validation by setting it to active
        vm.warp(order.startTime + 1);
        order.dstEid = 999; // Wrong destination EID

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Chain mismatch"));
        remoteAori.fill(order);
    }

    /**
     * @notice Test whitelist check failure
     */
    function testRevertFillWhitelistCheck() public {
        vm.chainId(remoteEid);

        // Create order and remove solver from whitelist
        IAori.Order memory order = createValidOrder();
        remoteAori.removeAllowedSolver(solver);

        // Set time to after order start
        vm.warp(order.startTime + 100);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Invalid solver"));
        remoteAori.fill(order);

        // Restore solver to whitelist for other tests
        remoteAori.addAllowedSolver(solver);
    }

    /**
     * @notice Test deadline check failure
     */
    function testRevertFillDeadlineCheck() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();

        // Warp to after the deadline
        vm.warp(order.endTime + 1);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Order has expired"));
        remoteAori.fill(order);
    }

    /**
     * @notice Test that fill reverts when trying to fill an order that hasn't started yet
     */
    function testRevertFillBeforeStart() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();

        // Current time is before order.startTime
        vm.warp(order.startTime - 1);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        vm.prank(solver);
        vm.expectRevert(bytes("Order not started"));
        remoteAori.fill(order);
    }

    /**
     * @notice Test that fill reverts when trying to fill the same order twice
     */
    function testRevertFillDuplicate() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);

        // Approve and fill the order
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount * 2);

        vm.prank(solver);
        remoteAori.fill(order);

        // Attempt to fill the same order again
        vm.prank(solver);
        vm.expectRevert(bytes("Order not active"));
        remoteAori.fill(order);

        // Verify order status
        bytes32 orderHash = remoteAori.hash(order);
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Filled), "Order should be in filled state"
        );
    }

    /**
     * @notice Test that fill reverts when trying to use a hook that fails
     */
    function testRevertFillWithFailingHook() public {
        vm.chainId(remoteEid);

        IAori.Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);

        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(failingHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(FailingHook.alwaysFail.selector),
            preferedDstInputAmount: order.outputAmount
        });

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(bytes("Call failed"));
        remoteAori.fill(order, dstData);
    }
}
