// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

/**
 * AoriLensTests - Tests for the AoriLens view contract
 *
 * Test cases cover:
 * 1. orders() - Reading order details from storage
 * 2. getLockedBalances() / getUnlockedBalances() - Balance reading
 * 3. MAX_FILLS_PER_SETTLE() - Configuration reading
 * 4. srcEidToFillerFills() - Fill array element access
 * 5. srcEidToFillerFillsLength() - Fill array length
 */
import "./TestUtils.sol";
import { AoriLens } from "../../contracts/AoriLens.sol";
import { Order, OrderStatus } from "../../contracts/types/AoriTypes.sol";

contract AoriLensTests is TestUtils {
    using OptionsBuilder for bytes;

    Order internal testOrder;
    bytes32 internal testOrderHash;

    function setUp() public override {
        super.setUp();

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
    /*                      orders() TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test reading an existing order via lens
     * @dev Note: When depositing with a hook, inputToken gets converted to convertedToken
     * Note: This test verifies the core packed fields (amounts, tokens) that are most critical
     */
    function testOrders_ExistingOrder() public view {
        Order memory retrieved = localLens.orders(testOrderHash);

        // Verify amounts (packed in slot0)
        assertEq(retrieved.inputAmount, testOrder.inputAmount, "Input amount mismatch");
        assertEq(retrieved.outputAmount, testOrder.outputAmount, "Output amount mismatch");

        // Verify tokens (slot1, slot2 lower bits)
        // Input token is converted by the hook during deposit
        assertEq(retrieved.inputToken, address(convertedToken), "Input token should be converted token");
        assertEq(retrieved.outputToken, testOrder.outputToken, "Output token mismatch");

        // Verify packed time/eid fields (slot2 upper bits + slot3 lower bits)
        assertEq(retrieved.startTime, testOrder.startTime, "startTime mismatch");
        assertEq(retrieved.endTime, testOrder.endTime, "endTime mismatch");
        assertEq(retrieved.srcEid, testOrder.srcEid, "srcEid mismatch");
        assertEq(retrieved.dstEid, testOrder.dstEid, "dstEid mismatch");

        // Verify addresses (slot3 upper bits + slot4)
        assertEq(retrieved.offerer, testOrder.offerer, "offerer mismatch");
        assertEq(retrieved.recipient, testOrder.recipient, "recipient mismatch");
    }

    /**
     * @notice Test orders() returns correct values for ALL fields including packed times, offerer/recipient, and Options
     * @dev Uses distinct addresses for offerer/recipient and non-zero Options to catch slot misalignment bugs
     */
    function testOrders_AllFieldsCorrect() public {
        address distinctRecipient = address(0xBBBB);
        address feeRecipient = address(0xCCCC);
        address optionsSolver = solver;

        Order memory order = Order({
            offerer: userA,
            recipient: distinctRecipient,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(1e18),
            outputAmount: uint128(2e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({
                feeMbps: 500,
                feeRecipient: feeRecipient,
                solver: optionsSolver,
                slippageMbps: 100
            })
        });

        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        Order memory r = localLens.orders(orderHash);

        assertEq(r.inputAmount, order.inputAmount, "inputAmount");
        assertEq(r.outputAmount, order.outputAmount, "outputAmount");
        assertEq(r.inputToken, order.inputToken, "inputToken");
        assertEq(r.outputToken, order.outputToken, "outputToken");
        assertEq(r.startTime, order.startTime, "startTime");
        assertEq(r.endTime, order.endTime, "endTime");
        assertEq(r.srcEid, order.srcEid, "srcEid");
        assertEq(r.dstEid, order.dstEid, "dstEid");
        assertEq(r.offerer, order.offerer, "offerer");
        assertEq(r.recipient, order.recipient, "recipient");
        assertEq(r.options.feeMbps, order.options.feeMbps, "feeMbps");
        assertEq(r.options.feeRecipient, order.options.feeRecipient, "feeRecipient");
        assertEq(r.options.solver, order.options.solver, "solver");
        assertEq(r.options.slippageMbps, order.options.slippageMbps, "slippageMbps");
    }

    /**
     * @notice Test reading a non-existent order returns zeros
     */
    function testOrders_NonExistentOrder() public view {
        bytes32 fakeOrderHash = keccak256("fake_order");
        Order memory retrieved = localLens.orders(fakeOrderHash);

        assertEq(retrieved.inputAmount, 0, "Should return zero input amount");
        assertEq(retrieved.outputAmount, 0, "Should return zero output amount");
        assertEq(retrieved.inputToken, address(0), "Should return zero address for input token");
        assertEq(retrieved.outputToken, address(0), "Should return zero address for output token");
        assertEq(retrieved.offerer, address(0), "Should return zero address for offerer");
        assertEq(retrieved.recipient, address(0), "Should return zero address for recipient");
    }

    /**
     * @notice Test reading multiple orders with distinct offerer/recipient
     * @dev Uses different recipient to ensure lens reads offerer and recipient from correct slots
     */
    function testOrders_MultipleOrders() public {
        // Create order with distinct recipient so offerer != recipient
        address distinctRecipient = address(0xAAAA);
        Order memory order2 = Order({
            offerer: userA,
            recipient: distinctRecipient,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(1e18),
            outputAmount: uint128(2e18),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: defaultOrderOptions()
        });
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2);

        bytes32 orderHash2 = localAori.hash(order2);

        // Both orders should be readable
        Order memory retrieved1 = localLens.orders(testOrderHash);
        Order memory retrieved2 = localLens.orders(orderHash2);

        // Verify offerer and recipient are read from correct slots (not swapped)
        assertEq(retrieved1.offerer, testOrder.offerer, "Order 1 offerer mismatch");
        assertEq(retrieved1.recipient, testOrder.recipient, "Order 1 recipient mismatch");
        assertEq(retrieved2.offerer, userA, "Order 2 offerer mismatch");
        assertEq(retrieved2.recipient, distinctRecipient, "Order 2 recipient mismatch");
        assertTrue(retrieved2.offerer != retrieved2.recipient, "offerer and recipient must differ to validate slot reads");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   BALANCE TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test getLockedBalances returns correct value after deposit
     */
    function testGetLockedBalances_AfterDeposit() public view {
        uint256 locked = localLens.getLockedBalances(userA, address(convertedToken));
        assertEq(locked, testOrder.inputAmount, "Locked balance should match deposit amount");
    }

    /**
     * @notice Test getLockedBalances returns zero for user with no balance
     */
    function testGetLockedBalances_ZeroBalance() public view {
        address randomUser = address(0x999);
        uint256 locked = localLens.getLockedBalances(randomUser, address(convertedToken));
        assertEq(locked, 0, "Should return zero for user with no balance");
    }

    /**
     * @notice Test getLockedBalances returns zero for token with no balance
     */
    function testGetLockedBalances_WrongToken() public view {
        uint256 locked = localLens.getLockedBalances(userA, address(outputToken));
        assertEq(locked, 0, "Should return zero for token with no locked balance");
    }

    /**
     * @notice Test getUnlockedBalances returns zero initially
     */
    function testGetUnlockedBalances_InitiallyZero() public view {
        uint256 unlocked = localLens.getUnlockedBalances(solver, address(convertedToken));
        assertEq(unlocked, 0, "Solver should have zero unlocked balance initially");
    }

    /**
     * @notice Test getUnlockedBalances after settlement
     */
    function testGetUnlockedBalances_AfterSettlement() public {
        // Fill the order on remote chain
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

        // Simulate LayerZero delivery
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");
        bytes memory payload = new bytes(55); // 23 header + 32 order hash
        payload[0] = 0x00; // Settlement type
        bytes20 fillerBytes = bytes20(solver);
        for (uint256 i = 0; i < 20; i++) {
            payload[1 + i] = fillerBytes[i];
        }
        payload[21] = 0x00;
        payload[22] = 0x01; // 1 fill
        bytes32 orderHash = localAori.hash(testOrder);
        for (uint256 i = 0; i < 32; i++) {
            payload[23 + i] = orderHash[i];
        }

        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1), guid, payload, address(0), bytes(""));

        // Solver should now have unlocked balance
        uint256 unlocked = localLens.getUnlockedBalances(solver, address(convertedToken));
        assertEq(unlocked, testOrder.inputAmount, "Solver should have unlocked balance after settlement");
    }

    /**
     * @notice Test both locked and unlocked balances for same user/token
     */
    function testBalances_LockedAndUnlocked() public {
        // Deposit another order
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2, defaultSrcSolverData(order2.inputAmount));

        // User should have locked balance from both orders
        uint256 locked = localLens.getLockedBalances(userA, address(convertedToken));
        assertEq(locked, testOrder.inputAmount + order2.inputAmount, "Locked should be sum of both deposits");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              MAX_FILLS_PER_SETTLE TESTS                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test MAX_FILLS_PER_SETTLE returns correct value
     */
    function testMaxFillsPerSettle_ReturnsCorrectValue() public view {
        uint16 maxFills = localLens.MAX_FILLS_PER_SETTLE();
        assertEq(maxFills, MAX_FILLS_PER_SETTLE, "Should match initialized value");
    }

    /**
     * @notice Test MAX_FILLS_PER_SETTLE on remote lens
     */
    function testMaxFillsPerSettle_RemoteLens() public view {
        uint16 maxFills = remoteLens.MAX_FILLS_PER_SETTLE();
        assertEq(maxFills, MAX_FILLS_PER_SETTLE, "Remote lens should return same value");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            srcEidToFillerFills TESTS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test srcEidToFillerFills returns order hash after fill
     */
    function testSrcEidToFillerFills_AfterFill() public {
        // Fill on remote chain
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Check the fill was recorded
        bytes32 fillHash = remoteLens.srcEidToFillerFills(localEid, solver, 0);
        bytes32 expectedHash = remoteAori.hash(testOrder);
        assertEq(fillHash, expectedHash, "Fill hash should match order hash");
    }

    /**
     * @notice Test srcEidToFillerFills with multiple fills
     */
    function testSrcEidToFillerFills_MultipleFills() public {
        // Create and deposit second order
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2, defaultSrcSolverData(order2.inputAmount));

        // Fill both orders on remote chain
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.startPrank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount + order2.outputAmount);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));
        remoteAori.fill(order2, defaultDstSolverData(order2.outputAmount));
        vm.stopPrank();

        // Both fills should be recorded
        bytes32 fill0 = remoteLens.srcEidToFillerFills(localEid, solver, 0);
        bytes32 fill1 = remoteLens.srcEidToFillerFills(localEid, solver, 1);

        assertTrue(fill0 != bytes32(0), "First fill should be recorded");
        assertTrue(fill1 != bytes32(0), "Second fill should be recorded");
        assertTrue(fill0 != fill1, "Fills should be different orders");
    }

    /**
     * @notice Test srcEidToFillerFills returns zero for non-existent index
     */
    function testSrcEidToFillerFills_NonExistentIndex() public view {
        // No fills yet on remote, so index 0 should return zero
        bytes32 fill = remoteLens.srcEidToFillerFills(localEid, solver, 0);
        assertEq(fill, bytes32(0), "Should return zero for non-existent index");
    }

    /**
     * @notice Test srcEidToFillerFills for wrong filler
     */
    function testSrcEidToFillerFills_WrongFiller() public {
        // Fill on remote
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Different filler should have no fills
        address wrongFiller = address(0x999);
        bytes32 fill = remoteLens.srcEidToFillerFills(localEid, wrongFiller, 0);
        assertEq(fill, bytes32(0), "Wrong filler should have no fills");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*          srcEidToFillerFillsLength TESTS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test srcEidToFillerFillsLength returns zero initially
     */
    function testSrcEidToFillerFillsLength_InitiallyZero() public view {
        uint256 length = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(length, 0, "Should be zero before any fills");
    }

    /**
     * @notice Test srcEidToFillerFillsLength increments after fill
     */
    function testSrcEidToFillerFillsLength_AfterFill() public {
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        uint256 length = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(length, 1, "Length should be 1 after one fill");
    }

    /**
     * @notice Test srcEidToFillerFillsLength with multiple fills
     */
    function testSrcEidToFillerFillsLength_MultipleFills() public {
        // Create second order
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        vm.prank(solver);
        localAori.deposit(order2, sig2, defaultSrcSolverData(order2.inputAmount));

        // Fill both
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.startPrank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount + order2.outputAmount);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));
        remoteAori.fill(order2, defaultDstSolverData(order2.outputAmount));
        vm.stopPrank();

        uint256 length = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(length, 2, "Length should be 2 after two fills");
    }

    /**
     * @notice Test srcEidToFillerFillsLength decreases after settle
     */
    function testSrcEidToFillerFillsLength_AfterSettle() public {
        // Fill order
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Verify length is 1 before settle
        uint256 lengthBefore = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(lengthBefore, 1, "Should have 1 fill before settle");

        // Settle
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver).nativeFee;
        vm.deal(solver, fee);
        vm.prank(solver);
        remoteAori.settle{ value: fee }(localEid, solver, options);

        // Length should be 0 after settle
        uint256 lengthAfter = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(lengthAfter, 0, "Should have 0 fills after settle");
    }

    /**
     * @notice Test srcEidToFillerFillsLength for different srcEids
     */
    function testSrcEidToFillerFillsLength_DifferentSrcEids() public {
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Check length for correct srcEid
        uint256 correctLength = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(correctLength, 1, "Should have 1 fill for correct srcEid");

        // Check length for different srcEid
        uint256 wrongLength = remoteLens.srcEidToFillerFillsLength(999, solver);
        assertEq(wrongLength, 0, "Should have 0 fills for wrong srcEid");
    }

    /**
     * @notice Test srcEidToFillerFillsLength for different fillers
     */
    function testSrcEidToFillerFillsLength_DifferentFillers() public {
        vm.chainId(remoteEid);
        vm.warp(testOrder.startTime + 1);

        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), testOrder.outputAmount);

        vm.prank(solver);
        remoteAori.fill(testOrder, defaultDstSolverData(testOrder.outputAmount));

        // Solver should have 1 fill
        uint256 solverLength = remoteLens.srcEidToFillerFillsLength(localEid, solver);
        assertEq(solverLength, 1, "Solver should have 1 fill");

        // Random address should have 0 fills
        uint256 randomLength = remoteLens.srcEidToFillerFillsLength(localEid, address(0x999));
        assertEq(randomLength, 0, "Random address should have 0 fills");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                CONSTRUCTOR TESTS                            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test lens stores correct Aori address
     */
    function testConstructor_StoresAoriAddress() public view {
        assertEq(address(localLens.aori()), address(localAori), "Should store local Aori address");
        assertEq(address(remoteLens.aori()), address(remoteAori), "Should store remote Aori address");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FUZZ TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Fuzz test balance consistency between locked and unlocked
     */
    function testFuzz_Balances_Consistency(
        uint128 depositAmount
    ) public {
        depositAmount = uint128(bound(depositAmount, 1e6, 1e24));

        // Record initial locked balance (from setUp)
        uint256 initialLocked = localLens.getLockedBalances(userA, address(convertedToken));

        // Mint sufficient tokens for user and hook
        inputToken.mint(userA, depositAmount);
        convertedToken.mint(address(mockHook), depositAmount);

        Order memory order = Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: depositAmount,
            outputAmount: depositAmount + 1, // Different output to ensure unique hash
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({ feeMbps: 0, feeRecipient: address(0), solver: address(0), slippageMbps: 0 })
        });

        vm.prank(userA);
        inputToken.approve(address(localAori), depositAmount);

        vm.prank(solver);
        localAori.deposit(order, signOrder(order), defaultSrcSolverData(depositAmount));

        // Locked balance should increase by deposit amount
        uint256 finalLocked = localLens.getLockedBalances(userA, address(convertedToken));
        assertEq(finalLocked - initialLocked, depositAmount, "Locked increase should match deposit");

        // Unlocked should be zero for user
        uint256 unlocked = localLens.getUnlockedBalances(userA, address(convertedToken));
        assertEq(unlocked, 0, "User unlocked should be zero");
    }

    /**
     * @notice Fuzz test fills length tracking
     */
    function testFuzz_FillsLength_Tracking(
        uint8 numFills
    ) public {
        numFills = uint8(bound(numFills, 1, 5));

        for (uint256 i = 0; i < numFills; i++) {
            Order memory order = createValidOrder(i + 200);
            bytes memory sig = signOrder(order);

            vm.prank(userA);
            inputToken.approve(address(localAori), order.inputAmount);

            vm.prank(solver);
            localAori.deposit(order, sig, defaultSrcSolverData(order.inputAmount));
        }

        vm.chainId(remoteEid);
        vm.warp(block.timestamp + 2 hours);

        for (uint256 i = 0; i < numFills; i++) {
            Order memory order = createValidOrder(i + 200);
            vm.prank(solver);
            dstPreferredToken.approve(address(remoteAori), order.outputAmount);
            vm.prank(solver);
            remoteAori.fill(order, defaultDstSolverData(order.outputAmount));

            // Verify length increments correctly
            assertEq(remoteLens.srcEidToFillerFillsLength(localEid, solver), i + 1);
        }
    }

    /**
     * @notice Fuzz test random user/token queries return zero
     */
    function testFuzz_Balances_RandomQueries(
        address randomUser,
        address randomToken
    ) public view {
        vm.assume(randomUser != userA && randomUser != address(0));
        vm.assume(randomToken != address(convertedToken) && randomToken != address(0));

        assertEq(localLens.getLockedBalances(randomUser, randomToken), 0);
        assertEq(localLens.getUnlockedBalances(randomUser, randomToken), 0);
    }
}
