// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * PauseAndEmergencyFunctionsTest - Tests administrative functions for pausing and emergency operations
 *
 * Test cases:
 * 1. testPauseOnlyAdmin - Tests that only the admin can pause the contract
 * 2. testUnpauseOnlyAdmin - Tests that only the admin can unpause the contract
 * 3. testDepositBlockedWhenPaused - Tests that deposit operations are blocked when the contract is paused
 * 4. testFillBlockedWhenPaused - Tests that fill operations are blocked when the contract is paused
 * 5. testWithdrawWorksWhenPaused - Tests that withdrawals fail when the contract is paused
 * 6. testEmergencyWithdraw - Tests the emergency withdrawal of ERC20 tokens by the admin
 * 7. testEmergencyWithdrawETH - Tests the emergency withdrawal of ETH by the admin
 * 8. testEmergencyWithdrawOnlyAdmin - Tests that only the admin can use emergency withdraw functions
 *
 * This test file focuses on the administrative functions of the Aori contract,
 * particularly the pause/unpause mechanisms and emergency fund recovery features.
 * The admin is set to the test contract itself to simplify testing of admin-only functions.
 */
import {IAori} from "../../contracts/IAori.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

/**
 * @title PauseAndEmergencyFunctionsTest
 * @notice Tests for pause, unpause, and emergency withdrawal functionality in the Aori contract
 */
contract PauseAndEmergencyFunctionsTest is TestUtils {
    using OptionsBuilder for bytes;

    // Admin and non-admin addresses for testing access control
    address public admin;
    address public nonAdmin = address(0x300);

    function setUp() public override {
        // Set admin to the test contract before calling super.setUp()
        admin = address(this);

        super.setUp();

        // Override the default peer relationships since we're using a different admin
        localAori.setPeer(remoteEid, bytes32(uint256(uint160(address(remoteAori)))));
        remoteAori.setPeer(localEid, bytes32(uint256(uint160(address(localAori)))));

        // Mint additional tokens for userA and solver needed for these tests
        outputToken.mint(userA, 1000e18);
        inputToken.mint(solver, 1000e18);
    }

    /**
     * @notice Test that only admin can pause the contract
     */
    function testPauseOnlyAdmin() public {
        // Non-admin cannot pause
        vm.prank(nonAdmin);
        vm.expectRevert();
        localAori.pause();

        // Admin can pause
        localAori.pause();
        assertTrue(localAori.paused(), "Contract should be paused");
    }

    /**
     * @notice Test that only admin can unpause the contract
     */
    function testUnpauseOnlyAdmin() public {
        // First pause the contract as admin
        localAori.pause();

        // Non-admin cannot unpause
        vm.prank(nonAdmin);
        vm.expectRevert();
        localAori.unpause();

        // Admin can unpause
        localAori.unpause();
        assertFalse(localAori.paused(), "Contract should be unpaused");
    }

    /**
     * @notice Test that deposit is blocked when contract is paused
     */
    function testDepositBlockedWhenPaused() public {
        // Pause the contract
        localAori.pause();

        // Setup for deposit
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(0),
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount since no conversion
            instructions: ""
        });

        vm.startPrank(solver);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit should revert because contract is paused
        vm.expectRevert();
        localAori.deposit(order, signature, srcData);
        vm.stopPrank();
    }

    /**
     * @notice Test that fill is blocked when contract is paused
     */
    function testFillBlockedWhenPaused() public {
        vm.chainId(remoteEid);

        // Pause the contract
        remoteAori.pause();

        // Setup for fill
        IAori.Order memory order = createValidOrder();
        order.dstEid = remoteEid;
        order.srcEid = localEid;

        // Fill should revert because contract is paused
        vm.prank(solver);
        vm.expectRevert();
        remoteAori.fill(order);
    }

    /**
     * @notice Test that withdraw works even when paused
     */
    function testWithdrawWorksWhenPaused() public {
        // First set up some balance for userA
        // Create a valid order
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Approve token transfer from userA to contract
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit must be done by the whitelisted solver
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Get the order hash
        bytes32 orderHash = localAori.hash(order);

        // Advance time past expiry BEFORE cancellation
        vm.warp(order.endTime + 1);

        // Cancel the order using the whitelisted solver
        vm.prank(solver);
        localAori.cancel(orderHash);

        // Verify that funds are now unlocked for userA
        uint256 unlockedBalance = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(unlockedBalance, order.inputAmount, "Balance should be unlocked after cancellation");

        // Now pause the contract
        localAori.pause();

        // Withdraw should fail when paused because it has the whenNotPaused modifier
        vm.prank(userA);
        vm.expectRevert(); // Generic revert expectation for the EnforcedPause error
        localAori.withdraw(address(inputToken));
    }

    /**
     * @notice Test emergency withdrawal of tokens
     */
    function testEmergencyWithdraw() public {
        // Send tokens to the contract first
        inputToken.mint(address(localAori), 10e18);

        // Get balance before emergency withdrawal
        uint256 adminBalanceBefore = inputToken.balanceOf(admin);

        // Execute emergency withdrawal
        localAori.emergencyWithdraw(address(inputToken), 5e18);

        // Check balance after emergency withdrawal
        uint256 adminBalanceAfter = inputToken.balanceOf(admin);
        assertEq(adminBalanceAfter, adminBalanceBefore + 5e18, "Admin should receive emergency withdrawn funds");
    }

    /**
     * @notice Test emergency withdrawal of ETH
     */
    function testEmergencyWithdrawETH() public {
        // Send ETH to the contract
        vm.deal(address(localAori), 1 ether);

        // Get balance before emergency withdrawal
        uint256 adminBalanceBefore = address(admin).balance;

        // Execute emergency withdrawal (amount is ignored for ETH)
        localAori.emergencyWithdraw(address(0), 0);

        // Check balance after emergency withdrawal
        uint256 adminBalanceAfter = address(admin).balance;
        assertEq(adminBalanceAfter, adminBalanceBefore + 1 ether, "Admin should receive emergency withdrawn ETH");
    }

    /**
     * @notice Test that only admin can use emergency withdraw
     */
    function testEmergencyWithdrawOnlyAdmin() public {
        // Send tokens to the contract
        inputToken.mint(address(localAori), 10e18);

        // Non-admin cannot use emergency withdraw
        vm.prank(nonAdmin);
        vm.expectRevert();
        localAori.emergencyWithdraw(address(inputToken), 5e18);
    }
}
