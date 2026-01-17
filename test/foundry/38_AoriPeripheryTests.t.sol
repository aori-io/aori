// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * AoriPeripheryTests - Tests for the AoriPeriphery aggregation contract
 *
 * Test cases cover:
 * 1. getPendingSettle() - Aggregating pending fills across multiple srcEids
 * 2. getOrdersInputTotals() - Aggregating input token totals for orders
 * 3. Edge cases: empty arrays, large arrays, non-existent data
 */
import "./TestUtils.sol";
import { AoriPeriphery } from "../../contracts/periphery/AoriPeriphery.sol";
import { AoriLens } from "../../contracts/periphery/AoriLens.sol";
import { Order } from "../../contracts/types/AoriTypes.sol";
import "../../contracts/types/AoriErrors.sol";

contract AoriPeripheryTests is TestUtils {
    using OptionsBuilder for bytes;

    AoriPeriphery public localPeriphery;
    AoriPeriphery public remotePeriphery;

    Order internal testOrder;
    bytes32 internal testOrderHash;

    function setUp() public override {
        super.setUp();

        // Deploy periphery contracts
        localPeriphery = new AoriPeriphery(address(localLens));
        remotePeriphery = new AoriPeriphery(address(remoteLens));

        // Create and deposit a test order
        testOrder = createValidOrder(1);
        bytes memory signature = signOrder(testOrder);

        vm.prank(userA);
        inputToken.approve(address(localAori), testOrder.inputAmount);

        vm.prank(solver);
        localAori.deposit(testOrder, signature, defaultSrcSolverData(testOrder.inputAmount));

        testOrderHash = localAori.hash(testOrder);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   CONSTRUCTOR TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test constructor stores correct lens address
     */
    function testConstructor_StoresLensAddress() public view {
        assertEq(address(localPeriphery.lens()), address(localLens), "Should store local lens");
        assertEq(address(remotePeriphery.lens()), address(remoteLens), "Should store remote lens");
    }

    /**
     * @notice Test constructor reverts with zero address
     */
    function testConstructor_RevertsZeroAddress() public {
        vm.expectRevert(InvalidAoriAddress.selector);
        new AoriPeriphery(address(0));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                getPendingSettle TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test getPendingSettle returns empty arrays when no fills
     */
    function testGetPendingSettle_NoFills() public view {
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results.length, 1, "Should return one array");
        assertEq(results[0].length, 0, "Should have no fills");
    }

    /**
     * @notice Test getPendingSettle returns correct fill data after order is filled
     */
    function testGetPendingSettle_OneFill() public {
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);
        bytes32 expectedHash = remoteAori.hash(testOrder);

        assertEq(results.length, 1);
        assertEq(results[0].length, 1);
        assertEq(results[0][0], expectedHash);
        // Verify hash matches what lens reports directly
        assertEq(results[0][0], remoteLens.srcEidToFillerFills(localEid, solver, 0));
    }

    /**
     * @notice Test getPendingSettle with multiple fills
     */
    function testGetPendingSettle_MultipleFills() public {
        // Create and deposit a second order
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2, defaultSrcSolverData(order2.inputAmount));

        // Fill both orders
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.startPrank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount + order2.outputAmount);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));
        remoteAori.fill(order2, defaultDstSolverData(order2.outputAmount));
        vm.stopPrank();

        // Query pending settles
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results.length, 1, "Should return one array");
        assertEq(results[0].length, 2, "Should have two fills");
    }

    /**
     * @notice Test getPendingSettle with multiple srcEids
     */
    function testGetPendingSettle_MultipleSrcEids() public {
        // Fill order
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Query multiple srcEids
        uint32[] memory srcEids = new uint32[](3);
        srcEids[0] = localEid;
        srcEids[1] = 999; // Non-existent
        srcEids[2] = 888; // Non-existent

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results.length, 3, "Should return three arrays");
        assertEq(results[0].length, 1, "First srcEid should have one fill");
        assertEq(results[1].length, 0, "Second srcEid should have no fills");
        assertEq(results[2].length, 0, "Third srcEid should have no fills");
    }

    /**
     * @notice Test getPendingSettle with empty srcEids array
     */
    function testGetPendingSettle_EmptyArray() public view {
        uint32[] memory srcEids = new uint32[](0);

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results.length, 0, "Should return empty array");
    }

    /**
     * @notice Test getPendingSettle for wrong filler
     */
    function testGetPendingSettle_WrongFiller() public {
        // Fill order
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Query for wrong filler
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, address(0x999));

        assertEq(results[0].length, 0, "Wrong filler should have no fills");
    }

    /**
     * @notice Test getPendingSettle is empty after settle
     */
    function testGetPendingSettle_AfterSettle() public {
        // Fill order
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Settle
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver).nativeFee;
        vm.deal(solver, fee);
        vm.prank(solver);
        remoteAori.settle{ value: fee }(localEid, solver, options);

        // Query should be empty after settle
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results[0].length, 0, "Should have no pending fills after settle");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              getOrdersInputTotals TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test getOrdersInputTotals with single order
     * @dev Note: Input token is converted by hook during deposit
     */
    function testGetOrdersInputTotals_SingleOrder() public view {
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = testOrderHash;

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        assertEq(tokens.length, 1, "Should have one token");
        assertEq(amounts.length, 1, "Should have one amount");
        // Input token is converted by hook during deposit
        assertEq(tokens[0], address(convertedToken), "Token should be converted token after hook");
        assertEq(amounts[0], testOrder.inputAmount, "Amount should match order input amount");
    }

    /**
     * @notice Test getOrdersInputTotals with multiple orders same token
     */
    function testGetOrdersInputTotals_MultipleOrdersSameToken() public {
        // Create and deposit second order with same input token
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2, defaultSrcSolverData(order2.inputAmount));

        bytes32 orderHash2 = localAori.hash(order2);

        // Query both orders
        bytes32[] memory orderHashes = new bytes32[](2);
        orderHashes[0] = testOrderHash;
        orderHashes[1] = orderHash2;

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        assertEq(tokens.length, 1, "Should aggregate to one token");
        assertEq(amounts[0], testOrder.inputAmount + order2.inputAmount, "Should sum both amounts");
    }

    /**
     * @notice Test getOrdersInputTotals with empty array
     */
    function testGetOrdersInputTotals_EmptyArray() public view {
        bytes32[] memory orderHashes = new bytes32[](0);

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        assertEq(tokens.length, 0, "Should return empty tokens array");
        assertEq(amounts.length, 0, "Should return empty amounts array");
    }

    /**
     * @notice Test getOrdersInputTotals with non-existent order hash
     */
    function testGetOrdersInputTotals_NonExistentOrder() public view {
        bytes32[] memory orderHashes = new bytes32[](1);
        orderHashes[0] = keccak256("fake_order");

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        // Non-existent order returns zeros, which means inputToken = address(0)
        // The function adds address(0) as a unique token with amount 0
        assertEq(tokens.length, 1, "Should have one entry");
        assertEq(tokens[0], address(0), "Token should be zero address");
        assertEq(amounts[0], 0, "Amount should be zero");
    }

    /**
     * @notice Test getOrdersInputTotals with mix of valid and non-existent orders
     */
    function testGetOrdersInputTotals_MixedOrders() public view {
        bytes32[] memory orderHashes = new bytes32[](2);
        orderHashes[0] = testOrderHash;
        orderHashes[1] = keccak256("fake_order");

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        // Should have two unique tokens: the real inputToken and address(0) from fake order
        assertEq(tokens.length, 2, "Should have two unique tokens");
    }

    /**
     * @notice Test getOrdersInputTotals with duplicate order hashes
     */
    function testGetOrdersInputTotals_DuplicateOrderHashes() public view {
        bytes32[] memory orderHashes = new bytes32[](3);
        orderHashes[0] = testOrderHash;
        orderHashes[1] = testOrderHash;
        orderHashes[2] = testOrderHash;

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        assertEq(tokens.length, 1, "Should aggregate to one token");
        assertEq(amounts[0], testOrder.inputAmount * 3, "Should triple the amount");
    }

    /**
     * @notice Test getOrdersInputTotals respects 20 token limit
     */
    function testGetOrdersInputTotals_TokenLimit() public {
        // Create orders with many different input tokens
        bytes32[] memory orderHashes = new bytes32[](25);
        MockERC20[] memory tokens = new MockERC20[](25);

        for (uint256 i = 0; i < 25; i++) {
            tokens[i] = new MockERC20(string(abi.encodePacked("Token", i)), string(abi.encodePacked("T", i)));
            tokens[i].mint(userA, 1e18);

            Order memory order = Order({
                offerer: userA,
                recipient: userA,
                inputToken: address(tokens[i]),
                outputToken: address(outputToken),
                inputAmount: uint128(1e18),
                outputAmount: uint128(1e18),
                startTime: uint32(block.timestamp),
                endTime: uint32(block.timestamp + 1 hours),
                srcEid: localEid,
                dstEid: remoteEid
            });

            bytes memory signature = signOrder(order);

            vm.prank(userA);
            tokens[i].approve(address(localAori), 1e18);

            vm.prank(solver);
            localAori.deposit(order, signature);

            orderHashes[i] = localAori.hash(order);
        }

        (address[] memory resultTokens, uint256[] memory resultAmounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        // Should cap at 20 unique tokens
        assertEq(resultTokens.length, 20, "Should cap at 20 tokens");
        assertEq(resultAmounts.length, 20, "Should cap at 20 amounts");
    }

    /**
     * @notice Test getOrdersInputTotals aggregates correctly with multiple different tokens
     * @dev First order uses hook (converted), second order has no hook
     */
    function testGetOrdersInputTotals_MultipleTokens() public {
        // Create second token
        MockERC20 token2 = new MockERC20("Token2", "T2");
        token2.mint(userA, 1e18);

        // Create order with different input token (no hook)
        Order memory order2 = Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(token2),
            outputToken: address(outputToken),
            inputAmount: uint128(5e17),
            outputAmount: uint128(1e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        token2.approve(address(localAori), 5e17);

        vm.prank(solver);
        localAori.deposit(order2, sig2);

        bytes32 orderHash2 = localAori.hash(order2);

        // Query both orders
        bytes32[] memory orderHashes = new bytes32[](2);
        orderHashes[0] = testOrderHash;
        orderHashes[1] = orderHash2;

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(orderHashes);

        assertEq(tokens.length, 2, "Should have two unique tokens");

        // Find each token and verify amounts
        // First order's input token was converted by hook
        bool foundConvertedToken = false;
        bool foundToken2 = false;
        for (uint256 i = 0; i < tokens.length; i++) {
            if (tokens[i] == address(convertedToken)) {
                assertEq(amounts[i], testOrder.inputAmount, "Converted token amount mismatch");
                foundConvertedToken = true;
            }
            if (tokens[i] == address(token2)) {
                assertEq(amounts[i], 5e17, "Token2 amount mismatch");
                foundToken2 = true;
            }
        }
        assertTrue(foundConvertedToken, "Should find converted token");
        assertTrue(foundToken2, "Should find token2");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FUZZ TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fuzz test getPendingSettle with variable number of fills
     */
    function testFuzz_GetPendingSettle_MultipleFills(
        uint8 numFills
    ) public {
        numFills = uint8(bound(numFills, 1, 5)); // Keep reasonable for gas

        // Create and deposit orders
        bytes32[] memory expectedHashes = new bytes32[](numFills);
        for (uint256 i = 0; i < numFills; i++) {
            Order memory order = createValidOrder(i + 100);
            bytes memory sig = signOrder(order);

            vm.prank(userA);
            inputToken.approve(address(localAori), order.inputAmount);

            vm.prank(solver);
            localAori.deposit(order, sig, defaultSrcSolverData(order.inputAmount));

            expectedHashes[i] = localAori.hash(order);
        }

        // Fill all orders
        vm.chainId(remoteEid);
        vm.warp(block.timestamp + 2 hours);

        for (uint256 i = 0; i < numFills; i++) {
            Order memory order = createValidOrder(i + 100);
            vm.prank(solver);
            dstPreferredToken.approve(address(remoteAori), order.outputAmount);
            vm.prank(solver);
            remoteAori.fill(order, defaultDstSolverData(order.outputAmount));
        }

        // Query and verify
        uint32[] memory srcEids = new uint32[](1);
        srcEids[0] = localEid;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results[0].length, numFills, "Fill count mismatch");
        // Verify length matches lens
        assertEq(results[0].length, remoteLens.srcEidToFillerFillsLength(localEid, solver));
    }

    /**
     * @notice Fuzz test getOrdersInputTotals aggregation accuracy
     */
    function testFuzz_GetOrdersInputTotals_Aggregation(
        uint128 amount1,
        uint128 amount2
    ) public {
        amount1 = uint128(bound(amount1, 1e6, 1e24));
        amount2 = uint128(bound(amount2, 1e6, 1e24));

        // Mint sufficient tokens for user and hook
        inputToken.mint(userA, uint256(amount1) + uint256(amount2));
        convertedToken.mint(address(mockHook), uint256(amount1) + uint256(amount2));

        // Create two orders with same converted token (via hook)
        // Use different output amounts to ensure unique order hashes
        Order memory order1 = Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: amount1,
            outputAmount: amount1 + 1, // Unique
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid
        });

        Order memory order2 = Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: amount2,
            outputAmount: amount2 + 2, // Unique
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Deposit both with hooks (converts to convertedToken)
        vm.startPrank(userA);
        inputToken.approve(address(localAori), uint256(amount1) + uint256(amount2));
        vm.stopPrank();

        vm.prank(solver);
        localAori.deposit(order1, signOrder(order1), defaultSrcSolverData(amount1));

        vm.prank(solver);
        localAori.deposit(order2, signOrder(order2), defaultSrcSolverData(amount2));

        bytes32[] memory hashes = new bytes32[](2);
        hashes[0] = localAori.hash(order1);
        hashes[1] = localAori.hash(order2);

        (address[] memory tokens, uint256[] memory amounts) = localPeriphery.getOrdersInputTotals(hashes);

        // Both orders use same converted token, should aggregate
        assertEq(tokens.length, 1, "Should aggregate to one token");
        assertEq(tokens[0], address(convertedToken));
        assertEq(amounts[0], uint256(amount1) + uint256(amount2), "Sum should match");
    }

    /**
     * @notice Fuzz test with random srcEid queries
     */
    function testFuzz_GetPendingSettle_RandomSrcEids(
        uint32 randomEid1,
        uint32 randomEid2
    ) public {
        vm.assume(randomEid1 != localEid && randomEid2 != localEid);
        vm.assume(randomEid1 != 0 && randomEid2 != 0);

        // Fill an order first
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Query with mix of valid and random srcEids
        uint32[] memory srcEids = new uint32[](3);
        srcEids[0] = randomEid1;
        srcEids[1] = localEid; // Valid one
        srcEids[2] = randomEid2;

        bytes32[][] memory results = remotePeriphery.getPendingSettle(srcEids, solver);

        assertEq(results.length, 3);
        assertEq(results[0].length, 0, "Random srcEid should have no fills");
        assertEq(results[1].length, 1, "Valid srcEid should have one fill");
        assertEq(results[2].length, 0, "Random srcEid should have no fills");
    }
}
