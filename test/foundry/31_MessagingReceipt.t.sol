// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {IAori} from "../../contracts/IAori.sol";
import {TestUtils} from "./TestUtils.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MessagingReceipt, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title MessagingReceiptTest
 * @notice Tests the capturing and emitting of MessagingReceipt information in events
 */
contract MessagingReceiptTest is TestUtils {
    // Test events matching IAori event signatures
    event SettleSent(uint32 indexed srcEid, address indexed filler, bytes payload, bytes32 guid, uint64 nonce, uint256 fee);
    event CancelSent(bytes32 indexed orderId, bytes32 guid, uint64 nonce, uint256 fee);
    
    // Mock values for testing
    bytes32 constant TEST_GUID = bytes32(uint256(0x123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0));
    uint64 constant TEST_NONCE = 12345678;
    uint256 constant TEST_FEE = 0.01 ether;
    uint256 constant REQUIRED_LZ_FEE = 0.3 ether; // Higher than the reported required fee (0.2 ETH)
    
    function setUp() public override {
        // Setup the test environment (tokens, contracts, etc.)
        super.setUp();
    }
    
    /**
     * @notice Tests that MessagingReceipt information is correctly included in SettleSent events
     */
    function testSettleSentReceiptInfo() public {
        // Create and deposit an order
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);
        
        // Deposit the order on the source chain
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Fill the order on the destination chain
        vm.chainId(remoteEid);
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);
        
        vm.prank(solver);
        remoteAori.fill(order);
        
        // Mock the quote function to return our fee
        vm.mockCall(
            address(remoteAori),
            abi.encodeWithSelector(remoteAori.quote.selector),
            abi.encode(REQUIRED_LZ_FEE)
        );
        
        // Use vm.recordLogs to capture emitted events
        vm.recordLogs();
        
        // Trigger the settle function with enough ETH to cover fees
        vm.deal(solver, REQUIRED_LZ_FEE); // Give the solver enough ETH
        vm.prank(solver);
        remoteAori.settle{value: REQUIRED_LZ_FEE}(order.srcEid, solver, defaultOptions());
        
        // Get the logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Look for SettleSent event
        bool foundEvent = false;
        for (uint i = 0; i < logs.length; i++) {
            // Check if this is our event's topic (keccak256 of event signature)
            if (logs[i].topics[0] == keccak256("SettleSent(uint32,address,bytes,bytes32,uint64,uint256)")) {
                // This is our event, now check the receipt fields (guid, nonce, fee)
                
                // Skip the first 32 bytes which contain array len for bytes, and extract guid, nonce and fee
                uint256 offset = 32 + 32; // Skip bytes length and payload
                bytes32 guid = abi.decode(slice(logs[i].data, offset, offset + 32), (bytes32));
                offset += 32;
                uint64 nonce = abi.decode(slice(logs[i].data, offset, offset + 32), (uint64));
                offset += 32;
                uint256 fee = abi.decode(slice(logs[i].data, offset, offset + 32), (uint256));
                
                // Now just check that the fields are non-empty/non-zero
                assertTrue(guid != bytes32(0), "GUID should not be empty");
                assertTrue(nonce > 0, "Nonce should be non-zero");
                assertTrue(fee > 0, "Fee should be non-zero");
                
                foundEvent = true;
                break;
            }
        }
        
        assertTrue(foundEvent, "SettleSent event with receipt info not found");
    }
    
    /**
     * @notice Tests that MessagingReceipt information is correctly included in CancelSent events
     */
    function testCancelSentReceiptInfo() public {
        // Create and deposit an order
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);
        bytes32 orderId = localAori.hash(order);
        
        // Deposit the order on the source chain
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Mock the quote function to return our fee
        vm.mockCall(
            address(remoteAori),
            abi.encodeWithSelector(remoteAori.quote.selector),
            abi.encode(REQUIRED_LZ_FEE)
        );
        
        // Warp past order expiry to allow cancellation
        vm.warp(order.endTime + 1);
        
        // Move to destination chain
        vm.chainId(remoteEid);
        
        // Use vm.recordLogs to capture emitted events
        vm.recordLogs();
        
        // Cancel from destination chain with enough ETH to cover fees
        vm.deal(solver, REQUIRED_LZ_FEE); // Give the solver enough ETH
        vm.prank(solver);
        remoteAori.cancel{value: REQUIRED_LZ_FEE}(orderId, order, defaultOptions());
        
        // Get the logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Look for CancelSent event
        bool foundEvent = false;
        for (uint i = 0; i < logs.length; i++) {
            // Check if this is our event's topic
            if (logs[i].topics[0] == keccak256("CancelSent(bytes32,bytes32,uint64,uint256)")) {
                // Extract parameters from data
                bytes32 guid = abi.decode(slice(logs[i].data, 0, 32), (bytes32));
                uint64 nonce = abi.decode(slice(logs[i].data, 32, 64), (uint64));
                uint256 fee = abi.decode(slice(logs[i].data, 64, 96), (uint256));
                
                // Check fields - just verify they're non-empty/non-zero
                assertTrue(guid != bytes32(0), "GUID should not be empty");
                assertTrue(nonce > 0, "Nonce should be non-zero");
                assertTrue(fee > 0, "Fee should be non-zero");
                
                foundEvent = true;
                break;
            }
        }
        
        assertTrue(foundEvent, "CancelSent event with receipt info not found");
    }
    
    /**
     * @notice Tests that local cancellations use the Cancel event instead of CancelSent
     */
    function testLocalCancelEmptyReceiptInfo() public {
        // Create and deposit a single-chain order (for local cancellation)
        IAori.Order memory order = createValidOrder();
        order.dstEid = order.srcEid; // Make it a single-chain order
        bytes memory signature = signOrder(order);
        bytes32 orderId = localAori.hash(order);
        
        // Deposit the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Warp past order expiry
        vm.warp(order.endTime + 1);
        
        // Use vm.recordLogs to capture emitted events
        vm.recordLogs();
        
        // Cancel locally
        vm.prank(solver);
        localAori.cancel(orderId);
        
        // Get the logs
        Vm.Log[] memory logs = vm.getRecordedLogs();
        
        // Look for Cancel event (not CancelSent) since this is a local cancellation
        bool foundCancelEvent = false;
        for (uint i = 0; i < logs.length; i++) {
            // Check if this is a Cancel event topic
            if (logs[i].topics[0] == keccak256("Cancel(bytes32)")) {
                // Verify the orderId matches
                bytes32 eventOrderId = logs[i].topics[1]; // First indexed parameter
                assertEq(eventOrderId, orderId, "Cancel event should contain correct order ID");
                foundCancelEvent = true;
                break;
            }
        }
        
        assertTrue(foundCancelEvent, "Cancel event not found for local cancellation");
        
        // Also verify that NO CancelSent event was emitted for local cancellation
        bool foundCancelSentEvent = false;
        for (uint i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == keccak256("CancelSent(bytes32,bytes32,uint64,uint256)")) {
                foundCancelSentEvent = true;
                break;
            }
        }
        
        assertFalse(foundCancelSentEvent, "CancelSent event should not be emitted for local cancellation");
    }
    
    /**
     * Helper function to slice a bytes array
     */
    function slice(bytes memory data, uint start, uint end) internal pure returns (bytes memory) {
        bytes memory result = new bytes(end - start);
        for (uint i = 0; i < end - start; i++) {
            result[i] = data[i + start];
        }
        return result;
    }
}