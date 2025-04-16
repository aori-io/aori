// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * FillFailTest - Tests various failure conditions for the fill functionality in the Aori contract
 *
 * Test cases:
 * 1. testRevertFillInvalidTimeRange - Tests that fill reverts when order's startTime is after its endTime
 * 2. testRevertFillZeroInputAmount - Tests that fill reverts when order's input amount is zero
 * 3. testRevertFillZeroOutputAmount - Tests that fill reverts when order's output amount is zero
 * 4. testRevertFillInsufficientBalance - Tests that fill reverts when solver has insufficient balance
 * 5. testRevertFillOrderExpiredBeforeStart - Tests that fill reverts when order has not yet started
 * 6. testRevertFillOrderExpiredAfterEnd - Tests that fill reverts when order has already expired
 * 7. testRevertFillAlreadyFilled - Tests that fill reverts when attempting to fill an already filled order
 * 8. testFillFailDueToInsufficientOutput - Tests that fill reverts when using a hook that doesn't provide output tokens
 *
 * This test file focuses on edge cases and failure conditions for the fill operation,
 * using a custom FailingHook that intentionally fails to transfer tokens to simulate errors.
 */
import {IAori} from "../../contracts/IAori.sol";
import "./TestUtils.sol";

/**
 * @notice A failing hook contract that does nothing (i.e. it does not transfer any tokens).
 * This hook is used to simulate a fill in which the expected output tokens are not provided.
 */
contract FailingHook {
    function handleHook(address token, uint256 expectedAmount) external {
        // Intentionally do nothing.
    }
}

contract FillFailTest is TestUtils {
    FailingHook public failingHook;

    function setUp() public override {
        super.setUp();

        // Deploy the failing hook.
        failingHook = new FailingHook();

        // Whitelist the failing hook in both Aori instances
        localAori.addAllowedHook(address(failingHook));
        remoteAori.addAllowedHook(address(failingHook));
    }

    /// @notice Returns a default DstSolverData for a direct fill (no hook conversion).
    function defaultDstSolverData(address _preferredToken, uint256 _expectedAmount)
        internal
        pure
        returns (IAori.DstHook memory)
    {
        return IAori.DstHook({
            hookAddress: address(0),
            preferredToken: _preferredToken,
            instructions: "",
            preferedDstInputAmount: _expectedAmount
        });
    }

    /// @notice Test that fill reverts when the order's startTime is after its endTime.
    function testRevertFillInvalidTimeRange() public {
        vm.warp(1000); // Initial warp (for underflow safety)
        IAori.Order memory order = createValidOrder();
        // Set an invalid time range: startTime > endTime.
        order.startTime = 1000 + 1 days;
        order.endTime = 1000;
        // Warp time to be after the (invalid) startTime.
        vm.warp(order.startTime);

        vm.prank(solver);
        vm.expectRevert(bytes("Invalid end time"));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order's input amount is zero.
    function testRevertFillZeroInputAmount() public {
        IAori.Order memory order = createValidOrder();
        order.inputAmount = 0;
        vm.warp(order.startTime);
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid input amount"));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order's output amount is zero.
    function testRevertFillZeroOutputAmount() public {
        IAori.Order memory order = createValidOrder();
        order.outputAmount = 0;
        vm.warp(order.startTime);
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid output amount"));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the filler (solver) has insufficient balance of the output token.
    function testRevertFillInsufficientBalance() public {
        IAori.Order memory order = createValidOrder();
        // Reduce solver's balance by transferring nearly all tokens.
        vm.prank(solver);
        outputToken.transfer(address(0xdead), 999e18); // Leaves solver with ~1e18.

        // Ensure solver approves the transfer.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Warp time so that validations pass.
        vm.warp(order.startTime + 1);

        vm.prank(solver);
        vm.expectRevert(bytes("Insufficient balance"));
        remoteAori.fill(order);
    }

    /// @notice Test that fill reverts when the order has not yet started (filled too early).
    function testRevertFillOrderExpiredBeforeStart() public {
        vm.warp(100);
        IAori.Order memory order = createValidOrder();
        order.startTime = 200; // e.g. current time 100, start at 200
        order.endTime = 100 + 1 days;
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(bytes("Order not started"));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order has already expired.
    function testRevertFillOrderExpiredAfterEnd() public {
        uint256 warpTime = 100000;
        vm.warp(warpTime);
        IAori.Order memory order = createValidOrder();
        order.startTime = uint32(warpTime - 1 days);
        order.endTime = uint32(warpTime - 10);
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(bytes("Order has expired"));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when attempting to fill an order that has already been filled.
    function testRevertFillAlreadyFilled() public {
        IAori.Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);
        // Approve and perform the first (successful) fill.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        vm.prank(solver);
        remoteAori.fill(order);

        // A second attempt to fill the same order should revert with "Order not active".
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
     * @notice This test deposits a valid order on the Source Chain.
     *         On the Destination Chain it attempts to fill the order using a failing hook
     *         that does not transfer any output tokens. The fill should revert with the expected error.
     */
    function testFillFailDueToInsufficientOutput() public {
        // PHASE 1: Deposit on the Source Chain.
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit.
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a relayer.
        vm.prank(solver);
        localAori.deposit(order, signature);

        // PHASE 2: Attempt to fill on the Destination Chain with the failing hook.
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        // Prepare DstSolverData with the failing hook.
        // The instructions encode a call to FailingHook.handleHook but, as this hook does nothing,
        // the expected output tokens are not provided.
        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(failingHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(FailingHook.handleHook.selector, address(outputToken), 0),
            preferedDstInputAmount: order.outputAmount
        });

        // Approve remoteAori so the fill function can pull tokens.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.expectRevert("Hook must provide at least the expected output amount");
        vm.prank(solver);
        remoteAori.fill(order, dstData);
    }
}
