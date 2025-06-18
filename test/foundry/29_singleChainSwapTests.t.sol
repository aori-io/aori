// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * SingleChainSwapTests - Comprehensive tests for single-chain swap pathways
 *
 * This test suite covers the remaining single-chain swap flows:
 * 1. Two-step path: deposit followed by fill
 * 2. Hook-based path: deposit with hook for token conversion
 *
 * It also tests edge cases, overflow conditions, and verifies the fixes for:
 * - No double-charging in hook path
 * - No double-transfers in fill path
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {MockHook} from "../Mock/MockHook.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract SingleChainSwapTests is TestUtils {
    using SafeERC20 for MockERC20;

    // Test-specific state
    MockHook public testHook;
    address public recipient;
    address public secondarySolver;
    address public liquiditySource;
    
    // Large values for overflow testing
    uint128 public constant MAX_UINT128 = type(uint128).max;
    uint128 public constant LARGE_AMOUNT = MAX_UINT128 - 1000;
    
    // Standard test amounts
    uint256 public constant INPUT_AMOUNT = 10 ether;
    uint256 public constant OUTPUT_AMOUNT = 5 ether;
    
    function setUp() public override {
        super.setUp();
        
        // Create recipient and liquidity source addresses
        recipient = makeAddr("recipient");
        liquiditySource = makeAddr("liquiditySource");
        
        // Set up secondary solver for multi-solver tests
        secondarySolver = makeAddr("secondarySolver");
        localAori.addAllowedSolver(secondarySolver);
        
        // Deploy and set up test hook
        testHook = new MockHook();
        localAori.addAllowedHook(address(testHook));
        
        // Mint tokens for testing
        inputToken.mint(userA, 1000 ether);
        outputToken.mint(solver, 500 ether);
        outputToken.mint(secondarySolver, 500 ether);
        outputToken.mint(address(testHook), 500 ether);
        outputToken.mint(liquiditySource, 1000 ether);
        
        // Mint tokens for overflow tests
        MockERC20 largeToken = new MockERC20("Large", "LRG");
        largeToken.mint(userA, LARGE_AMOUNT);
        largeToken.mint(solver, LARGE_AMOUNT);
        largeToken.mint(address(testHook), LARGE_AMOUNT);
    }
    
    /**
     * @notice Creates a valid single-chain order
     */
    function createSingleChainOrder(
        address _recipient,
        address _inputToken,
        uint256 _inputAmount,
        address _outputToken,
        uint256 _outputAmount
    ) internal view returns (IAori.Order memory) {
        return IAori.Order({
            offerer: userA,
            recipient: _recipient,
            inputToken: _inputToken,
            outputToken: _outputToken,
            inputAmount: uint128(_inputAmount),
            outputAmount: uint128(_outputAmount),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: localEid // Same chain for single-chain swap
        });
    }
    
    /**
     * @notice Creates hook data for the test hook
     */
    function createHookData(
        address tokenToReturn,
        uint256 amount
    ) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(
            MockHook.handleHook.selector,
            tokenToReturn,
            amount
        );
    }
    // =========================================================================
    // PATH 2: DEPOSIT-THEN-FILL TESTS
    // =========================================================================
    
    /**
     * @notice Test basic deposit followed by fill for single-chain swap
     */
    function testDepositThenFill() public {
        // Create order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Record balances before operation
        uint256 initialInputTokenUserA = inputToken.balanceOf(userA);
        uint256 initialOutputTokenRecipient = outputToken.balanceOf(recipient);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit - This is the key operation we're testing
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Verify input tokens have been locked
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - INPUT_AMOUNT, "UserA input token balance should decrease");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), INPUT_AMOUNT, "Input tokens should be locked");
        
        // Step 2: Simulate solver sourcing the output tokens from a liquidity source
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, OUTPUT_AMOUNT);
        vm.stopPrank();
        
        // Step 3: Execute fill
        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        // Record solver's balance before fill
        uint256 solverOutputTokenBeforeFill = outputToken.balanceOf(solver);
        
        // Solver fills the order
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers - output should transfer exactly once
        assertEq(outputToken.balanceOf(solver), solverOutputTokenBeforeFill - OUTPUT_AMOUNT, "Solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + OUTPUT_AMOUNT, "Output tokens should be transferred to recipient exactly once");
        
        // Verify contract balances - solver should receive input tokens
        uint256 solverUnlocked = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(solverUnlocked, INPUT_AMOUNT, "Solver should receive unlocked input tokens");
    }
    
    /**
     * @notice Test deposit by one solver and fill by another
     */
    function testDepositThenFillByDifferentSolver() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Record balances before operation
        uint256 initialInputTokenUserA = inputToken.balanceOf(userA);
        uint256 initialOutputTokenRecipient = outputToken.balanceOf(recipient);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit with primary solver
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), INPUT_AMOUNT, "Input tokens should be locked");
        
        // Step 2: Simulate secondary solver sourcing the output tokens from a liquidity source
        vm.startPrank(liquiditySource);
        outputToken.transfer(secondarySolver, OUTPUT_AMOUNT);
        vm.stopPrank();
        
        // Step 3: Execute fill with secondary solver
        vm.prank(secondarySolver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        // Record secondary solver's balance before fill
        uint256 secondarySolverOutputTokenBeforeFill = outputToken.balanceOf(secondarySolver);
        
        // Secondary solver fills the order
        vm.prank(secondarySolver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - INPUT_AMOUNT, "UserA input token balance should decrease");
        assertEq(outputToken.balanceOf(secondarySolver), secondarySolverOutputTokenBeforeFill - OUTPUT_AMOUNT, "Secondary solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + OUTPUT_AMOUNT, "Output tokens should be transferred to recipient exactly once");
        
        // Verify contract balances - secondary solver should receive the unlocked input tokens
        uint256 secondarySolverUnlocked = localAori.getUnlockedBalances(secondarySolver, address(inputToken));
        assertEq(secondarySolverUnlocked, INPUT_AMOUNT, "Secondary solver should receive unlocked input tokens");
    }
    
    /**
     * @notice Test deposit, cancel, and attempted fill (should fail)
     */
    function testDepositThenCancelThenFill() public {
        // Store user's initial balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Step 2: Cancel the order
        vm.prank(solver);
        localAori.cancel(orderId);
        
        // Verify order status after cancel
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Cancelled), "Order should be cancelled");
        
        // Verify input tokens have been transferred directly back to user
        uint256 finalUserBalance = inputToken.balanceOf(userA);
        assertEq(finalUserBalance, initialUserBalance, "Input tokens should be returned directly to user after cancel");
        
        // Verify no unlocked balance exists
        assertEq(localAori.getUnlockedBalances(userA, address(inputToken)), 0, "No unlocked balance should exist with direct transfer");
        
        // Step 3: Simulate solver sourcing the output tokens
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, OUTPUT_AMOUNT);
        vm.stopPrank();
        
        // Step 4: Attempt to fill (should fail)
        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        vm.prank(solver);
        vm.expectRevert(); // Should revert as order is not active
        localAori.fill(order);
    }
    
    /**
     * @notice Test deposit with time delay before fill
     */
    function testDepositThenFillWithDelay() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Record balances before operation
        uint256 initialInputTokenUserA = inputToken.balanceOf(userA);
        uint256 initialOutputTokenRecipient = outputToken.balanceOf(recipient);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Simulate time passing (4 hours) - This is the key part of this test
        // Simulating the solver finding the output tokens over time
        vm.warp(block.timestamp + 4 hours);
        
        // Step 2: Simulate solver sourcing the output tokens after some time
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, OUTPUT_AMOUNT);
        vm.stopPrank();
        
        // Step 3: Execute fill after delay
        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        // Record solver's balance before fill
        uint256 solverOutputTokenBeforeFill = outputToken.balanceOf(solver);
        
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - INPUT_AMOUNT, "UserA input token balance should decrease");
        assertEq(outputToken.balanceOf(solver), solverOutputTokenBeforeFill - OUTPUT_AMOUNT, "Solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + OUTPUT_AMOUNT, "Output tokens should be transferred to recipient exactly once");
    }

    /**
     * @notice Test fill attempt after order expiry (should fail)
     */
    function testDepositThenFillAfterExpiry() public {
        // Create the order with short expiration time
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(INPUT_AMOUNT),
            outputAmount: uint128(OUTPUT_AMOUNT),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours), // Short expiration
            srcEid: localEid,
            dstEid: localEid // Same chain for single-chain swap
        });
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Warp time past expiration
        vm.warp(block.timestamp + 2 hours);
        
        // Step 2: Attempt to fill after expiry (should fail)
        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        // Solver attempts to fill the expired order
        vm.prank(solver);
        vm.expectRevert(); // Should revert as order is expired
        localAori.fill(order);
        
        // Order should still be active but expired
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should still be active until cancelled");
    }
    
    /**
     * @notice Test user cancellation of their own expired single-chain order
     * @dev Tests the new functionality allowing users to cancel expired orders
     */
    function testUserCancelExpiredSingleChainOrder() public {
        // Record initial token balance
        uint256 initialUserBalance = inputToken.balanceOf(userA);
        
        // Create the order with short expiration time
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(INPUT_AMOUNT),
            outputAmount: uint128(OUTPUT_AMOUNT),
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours), // Short expiration
            srcEid: localEid,
            dstEid: localEid // Same chain for single-chain swap
        });
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), INPUT_AMOUNT, "Input tokens should be locked");
        
        // Warp time past expiration
        vm.warp(block.timestamp + 2 hours);
        
        // Step 2: User cancels their own expired order
        vm.prank(userA);
        localAori.cancel(orderId);
        
        // Verify order status after cancellation
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Cancelled), "Order should be cancelled");
        
        // Verify tokens are transferred directly back to the user
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), 0, "No tokens should remain locked");
        assertEq(localAori.getUnlockedBalances(userA, address(inputToken)), 0, "No unlocked balance should exist with direct transfer");
        
        // Verify tokens returned to the user - check against initial balance
        assertEq(inputToken.balanceOf(userA), initialUserBalance, "User should receive their tokens back directly");
        
        // No withdrawal needed since tokens were transferred directly
    }
    
    /**
     * @notice Test fill with insufficient output amount (should fail)
     */
    function testInsufficientFillAmount() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Step 2: Prepare insufficient output tokens (less than required)
        uint256 insufficientAmount = OUTPUT_AMOUNT - 1;
        
        // Step 3: Attempt to fill with insufficient amount
        vm.prank(solver);
        outputToken.approve(address(localAori), insufficientAmount);
        
        // Solver attempts to fill with insufficient amount
        vm.prank(solver);
        vm.expectRevert(); // Should revert as amount is insufficient
        localAori.fill(order);
        
        // Order should still be active
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should still be active");
    }
    
    /**
     * @notice Test multiple fill attempts (only first should succeed)
     */
    function testDepositThenMultipleFillAttempts() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Step 2: First solver execution (should succeed)
        vm.startPrank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        localAori.fill(order);
        vm.stopPrank();
        
        // Verify order status after first fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after first fill");
        
        // Step 3: Second solver attempts to fill the same order (should fail)
        vm.startPrank(secondarySolver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        vm.expectRevert(); // Should revert as order is already settled
        localAori.fill(order);
        vm.stopPrank();
    }
    
    /**
     * @notice Test fill with extra output (surplus should remain with solver)
     */
    function testDepositThenFillWithExtraOutput() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Step 2: Prepare extra output tokens
        uint256 extraAmount = OUTPUT_AMOUNT + 1 ether;
        
        // Transfer extra tokens to solver
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, extraAmount);
        vm.stopPrank();
        
        // Step 3: Approve and fill with extra amount
        vm.startPrank(solver);
        outputToken.approve(address(localAori), extraAmount);
        
        // Record balances before fill
        uint256 solverBalanceBefore = outputToken.balanceOf(solver);
        uint256 recipientBalanceBefore = outputToken.balanceOf(recipient);
        
        // Fill the order
        localAori.fill(order);
        vm.stopPrank();
        
        // Verify only the exact amount was transferred to recipient
        assertEq(
            outputToken.balanceOf(recipient), 
            recipientBalanceBefore + OUTPUT_AMOUNT, 
            "Recipient should receive exactly the output amount"
        );
        
        // Verify solver kept the surplus
        assertEq(
            outputToken.balanceOf(solver),
            solverBalanceBefore - OUTPUT_AMOUNT,
            "Solver should only transfer the exact amount in the order"
        );
    }
    
    // =========================================================================
    // PATH 3: HOOK-BASED TESTS
    // =========================================================================
    
    /**
     * @notice Test successful deposit with hook for single-chain swaps
     * @dev Verifies tokens are correctly transferred and no double charging occurs
     */
    function testDepositWithHookSuccess() public {
        // Create hook data
        bytes memory hookData = createHookData(
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Create hook structure
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: address(testHook),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: hookData
        });
        
        // Record balances before operation
        uint256 initialInputBalance = inputToken.balanceOf(userA);
        uint256 initialRecipientBalance = outputToken.balanceOf(recipient);
        bytes32 orderId = localAori.hash(order);
        
        // Execute deposit with hook
        vm.prank(solver);
        localAori.deposit(order, signature, hook);
        
        // Verify input tokens were deducted exactly once
        assertEq(inputToken.balanceOf(userA), initialInputBalance - INPUT_AMOUNT, "Input tokens should be deducted exactly once");
        
        // Verify output tokens were sent exactly once
        assertEq(outputToken.balanceOf(recipient), initialRecipientBalance + OUTPUT_AMOUNT, "Output tokens should be sent exactly once");
        
        // Verify order status
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled immediately");
        
        // In the hook path, solver does NOT receive credit for input tokens
        // since they went directly to the hook, not through the contract
        assertEq(localAori.getUnlockedBalances(solver, address(inputToken)), 0, "Solver should NOT have unlocked balance in hook path");
    }
    
    /**
     * @notice Test deposit with hook with extra output for single-chain swaps
     * @dev Verifies surplus tokens are returned to the solver
     */
    function testDepositWithHookSurplus() public {
        // Use larger output amount than required
        uint256 extraOutputAmount = OUTPUT_AMOUNT + 1 ether;
        
        // Create hook data with extra output
        bytes memory hookData = createHookData(
            address(outputToken),
            extraOutputAmount
        );
        
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT  // Order only expects this amount
        );
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Create hook structure
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: address(testHook),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: hookData
        });
        
        // Record balances before
        uint256 initialSolverBalance = outputToken.balanceOf(solver);
        uint256 initialRecipientBalance = outputToken.balanceOf(recipient);
        
        // Execute deposit with hook
        vm.prank(solver);
        localAori.deposit(order, signature, hook);
        
        // Verify recipient received exactly the output amount (not extra)
        assertEq(outputToken.balanceOf(recipient), initialRecipientBalance + OUTPUT_AMOUNT, "Recipient should receive exact output amount");
        
        // Verify solver received the surplus
        uint256 expectedSurplus = extraOutputAmount - OUTPUT_AMOUNT;
        assertEq(outputToken.balanceOf(solver), initialSolverBalance + expectedSurplus, "Solver should receive surplus tokens");
    }
    
    // =========================================================================
    // SPECIFIC FIX VALIDATION TESTS
    // =========================================================================
    
    /**
     * @notice Test that hook-based settlement doesn't double-charge the offerer
     */
    function testNoDoubleChargingInHookPath() public {
        // Create order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Set up hook
        bytes memory hookData = createHookData(
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: address(testHook),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: hookData
        });
        
        // Record initial balance
        uint256 initialBalance = inputToken.balanceOf(userA);
        
        // Execute deposit with hook
        vm.prank(userA);
        inputToken.approve(address(localAori), INPUT_AMOUNT);
        
        vm.prank(solver);
        localAori.deposit(order, signOrder(order), hook);
        
        // Verify user was only charged once
        assertEq(
            inputToken.balanceOf(userA), 
            initialBalance - INPUT_AMOUNT,
            "User should only be charged input amount once"
        );
    }

    /**
     * @notice Test that fill path doesn't double-transfer output tokens
     */
    function testNoDoubleTransferInFillPath() public {
        // Create and deposit order first
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            INPUT_AMOUNT,
            address(outputToken),
            OUTPUT_AMOUNT
        );
        
        // Deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), INPUT_AMOUNT);
        
        vm.prank(solver);
        localAori.deposit(order, signOrder(order));
        
        // Record balances before fill
        uint256 initialSolverBalance = outputToken.balanceOf(solver);
        uint256 initialRecipientBalance = outputToken.balanceOf(recipient);
        
        // Fill
        vm.prank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);
        
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify output tokens were transferred exactly once
        assertEq(
            outputToken.balanceOf(solver),
            initialSolverBalance - OUTPUT_AMOUNT,
            "Solver should only be charged output amount once"
        );
        
        assertEq(
            outputToken.balanceOf(recipient),
            initialRecipientBalance + OUTPUT_AMOUNT,
            "Recipient should receive output amount exactly once"
        );
    }
    
    // =========================================================================
    // COMPARISONS AND EDGE CASES
    // =========================================================================
    
    /**
     * @notice Comprehensive test comparing the two remaining pathways with identical parameters
     */
    function testAllPathsConsistency() public {
        // Create two orders with slight differences
        IAori.Order memory order1 = createSingleChainOrder(
            recipient, address(inputToken), INPUT_AMOUNT, address(outputToken), OUTPUT_AMOUNT
        );
        IAori.Order memory order2 = createSingleChainOrder(
            recipient, address(inputToken), INPUT_AMOUNT + 1, address(outputToken), OUTPUT_AMOUNT
        );
        
        // Calculate accurate total - only deposit+fill path credits solver with input tokens
        // Hook path doesn't credit solver with input tokens
        uint256 expectedTotal = INPUT_AMOUNT;
        
        // Ensure userA has enough tokens
        inputToken.mint(userA, INPUT_AMOUNT + (INPUT_AMOUNT + 1));
        
        // Sign all orders
        bytes memory sig1 = signOrder(order1);
        bytes memory sig2 = signOrder(order2);
        
        // Approve tokens for all paths - explicit larger amounts
        vm.startPrank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        vm.stopPrank();
        
        // Setup hook for path 2
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: address(testHook),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: createHookData(address(outputToken), OUTPUT_AMOUNT)
        });
        
        // Ensure solver has enough output tokens
        outputToken.mint(solver, OUTPUT_AMOUNT * 2);
        
        vm.startPrank(solver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT * 2);
        
        // Execute Path 1: deposit+fill
        localAori.deposit(order1, sig1);
        localAori.fill(order1);
        
        // Execute Path 2: deposit with hook
        localAori.deposit(order2, sig2, hook);
        vm.stopPrank();
        
        // Get solver unlocked balances for all paths
        uint256 balance1 = localAori.getUnlockedBalances(solver, address(inputToken));
        
        // Verify only deposit+fill path credits solver, but hook path doesn't
        assertEq(balance1, expectedTotal, "Only deposit+fill path should credit solver with input tokens");
        
        // Verify recipient received the same amount each time (2 * OUTPUT_AMOUNT)
        assertEq(outputToken.balanceOf(recipient), OUTPUT_AMOUNT * 2, "Recipient should receive the same amount from both paths");
        
        // Verify all orders have the same final status
        bytes32 id1 = localAori.hash(order1);
        bytes32 id2 = localAori.hash(order2);
        
        assertEq(uint8(localAori.orderStatus(id1)), uint8(IAori.OrderStatus.Settled), "Order 1 should be settled");
        assertEq(uint8(localAori.orderStatus(id2)), uint8(IAori.OrderStatus.Settled), "Order 2 should be settled");
    }


}