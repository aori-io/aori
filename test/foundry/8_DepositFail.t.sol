// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * DepositFailTest - Tests failure conditions for the deposit functionality in the Aori contract
 *
 * Test cases:
 * 1. testRevertDepositEmptySignature - Tests that deposit reverts when an empty signature is provided
 * 2. testRevertDepositInvalidSignature - Tests that deposit reverts when an invalid signature is provided
 * 3. testRevertDepositOrderAlreadyExists - Tests that deposit reverts when the same order is deposited twice
 * 4. testRevertDepositInvalidParameters - Tests that deposit reverts when order parameters are invalid
 * 5. testRevertDepositHookFailure (commented out) - Tests that deposit reverts when a hook call fails
 *
 * This test file focuses on edge cases and failure conditions for the deposit operation,
 * using a custom FailingDepositHook that intentionally reverts to simulate errors.
 */
import { Order, OrderStatus, SrcHook, DstHook, Balance } from "../../contracts/types/AoriTypes.sol";
import { IAori } from "../../contracts/interfaces/IAori.sol";
import "../../contracts/types/AoriErrors.sol";
import "./TestUtils.sol";

/**
 * @title DepositFailTest
 * @notice Tests that the deposit function in Aori reverts when provided with invalid parameters.
 */
contract DepositFailTest is TestUtils {
    FailingDepositHook public failingHook; // Hook that always reverts

    function setUp() public override {
        super.setUp();

        // Deploy the failing deposit hook contract.
        failingHook = new FailingDepositHook();

        // Whitelist the failing hook in both Aori instances
        localAori.addAllowedHook(address(failingHook));
        remoteAori.addAllowedHook(address(failingHook));
    }

    //////////////////////////////////////////////////////////////
    // TESTS – DEPOSIT FAILURES
    //////////////////////////////////////////////////////////////

    /// @notice Test that deposit reverts when an empty signature is provided.
    function testRevertDepositEmptySignature() public {
        Order memory order = createValidOrder();
        vm.prank(userA);
        // Approve token transfer.
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        vm.expectRevert(InvalidSignature.selector);
        localAori.deposit(order, "");
    }

    /// @notice Test that deposit reverts when an invalid signature is provided.
    function testRevertDepositInvalidSignature() public {
        Order memory order = createValidOrder();
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        // Create an invalid signature by signing with a different private key.
        bytes memory invalidSignature = signOrder(order, 0xABCD);
        vm.prank(solver);
        vm.expectRevert(InvalidSignature.selector);
        localAori.deposit(order, invalidSignature);
    }

    /// @notice Test that a deposit reverts when the same order is deposited twice.
    function testRevertDepositOrderAlreadyExists() public {
        Order memory order = createValidOrder();
        uint256 minPreferredTokenAmountOut = 1000;
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        inputToken.mint(address(localAori), minPreferredTokenAmountOut);
        // First deposit should succeed.
        vm.prank(solver);
        localAori.deposit(order, signature);
        // A second deposit with the same order should revert.
        vm.prank(solver);
        vm.expectRevert(OrderAlreadyExists.selector);
        localAori.deposit(order, signature);
    }

    /// @notice Test that deposit reverts when the order parameters are invalid (e.g. an invalid endTime).
    function testRevertDepositInvalidParameters() public {
        Order memory order = createValidOrder();
        // Set an invalid endTime (endTime must be greater than uint32(block.timestamp)).
        uint32 startTime = order.startTime;
        uint32 endTime = uint32(block.timestamp);
        order.endTime = endTime;
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(InvalidEndTime.selector, startTime, endTime));
        localAori.deposit(order, signature);
    }

    // /// @notice Test that deposit reverts when a hook call fails.
    // /// To trigger the hook branch we set a nonzero hookAddress and non‐empty instructions, and we use
    // /// a preferred token different from the order's inputToken.
    // function testRevertDepositHookFailure() public {
    //     Order memory order = createValidOrder();
    //     // Prepare SrcSolverData to trigger the hook branch.
    //     // (order.inputToken != preferredToken so that the hook branch is taken)
    //     uint minPreferredTokenAmountOut = 1000;
    //     SrcHook memory srcData = SrcHook({
    //         hookAddress: address(failingHook),
    //         preferredToken: address(outputToken), // different from order.inputToken
    //         minPreferredTokenAmountOut: minPreferredTokenAmountOut, // Arbitrary minimum amount since no conversion
    //         instructions: abi.encodeWithSelector(FailingDepositHook.failHook.selector, address(outputToken), order.inputAmount)
    //     });
    //     bytes memory signature = signOrder(order);
    //     vm.prank(userA);
    //     inputToken.approve(address(localAori), order.inputAmount);
    //     vm.prank(solver);
    //     vm.expectRevert(bytes("Hook call failed"));
    //     localAori.deposit(order, signature, srcData);
    // }
}

//////////////////////////////////////////////////////////////
// FailingDepositHook
//
// A simple hook contract that always reverts when called.
// It is used to simulate a deposit where the hook call fails.
contract FailingDepositHook {
    function failHook(
        bytes memory
    ) external payable {
        revert("Failing deposit hook");
    }
}
