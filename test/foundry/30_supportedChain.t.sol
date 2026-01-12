// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Test.sol";
import "forge-std/console.sol";
import { TestUtils } from "./TestUtils.sol";
import { Order, OrderStatus, SrcHook, DstHook, Balance } from "../../contracts/types/AoriTypes.sol";
import { MockERC20 } from "../Mock/MockERC20.sol";
import { Aori, IAori } from "../../contracts/Aori.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import "../../contracts/types/AoriErrors.sol";

/**
 * @title SupportedChainTest
 * @notice Tests chain validation and support functionality for Aori contract
 *
 * Test coverage:
 * - Adding supported chains
 * - Removing supported chains
 * - Deposit validation with supported/unsupported destination chains
 * - Permission checks for admin functions
 * - Current chain auto-support functionality
 */
contract SupportedChainTest is TestUtils {
    // Use real LayerZero endpoint IDs from docs
    uint32 constant ETHEREUM_EID = 30101; // Ethereum Mainnet
    uint32 constant AVALANCHE_EID = 30106; // Avalanche Mainnet
    uint32 constant ARBITRUM_EID = 30110; // Arbitrum Mainnet

    function setUp() public override {
        // Call the parent setup to initialize the test environment
        super.setUp();

        // No need to set up local chain support as it's now done in the constructor

        // Clear any existing chain support for clean testing
        vm.startPrank(address(this)); // TestUtils is the owner
        localAori.adminSetSupportedChain(remoteEid, false);
        vm.stopPrank();
    }

    /**
     * @notice Tests adding a valid supported chain
     */
    function testAddValidSupportedChain() public {
        // Add Ethereum as supported chain
        vm.prank(address(this)); // TestUtils is the owner
        localAori.adminSetSupportedChain(ETHEREUM_EID, true);

        // Verify chain is supported
        bool isSupported = localAori.isSupportedChain(ETHEREUM_EID);
        assertTrue(isSupported, "Chain should be supported after adding");
    }

    /**
     * @notice Tests removing a supported chain
     */
    function testRemoveSupportedChain() public {
        // First add a chain
        vm.startPrank(address(this)); // TestUtils is the owner
        localAori.adminSetSupportedChain(AVALANCHE_EID, true);

        // Verify it's supported
        assertTrue(localAori.isSupportedChain(AVALANCHE_EID), "Chain should be supported");

        // Remove the chain
        localAori.adminSetSupportedChain(AVALANCHE_EID, false);
        vm.stopPrank();

        // Verify it's no longer supported
        assertFalse(localAori.isSupportedChain(AVALANCHE_EID), "Chain should no longer be supported");
    }

    /**
     * @notice Tests that deposit rejects orders with unsupported destination chains
     */
    function testDepositWithUnsupportedDestination() public {
        // Create an order to an unsupported chain
        Order memory order = createCustomOrder(
            userA, // offerer
            userA, // recipient
            address(inputToken), // inputToken
            address(outputToken), // outputToken
            1 ether, // inputAmount
            0.9 ether, // outputAmount
            uint32(block.timestamp), // startTime
            uint32(block.timestamp + 1 hours), // endTime
            localEid, // srcEid
            ARBITRUM_EID // dstEid - not supported
        );

        // Generate signature
        bytes memory signature = signOrder(order);

        // Approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);

        // Attempt deposit should revert with unsupported destination
        vm.startPrank(solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotSupported.selector, ARBITRUM_EID));
        localAori.deposit(order, signature);
        vm.stopPrank();
    }

    /**
     * @notice Tests that deposit accepts orders with supported destination chains
     */
    function testDepositWithSupportedDestination() public {
        // Add the remote chain as supported
        vm.prank(address(this));
        localAori.adminSetSupportedChain(remoteEid, true);

        // Create a valid order using TestUtils helper
        Order memory order = createValidOrder();

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
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(OrderStatus.Active), "Order should be active");
    }

    /**
     * @notice Tests that only owner can add supported chains
     */
    function testOnlyOwnerCanAddSupportedChain() public {
        vm.prank(userA);
        vm.expectRevert();
        localAori.adminSetSupportedChain(ETHEREUM_EID, true);
    }

    /**
     * @notice Tests that only owner can remove supported chains
     */
    function testOnlyOwnerCanRemoveSupportedChain() public {
        vm.prank(userA);
        vm.expectRevert();
        localAori.adminSetSupportedChain(localEid, false);
    }

    /**
     * @notice Tests that current chain's EID is automatically supported via constructor
     */
    function testCurrentChainAutoSupport() public view {
        // Verify current chain is supported without any explicit action
        assertTrue(localAori.isSupportedChain(localEid), "Current chain should be auto-supported");
    }

    /**
     * @notice Tests that current chain's EID is always valid when re-added
     */
    function testCurrentChainAlwaysValid() public {
        // Create a fresh instance with local EID not supported
        vm.prank(address(this));
        localAori.adminSetSupportedChain(localEid, false);
        assertFalse(localAori.isSupportedChain(localEid), "Chain should not be supported after removal");

        // Add current chain - should work
        vm.prank(address(this));
        localAori.adminSetSupportedChain(localEid, true);

        // Verify current chain is now supported
        assertTrue(localAori.isSupportedChain(localEid), "Current chain should be supported after adding");
    }

    /**
     * @notice Tests batch adding of supported chains
     */
    function testAddSupportedChainsBatch() public {
        // Add multiple chains one by one
        vm.startPrank(address(this));
        localAori.adminSetSupportedChain(ETHEREUM_EID, true);
        localAori.adminSetSupportedChain(AVALANCHE_EID, true);
        localAori.adminSetSupportedChain(localEid, true);
        vm.stopPrank();

        // Verify mapping state reflects results
        assertTrue(localAori.isSupportedChain(ETHEREUM_EID), "ETHEREUM_EID should be supported");
        assertTrue(localAori.isSupportedChain(AVALANCHE_EID), "AVALANCHE_EID should be supported");
        assertTrue(localAori.isSupportedChain(localEid), "localEid should be supported");
    }
}
