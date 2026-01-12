// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
import { Order, OrderStatus, SrcHook, DstHook, Balance } from "../../contracts/types/AoriTypes.sol";
import { IAori } from "../../contracts/interfaces/IAori.sol";
import "../../contracts/types/AoriErrors.sol";
import "./TestUtils.sol";

/**
 * @notice A failing hook contract that does nothing (i.e. it does not transfer any tokens).
 * This hook is used to simulate a fill in which the expected output tokens are not provided.
 */
contract FailingHook {
    function handleHook(
        address token,
        uint256 expectedAmount
    ) external {
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
        localAori.adminSetAllowedHook(address(failingHook), true);
        remoteAori.adminSetAllowedHook(address(failingHook), true);
    }

    /// @notice Returns a default DstSolverData for a direct fill (no hook conversion).
    function defaultDstSolverData(
        address _preferredToken,
        uint256 _expectedAmount
    ) internal pure returns (DstHook memory) {
        return
            DstHook({
                hookAddress: address(0), preferredToken: _preferredToken, instructions: "", preferredDstInputAmount: _expectedAmount
            });
    }

    /// @notice Test that fill reverts when the order's startTime is after its endTime.
    function testRevertFillInvalidTimeRange() public {
        vm.warp(1000); // Initial warp (for underflow safety)
        Order memory order = createValidOrder();
        // Set an invalid time range: startTime > endTime.
        uint32 startTime = 1000 + 1 days;
        uint32 endTime = 1000;
        order.startTime = startTime;
        order.endTime = endTime;
        // Warp time to be after the (invalid) startTime.
        vm.warp(order.startTime);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(InvalidEndTime.selector, startTime, endTime));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order's input amount is zero.
    function testRevertFillZeroInputAmount() public {
        Order memory order = createValidOrder();
        order.inputAmount = 0;
        vm.warp(order.startTime);
        vm.prank(solver);
        vm.expectRevert(InvalidInputAmount.selector);
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order's output amount is zero.
    function testRevertFillZeroOutputAmount() public {
        Order memory order = createValidOrder();
        order.outputAmount = 0;
        vm.warp(order.startTime);
        vm.prank(solver);
        vm.expectRevert(InvalidOutputAmount.selector);
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the filler (solver) has insufficient balance of the output token.
    function testRevertFillInsufficientBalance() public {
        Order memory order = createValidOrder();
        // Reduce solver's balance by transferring nearly all tokens.
        vm.prank(solver);
        outputToken.transfer(address(0xdead), 999e18); // Leaves solver with ~1e18.

        // Ensure solver approves the transfer.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Warp time so that validations pass.
        vm.warp(order.startTime + 1);

        vm.prank(solver);
        vm.expectRevert("Insufficient balance");
        remoteAori.fill(order);
    }

    /// @notice Test that fill reverts when the order has not yet started (filled too early).
    function testRevertFillOrderExpiredBeforeStart() public {
        uint256 currentTime = 100;
        vm.warp(currentTime);
        Order memory order = createValidOrder();
        uint32 startTime = 200; // e.g. current time 100, start at 200
        order.startTime = startTime;
        order.endTime = 100 + 1 days;
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(OrderNotStarted.selector, startTime, currentTime));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when the order has already expired.
    function testRevertFillOrderExpiredAfterEnd() public {
        uint256 warpTime = 100000;
        vm.warp(warpTime);
        Order memory order = createValidOrder();
        order.startTime = uint32(warpTime - 1 days);
        uint32 endTime = uint32(warpTime - 10);
        order.endTime = endTime;
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(OrderExpired.selector, endTime, warpTime));
        remoteAori.fill(order, defaultDstSolverData(order.outputToken, order.outputAmount));
    }

    /// @notice Test that fill reverts when attempting to fill an order that has already been filled.
    function testRevertFillAlreadyFilled() public {
        Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);
        // Approve and perform the first (successful) fill.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        vm.prank(solver);
        remoteAori.fill(order);

        // A second attempt to fill the same order should revert with OrderAlreadyProcessed.
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(OrderAlreadyProcessed.selector, OrderStatus.Filled));
        remoteAori.fill(order);

        // Verify order status
        bytes32 orderHash = remoteAori.hash(order);
        assertEq(uint8(remoteAori.orderStatus(orderHash)), uint8(OrderStatus.Filled), "Order should be in filled state");
    }

    /**
     * @notice This test deposits a valid order on the Source Chain.
     *         On the Destination Chain it attempts to fill the order using a failing hook
     *         that does not transfer any output tokens. The fill should revert with the expected error.
     */
    function testFillFailDueToInsufficientOutput() public {
        // PHASE 1: Deposit on the Source Chain.
        vm.chainId(localEid);
        Order memory order = createValidOrder();
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
        DstHook memory dstData = DstHook({
            hookAddress: address(failingHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(FailingHook.handleHook.selector, address(outputToken), 0),
            preferredDstInputAmount: order.outputAmount
        });

        // Approve remoteAori so the fill function can pull tokens.
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.expectRevert(abi.encodeWithSelector(InsufficientDstHookOutput.selector, order.outputAmount, 0));
        vm.prank(solver);
        remoteAori.fill(order, dstData);
    }
}
