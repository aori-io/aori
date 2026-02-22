// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title Fee-on-Transfer Guard Tests
 * @notice Tests that the balance-delta checks in deposit and fill paths
 *         correctly revert when a fee-on-transfer (deflationary) token is used.
 * @dev Covers:
 *   1. deposit(Order, signature) with FOT input token  -> reverts
 *   2. fill(Order) with FOT output token               -> reverts
 *   3. Normal tokens still pass through the same paths  -> succeeds (sanity)
 */
import { TestUtils } from "./TestUtils.sol";
import { Order, OrderStatus } from "../../contracts/types/AoriTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MockFeeOnTransferERC20 } from "../Mock/MockFeeOnTransferERC20.sol";
import "../../contracts/types/AoriErrors.sol";

contract FeeOnTransferGuard_Test is TestUtils {
    MockFeeOnTransferERC20 public fotToken;

    uint128 public constant INPUT_AMOUNT = 1e18;
    uint128 public constant OUTPUT_AMOUNT = 2e18;

    function setUp() public override {
        super.setUp();
        fotToken = new MockFeeOnTransferERC20("FeeOnTransfer", "FOT", 10); // 10% fee
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DEPOSIT GUARD TESTS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice FOT input token on deposit must revert
    function testDepositRevertsWithFOTInputToken() public {
        fotToken.mint(userA, 10e18);

        Order memory order = createCustomOrder(
            userA,
            userA,
            address(fotToken),
            address(outputToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        fotToken.approve(address(localAori), INPUT_AMOUNT);

        vm.expectRevert(TransferAmountMismatch.selector);
        vm.prank(solver);
        localAori.deposit(order, signature);
    }

    /// @notice Normal input token on deposit should succeed
    function testDepositSucceedsWithNormalInputToken() public {
        Order memory order = createCustomOrder(
            userA,
            userA,
            address(inputToken),
            address(outputToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
        assertEq(localLens.getLockedBalances(userA, address(inputToken)), INPUT_AMOUNT, "Locked balance should match input amount");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FILL GUARD TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice FOT output token on fill must revert
    function testFillRevertsWithFOTOutputToken() public {
        // Deposit with normal input token first
        Order memory order = createCustomOrder(
            userA,
            userA,
            address(inputToken),
            address(fotToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solver);
        localAori.deposit(order, signature);

        // Solver attempts to fill with FOT output token
        fotToken.mint(solver, 10e18);

        vm.prank(solver);
        fotToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.expectRevert(TransferAmountMismatch.selector);
        vm.prank(solver);
        localAori.fill(order);
    }

    /// @notice Normal output token on fill should succeed (full single-chain swap)
    function testFillSucceedsWithNormalOutputToken() public {
        Order memory order = createCustomOrder(
            userA,
            userA,
            address(inputToken),
            address(outputToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solver);
        localAori.deposit(order, signature);

        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.prank(solver);
        localAori.fill(order);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Settled, "Order should be Settled");
        assertEq(outputToken.balanceOf(userA), OUTPUT_AMOUNT, "User should receive full output amount");
    }
}
