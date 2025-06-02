// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * CancellationTests - Comprehensive tests for all order cancellation scenarios
 *
 * Test cases:
 * 
 * Source Chain Cancellations:
 * 1. testSingleChainCancelBySolver - Tests solver cancellation of single-chain order
 * 2. testSingleChainCancelByOffererAfterExpiry - Tests user cancellation after expiry
 * 3. testCrossChainCancelBySolverAfterExpiry - Tests solver cancellation with time restriction
 * 4. testEmergencyCancelByOwner - Tests the emergency cancellation by contract owner
 * 5. testSourceChainNegativeCases - Tests various invalid source chain cancellation attempts
 * 
 * Destination Chain Cancellations:
 * 6. testCrossChainSolverCancel - Tests solver cancellation from destination chain
 * 7. testCrossChainUserCancelAfterExpiry - Tests user cancellation after expiry 
 * 8. testCrossChainCancelFlowViaLayerZero - Tests full cross-chain cancellation flow
 * 9. testDestinationChainNegativeCases - Tests various invalid destination chain cancellation attempts
 */
import {IAori} from "../../contracts/IAori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

contract CancellationTests is TestUtils {
    using OptionsBuilder for bytes;
    
    function setUp() public override {
        super.setUp();
        vm.deal(solver, 1 ether); // Fund solver for paying fees
        vm.deal(userA, 1 ether); // Fund user for cross-chain fees
    }

    /**
     * @notice Create a single-chain order
     */
    function createSingleChainOrder() internal view returns (IAori.Order memory) {
        return IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(1e18),
            outputAmount: uint128(2e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: localEid // Same chain
        });
    }
    
    /**
     * @notice Create a cross-chain order
     */
    function createCrossChainOrder() internal view returns (IAori.Order memory) {
        return IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(1e18),
            outputAmount: uint128(2e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid // Different chain
        });
    }

    /************************************
     *     SOURCE CHAIN CANCELLATIONS   *
     ************************************/

    /**
     * @notice Tests that a solver can cancel a single-chain order at any time
     */
    function testSingleChainCancelBySolver() public {
        // PHASE 1: Deposit on the source chain
        vm.chainId(localEid);
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);

        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify locked balance
        uint256 lockedBefore = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBefore, order.inputAmount, "Locked balance should increase after deposit");

        // PHASE 2: Solver cancels without waiting for expiry
        bytes32 orderHash = localAori.hash(order);
        vm.prank(solver);
        localAori.cancel(orderHash);

        // Verify balances and order status - tokens should be transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests that an offerer can cancel their own single-chain order but only after expiry
     */
    function testSingleChainCancelByOffererAfterExpiry() public {
        vm.chainId(localEid);
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);

        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // Offerer tries to cancel before expiry (should fail)
        vm.prank(userA);
        vm.expectRevert("Only solver or offerer (after expiry) can cancel");
        localAori.cancel(orderHash);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        // Offerer can now cancel after expiry
        vm.prank(userA);
        localAori.cancel(orderHash);
        
        // Verify balances and status - tokens should be transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }
    
    /**
     * @notice Tests that a solver can cancel a cross-chain order, but only after expiry
     */
    function testCrossChainCancelBySolverAfterExpiry() public {
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // Solver tries to cancel before expiry (should fail)
        vm.prank(solver);
        vm.expectRevert("Cross-chain orders can only be cancelled by solver after expiry");
        localAori.cancel(orderHash);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        // Solver can now cancel after expiry
        vm.prank(solver);
        localAori.cancel(orderHash);
        
        // Verify balances and status - tokens should be transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests the emergency cancellation by contract owner
     */
    function testEmergencyCancelByOwner() public {
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // Non-owner cannot use emergency cancel
        address nonOwner = makeAddr("non-owner");
        vm.prank(nonOwner);
        vm.expectRevert(); // Owner check fails
        localAori.emergencyCancel(orderHash);
        
        // Owner can cancel without restriction (even cross-chain orders before expiry)
        localAori.emergencyCancel(orderHash);
        
        // Verify balances and status - tokens should be transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }
    
    /**
     * @notice Tests various negative source chain cancellation scenarios
     */
    function testSourceChainNegativeCases() public {
        vm.chainId(localEid);
        
        // Create orders
        IAori.Order memory singleChainOrder = createSingleChainOrder();
        IAori.Order memory crossChainOrder = createCrossChainOrder();
        
        // Sign orders
        bytes memory singleChainSig = signOrder(singleChainOrder);
        bytes memory crossChainSig = signOrder(crossChainOrder);
        
        // Approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Deposit orders
        vm.startPrank(solver);
        localAori.deposit(singleChainOrder, singleChainSig);
        localAori.deposit(crossChainOrder, crossChainSig);
        vm.stopPrank();
        
        bytes32 singleChainId = localAori.hash(singleChainOrder);
        bytes32 crossChainId = localAori.hash(crossChainOrder);
        
        // Create random address
        address randomUser = makeAddr("random");
        
        // Case 1: Random user cannot cancel single-chain order
        vm.prank(randomUser);
        vm.expectRevert("Only solver or offerer (after expiry) can cancel");
        localAori.cancel(singleChainId);
        
        // Case 2: Random user cannot cancel cross-chain order
        vm.prank(randomUser);
        vm.expectRevert("Cross-chain orders can only be cancelled by solver after expiry");
        localAori.cancel(crossChainId);
        
        // Case 3: Offerer cannot cancel cross-chain order even after expiry
        vm.warp(crossChainOrder.endTime + 1);
        vm.prank(userA);
        vm.expectRevert("Cross-chain orders can only be cancelled by solver after expiry");
        localAori.cancel(crossChainId);
        
        // Case 4: Cannot cancel non-existent order
        IAori.Order memory realOrder = createSingleChainOrder();
        realOrder.offerer = makeAddr("non-existent-user");
        bytes32 nonExistentId = localAori.hash(realOrder);

        vm.prank(solver);
        vm.expectRevert("Not on source chain");
        localAori.cancel(nonExistentId);
        
        // Case 5: Cannot cancel already cancelled order
        vm.prank(solver);
        localAori.cancel(singleChainId); // Cancel once
        vm.prank(solver);
        vm.expectRevert("Order not active");
        localAori.cancel(singleChainId); // Try to cancel again
    }

    /************************************
     *   DESTINATION CHAIN CANCELLATIONS *
     ************************************/

    /**
     * @notice Tests that a solver can cancel from destination chain any time
     */
    function testCrossChainSolverCancel() public {
        // PHASE 1: Deposit on source chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // Verify order is active on source chain
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Active),
            "Order should be active on source chain"
        );
        
        // PHASE 2: Switch to destination chain - solver cancels
        vm.chainId(remoteEid);
        
        // No need to advance time for solver
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
                uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);

        
        // Solver initiates cancellation
        vm.prank(solver);
        vm.deal(solver, cancelFee);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // Order should be cancelled on destination chain
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled on destination chain"
        );
    }
    
    /**
     * @notice Tests that a user can cancel from destination chain after expiry
     */
    function testCrossChainUserCancelAfterExpiry() public {
        // PHASE 1: Deposit on source chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // PHASE 2: Switch to destination chain
        vm.chainId(remoteEid);
        
        // User fails to cancel before expiry
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        vm.prank(userA);
        vm.expectRevert("Only whitelisted solver or offerer(after expiry) can cancel");
        remoteAori.cancel(orderHash, order, options);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        // Now user can cancel
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        vm.prank(userA);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // Order should be cancelled on destination chain
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled on destination chain"
        );
    }

    /**
     * @notice Tests full cross-chain cancellation flow from destination to source chain
     */
    function testCrossChainCancelFlowViaLayerZero() public {
        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // PHASE 1: Deposit on source chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // PHASE 2: Switch to destination chain and initiate cancellation
        vm.chainId(remoteEid);
        vm.warp(order.endTime + 1); // For user to cancel
        
        // Prepare options and get fee
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        
        // User initiates cancellation
        vm.prank(userA);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // Verify order marked as cancelled on destination chain
        assertEq(
            uint8(remoteAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled on destination chain"
        );
        
        // PHASE 3: Simulate LayerZero message receipt on source chain
        vm.chainId(localEid);
        
        // Create cancellation payload
        bytes memory cancelPayload = abi.encodePacked(uint8(1), orderHash); // Type 1 = Cancellation
        
        // Simulate LayerZero message
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-cancel-guid"),
            cancelPayload,
            address(0),
            bytes("")
        );
        
        // Verify balances and status on source chain - tokens should be transferred directly back to user
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        
        assertEq(lockedAfter, 0, "Locked balance should be zero after cancellation");
        assertEq(unlockedAfter, 0, "Unlocked balance should remain zero with direct transfer");
        assertEq(finalUserBalance, initialUserBalance, "User should have received their tokens back directly");
        
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled on source chain"
        );
        
        // PHASE 4: No withdrawal needed since tokens were transferred directly
        // User already has their tokens back
    }
    
    /**
     * @notice Tests various negative destination chain cancellation scenarios
     */
    function testDestinationChainNegativeCases() public {
        // PHASE 1: Set up orders on source chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        // Approve and deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // PHASE 2: Switch to destination chain for cancel tests
        vm.chainId(remoteEid);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // Case 1: Order hash doesn't match the provided order
        IAori.Order memory modifiedOrder = IAori.Order({
            offerer: order.offerer,
            recipient: order.recipient,
            inputToken: order.inputToken,
            outputToken: order.outputToken,
            inputAmount: uint128(2e18), // Different value
            outputAmount: order.outputAmount,
            startTime: order.startTime,
            endTime: order.endTime,
            srcEid: order.srcEid,
            dstEid: order.dstEid
        });
        
        vm.prank(solver);
        vm.expectRevert("Submitted order data doesn't match orderId");
        remoteAori.cancel(orderHash, modifiedOrder, options);
        
        // Case 2: Random user can't cancel before expiry
        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert("Only whitelisted solver or offerer(after expiry) can cancel");
        remoteAori.cancel(orderHash, order, options);
        
        // Case 3: Can't cancel after already cancelling
                uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);

        vm.prank(solver);
        vm.deal(solver, cancelFee);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // Already cancelled, can't cancel again
        vm.prank(solver);
        vm.expectRevert("Order not active");
        remoteAori.cancel(orderHash, order, options);
        
        // Case 4: Can't cancel after filling
        // (Would need to test this in another function as we'd need to fill, not cancel first)
    }
}
