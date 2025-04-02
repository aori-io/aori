// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {IAori} from "../../contracts/IAori.sol";
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
        IAori.Order memory order = createValidOrder();
        vm.prank(userA);
        // Approve token transfer.
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        bytes memory errMsg = hex"8baa579f"; // InvalidSignature()
        vm.expectRevert(errMsg);
        localAori.deposit(order, "");
    }

    /// @notice Test that deposit reverts when an invalid signature is provided.
    function testRevertDepositInvalidSignature() public {
        IAori.Order memory order = createValidOrder();
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        // Create an invalid signature by signing with a different private key.
        bytes memory invalidSignature = signOrder(order, 0xABCD);
        vm.prank(solver);
        vm.expectRevert(bytes("InvalidSignature"));
        localAori.deposit(order, invalidSignature);
    }

    /// @notice Test that a deposit reverts when the same order is deposited twice.
    function testRevertDepositOrderAlreadyExists() public {
        IAori.Order memory order = createValidOrder();
        uint256 minPreferedTokenAmountOut = 1000;
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        inputToken.mint(address(localAori), minPreferedTokenAmountOut);
        // First deposit should succeed.
        vm.prank(solver);
        localAori.deposit(order, signature);
        // A second deposit with the same order should revert.
        vm.prank(solver);
        vm.expectRevert(bytes("Order already exists"));
        localAori.deposit(order, signature);
    }

    /// @notice Test that deposit reverts when the order parameters are invalid (e.g. an invalid endTime).
    function testRevertDepositInvalidParameters() public {
        IAori.Order memory order = createValidOrder();
        // Set an invalid endTime (endTime must be greater than uint32(block.timestamp)).
        order.endTime = uint32(block.timestamp);
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid end time"));
        localAori.deposit(order, signature);
    }

    // /// @notice Test that deposit reverts when a hook call fails.
    // /// To trigger the hook branch we set a nonzero hookAddress and non‐empty instructions, and we use
    // /// a preferred token different from the order's inputToken.
    // function testRevertDepositHookFailure() public {
    //     IAori.Order memory order = createValidOrder();
    //     // Prepare SrcSolverData to trigger the hook branch.
    //     // (order.inputToken != preferredToken so that the hook branch is taken)
    //     uint minPreferedTokenAmountOut = 1000;
    //     IAori.SrcHook memory srcData = IAori.SrcHook({
    //         hookAddress: address(failingHook),
    //         preferredToken: address(outputToken), // different from order.inputToken
    //         minPreferedTokenAmountOut: minPreferedTokenAmountOut, // Arbitrary minimum amount since no conversion
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
    function failHook(bytes memory) external payable {
        revert("Failing deposit hook");
    }
}
