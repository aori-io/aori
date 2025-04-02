// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * SettlementTests - Tests for settlement functionality and array manipulation in the Aori protocol
 * 
 * Test cases:
 * 1. testRevertSettleNoOrders - Tests that settlement reverts when no orders have been filled
 * 2. testRevertSettleBeforeFill - Tests that settlement reverts when an order was deposited but not filled
 * 3. testBasicSettlement - Tests a basic settlement flow for a single order
 * 4. testArrayCleanup - Tests that the fills array is properly cleaned up after settlement
 * 5. testPartialSettlement - Tests partial settlement where only some orders are processed
 * 6. testMultipleSettlements - Tests multiple rounds of settlement
 * 
 * This test file verifies both error conditions for settlement operations and proper array 
 * manipulation during the settlement process. It ensures that filled orders are correctly
 * tracked, processed, and removed from the fills array after processing.
 */

import {Aori, IAori} from "../../contracts/Aori.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

/**
 * @title TestSettlementAori
 * @notice Extension of Aori contract for testing settlement-specific functionality
 */
contract TestSettlementAori is Aori {
    constructor(address _endpoint, address _owner, uint32 _eid, uint16 _maxFillsPerSettle)
        Aori(_endpoint, _owner, _eid, _maxFillsPerSettle)
    {}

    // Test-specific function to get the length of the fills array
    function getFillsLength(uint32 srcEid, address filler) external view returns (uint256) {
        return srcEidToFillerFills[srcEid][filler].length;
    }
    
    // Test-specific function to add an order to the fills array
    function addFill(uint32 srcEid, address filler, bytes32 orderId) external {
        srcEidToFillerFills[srcEid][filler].push(orderId);
    }
}

/**
 * @title SettlementTests
 * @notice Tests for settlement functionality and array manipulation in Aori
 */
contract SettlementTests is TestUtils {
    using OptionsBuilder for bytes;

    // Test-specific Aori contracts
    TestSettlementAori public testLocalAori;
    TestSettlementAori public testRemoteAori;
    
    function setUp() public override {
        super.setUp();
        
        // Deploy test-specific Aori contracts
        testLocalAori = new TestSettlementAori(address(endpoints[localEid]), address(this), localEid, MAX_FILLS_PER_SETTLE);
        testRemoteAori = new TestSettlementAori(address(endpoints[remoteEid]), address(this), remoteEid, MAX_FILLS_PER_SETTLE);
        
        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(testLocalAori);
        aoriInstances[1] = address(testRemoteAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        testLocalAori.setPeer(remoteEid, bytes32(uint256(uint160(address(testRemoteAori)))));
        testRemoteAori.setPeer(localEid, bytes32(uint256(uint160(address(testLocalAori)))));
        
        // Whitelist the solver and hook in both test contracts
        testLocalAori.addAllowedSolver(solver);
        testRemoteAori.addAllowedSolver(solver);
        testLocalAori.addAllowedHook(address(mockHook));
        testRemoteAori.addAllowedHook(address(mockHook));
    }

    /**
     * @notice Test that settlement reverts when no orders have been filled
     */
    function testRevertSettleNoOrders() public {
        // Switch to remote chain
        vm.chainId(remoteEid);
        
        // Attempt to settle with no filled orders
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        vm.expectRevert("No orders provided");
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

    /**
     * @notice Test that settlement reverts when an order was deposited but not filled
     */
    function testRevertSettleBeforeFill() public {
        // Create and deposit an order
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Try to settle when no fill has happened
        vm.chainId(remoteEid);
        
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        vm.expectRevert("No orders provided");
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

    /**
     * @notice Test basic settlement flow for a single order
     */
    function testBasicSettlement() public {
        // Create and deposit an order
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);
        bytes32 orderId = keccak256(abi.encode(order));

        vm.prank(userA);
        inputToken.approve(address(testLocalAori), order.inputAmount);
        
        vm.prank(solver);
        testLocalAori.deposit(order, signature);

        // Verify order is active
        assertEq(uint8(testLocalAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), 
                "Order should be active after deposit");

        // Fill the order
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);
        
        vm.prank(solver);
        outputToken.approve(address(testRemoteAori), order.outputAmount);
        
        vm.prank(solver);
        testRemoteAori.fill(order);

        // Verify order is filled
        assertEq(uint8(testRemoteAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Filled), 
                "Order should be filled after fill operation");

        // Get fills length before settlement
        uint256 fillsLengthBefore = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthBefore, 1, "Should have 1 fill before settlement");

        // Settle the order
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = testRemoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        testRemoteAori.settle{value: fee}(localEid, solver, options);

        // Get fills length after settlement
        uint256 fillsLengthAfter = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthAfter, 0, "Should have 0 fills after settlement");

        // Verify order is settled on source chain
        vm.chainId(localEid);
        assertEq(uint8(testLocalAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), 
                "Order should be settled after settlement");
    }
    
    /**
     * @notice Test that fills array is properly cleaned up after settlement
     */
    function testArrayCleanup() public {
        // Create 5 orders and add them to the fills array
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createValidOrder();
        bytes32 orderId = keccak256(abi.encode(order));
        
        uint256 numOrders = 5;
        for (uint256 i = 0; i < numOrders; i++) {
            testRemoteAori.addFill(localEid, solver, orderId);
        }
        
        // Verify fills array has 5 entries
        uint256 fillsLengthBefore = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthBefore, numOrders, "Should have numOrders fills before settlement");
        
        // Settle the orders
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = testRemoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        testRemoteAori.settle{value: fee}(localEid, solver, options);
        
        // Verify fills array is empty after settlement
        uint256 fillsLengthAfter = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthAfter, 0, "Should have 0 fills after settlement");
    }
    
    /**
     * @notice Test partial settlement where only some orders are processed
     */
    function testPartialSettlement() public {
        // Create MAX_FILLS_PER_SETTLE + 5 orders
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createValidOrder();
        bytes32 orderId = keccak256(abi.encode(order));
        
        uint256 totalOrders = MAX_FILLS_PER_SETTLE + 5;
        for (uint256 i = 0; i < totalOrders; i++) {
            testRemoteAori.addFill(localEid, solver, orderId);
        }
        
        // Verify fills array has the correct number of entries
        uint256 fillsLengthBefore = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthBefore, totalOrders, "Should have totalOrders fills before settlement");
        
        // Settle the orders
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = testRemoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        testRemoteAori.settle{value: fee}(localEid, solver, options);
        
        // Verify only MAX_FILLS_PER_SETTLE orders were processed
        uint256 fillsLengthAfter = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthAfter, 5, "Should have 5 fills remaining after settlement");
    }
    
    /**
     * @notice Test multiple rounds of settlement
     */
    function testMultipleSettlements() public {
        // Create MAX_FILLS_PER_SETTLE + 5 orders
        vm.chainId(remoteEid);
        
        IAori.Order memory order = createValidOrder();
        bytes32 orderId = keccak256(abi.encode(order));
        
        uint256 totalOrders = MAX_FILLS_PER_SETTLE + 5;
        for (uint256 i = 0; i < totalOrders; i++) {
            testRemoteAori.addFill(localEid, solver, orderId);
        }
        
        // First settlement round
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = testRemoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        testRemoteAori.settle{value: fee}(localEid, solver, options);
        
        // Verify first round processed MAX_FILLS_PER_SETTLE orders
        uint256 fillsLengthAfterFirst = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthAfterFirst, 5, "Should have 5 fills remaining after first settlement");
        
        // Second settlement round
        fee = testRemoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        
        vm.prank(solver);
        testRemoteAori.settle{value: fee}(localEid, solver, options);
        
        // Verify second round processed the remaining orders
        uint256 fillsLengthAfterSecond = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(fillsLengthAfterSecond, 0, "Should have 0 fills after second settlement");
    }
} 