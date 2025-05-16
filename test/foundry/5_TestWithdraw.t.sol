// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * WithdrawTest - Tests the withdraw functionality in the Aori contract
 *
 * Test cases:
 * 1. testWithdrawUnlockedFunds - Tests the full flow of depositing, canceling, and withdrawing tokens
 *    after cross-chain cancellation via LayerZero
 */
import "../../contracts/AoriUtils.sol";
import {IAori} from "../../contracts/IAori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

contract WithdrawTest is TestUtils {
    using OptionsBuilder for bytes;
    
    function setUp() public override {
        super.setUp();
        vm.deal(userA, 1e18); // Fund the account with 1 ETH
        vm.deal(solver, 1e18); // Fund solver for cross-chain fees
    }

    /**
     * @dev Returns a cross-chain cancelable order.
     */
    function createCrossChainOrder() internal view returns (IAori.Order memory order) {
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
            dstEid: remoteEid  // Cross-chain order
        });
    }

    /**
     * @notice Tests the full cross-chain flow of depositing, canceling via destination chain,
     * receiving the cancellation message, and withdrawing unlocked tokens.
     */
    function testWithdrawUnlockedFunds() public {
        // PHASE 1: Deposit on the Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();

        // Generate a valid signature
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a solver
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify locked balance increased
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount, "Locked balance should equal order inputAmount");

        // PHASE 2: Switch to destination chain and initiate cancellation
        vm.chainId(remoteEid);
        bytes32 orderHash = localAori.hash(order);
        
        // Advance time past expiry (for safety)
        vm.warp(order.endTime + 1);
        
        // Prepare cancellation options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
                uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);

        
        // Execute cancellation from destination chain
        vm.prank(solver);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // PHASE 3: Simulate LayerZero message receipt on source chain
        vm.chainId(localEid);
        
        // Create cancellation payload
        bytes memory cancelPayload = abi.encodePacked(uint8(1), orderHash); // Type 1 = Cancellation
        
        // Simulate LayerZero message receipt
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-cancel-guid"),
            cancelPayload,
            address(0),
            bytes("")
        );

        // Verify balances after cancellation
        uint256 lockedAfterCancel = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfterCancel = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(lockedAfterCancel, 0, "Locked balance should be zero after cancellation");
        assertEq(
            unlockedAfterCancel, order.inputAmount, "Unlocked balance should equal order inputAmount after cancellation"
        );

        // PHASE 4: Withdraw the unlocked funds
        uint256 userInitialBalance = inputToken.balanceOf(userA);
        vm.prank(userA);
        localAori.withdraw(address(inputToken));

        // Verify balances after withdrawal
        uint256 unlockedAfterWithdraw = localAori.getUnlockedBalances(userA, address(inputToken));
        assertEq(unlockedAfterWithdraw, 0, "Unlocked balance should be zero after withdrawal");

        uint256 userFinalBalance = inputToken.balanceOf(userA);
        assertEq(
            userFinalBalance, userInitialBalance + order.inputAmount, "User balance should increase by withdrawn amount"
        );
    }
}
