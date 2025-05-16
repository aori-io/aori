// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * HookFailuresTest - Tests various hook-related failure conditions in the Aori contract
 *
 * Test cases:
 * 1. testRevertFillHookFailure - Tests that fill reverts when the hook call fails
 * 2. testRevertFillInsufficientOutput - Tests that fill reverts when the hook returns insufficient output tokens
 * 3. testRevertDepositHookInsufficientApproval - Tests that deposit with a hook fails when there's insufficient approval
 * 4. testRevertDepositHookWithUnexpectedValue - Tests that deposit with a hook fails when msg.value is sent but not expected
 *
 * This test file focuses on edge cases involving hook interactions in the Aori protocol,
 * using custom hooks (FailingHook and PartialOutputHook) to simulate error conditions.
 */
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IAori} from "../../contracts/IAori.sol";
import "./TestUtils.sol";

/**
 * @title HookFailuresTest
 * @notice Tests hook-related failures in the Aori contract
 */
contract HookFailuresTest is TestUtils {
    FailingHook public failingHook;
    PartialOutputHook public partialOutputHook;

    function setUp() public override {
        super.setUp();

        // Deploy hook contracts
        failingHook = new FailingHook();
        partialOutputHook = new PartialOutputHook();
        outputToken.mint(address(partialOutputHook), 1e18); // Only give half the expected output

        // Whitelist both hooks in both Aori instances
        localAori.addAllowedHook(address(failingHook));
        remoteAori.addAllowedHook(address(failingHook));
        localAori.addAllowedHook(address(partialOutputHook));
        remoteAori.addAllowedHook(address(partialOutputHook));
    }

    /**
     * @notice Test that fill reverts when the hook call fails
     */
    function testRevertFillHookFailure() public {
        vm.chainId(remoteEid);
        IAori.Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);

        // Create DstSolverData with a failing hook
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

    /**
     * @notice Test that fill reverts when the hook returns insufficient output tokens
     */
    function testRevertFillInsufficientOutput() public {
        vm.chainId(remoteEid);
        IAori.Order memory order = createValidOrder();
        vm.warp(order.startTime + 1);

        // Create DstSolverData with a hook that only returns half the required output
        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(partialOutputHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(PartialOutputHook.partialTransfer.selector, address(outputToken), 1e18), // Only half
            preferedDstInputAmount: order.outputAmount
        });

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert(bytes("Hook must provide at least the expected output amount"));
        remoteAori.fill(order, dstData);
    }

    /**
     * @notice Test that deposit with a hook fails when there's insufficient approval
     */
    function testRevertDepositHookInsufficientApproval() public {
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Create SrcSolverData with a non-failing hook but no approval
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(failingHook),
            preferredToken: address(outputToken), // Different from input to take the hook path
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount since no conversion
            instructions: abi.encodeWithSelector(FailingHook.transfer.selector)
        });

        // No approval for the preferred token
        vm.prank(userA);
        // This will revert when the contract tries to transferFrom without approval
        vm.expectRevert();
        localAori.deposit(order, signature, srcData);
    }

    /**
     * @notice Test that deposit with a hook fails when called by a non-solver
     * @dev Replaces the previous test that checked for unexpected ETH since deposit is no longer payable
     */
    function testRevertDepositNonSolver() public {
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Create SrcSolverData with a valid hook
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(failingHook),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: 1000,
            instructions: abi.encodeWithSelector(FailingHook.transfer.selector)
        });

        // Approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Call directly from userA (not a solver)
        vm.prank(userA);
        vm.expectRevert("Invalid solver");
        localAori.deposit(order, signature, srcData);
    }
}

// Mock contract that always reverts when called
contract FailingHook {
    function alwaysFail() external pure {
        revert("Hook deliberately failed");
    }

    function transfer() external pure {
        // Would normally transfer tokens, but this function just succeeds
        // The test will fail earlier due to lack of approval
    }
}

// Mock contract that returns insufficient output tokens
contract PartialOutputHook {
    function partialTransfer(address token, uint256 amount) external {
        // Transfer only the specified amount to the caller
        IERC20(token).transfer(msg.sender, amount);
    }
}
