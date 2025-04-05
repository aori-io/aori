// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * CancelSuccessTest - Tests the order cancellation functionality in the Aori contract
 *
 * Test cases:
 * 1. testCancelSuccess - Tests source chain cancellation (srcCancel)
 *    - Verifies tokens are unlocked on the source chain
 *    - Confirms order status changes to Cancelled
 *
 * 2. testCrossChainCancelSuccess - Tests full cross-chain cancellation flow (dstCancel)
 *    - Deposits order on source chain
 *    - Cancels from destination chain
 *    - Simulates LayerZero message delivery
 *    - Verifies tokens are unlocked on the source chain
 *    - Tests withdrawal of unlocked tokens
 */
import {IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

contract CancelSuccessTest is TestUtils {
    using OptionsBuilder for bytes;
    
    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Tests that cancellation unlocks the deposit on the source chain.
     *
     * Flow:
     * 1. Deposits an order on the source chain
     * 2. Verifies the locked balance for userA increases by order.inputAmount
     * 3. Whitelisted solver calls srcCancel
     * 4. Verifies the locked balance is zero and the unlocked balance for userA is updated
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

    /**
     * @notice Tests end-to-end cross-chain cancellation flow from destination to source chain
     *
     * Flow:
     * 1. Deposits an order on the source chain
     * 2. Verifies the locked balance increases
     * 3. Switches to destination chain
     * 4. Initiates cancellation from destination chain (dstCancel)
     * 5. Verifies the cancellation message is sent via LayerZero
     * 6. Simulates the message being received on source chain
     * 7. Verifies the order is cancelled and tokens unlocked on the source chain
     * 8. Tests the full withdrawal flow to confirm tokens return to the user
     */
    function testCrossChainCancelSuccess() public {
        // Store the user's initial token balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // PHASE 1: Deposit on the Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit the order via a relayer
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify that the locked balance has increased
        uint256 lockedBefore = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBefore, order.inputAmount, "Locked balance not updated after deposit");
        
        bytes32 orderHash = localAori.hash(order);
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Active),
            "Order should be in active state after deposit"
        );

        // PHASE 2: Switch to destination chain and initiate cancellation
        vm.chainId(remoteEid);
        
        // Prepare LayerZero options for cancellation
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // Get the fee for cancellation
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);
        
        // Fund the solver with ETH for the fee
        vm.deal(solver, cancelFee);
        
        // The solver initiates cancellation from destination chain
        vm.startPrank(solver);
        
        // Verify order status on destination chain before cancellation
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Unknown),
            "Order should be unknown on dst chain before cancellation"
        );
        
        // Call dstCancel to send the cancellation message
        remoteAori.dstCancel{value: cancelFee}(orderHash, order, options);
        
        // Verify order is marked as cancelled on destination chain
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be in cancelled state on dst chain"
        );
        
        vm.stopPrank();

        // PHASE 3: Simulate receiving the LayerZero message on source chain
        vm.chainId(localEid);
        
        // Create cancellation payload
        bytes memory cancelPayload = abi.encodePacked(uint8(1), orderHash); // Type 1 = Cancellation
        
        // Mock receiving the message from LayerZero on the source chain
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-cancellation-guid"),
            cancelPayload,
            address(0),
            bytes("")
        );

        // PHASE 4: Verify the order is cancelled and tokens unlocked on source chain
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));

        assertEq(lockedAfter, 0, "User input tokens should be unlocked after cross-chain cancel");
        assertEq(unlockedAfter, order.inputAmount, "User's unlocked balance should contain the order amount");
        
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be in cancelled state on source chain after lzReceive"
        );
        
        // PHASE 5: Verify user can withdraw the unlocked tokens
        vm.prank(userA);
        localAori.withdraw(address(inputToken));
        
        // Check that the user's balance is now equal to their initial balance + the unlocked amount
        uint256 expectedBalance = initialUserBalance;
        assertEq(
            inputToken.balanceOf(userA),
            expectedBalance,
            "User should be able to withdraw unlocked tokens after cancellation"
        );
        
        assertEq(
            localAori.getUnlockedBalances(userA, address(inputToken)),
            0,
            "Unlocked balance should be zero after withdrawal"
        );
    }
}
