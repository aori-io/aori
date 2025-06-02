// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * SecurityAndAdvancedEdgeCasesTest - Tests for security features and advanced edge cases in the Aori protocol
 *
 * Test cases:
 * 1. testWhitelistEnforcement - Tests that only whitelisted solvers can perform operations
 * 2. testMaxFillsPerSettleLimit - Tests the limit on number of fills per settlement
 * 3. testInvalidOrderParameters - Tests rejection of invalid order parameters
 * 4. testInvalidSolverData - Tests rejection of invalid solver data
 * 5. testPauseAndUnpause - Tests pausing and unpausing functionality
 *
 * This test file verifies the security measures in the Aori contract,
 * particularly the solver whitelist enforcement, parameter validation, and rate
 * limiting features. Some tests use extreme token values to ensure the contract
 * can handle large amounts correctly.
 */
import "./TestUtils.sol";
import "../../contracts/AoriUtils.sol";
import { Aori, IAori } from "../../contracts/Aori.sol";

/**
 * @title TestAori
 * @notice Extension of Aori contract for testing purposes
 */
contract TestAori is Aori {
    constructor(
        address _endpoint,
        address _owner,
        uint32 _eid,
        uint16 _maxFillsPerSettle
    ) Aori(_endpoint, _owner, _eid, _maxFillsPerSettle) {}

    // Helper function to get the fills array length for a specific srcEid and filler
    function getFillsLength(uint32 srcEid, address filler) external view returns (uint256) {
        return srcEidToFillerFills[srcEid][filler].length;
    }

    // Helper function to manually add orders to the fills array (for testing batch limits)
    function addToFills(uint32 srcEid, address filler, bytes32 orderId) external {
        srcEidToFillerFills[srcEid][filler].push(orderId);
    }
}

/**
 * @title SecurityAndAdvancedEdgeCasesTest
 * @notice Tests for security features and advanced edge cases in the Aori contract
 */
contract SecurityAndAdvancedEdgeCasesTest is TestUtils {
    // A non-whitelisted solver address for testing whitelist restrictions
    address public nonWhitelistedSolver = address(0x300);
    TestAori public testLocalAori;
    TestAori public testRemoteAori;

    function setUp() public override(TestUtils) {
        super.setUp();

        // Deploy test-specific Aori contracts that extend functionality
        testLocalAori = new TestAori(
            address(endpoints[localEid]),
            address(this),
            localEid,
            MAX_FILLS_PER_SETTLE
        );
        testRemoteAori = new TestAori(
            address(endpoints[remoteEid]),
            address(this),
            remoteEid,
            MAX_FILLS_PER_SETTLE
        );

        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(testLocalAori);
        aoriInstances[1] = address(testRemoteAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        testLocalAori.setPeer(remoteEid, bytes32(uint256(uint160(address(testRemoteAori)))));
        testRemoteAori.setPeer(localEid, bytes32(uint256(uint160(address(testLocalAori)))));

        // Whitelist the solver in both contracts
        testLocalAori.addAllowedSolver(solver);
        testRemoteAori.addAllowedSolver(solver);

        // Additional setup for extreme testing scenarios
        inputToken.mint(userA, type(uint128).max);
        outputToken.mint(solver, type(uint128).max);
        outputToken.mint(nonWhitelistedSolver, type(uint128).max);

        // Setup chains as supported
        // Mock the quote calls
        vm.mockCall(
            address(testLocalAori),
            abi.encodeWithSelector(
                testLocalAori.quote.selector,
                remoteEid,
                0,
                bytes(""),
                false,
                0,
                address(0)
            ),
            abi.encode(1 ether)
        );
        vm.mockCall(
            address(testRemoteAori),
            abi.encodeWithSelector(
                testRemoteAori.quote.selector,
                localEid,
                0,
                bytes(""),
                false,
                0,
                address(0)
            ),
            abi.encode(1 ether)
        );

        // Add support for chains
        testLocalAori.addSupportedChain(remoteEid);
        testRemoteAori.addSupportedChain(localEid);
    }

    /**
     * @dev Helper to hash an order
     */
    function hash(IAori.Order memory order) internal pure returns (bytes32) {
        return keccak256(abi.encode(order));
    }

    /**
     * @notice Test whitelist-based solver restrictions
     * Only whitelisted solvers can perform operations
     */
    function testWhitelistEnforcement() public {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Remove solver from whitelist temporarily
        localAori.removeAllowedSolver(solver);

        // Non-whitelisted solver should fail to deposit
        vm.prank(solver);
        vm.expectRevert("Invalid solver");
        localAori.deposit(order, signature);

        // Add solver back to whitelist
        localAori.addAllowedSolver(solver);

        // Whitelisted solver should be able to deposit
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Test fill with whitelist enforcement
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);

        // Remove solver from whitelist temporarily
        remoteAori.removeAllowedSolver(solver);

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert("Invalid solver");
        remoteAori.fill(order);

        // Add solver back to whitelist
        remoteAori.addAllowedSolver(solver);

        // Whitelisted solver should be able to fill
        vm.prank(solver);
        remoteAori.fill(order);

        assertEq(
            outputToken.balanceOf(userA),
            order.outputAmount,
            "User did not receive correct output amount"
        );
    }

    /**
     * @notice Test maximum fills per settle limit
     * Verifies that the contract enforces the maximum number of fills per settlement
     */
    function testMaxFillsPerSettleLimit() public {
        // We'll use the TestAori extensions for this test
        vm.chainId(localEid);

        // Create a single order for test simplicity
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes32 orderId = hash(order);

        // Manually populate the fills array with more than MAX_FILLS_PER_SETTLE entries
        vm.chainId(remoteEid);
        for (uint16 i = 0; i < MAX_FILLS_PER_SETTLE + 5; i++) {
            testRemoteAori.addToFills(localEid, solver, orderId);
        }

        // Check that we have the expected number of fills
        uint256 beforeFillsCount = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(
            beforeFillsCount,
            MAX_FILLS_PER_SETTLE + 5,
            "Should have MAX_FILLS_PER_SETTLE + 5 fills before settlement"
        );

        // Create options for the LayerZero message
        bytes memory options = defaultOptions();

        // Get quote for settlement and add buffer
        uint256 msgFee = testRemoteAori.quote(
            localEid,
            uint8(PayloadType.Settlement),
            options,
            false,
            localEid,
            solver
        );

        uint256 feeWithBuffer = (msgFee * 15) / 10; // 50% buffer for safety

        // Give solver plenty of ETH
        vm.deal(solver, feeWithBuffer * 2);

        // Settle orders - this should process MAX_FILLS_PER_SETTLE orders
        vm.prank(solver);
        testRemoteAori.settle{ value: feeWithBuffer }(localEid, solver, options);

        // Verify the number of orders that remain
        uint256 afterFillsCount = testRemoteAori.getFillsLength(localEid, solver);
        assertEq(afterFillsCount, 5, "Should have 5 fills remaining after settlement");
        assertEq(
            beforeFillsCount - afterFillsCount,
            MAX_FILLS_PER_SETTLE,
            "Should have processed exactly MAX_FILLS_PER_SETTLE fills"
        );
    }

    /**
     * @notice Test invalid order parameters
     * Verifies that the contract properly rejects orders with invalid parameters
     */
    function testInvalidOrderParameters() public {
        vm.chainId(localEid);

        // Test zero input amount
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 0, // Invalid: zero input amount
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), 1e18); // Approve some tokens even though input is 0

        // Whitelisted solver should fail to deposit with invalid parameters
        vm.prank(solver);
        vm.expectRevert("Invalid input amount");
        localAori.deposit(order, signature);

        // Test zero output amount
        order.inputAmount = 1e18;
        order.outputAmount = 0; // Invalid: zero output amount

        signature = signOrder(order); // Re-sign with updated parameters

        vm.prank(solver);
        vm.expectRevert("Invalid output amount");
        localAori.deposit(order, signature);

        // Test end time before start time
        order.outputAmount = 2e18;
        order.startTime = uint32(block.timestamp);
        order.endTime = uint32(block.timestamp - 1); // Invalid: end time before start time

        signature = signOrder(order); // Re-sign with updated parameters

        vm.prank(solver);
        vm.expectRevert("Invalid end time");
        localAori.deposit(order, signature);

        // Test invalid tokens (zero address)
        order.startTime = uint32(block.timestamp);
        order.endTime = uint32(block.timestamp + 2 days);
        order.inputToken = address(0); // Invalid token address

        signature = signOrder(order); // Re-sign with updated parameters

        vm.prank(solver);
        vm.expectRevert("Invalid token");
        localAori.deposit(order, signature);

        // Test chain mismatch
        order.inputToken = address(inputToken);
        order.srcEid = remoteEid; // Invalid: source endpoint doesn't match current chain

        signature = signOrder(order); // Re-sign with updated parameters

        vm.prank(solver);
        vm.expectRevert("Chain mismatch");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test invalid solver data
     * Verifies that the contract properly rejects invalid hook configurations
     */
    function testInvalidSolverData() public {
        vm.chainId(localEid);

        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Test non-whitelisted hook
        address nonWhitelistedHook = address(0x400);
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: nonWhitelistedHook,
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1000,
            instructions: ""
        });

        vm.prank(solver);
        vm.expectRevert("Invalid hook address");
        localAori.deposit(order, signature, srcData);

        // Test zero preferred token
        srcData.hookAddress = address(mockHook);
        srcData.preferredToken = address(0); // Invalid: zero token address

        vm.prank(solver);
        vm.expectRevert(); // Will revert when trying to transfer to address(0)
        localAori.deposit(order, signature, srcData);

        // Test insufficient output from hook
        srcData.preferredToken = address(convertedToken);
        srcData.minPreferedTokenAmountOut = 2000e18; // Set to an impossibly high amount
        srcData.instructions = abi.encodeWithSelector(
            MockHook.handleHook.selector,
            address(convertedToken),
            100
        ); // Will return much less than required

        vm.prank(solver);
        vm.expectRevert("Insufficient output from hook");
        localAori.deposit(order, signature, srcData);

        // Test destination hook validation
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 10);

        // First deposit and approve for fill
        vm.chainId(localEid);
        srcData.minPreferedTokenAmountOut = 1; // Set to a very low amount to make deposit succeed

        vm.prank(solver);
        localAori.deposit(order, signature, srcData);

        vm.chainId(remoteEid);

        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(0x400), // Non-whitelisted hook
            preferredToken: address(outputToken),
            instructions: "",
            preferedDstInputAmount: order.outputAmount
        });

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        vm.expectRevert("Invalid hook address");
        remoteAori.fill(order, dstData);

        // Test insufficient output from destination hook
        dstData.hookAddress = address(mockHook);
        dstData.instructions = abi.encodeWithSelector(
            MockHook.handleHook.selector,
            address(outputToken),
            1
        ); // Will return much less than required

        vm.prank(solver);
        vm.expectRevert("Hook must provide at least the expected output amount");
        remoteAori.fill(order, dstData);
    }

    /**
     * @notice Test pause and unpause functionality
     * Verifies that pausing blocks operations and unpausing enables them again
     */
    function testPauseAndUnpause() public {
        vm.chainId(localEid);

        // Create a valid order
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Sign the order with the testLocalAori contract address
        bytes memory signature = signOrderWithContract(order, userAPrivKey, address(testLocalAori));

        vm.prank(userA);
        inputToken.approve(address(testLocalAori), order.inputAmount);

        // Pause the contract - ensure we're using the owner address
        // Note: Since testLocalAori was deployed with address(this) as owner
        testLocalAori.pause();

        // Attempt deposit while paused - should revert
        vm.prank(solver);
        vm.expectRevert();
        testLocalAori.deposit(order, signature);

        // Unpause the contract
        testLocalAori.unpause();

        // Deposit should now succeed
        vm.prank(solver);
        testLocalAori.deposit(order, signature);

        // Create a new order for the remote chain test
        IAori.Order memory remoteOrder = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Sign with the remote contract as the verifying address
        bytes memory remoteSignature = signOrderWithContract(
            remoteOrder,
            userAPrivKey,
            address(testRemoteAori)
        );

        // Test pause affecting fills on destination chain
        vm.chainId(remoteEid);
        vm.warp(remoteOrder.startTime + 10);

        vm.prank(solver);
        outputToken.approve(address(testRemoteAori), remoteOrder.outputAmount);

        // Pause the remote contract - ensure we're using the owner address
        testRemoteAori.pause();

        // Attempt fill while paused - should revert
        vm.prank(solver);
        vm.expectRevert();
        testRemoteAori.fill(remoteOrder);

        // Unpause the remote contract
        testRemoteAori.unpause();

        // Fill should now succeed
        vm.prank(solver);
        testRemoteAori.fill(remoteOrder);

        // Verify fill was successful
        assertEq(
            outputToken.balanceOf(userA),
            remoteOrder.outputAmount,
            "User did not receive correct output amount"
        );

        // Test pause affecting settlement
        vm.chainId(remoteEid);

        // Create options for the LayerZero message
        bytes memory options = defaultOptions();

        // Get quote for settlement and add buffer
        uint256 msgFee = testRemoteAori.quote(
            localEid,
            uint8(PayloadType.Settlement),
            options,
            false,
            localEid,
            solver
        );
        uint256 feeWithBuffer = (msgFee * 15) / 10; // 50% buffer for safety

        // Give solver ETH
        vm.deal(solver, feeWithBuffer * 2);

        // Pause the contract again
        testRemoteAori.pause();

        // Attempt settle while paused - should revert
        vm.prank(solver);
        vm.expectRevert();
        testRemoteAori.settle{ value: feeWithBuffer }(localEid, solver, options);

        // Unpause the contract
        testRemoteAori.unpause();

        // Settlement should now succeed
        vm.prank(solver);
        testRemoteAori.settle{ value: feeWithBuffer }(localEid, solver, options);
    }

    /**
     * @notice Signs an order using EIP712 with a specific contract address
     * This function is needed when testing with custom contract instances
     */
    function signOrderWithContract(
        IAori.Order memory order,
        uint256 privKey,
        address contractAddress
    ) internal pure returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
                ),
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.outputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid,
                order.offerer,
                order.recipient
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("0.3.0")),
                contractAddress
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }
}
