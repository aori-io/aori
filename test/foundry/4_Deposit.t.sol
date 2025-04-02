// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * DepositTest - Tests the deposit functionality in the Aori contract
 *
 * Test cases:
 * 1. testDepositOnly - Tests that a deposit properly increases the locked balance of the order offerer
 *                     and verifies token transfers and order status
 *
 * This test verifies that:
 * - Depositing an order increases the user's locked balance by the input amount
 * - The user's token balance decreases by the same amount
 * - The order is not incorrectly marked as filled
 */
import {IAori} from "../../contracts/Aori.sol";
import "./TestUtils.sol";

contract DepositTest is TestUtils {
    // The recipient address (separate from userA and solver)
    address public recipient;

    function setUp() public override {
        super.setUp();
        recipient = address(0x300);
    }

    /// @notice Tests that a deposit increases the locked balance of the order offerer.
    function testDepositOnly() public {
        // Create the order with custom recipient.
        IAori.Order memory order = createCustomOrder(
            userA, // offerer
            recipient, // recipient (not the same as offerer)
            address(inputToken),
            address(outputToken),
            1e18, // inputAmount
            2e18, // outputAmount
            uint32(block.timestamp), // startTime (now)
            uint32(block.timestamp + 1 days), // endTime
            localEid,
            remoteEid
        );

        uint256 initialLocked = localAori.getLockedBalances(userA, address(inputToken));
        uint256 initialBalance = inputToken.balanceOf(userA);

        // Generate a valid signature.
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit.
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a relayer.
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify the locked balance update and token transfer.
        assertEq(
            localAori.getLockedBalances(userA, address(inputToken)),
            initialLocked + order.inputAmount,
            "Locked balance not increased"
        );
        assertEq(inputToken.balanceOf(userA), initialBalance - order.inputAmount, "User balance not decreased");
        // Check that the order is not marked as filled.
        bytes32 orderHash = localAori.hash(order);
        assertNotEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Filled),
            "Order should not be marked filled"
        );
    }
}
