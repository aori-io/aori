// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * CancelSuccessTest - Tests the order cancellation functionality in the Aori contract
 *
 * Test cases:
 * 1. testCancelSuccess - Tests that cancellation successfully unlocks a deposited order's tokens
 *                        and verifies the order status changes to Cancelled
 *
 * This test confirms the basic cancellation flow where:
 * - A user deposits an order on the source chain
 * - The locked balance increases appropriately
 * - A whitelisted solver cancels the order via srcCancel
 * - The tokens are unlocked and become available to the user
 * - The order status is correctly updated to Cancelled
 */
import {IAori} from "../../contracts/Aori.sol";
import "./TestUtils.sol";

contract CancelSuccessTest is TestUtils {
    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Tests that cancellation unlocks the deposit.
     *
     * Flow:
     * 1. Deposits an order on the source chain (without hook conversion) so that inputToken is used.
     * 2. Verifies the locked balance for userA increases by order.inputAmount.
     * 3. The whitelisted solver calls srcCancel.
     * 4. Verifies that the locked balance is zero and the unlocked balance for userA is updated.
     */
    function testCancelSuccess() public {
        // PHASE 1: Deposit on the Source Chain.
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();

        // Generate a valid signature.
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit.
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a relayer.
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify that the locked balance has increased.
        uint256 lockedBefore = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBefore, order.inputAmount, "Locked balance not updated after deposit");

        // PHASE 2: Cancel the order.
        // Get the order hash
        bytes32 orderHash = localAori.hash(order);

        // Cancel the order locally using the whitelisted solver
        vm.prank(solver);
        localAori.srcCancel(orderHash);

        // Check balances after cancellation
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));

        assertEq(lockedAfter, 0, "User input tokens remain locked after local cancel");
        assertEq(unlockedAfter, order.inputAmount, "User unlocked balance not updated correctly after local cancel");

        // Verify the order status after cancellation
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be in cancelled state"
        );
    }
}
