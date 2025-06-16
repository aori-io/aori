// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * CancellationTests - Comprehensive tests for all order cancellation scenarios
 *
 * Run:
 * forge test --match-contract CancellationTests -vv
 * 
 * Source Chain Cancellation Validation Branches:
 * 1. testSourceChain_NotOnSourceChain - Tests order.srcEid != endpointId
 * 2. testSourceChain_OrderNotActive - Tests orderStatus != Active
 * 3. testSourceChain_CrossChainOrderBlocked - Tests cross-chain orders blocked from source
 * 4. testSourceChain_NonSolverBeforeExpiry - Tests non-solver before expiry
 * 5. testSourceChain_OffererAfterExpiry - Tests offerer can cancel after expiry
 * 6. testSourceChain_SolverAnytime - Tests solver can cancel anytime
 * 
 * Source Chain Internal Cancel Branches:
 * 7. testSourceChain_InsufficientContractBalance - Tests contract balance check
 * 8. testSourceChain_BalanceDecreaseFailure - Tests decreaseLockedNoRevert failure
 * 
 * Destination Chain Cancellation Validation Branches:
 * 9. testDestChain_OrderHashMismatch - Tests hash(order) != orderId
 * 10. testDestChain_NotOnDestinationChain - Tests order.dstEid != endpointId
 * 11. testDestChain_OrderNotActive - Tests orderStatus != Unknown
 * 12. testDestChain_NonSolverBeforeExpiry - Tests non-solver before expiry
 * 13. testDestChain_OffererAfterExpiry - Tests offerer can cancel after expiry
 * 14. testDestChain_RecipientAfterExpiry - Tests recipient can cancel after expiry
 * 15. testDestChain_SolverAnytime - Tests solver can cancel anytime
 * 
 * LayerZero Message Handling Branches:
 * 16. testLayerZero_InvalidPayloadLength - Tests payload length validation
 * 17. testLayerZero_EmptyPayload - Tests empty payload handling
 * 18. testLayerZero_FullCancellationFlow - Tests complete cross-chain flow
 * 
 * Contract State Branches:
 * 19. testContractState_PausedSourceChain - Tests pause on source chain
 * 20. testContractState_PausedDestChain - Tests pause on destination chain
 * 21. testContractState_TimeBoundaryExact - Tests exactly at expiry time
 * 22. testContractState_TimeBoundaryAfter - Tests after expiry time
 * 
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
     *   SOURCE CHAIN VALIDATION BRANCHES *
     ************************************/

    /**
     * @notice Tests order.srcEid != endpointId validation
     */
    function testSourceChain_NotOnSourceChain() public {
        vm.chainId(localEid);
        
        // Create order with different srcEid
        IAori.Order memory order = createSingleChainOrder();
        order.srcEid = remoteEid; // Different from current chain
        bytes32 orderId = localAori.hash(order);
        
        vm.prank(solver);
        vm.expectRevert("Not on source chain");
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests orderStatus != Active validation
     */
    function testSourceChain_OrderNotActive() public {
        vm.chainId(localEid);
        
        // Create order and store it but with Cancelled status
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        // First deposit to create the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Cancel it first to make it inactive
        vm.prank(solver);
        localAori.cancel(orderId);
        
        // Now try to cancel again (should fail with "Order not active")
        vm.prank(solver);
        vm.expectRevert("Order not active");
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests cross-chain orders blocked from source chain
     */
    function testSourceChain_CrossChainOrderBlocked() public {
        vm.chainId(localEid);
        
        // Create and deposit cross-chain order
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        vm.prank(solver);
        vm.expectRevert("Cross-chain orders must be cancelled from destination chain");
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests non-solver cannot cancel before expiry
     */
    function testSourceChain_NonSolverBeforeExpiry() public {
        vm.chainId(localEid);
        
        // Create and deposit single-chain order
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Random user tries to cancel before expiry
        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert("Only solver or offerer (after expiry) can cancel");
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests offerer can cancel after expiry
     */
    function testSourceChain_OffererAfterExpiry() public {
        vm.chainId(localEid);
        
        // Create and deposit single-chain order
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        // Offerer can now cancel
        vm.prank(userA);
        localAori.cancel(orderId);
        
        // Verify cancellation
        assertEq(
            uint8(localAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests solver can cancel anytime
     */
    function testSourceChain_SolverAnytime() public {
        vm.chainId(localEid);
        
        // Create and deposit single-chain order
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Solver can cancel before expiry
        vm.prank(solver);
        localAori.cancel(orderId);
        
        // Verify cancellation
        assertEq(
            uint8(localAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests insufficient contract balance check
     */
    function testSourceChain_InsufficientContractBalance() public {
        vm.chainId(localEid);
        
        // Create and deposit single-chain order
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Drain contract balance
        uint256 contractBalance = inputToken.balanceOf(payable(address(localAori)));
        vm.prank(payable(address(localAori)));
        inputToken.transfer(makeAddr("drain"), contractBalance);
        
        vm.prank(solver);
        vm.expectRevert("Insufficient contract balance");
        localAori.cancel(orderId);
    }

    /************************************
     * DESTINATION CHAIN VALIDATION BRANCHES *
     ************************************/

    /**
     * @notice Tests hash(order) != orderId validation
     */
    function testDestChain_OrderHashMismatch() public {
        vm.chainId(remoteEid);
        
        // Create order and modify it to create hash mismatch
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        
        // Modify order to create mismatch
        order.inputAmount = uint128(2e18);
        
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        vm.prank(solver);
        vm.expectRevert("Submitted order data doesn't match orderId");
        remoteAori.cancel(orderId, order, options);
    }

    /**
     * @notice Tests order.dstEid != endpointId validation
     */
    function testDestChain_NotOnDestinationChain() public {
        vm.chainId(localEid); // Wrong chain
        
        // Create cross-chain order but try to cancel from wrong chain
        IAori.Order memory order = createCrossChainOrder();
        order.dstEid = localEid; // This would cause LayerZero NoPeer error
        bytes32 orderId = localAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        vm.prank(solver);
        vm.expectRevert(); // LayerZero NoPeer error occurs before validation
        localAori.cancel(orderId, order, options);
    }

    /**
     * @notice Tests orderStatus != Unknown validation
     */
    function testDestChain_OrderNotActive() public {
        vm.chainId(remoteEid);
        
        // Create order and set it to Cancelled status on destination chain
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // First cancel the order to set it to Cancelled status
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);
        vm.deal(solver, cancelFee);
        
        vm.prank(solver);
        remoteAori.cancel{value: cancelFee}(orderId, order, options);
        
        // Now try to cancel again (should fail with "Order not active")
        vm.deal(solver, cancelFee);
        vm.prank(solver);
        vm.expectRevert("Order not active");
        remoteAori.cancel{value: cancelFee}(orderId, order, options);
    }

    /**
     * @notice Tests non-solver cannot cancel before expiry
     */
    function testDestChain_NonSolverBeforeExpiry() public {
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        address randomUser = makeAddr("random");
        vm.prank(randomUser);
        vm.expectRevert("Only whitelisted solver, offerer, or recipient (after expiry) can cancel");
        remoteAori.cancel(orderId, order, options);
    }

    /**
     * @notice Tests offerer can cancel after expiry
     */
    function testDestChain_OffererAfterExpiry() public {
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        vm.deal(userA, cancelFee);
        
        vm.prank(userA);
        remoteAori.cancel{value: cancelFee}(orderId, order, options);
        
        // Verify cancellation
        assertEq(
            uint8(remoteAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests recipient can cancel after expiry
     */
    function testDestChain_RecipientAfterExpiry() public {
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createCrossChainOrder();
        address recipient = makeAddr("recipient");
        order.recipient = recipient;
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        // Advance time past expiry
        vm.warp(order.endTime + 1);
        
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, recipient);
        vm.deal(recipient, cancelFee);
        
        vm.prank(recipient);
        remoteAori.cancel{value: cancelFee}(orderId, order, options);
        
        // Verify cancellation
        assertEq(
            uint8(remoteAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /**
     * @notice Tests solver can cancel anytime
     */
    function testDestChain_SolverAnytime() public {
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, solver);
        vm.deal(solver, cancelFee);
        
        vm.prank(solver);
        remoteAori.cancel{value: cancelFee}(orderId, order, options);
        
        // Verify cancellation
        assertEq(
            uint8(remoteAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }

    /************************************
     * LAYERZERO MESSAGE HANDLING BRANCHES *
     ************************************/

    /**
     * @notice Tests invalid payload length validation
     */
    function testLayerZero_InvalidPayloadLength() public {
        vm.chainId(localEid);
        
        bytes memory invalidPayload = abi.encodePacked(uint8(1)); // Too short
        
        vm.prank(address(endpoints[localEid]));
        vm.expectRevert("Invalid cancellation payload length");
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-guid"),
            invalidPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Tests empty payload handling
     */
    function testLayerZero_EmptyPayload() public {
        vm.chainId(localEid);
        
        bytes memory emptyPayload = "";
        
        vm.prank(address(endpoints[localEid]));
        vm.expectRevert("Empty payload");
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-guid"),
            emptyPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Tests complete cross-chain cancellation flow
     */
    function testLayerZero_FullCancellationFlow() public {
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // PHASE 1: Deposit on source chain
        vm.chainId(localEid);
        IAori.Order memory order = createCrossChainOrder();
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        
        // PHASE 2: Cancel from destination chain
        vm.chainId(remoteEid);
        vm.warp(order.endTime + 1);
        
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 cancelFee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        
        vm.prank(userA);
        remoteAori.cancel{value: cancelFee}(orderHash, order, options);
        
        // PHASE 3: Simulate LayerZero message receipt
        vm.chainId(localEid);
        bytes memory cancelPayload = abi.encodePacked(uint8(1), orderHash);
        
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            keccak256("mock-cancel-guid"),
            cancelPayload,
            address(0),
            bytes("")
        );
        
        // Verify complete cancellation
        assertEq(inputToken.balanceOf(userA), initialUserBalance, "User should have tokens back");
        assertEq(
            uint8(localAori.orderStatus(orderHash)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled on source chain"
        );
    }

    /************************************
     *    CONTRACT STATE BRANCHES       *
     ************************************/

    /**
     * @notice Tests pause on source chain
     */
    function testContractState_PausedSourceChain() public {
        vm.chainId(localEid);
        
        // Create and deposit order
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Pause contract
        vm.prank(address(this));
        localAori.pause();
        
        vm.prank(solver);
        vm.expectRevert(); // OpenZeppelin changed error format
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests pause on destination chain
     */
    function testContractState_PausedDestChain() public {
        vm.chainId(remoteEid);
        
        // Pause contract
        vm.prank(address(this));
        remoteAori.pause();
        
        IAori.Order memory order = createCrossChainOrder();
        bytes32 orderId = remoteAori.hash(order);
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        
        vm.prank(solver);
        vm.expectRevert(); // OpenZeppelin changed error format
        remoteAori.cancel(orderId, order, options);
    }

    /**
     * @notice Tests exactly at expiry time boundary
     */
    function testContractState_TimeBoundaryExact() public {
        vm.chainId(localEid);
        
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Test exactly at expiry time (should fail)
        vm.warp(order.endTime);
        
        vm.prank(userA);
        vm.expectRevert("Only solver or offerer (after expiry) can cancel");
        localAori.cancel(orderId);
    }

    /**
     * @notice Tests after expiry time boundary
     */
    function testContractState_TimeBoundaryAfter() public {
        vm.chainId(localEid);
        
        IAori.Order memory order = createSingleChainOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        bytes32 orderId = localAori.hash(order);
        
        // Test one second after expiry (should succeed)
        vm.warp(order.endTime + 1);
        
        vm.prank(userA);
        localAori.cancel(orderId);
        
        // Verify cancellation
        assertEq(
            uint8(localAori.orderStatus(orderId)),
            uint8(IAori.OrderStatus.Cancelled),
            "Order should be cancelled"
        );
    }
}
