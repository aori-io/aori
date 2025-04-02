// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * WithdrawTest - Tests the withdraw functionality in the Aori contract
 *
 * Test cases:
 * 1. testWithdrawUnlockedFunds - Tests the full flow of depositing, canceling, and withdrawing tokens
 *
 * This test verifies that:
 * - A user can deposit an order, locking their tokens
 * - After cancellation, the tokens become unlocked
 * - The user can then withdraw their unlocked tokens
 * - Balances are correctly tracked and updated throughout the process
 */
import {ExecutionUtils, HookUtils, PayloadPackUtils, PayloadUnpackUtils} from "../../contracts/lib/AoriUtils.sol";
import {IAori} from "../../contracts/interfaces/IAori.sol";
import "./TestUtils.sol";

contract WithdrawTest is TestUtils {
    function setUp() public override {
        super.setUp();
        vm.deal(userA, 1e18); // Fund the account with 1 ETH
    }

    /**
     * @dev Returns a cancelable order.
     * For cancellation to be valid, the caller must be a whitelisted solver.
     */
    function createCancelableOrder() internal view returns (IAori.Order memory order) {
        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(1e18),
            outputAmount: uint128(2e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });
    }

    /**
     * @notice Deposits a cancelable order, cancels it (unlocking the funds), and then withdraws the unlocked tokens.
     */
    function testWithdrawUnlockedFunds() public {
        // PHASE 1: Deposit on the Source Chain.
        vm.chainId(localEid);
        IAori.Order memory order = createCancelableOrder();

        // Generate a valid signature.
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit.
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a relayer.
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify that the locked balance increased.
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount, "Locked balance should equal order inputAmount");

        // PHASE 2: Cancel the order to unlock the funds.
        bytes32 orderHash = localAori.hash(order);
        vm.prank(solver);
        localAori.srcCancel(orderHash);

        // After cancellation, the locked balance must be 0 and the unlocked balance equal to order.inputAmount.
        uint256 lockedAfterCancel = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfterCancel = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(lockedAfterCancel, 0, "Locked balance should be zero after cancellation");
        assertEq(
            unlockedAfterCancel, order.inputAmount, "Unlocked balance should equal order inputAmount after cancellation"
        );

        // PHASE 3: Withdraw the unlocked funds.
        uint256 userInitialBalance = inputToken.balanceOf(userA);
        vm.prank(userA);
        localAori.withdraw(address(inputToken));

        // After withdrawal, unlocked balance should reset and the user's wallet balance increased.
        uint256 unlockedAfterWithdraw = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(unlockedAfterWithdraw, 0, "Unlocked balance should be zero after withdrawal");

        uint256 userFinalBalance = inputToken.balanceOf(userA);
        assertEq(
            userFinalBalance, userInitialBalance + order.inputAmount, "User balance should increase by withdrawn amount"
        );
    }
}
