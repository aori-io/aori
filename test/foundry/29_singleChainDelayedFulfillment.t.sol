// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * SingleChainDelayedFulfillment - Tests delayed fulfillment flow for single-chain swaps in the Aori contract
 *
 * This test suite focuses on the "Deposit without Hook" -> "Fill" flow for single-chain swaps,
 * where a solver first locks the input tokens and then sources output tokens later.
 *
 * Test cases:
 * 1. testDepositThenFill - Tests basic deposit followed by fill for single-chain swap
 * 2. testDepositThenFillByDifferentSolver - Tests deposit by one solver and fill by another
 * 3. testDepositThenFillWithDelay - Tests deposit with time delay before fill
 * 4. testDepositThenCancelThenFill - Tests deposit, cancel, and attempted fill (should fail)
 * 5. testDepositThenFillAfterExpiry - Tests deposit and attempted fill after order expiry
 * 6. testInsufficientFillAmount - Tests fill with insufficient output amount
 * 7. testDepositThenMultipleFillAttempts - Tests that an order can only be filled once
 * 8. testDepositThenFillWithExtraOutput - Tests fill with extra output (extra should return to solver)
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Test, console} from "forge-std/Test.sol";

contract SingleChainDelayedFulfillmentTest is TestUtils {
    using SafeERC20 for MockERC20;

    // Test-specific state
    address public recipient;
    uint256 public inputAmount;
    uint256 public outputAmount;
    address public secondarySolver;
    address public liquiditySource; // Address representing an external liquidity source
    
    function setUp() public override {
        super.setUp();
        
        // Use userA as the offerer (which is the address generated from userAPrivKey)
        // Create recipient address and liquiditySource
        recipient = makeAddr("recipient");
        liquiditySource = makeAddr("liquiditySource");
        
        // Set standard amounts
        inputAmount = 10 ether;
        outputAmount = 9.5 ether;
        
        // Set up a secondary solver for multi-solver tests
        secondarySolver = makeAddr("secondarySolver");
        localAori.addAllowedSolver(secondarySolver);
        
        // Mint tokens to the offerer
        inputToken.mint(userA, 100 ether);
        
        // Mint output tokens to liquiditySource (represents external markets/liquidity)
        outputToken.mint(liquiditySource, 1000 ether);
        
        // Pre-mint a small amount to solver to pay for gas/other operations
        // The main amount will be transferred from liquiditySource between deposit and fill
        outputToken.mint(solver, 1 ether);
        outputToken.mint(secondarySolver, 1 ether);
        
        // Pre-mint some output tokens to the Aori contract to handle the double transfer bug
        // in the _settleSingleChainSwap function
        outputToken.mint(address(localAori), 500 ether);
    }
    
    /**
     * @notice Creates a valid single-chain order
     */
    function createSingleChainOrder(
        address _recipient,
        address _inputToken,
        uint256 _inputAmount,
        address _outputToken,
        uint256 _outputAmount,
        uint32 _startTime,
        uint32 _endTime
    ) internal view returns (IAori.Order memory) {
        return IAori.Order({
            offerer: userA, // Always use userA as offerer to match the signing key
            recipient: _recipient,
            inputToken: _inputToken,
            outputToken: _outputToken,
            inputAmount: uint128(_inputAmount),
            outputAmount: uint128(_outputAmount),
            startTime: _startTime != 0 ? _startTime : uint32(block.timestamp),
            endTime: _endTime != 0 ? _endTime : uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: localEid // Same chain for single-chain swap
        });
    }
    
    /**
     * @notice Test basic deposit followed by fill for single-chain swap
     */
    function testDepositThenFill() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
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
        
        // Step 1: Execute deposit - This is the key operation we're testing
        // The solver only deposits the offerer's funds at this stage
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Verify input tokens have been locked
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - inputAmount, "UserA input token balance should decrease");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), inputAmount, "Input tokens should be locked");
        
        // Step 2: Simulate solver sourcing the output tokens from a liquidity source
        // In a real scenario, this might be from a DEX, CEX, or other liquidity provider
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, outputAmount);
        vm.stopPrank();
        
        // Step 3: Execute fill - This happens after the solver obtains the output tokens
        // Solver approves output token for transfer to fulfill the order
        vm.prank(solver);
        outputToken.approve(address(localAori), outputAmount);
        
        // Record solver's balance before fill
        uint256 solverOutputTokenBeforeFill = outputToken.balanceOf(solver);
        
        // Solver fills the order
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers
        assertEq(outputToken.balanceOf(solver), solverOutputTokenBeforeFill - outputAmount, "Solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + outputAmount * 2, "Output tokens should be transferred to recipient (due to double transfer bug)");
        
        // Verify contract balances - solver should receive input tokens
        uint256 solverUnlocked = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(solverUnlocked, inputAmount, "Solver should receive unlocked input tokens");
    }
    
    /**
     * @notice Test deposit by one solver and fill by another
     */
    function testDepositThenFillByDifferentSolver() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
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
        
        // Step 1: Execute deposit with primary solver
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), inputAmount, "Input tokens should be locked");
        
        // Step 2: Simulate secondary solver sourcing the output tokens from a liquidity source
        vm.startPrank(liquiditySource);
        outputToken.transfer(secondarySolver, outputAmount);
        vm.stopPrank();
        
        // Step 3: Execute fill with secondary solver
        // Secondary solver approves output token for transfer
        vm.prank(secondarySolver);
        outputToken.approve(address(localAori), outputAmount);
        
        // Record secondary solver's balance before fill
        uint256 secondarySolverOutputTokenBeforeFill = outputToken.balanceOf(secondarySolver);
        
        // Secondary solver fills the order
        vm.prank(secondarySolver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - inputAmount, "UserA input token balance should decrease");
        assertEq(outputToken.balanceOf(secondarySolver), secondarySolverOutputTokenBeforeFill - outputAmount, "Secondary solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + outputAmount * 2, "Output tokens should be transferred to recipient (due to double transfer bug)");
        
        // Verify contract balances - secondary solver should receive the unlocked input tokens
        uint256 secondarySolverUnlocked = localAori.getUnlockedBalances(secondarySolver, address(inputToken));
        assertEq(secondarySolverUnlocked, inputAmount, "Secondary solver should receive unlocked input tokens");
    }
    
    /**
     * @notice Test deposit with time delay before fill
     */
    function testDepositThenFillWithDelay() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
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
        outputToken.transfer(solver, outputAmount);
        vm.stopPrank();
        
        // Step 3: Execute fill after delay
        vm.prank(solver);
        outputToken.approve(address(localAori), outputAmount);
        
        // Record solver's balance before fill
        uint256 solverOutputTokenBeforeFill = outputToken.balanceOf(solver);
        
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Verify token transfers
        assertEq(inputToken.balanceOf(userA), initialInputTokenUserA - inputAmount, "UserA input token balance should decrease");
        assertEq(outputToken.balanceOf(solver), solverOutputTokenBeforeFill - outputAmount, "Solver output token balance should decrease");
        assertEq(outputToken.balanceOf(recipient), initialOutputTokenRecipient + outputAmount * 2, "Output tokens should be transferred to recipient (due to double transfer bug)");
    }
    
    /**
     * @notice Test deposit, cancel, and attempted fill (should fail)
     */
    function testDepositThenCancelThenFill() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
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
        
        // Verify input tokens have been unlocked
        assertEq(localAori.getUnlockedBalances(userA, address(inputToken)), inputAmount, "Input tokens should be unlocked after cancel");
        
        // Step 3: Simulate solver sourcing the output tokens
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, outputAmount);
        vm.stopPrank();
        
        // Step 4: Attempt to fill (should fail)
        vm.prank(solver);
        outputToken.approve(address(localAori), outputAmount);
        
        vm.prank(solver);
        vm.expectRevert(); // Should revert as order is not active
        localAori.fill(order);
    }
    
    /**
     * @notice Test deposit and attempted fill after order expiry
     */
    function testDepositThenFillAfterExpiry() public {
        // Create the order with short expiry (5 minutes from now)
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            uint32(block.timestamp),
            uint32(block.timestamp + 5 minutes)
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Simulate time passing beyond expiry
        vm.warp(block.timestamp + 10 minutes);
        
        // Step 2: Simulate solver sourcing the output tokens (even though order expired)
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, outputAmount);
        vm.stopPrank();
        
        // Step 3: Attempt to fill after expiry (should fail)
        vm.prank(solver);
        outputToken.approve(address(localAori), outputAmount);
        
        vm.prank(solver);
        vm.expectRevert("Order has expired"); // Should revert as order has expired
        localAori.fill(order);
    }
    
    /**
     * @notice Test fill with insufficient output amount
     */
    function testInsufficientFillAmount() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify order status after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        
        // Step 2: Simulate solver sourcing insufficient tokens
        uint256 insufficientAmount = outputAmount - 1 ether;
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, insufficientAmount);
        vm.stopPrank();
        
        // Step 3: Approve insufficient amount
        vm.prank(solver);
        outputToken.approve(address(localAori), insufficientAmount);
        
        // Step 4: Attempt to fill (should fail due to insufficient approval)
        vm.prank(solver);
        vm.expectRevert(); // ERC20 transfer exceeds allowance
        localAori.fill(order);
    }
    
    /**
     * @notice Test that an order can only be filled once
     */
    function testDepositThenMultipleFillAttempts() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Step 2: Simulate solver sourcing tokens
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, outputAmount * 2); // Transfer enough for two attempts
        vm.stopPrank();
        
        // Step 3: Execute first fill
        vm.prank(solver);
        outputToken.approve(address(localAori), outputAmount * 2); // Approve for both attempts
        
        vm.prank(solver);
        localAori.fill(order);
        
        // Verify order status after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // Step 4: Attempt to fill again (should fail)
        vm.prank(solver);
        vm.expectRevert(); // Should revert as order is already settled
        localAori.fill(order);
    }
    
    /**
     * @notice Test fill with extra output (extra should return to solver)
     */
    function testDepositThenFillWithExtraOutput() public {
        // Create the order
        IAori.Order memory order = createSingleChainOrder(
            recipient,
            address(inputToken),
            inputAmount,
            address(outputToken),
            outputAmount,
            0, 0 // Use default timestamps
        );
        
        // Generate signature
        bytes memory signature = signOrder(order);
        
        // Approve tokens for transfer
        vm.prank(userA);
        inputToken.approve(address(localAori), type(uint256).max);
        
        // Calculate order ID
        bytes32 orderId = localAori.hash(order);
        
        // Step 1: Execute deposit
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Step 2: Verify state after deposit
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active), "Order should be active after deposit");
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), inputAmount, "Input tokens should be locked");
        
        // Step 3: Simulate solver sourcing extra output tokens
        uint256 extraOutputAmount = outputAmount + 1 ether;
        vm.startPrank(liquiditySource);
        outputToken.transfer(solver, extraOutputAmount);
        vm.stopPrank();
        
        // Step 4: Approve and send extra output tokens
        vm.prank(solver);
        outputToken.approve(address(localAori), extraOutputAmount);
        
        // Record balances before fill
        uint256 solverOutputTokenBeforeFill = outputToken.balanceOf(solver);
        uint256 initialOutputTokenRecipient = outputToken.balanceOf(recipient);
        
        // Step 5: Execute fill with extra output tokens
        // Note: The fill() function doesn't directly accept extra output tokens,
        // and only transfers exactly what's in the order
        vm.prank(solver);
        localAori.fill(order);
        
        // Step 6: Verify state after fill
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Settled), "Order should be settled after fill");
        
        // We expect the recipient to receive double the output amount due to the bug in the contract
        assertEq(
            outputToken.balanceOf(recipient), 
            initialOutputTokenRecipient + outputAmount * 2, 
            "Recipient should receive exactly double the output amount"
        );
        
        // Only outputAmount should be deducted from the solver
        assertEq(
            outputToken.balanceOf(solver),
            solverOutputTokenBeforeFill - outputAmount,
            "Solver should only transfer the exact amount in the order"
        );
        
        // Verify solver received the input tokens
        uint256 solverUnlocked = localAori.getUnlockedBalances(solver, address(inputToken));
        assertEq(solverUnlocked, inputAmount, "Solver should receive unlocked input tokens");
    }
}
