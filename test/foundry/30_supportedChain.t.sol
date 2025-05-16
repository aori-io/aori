// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TestUtils } from "./TestUtils.sol";
import { MockERC20 } from "../Mock/MockERC20.sol";
import { Aori, IAori } from "../../contracts/Aori.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @title SupportedChainTest
 * @notice Tests chain validation and support functionality for Aori contract
 * 
 * Test coverage:
 * - Adding valid supported chains with EID validation
 * - Preventing addition of invalid/unsupported EIDs
 * - Removing supported chains
 * - Deposit validation with supported/unsupported destination chains
 * - Permission checks for admin functions
 * - Current chain auto-support functionality
 */
contract SupportedChainTest is TestUtils {
    // Use real LayerZero endpoint IDs from docs
    uint32 constant ETHEREUM_EID = 30101;   // Ethereum Mainnet
    uint32 constant AVALANCHE_EID = 30106;  // Avalanche Mainnet  
    uint32 constant ARBITRUM_EID = 30110;   // Arbitrum Mainnet
    uint32 constant INVALID_EID = 999999;   // Non-existent EID
    
    function setUp() public override {
        // Call the parent setup to initialize the test environment
        super.setUp();
        
        // No need to set up local chain support as it's now done in the constructor
        
        // Clear any existing chain support for clean testing
        vm.startPrank(address(this)); // TestUtils is the owner
        localAori.removeSupportedChain(remoteEid);
        vm.stopPrank();
    }
    
    /**
     * @notice Tests adding a valid supported chain
     */
    function testAddValidSupportedChain() public {
        // Mock successful quote call for a real chain
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, ETHEREUM_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether) // Return a mock fee
        );
        
        // Add Ethereum as supported chain
        vm.prank(address(this)); // TestUtils is the owner
        localAori.addSupportedChain(ETHEREUM_EID);
        
        // Verify chain is supported
        bool isSupported = localAori.isSupportedChain(ETHEREUM_EID);
        assertTrue(isSupported, "Chain should be supported after adding");
    }
    
    /**
     * @notice Tests adding an invalid chain ID
     */
    function testAddInvalidChain() public {
        // Mock a failing quote call for invalid chain
        vm.mockCallRevert(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, INVALID_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode("LayerZero: invalid endpoint")
        );
        
        // Attempt to add invalid chain should revert
        vm.prank(address(this)); // TestUtils is the owner
        vm.expectRevert("Invalid or unsupported LayerZero EID");
        localAori.addSupportedChain(INVALID_EID);
        
        // Verify chain is not supported
        bool isSupported = localAori.isSupportedChain(INVALID_EID);
        assertFalse(isSupported, "Invalid chain should not be supported");
    }
    
    /**
     * @notice Tests removing a supported chain
     */
    function testRemoveSupportedChain() public {
        // First add a chain
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, AVALANCHE_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        
        vm.startPrank(address(this)); // TestUtils is the owner
        localAori.addSupportedChain(AVALANCHE_EID);
        
        // Verify it's supported
        assertTrue(localAori.isSupportedChain(AVALANCHE_EID), "Chain should be supported");
        
        // Remove the chain
        localAori.removeSupportedChain(AVALANCHE_EID);
        vm.stopPrank();
        
        // Verify it's no longer supported
        assertFalse(localAori.isSupportedChain(AVALANCHE_EID), "Chain should no longer be supported");
    }
    
    /**
     * @notice Tests that deposit rejects orders with unsupported destination chains
     */
    function testDepositWithUnsupportedDestination() public {
        // Create an order to an unsupported chain
        IAori.Order memory order = createCustomOrder(
            userA,                    // offerer
            userA,                    // recipient
            address(inputToken),      // inputToken 
            address(outputToken),     // outputToken
            1 ether,                  // inputAmount
            0.9 ether,                // outputAmount
            uint32(block.timestamp),  // startTime
            uint32(block.timestamp + 1 hours), // endTime
            localEid,                 // srcEid
            ARBITRUM_EID              // dstEid - not supported
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Attempt deposit should revert with unsupported destination
        vm.startPrank(solver);
        vm.expectRevert("Destination chain not supported");
        localAori.deposit(order, signature);
        vm.stopPrank();
    }
    
    /**
     * @notice Tests that deposit accepts orders with supported destination chains
     */
    function testDepositWithSupportedDestination() public {
        // Add the remote chain as supported
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, remoteEid, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        
        vm.prank(address(this));
        localAori.addSupportedChain(remoteEid);
        
        // Create a valid order using TestUtils helper
        IAori.Order memory order = createValidOrder();
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Deposit should succeed with supported destination
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order was created
        bytes32 orderId = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active");
    }
    
    /**
     * @notice Tests that only owner can add supported chains
     */
    function testOnlyOwnerCanAddSupportedChain() public {
        vm.prank(userA);
        vm.expectRevert();
        localAori.addSupportedChain(ETHEREUM_EID);
    }
    
    /**
     * @notice Tests that only owner can remove supported chains
     */
    function testOnlyOwnerCanRemoveSupportedChain() public {
        vm.prank(userA);
        vm.expectRevert();
        localAori.removeSupportedChain(localEid);
    }
    
    /**
     * @notice Tests that current chain's EID is automatically supported via constructor
     */
    function testCurrentChainAutoSupport() public view {
        // Verify current chain is supported without any explicit action
        assertTrue(localAori.isSupportedChain(localEid), "Current chain should be auto-supported");
    }
    
    /**
     * @notice Tests that current chain's EID is always valid without quote validation when re-added
     */
    function testCurrentChainAlwaysValid() public {
        // Create a fresh instance with local EID not supported
        vm.prank(address(this));
        localAori.removeSupportedChain(localEid);
        assertFalse(localAori.isSupportedChain(localEid), "Chain should not be supported after removal");
        
        // Add current chain without mocking quote call - should work without validation
        vm.prank(address(this));
        localAori.addSupportedChain(localEid);
        
        // Verify current chain is now supported
        assertTrue(localAori.isSupportedChain(localEid), "Current chain should be supported after adding");
    }
    
    /**
     * @notice Tests batch adding of supported chains with mixed valid and invalid EIDs
     */
    function testAddSupportedChainsBatch() public {
        // Create an array with valid and invalid EIDs
        uint32[] memory eids = new uint32[](4);
        eids[0] = ETHEREUM_EID;  // Valid
        eids[1] = INVALID_EID;   // Invalid
        eids[2] = AVALANCHE_EID; // Valid
        eids[3] = localEid;      // Valid (current chain)
        
        // Mock successful quote calls for valid chains
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, ETHEREUM_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, AVALANCHE_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        
        // Mock failing quote call for invalid chain
        vm.mockCallRevert(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, INVALID_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode("LayerZero: invalid endpoint")
        );
        
        // Call the batch function
        vm.prank(address(this));
        bool[] memory results = localAori.addSupportedChains(eids);
        
        // Verify results array
        assertTrue(results[0], "ETHEREUM_EID should be added successfully");
        assertFalse(results[1], "INVALID_EID should fail to add");
        assertTrue(results[2], "AVALANCHE_EID should be added successfully");
        assertTrue(results[3], "localEid should be added successfully");
        
        // Verify mapping state reflects results
        assertTrue(localAori.isSupportedChain(ETHEREUM_EID), "ETHEREUM_EID should be supported");
        assertFalse(localAori.isSupportedChain(INVALID_EID), "INVALID_EID should not be supported");
        assertTrue(localAori.isSupportedChain(AVALANCHE_EID), "AVALANCHE_EID should be supported");
        assertTrue(localAori.isSupportedChain(localEid), "localEid should be supported");
        
        // Additional check: verify transaction didn't revert despite one invalid EID
        assertTrue(true, "Transaction completed successfully despite invalid EID");
    }
}