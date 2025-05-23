// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TestUtils.sol";

/**
 * @title CancelGasReport
 * @notice Gas comparison tests for source chain vs destination chain cancellations
 * @dev Tests the gas consumption difference between cancelling orders on the source chain 
 *      versus sending a cross-chain cancellation message from the destination chain
 */
contract CancelGasReport is TestUtils {
    
    // Track gas measurements
    uint256 public sourceChainCancelGas;
    uint256 public destinationChainCancelGas;
    
    function setUp() public override {
        super.setUp();
        
        // Give solver ETH for cross-chain fees
        vm.deal(solver, 10 ether);
        
        // Ensure mock hook has enough converted tokens
        convertedToken.mint(address(mockHook), 10000e18);
    }
    
    /**
     * @notice Test gas consumption for source chain cancellation
     * @dev Measures gas used when a solver cancels a single-chain order on the source chain
     */
    function test_SourceChainCancelGas() public {
        // Create a SINGLE-CHAIN order (srcEid = dstEid = localEid) for source chain cancellation
        IAori.Order memory order = createCustomOrder(
            userA,           // offerer
            userA,           // recipient  
            address(inputToken),  // inputToken
            address(outputToken), // outputToken
            1e18,            // inputAmount
            2e18,            // outputAmount
            block.timestamp, // startTime
            block.timestamp + 1 days, // endTime
            localEid,        // srcEid
            localEid         // dstEid - SAME as srcEid for single-chain
        );
        
        bytes memory signature = signOrder(order);
        
        // Setup tokens for deposit
        vm.startPrank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.stopPrank();
        
        // Deposit order as solver
        vm.startPrank(solver);
        localAori.deposit(order, signature);
        vm.stopPrank();
        
        // Get order hash
        bytes32 orderId = localAori.hash(order);
        
        // Verify order is active
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Active));
        
        // Measure gas for source chain cancellation
        vm.startPrank(solver);
        uint256 gasBefore = gasleft();
        localAori.cancel(orderId);
        sourceChainCancelGas = gasBefore - gasleft();
        vm.stopPrank();
        
        // Verify cancellation worked
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Cancelled));
        
        console.log("Source Chain Cancel Gas:", sourceChainCancelGas);
    }
    
    /**
     * @notice Test gas consumption for destination chain cancellation
     * @dev Measures gas used when a solver cancels an expired cross-chain order from the destination chain
     */
    function test_DestinationChainCancelGas() public {
        // Create a CROSS-CHAIN order but with short expiry time
        IAori.Order memory order = createCustomOrder(
            userA,           // offerer
            userA,           // recipient  
            address(inputToken),  // inputToken
            address(outputToken), // outputToken
            1e18,            // inputAmount
            2e18,            // outputAmount
            block.timestamp, // startTime
            block.timestamp + 1 hours, // endTime - shorter for easier expiry
            localEid,        // srcEid
            remoteEid        // dstEid - different from srcEid for cross-chain
        );
        
        bytes memory signature = signOrder(order);
        
        // Setup tokens for deposit
        vm.startPrank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.stopPrank();
        
        // Deposit order as solver on source chain
        vm.startPrank(solver);
        localAori.deposit(order, signature);
        vm.stopPrank();
        
        // Get order hash
        bytes32 orderId = localAori.hash(order);
        
        // Verify order is active on source chain
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Active));
        
        // ADVANCE TIME PAST EXPIRY so solver can cancel
        vm.warp(block.timestamp + 2 hours);
        
        // Measure gas for destination chain cancellation (cross-chain message)
        vm.startPrank(solver);
        uint256 gasBefore = gasleft();
        
        // Cancel from destination chain - this sends a cross-chain message
        remoteAori.cancel{value: 1 ether}(
            orderId, 
            order, 
            defaultOptions()
        );
        
        destinationChainCancelGas = gasBefore - gasleft();
        vm.stopPrank();
        
        // Verify cancellation was initiated on destination chain
        assertEq(uint256(remoteAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Cancelled));
        
        console.log("Destination Chain Cancel Gas:", destinationChainCancelGas);
    }
    
    /**
     * @notice Compare gas costs between source and destination chain cancellations
     * @dev Runs both tests and provides a detailed comparison
     */
    function test_CancelGasComparison() public {
        // Run both gas tests
        test_SourceChainCancelGas();
        test_DestinationChainCancelGas();
        
        // Calculate difference and percentage
        uint256 gasDifference = destinationChainCancelGas > sourceChainCancelGas 
            ? destinationChainCancelGas - sourceChainCancelGas
            : sourceChainCancelGas - destinationChainCancelGas;
            
        uint256 percentageIncrease = destinationChainCancelGas > sourceChainCancelGas
            ? (gasDifference * 100) / sourceChainCancelGas
            : 0;
        
        // Report results
        console.log("=== CANCEL GAS COMPARISON REPORT ===");
        console.log("Source Chain Cancel Gas:     ", sourceChainCancelGas);
        console.log("Destination Chain Cancel Gas:", destinationChainCancelGas);
        console.log("Gas Difference:              ", gasDifference);
        
        if (destinationChainCancelGas > sourceChainCancelGas) {
            console.log("Destination chain cancel uses", percentageIncrease, "% more gas");
        } else {
            console.log("Source chain cancel uses more gas");
        }
        
        // Assertions for expected behavior
        assertTrue(destinationChainCancelGas > sourceChainCancelGas, "Destination cancel should use more gas due to LayerZero messaging");
        assertTrue(gasDifference > 50000, "Expected significant gas difference due to cross-chain messaging overhead");
    }
    
    /**
     * @notice Test gas consumption for source chain cancellation with hook-deposited order
     * @dev Tests cancellation gas when the order was deposited using a source hook
     */
    function test_SourceChainCancelWithHookGas() public {
        // Create CROSS-CHAIN order for hook-based deposit (single-chain orders with hooks get immediately settled)
        IAori.Order memory order = createCustomOrder(
            userA,           // offerer
            userA,           // recipient  
            address(inputToken),  // inputToken
            address(outputToken), // outputToken
            1e18,            // inputAmount
            2e18,            // outputAmount
            block.timestamp, // startTime
            block.timestamp + 1 days, // endTime
            localEid,        // srcEid
            remoteEid        // dstEid - cross-chain so it doesn't auto-settle
        );
        
        bytes memory signature = signOrder(order);
        
        // For cross-chain orders with hooks, the hook receives inputToken and provides preferredToken
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook),
            preferredToken: address(convertedToken), // This is what the hook will provide
            minPreferedTokenAmountOut: 1e18, // Minimum we expect from hook
            instructions: abi.encodeWithSelector(
                mockHook.handleHook.selector, 
                address(convertedToken), // Hook will return this token
                2e18  // Hook will provide 2e18 of convertedToken
            )
        });
        
        // Setup tokens for hook deposit - hook needs convertedToken to give back
        convertedToken.mint(address(mockHook), 10e18);
        
        // Setup user approval for inputToken (what goes to hook)
        vm.startPrank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.stopPrank();
        
        // Deposit order with hook as solver
        vm.startPrank(solver);
        localAori.deposit(order, signature, srcHook);
        vm.stopPrank();
        
        // Get order hash
        bytes32 orderId = localAori.hash(order);
        
        // Verify order is active (cross-chain with hook should be Active, not Settled)
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Active));
        
        // Advance time past expiry so solver can cancel cross-chain order
        vm.warp(block.timestamp + 2 days);
        
        // Measure gas for cancellation of hook-deposited order
        vm.startPrank(solver);
        uint256 gasBefore = gasleft();
        localAori.cancel(orderId);
        uint256 hookCancelGas = gasBefore - gasleft();
        vm.stopPrank();
        
        // Verify cancellation worked
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Cancelled));
        
        console.log("Source Chain Cancel (with hook) Gas:", hookCancelGas);
        
        // Compare with regular source chain cancel
        if (sourceChainCancelGas > 0) {
            uint256 difference = hookCancelGas > sourceChainCancelGas 
                ? hookCancelGas - sourceChainCancelGas
                : sourceChainCancelGas - hookCancelGas;
            console.log("Gas difference vs regular cancel:", difference);
        }
    }
    
    /**
     * @notice Test cross-chain solver cancellation on source chain after expiry
     * @dev Tests gas consumption when solver cancels expired cross-chain order on source chain
     */
    function test_SourceChainCrossChainSolverCancelGas() public {
        // Create cross-chain order with short expiry
        IAori.Order memory order = createCustomOrder(
            userA,           // offerer
            userA,           // recipient  
            address(inputToken),  // inputToken
            address(outputToken), // outputToken
            1e18,            // inputAmount
            2e18,            // outputAmount
            block.timestamp, // startTime
            block.timestamp + 1 hours, // endTime
            localEid,        // srcEid
            remoteEid        // dstEid - cross-chain
        );
        
        bytes memory signature = signOrder(order);
        
        // Setup tokens for deposit
        vm.startPrank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        vm.stopPrank();
        
        // Deposit order as solver
        vm.startPrank(solver);
        localAori.deposit(order, signature);
        vm.stopPrank();
        
        // Get order hash
        bytes32 orderId = localAori.hash(order);
        
        // Verify order is active
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Active));
        
        // ADVANCE TIME PAST EXPIRY
        vm.warp(block.timestamp + 2 hours);
        
        // Measure gas for solver cancelling cross-chain order on source chain
        vm.startPrank(solver);
        uint256 gasBefore = gasleft();
        localAori.cancel(orderId);
        uint256 crossChainSolverCancelGas = gasBefore - gasleft();
        vm.stopPrank();
        
        // Verify cancellation worked
        assertEq(uint256(localAori.orderStatus(orderId)), uint256(IAori.OrderStatus.Cancelled));
        
        console.log("Cross-chain Solver Cancel (source) Gas:", crossChainSolverCancelGas);
    }
}
