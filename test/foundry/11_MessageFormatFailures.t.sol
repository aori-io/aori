// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * MessageFormatFailuresTest - Tests failures related to message formats in the Aori cross-chain protocol
 *
 * Test cases:
 * 1. testRevertSettlementInvalidLength - Tests that lzReceive reverts for settlement message with invalid length
 * 2. testRevertSettlementInvalidHashCount - Tests that lzReceive reverts for settlement message with wrong order hash count
 * 3. testRevertCancellationInvalidLength - Tests that lzReceive reverts for cancellation message with invalid length
 * 4. testRevertInvalidPeer - Tests that lzReceive reverts when receiving a message from an invalid peer
 * 5. testRevertInvalidEndpoint - Tests that lzReceive reverts when receiving a message from an invalid endpoint
 * 6. testRevertSettleNoFee - Tests that settle reverts when no fee is provided
 *
 * This test file focuses on edge cases and failure conditions related to the LayerZero cross-chain messaging
 * system used by Aori, including payload format violations, authorization issues, and fee-related failures.
 */
import {IAori} from "../../contracts/IAori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./TestUtils.sol";

/**
 * @title MessageFormatFailuresTest
 * @notice Tests failures related to message formats in the Aori cross-chain protocol
 */
contract MessageFormatFailuresTest is TestUtils {
    using OptionsBuilder for bytes;

    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Test that lzReceive reverts for settlement message with invalid length
     */
    function testRevertSettlementInvalidLength() public {
        vm.chainId(localEid);

        // Create a settlement message (type 0x00) that's too short (missing fill count)
        bytes memory invalidPayload = new bytes(21); // Too short (should be 23 + orderHashes)
        invalidPayload[0] = 0x00; // Settlement message type

        bytes32 guid = keccak256("mock-guid");

        vm.prank(address(endpoints[localEid]));
        vm.expectRevert(bytes("Payload too short for settlement"));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            invalidPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Test that lzReceive reverts for settlement message with wrong order hash count
     */
    function testRevertSettlementInvalidHashCount() public {
        vm.chainId(localEid);

        // Create a settlement message with fill count = 2 but only provide 1 order hash
        bytes memory invalidPayload = new bytes(23 + 32); // One order hash (32 bytes)
        invalidPayload[0] = 0x00; // Settlement message type

        // Set fill count to 2 (bytes 21-22)
        invalidPayload[21] = 0x00;
        invalidPayload[22] = 0x02; // Claiming 2 hashes but only providing 1

        bytes32 guid = keccak256("mock-guid");

        vm.prank(address(endpoints[localEid]));
        vm.expectRevert(bytes("Invalid payload length for settlement"));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            invalidPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Test that lzReceive reverts for cancellation message with invalid length
     */
    function testRevertCancellationInvalidLength() public {
        vm.chainId(remoteEid);

        // Create a cancellation message (type 0x01) that's too short
        bytes memory invalidPayload = new bytes(1); // Just the message type
        invalidPayload[0] = 0x01; // Cancellation message type

        bytes32 guid = keccak256("mock-guid");

        vm.prank(address(endpoints[remoteEid]));
        vm.expectRevert(bytes("Invalid cancellation payload length"));
        remoteAori.lzReceive(
            Origin(localEid, bytes32(uint256(uint160(address(localAori)))), 1),
            guid,
            invalidPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Test that lzReceive reverts when receiving a message from an invalid peer
     */
    function testRevertInvalidPeer() public {
        vm.chainId(localEid);

        // Valid settlement payload structure
        bytes memory payload = new bytes(23);
        payload[0] = 0x00; // Settlement message type

        bytes32 guid = keccak256("mock-guid");
        address fakePeer = address(0xDEAD);

        // For OnlyPeer errors, we need to use a different approach since the error contains dynamic data
        vm.prank(address(endpoints[localEid]));

        // Using a generic expectRevert without specific message
        vm.expectRevert();
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(fakePeer))), 1), guid, payload, address(0), bytes("")
        );
    }

    /**
     * @notice Test that lzReceive reverts when receiving a message from an invalid endpoint
     */
    function testRevertInvalidEndpoint() public {
        vm.chainId(localEid);

        // Valid settlement payload structure
        bytes memory payload = new bytes(23);
        payload[0] = 0x00; // Settlement message type

        bytes32 guid = keccak256("mock-guid");

        // For OnlyEndpoint errors, we need to use a different approach since the error contains dynamic data
        // Call lzReceive from an address that's not the endpoint
        vm.prank(address(0xBEEF));

        // Using a generic expectRevert without specific message
        vm.expectRevert();
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1), guid, payload, address(0), bytes("")
        );
    }

    /**
     * @notice Test that settle reverts when no fee is provided
     */
    function testRevertSettleNoFee() public {
        vm.chainId(remoteEid);

        // Create a valid order and fill it
        IAori.Order memory order = createValidOrder();

        // Warp to after the order start time
        vm.warp(order.startTime + 10);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order);

        // Try to settle with no value
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(200000), 0);

        vm.prank(solver);

        // For LayerZero fee errors, which contain dynamic data, use generic expectRevert
        vm.expectRevert();
        remoteAori.settle(localEid, solver, options);
    }
}
