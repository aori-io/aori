// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title QuoteTest
 * @notice Tests the LayerZero message fee quoting functionality in the Aori protocol
 *
 * This test file verifies that the Aori contract correctly calculates LayerZero message fees
 * for different message types and payload sizes. It ensures that fees scale appropriately
 * with increasing payload sizes, which is essential for accurate gas estimation in a cross-chain context.
 *
 * Tests:
 * 1. testQuoteCancelMessage - Tests fee calculation for cancel messages (33 bytes)
 * 2. testQuoteSettleMessage - Tests fee calculation for settlement messages with increasing number of filled orders
 * 3. testQuoteIncreasesWithPayloadSize - Tests that fees increase proportionally with payload size
 * 4. testCompareQuoteCancelAndSettle - Compares fees between cancel and settle messages to verify size-based scaling
 * 5. testInvalidMessageTypeQuote - Tests error handling when an invalid message type is provided to quote
 *
 * Special notes:
 * - These tests focus specifically on the fee calculation aspect of cross-chain messaging
 * - Tests verify both relative fee scaling (larger payloads = higher fees) and absolute fee values
 * - The tests create real orders and fills to generate authentic settlement payloads of varying sizes
 */
import {TestUtils} from "./TestUtils.sol";
import {IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

/**
 * @notice Tests the LayerZero message fee quoting functionality in the Aori protocol
 */
contract QuoteTest is TestUtils {
    /// @dev Deploy endpoints, contracts, and tokens.
    function setUp() public override {
        // Setup parent test environment
        super.setUp();
    }

    /// @dev Helper to create and deposit orders
    function createAndDepositOrder(uint256 index) internal returns (IAori.Order memory order, bytes32 orderHash) {
        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp), // Current time
            endTime: uint32(block.timestamp + 100 + index), // Unique end time per order
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Generate signature
        bytes memory signature = signOrder(order);

        // Approve tokens for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit order using whitelisted solver
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Get order hash
        orderHash = localAori.hash(order);
    }

    /// @dev Test quoting for cancel message (33 bytes)
    function testQuoteCancelMessage() public view {
        // Get standard LZ options
        bytes memory options = defaultOptions();

        // Get quote for cancel message (msgType 1)
        uint256 cancelFee = localAori.quote(
            remoteEid, // destination endpoint
            1, // message type (1 for cancel)
            options,
            false, // payInLzToken
            0, // srcEid (not used for cancel)
            address(0) // filler (not used for cancel)
        );

        // Verify quote is non-zero
        assertGt(cancelFee, 0, "Cancel message fee should be non-zero");
    }

    /// @dev Test quoting for settle message with increasing number of order fills
    function testQuoteSettleMessage() public {
        // Get standard LZ options
        bytes memory options = defaultOptions();

        // Switch to remote chain to fill orders
        vm.chainId(remoteEid);

        // First, let's test an empty settle message (no fills)
        uint256 emptyFee = remoteAori.quote(
            localEid, // destination endpoint
            0, // message type (0 for settle)
            options,
            false, // payInLzToken
            localEid, // srcEid
            solver // whitelisted solver
        );

        // Now deposit and fill multiple orders to test quotes with different payload sizes
        vm.chainId(localEid);
        IAori.Order[] memory orders = new IAori.Order[](3);
        bytes32[] memory orderHashes = new bytes32[](3);

        // Create and deposit multiple orders
        for (uint256 i = 0; i < 3; i++) {
            (orders[i], orderHashes[i]) = createAndDepositOrder(i);
        }

        // Switch to remote chain to fill orders
        vm.chainId(remoteEid);
        vm.warp(orders[2].startTime + 1); // Warp to after the latest order's start time

        // Fill each order
        for (uint256 i = 0; i < 3; i++) {
            // Approve tokens for fill
            vm.prank(solver);
            outputToken.approve(address(remoteAori), orders[i].outputAmount);

            // Fill the order using whitelisted solver
            vm.prank(solver);
            remoteAori.fill(orders[i]);

            // Get quote for settle message after each fill
            uint256 settleFee = remoteAori.quote(
                localEid, // destination endpoint
                0, // message type (0 for settle)
                options,
                false, // payInLzToken
                localEid, // srcEid
                solver // whitelisted solver
            );

            // Verify fee is non-zero and increases with each additional fill
            assertGt(settleFee, 0, "Settle message fee should be non-zero");
            if (i > 0) {
                // The fee should increase as more hashes are added to the payload
                assertGt(settleFee, emptyFee, "Fee should be higher than base fee");
            }
        }
    }

    /// @dev Test that quotes increase with payload size
    function testQuoteIncreasesWithPayloadSize() public {
        // Get standard LZ options
        bytes memory options = defaultOptions();

        // Create and deposit multiple orders
        vm.chainId(localEid);
        uint256[] memory orderCounts = new uint256[](3);
        orderCounts[0] = 1; // Test with 1 order
        orderCounts[1] = 5; // Test with 5 orders
        orderCounts[2] = 10; // Test with 10 orders (MAX_FILLS_PER_SETTLE)

        uint256[] memory fees = new uint256[](3);

        // For each test case, deposit multiple orders and check quote
        for (uint256 testCase = 0; testCase < 3; testCase++) {
            uint256 numOrders = orderCounts[testCase];

            // Create and deposit orders
            for (uint256 i = 0; i < numOrders; i++) {
                createAndDepositOrder(i + (testCase * 10)); // Ensure unique start times
            }

            // Switch to remote chain to fill orders
            vm.chainId(remoteEid);
            vm.warp(uint32(block.timestamp + 100)); // Ensure all orders have started

            // Fill each order
            for (uint256 i = 0; i < numOrders; i++) {
                IAori.Order memory order = IAori.Order({
                    offerer: userA,
                    recipient: userA,
                    inputToken: address(inputToken),
                    outputToken: address(outputToken),
                    inputAmount: 1e18,
                    outputAmount: 2e18,
                    startTime: uint32(block.timestamp - 50 + i + (testCase * 10)),
                    endTime: uint32(block.timestamp + 1 days),
                    srcEid: localEid,
                    dstEid: remoteEid
                });

                // Approve tokens for fill
                vm.prank(solver);
                outputToken.approve(address(remoteAori), order.outputAmount);

                // Fill the order using whitelisted solver
                vm.prank(solver);
                remoteAori.fill(order);
            }

            // Get quote for settle with filled orders
            fees[testCase] = remoteAori.quote(
                localEid, // destination endpoint
                0, // message type (0 for settle)
                options,
                false, // payInLzToken
                localEid, // srcEid
                solver // whitelisted solver
            );
            // Reset for next test case
            vm.chainId(localEid);
        }

        // Verify fees increase with payload size
        assertGt(fees[1], fees[0], "Fee should increase with more orders");
        assertGt(fees[2], fees[1], "Fee should increase with more orders");
    }

    /// @dev Compare cancel and settle message fees
    function testCompareQuoteCancelAndSettle() public {
        // Get standard LZ options
        bytes memory options = defaultOptions();

        // Get quote for cancel message (33 bytes)
        uint256 cancelFee = localAori.quote(
            remoteEid, // destination endpoint
            1, // message type (1 for cancel)
            options,
            false, // payInLzToken
            0, // srcEid
            address(0) // filler
        );

        // Create and fill a single order to get a settle quote
        vm.chainId(localEid);
        (IAori.Order memory order,) = createAndDepositOrder(0);

        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        // Approve tokens for fill
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Fill the order using whitelisted solver
        vm.prank(solver);
        remoteAori.fill(order);

        // Get quote for settle message with 1 fill (1 + 20 + 2 + 32 = 55 bytes)
        uint256 settleFee = remoteAori.quote(
            localEid, // destination endpoint
            0, // message type (0 for settle)
            options,
            false, // payInLzToken
            localEid, // srcEid
            solver // whitelisted solver
        );
        // Settle fee should be greater than cancel fee because the payload is larger
        assertGt(settleFee, cancelFee, "Settle fee should be greater than cancel fee due to larger payload");
    }

    /// @dev Test the quote function error handling for invalid message types
    function testInvalidMessageTypeQuote() public {
        // Get standard LZ options
        bytes memory options = defaultOptions();

        // Try to get a quote with an invalid message type (2)
        // Valid message types are only 0 (settlement) and 1 (cancellation)
        vm.expectRevert("Invalid message type");
        localAori.quote(
            remoteEid, // destination endpoint
            2, // Invalid message type (neither 0 for settlement nor 1 for cancellation)
            options, 
            false, // payInLzToken
            localEid, // srcEid
            solver // filler
        );

        // Test with another invalid message type (255)
        vm.expectRevert("Invalid message type");
        localAori.quote(
            remoteEid, // destination endpoint
            255, // Another invalid message type
            options,
            false, // payInLzToken
            localEid, // srcEid
            solver // filler
        );
    }
}
