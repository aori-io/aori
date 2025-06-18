// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain Native Deposit → ERC20 (No Hooks)
 * @notice Tests the simplest single-chain swap case: Native deposit (no Hook) → ERC20 output (no Hook)
 * @dev Tests the complete flow:
 *   1. User deposits native ETH using depositNative() - ETH gets locked in contract
 *   2. Solver fills order with ERC20 tokens using fill() - direct ERC20 transfer to user
 *   3. Atomic settlement - locked ETH transferred to solver's unlocked balance
 * @dev Flow: depositNative(order) -> fill(order)
 * 
 * @dev This is the simplest case with no hooks involved - pure atomic settlement
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testNativeToERC20NoHookWithDetailedLogging -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";

contract SC_NativeToERC20NoHook_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;        // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 2000e18;       // ERC20 output tokens (user receives)

    // Single-chain addresses
    address public userSC;     // User on single chain
    address public solverSC;   // Solver on single chain

    // Private keys for signing
    uint256 public userSCPrivKey = 0xABCD;
    uint256 public solverSCPrivKey = 0xDEAD;

    // Order details
    IAori.Order private order;

    /**
     * @notice Helper function to format wei amount to ETH string
     */
    function formatETH(int256 weiAmount) internal pure returns (string memory) {
        if (weiAmount == 0) return "0 ETH";
        
        bool isNegative = weiAmount < 0;
        uint256 absAmount = uint256(isNegative ? -weiAmount : weiAmount);
        
        uint256 ethPart = absAmount / 1e18;
        uint256 weiPart = absAmount % 1e18;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (weiPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(ethPart), " ETH"));
        } else {
            // Show up to 6 decimal places, removing trailing zeros
            uint256 decimals = weiPart / 1e12; // Convert to 6 decimal places
            return string(abi.encodePacked(sign, vm.toString(ethPart), ".", vm.toString(decimals), " ETH"));
        }
    }

    /**
     * @notice Helper function to format token amount to readable string
     */
    function formatTokens(int256 tokenAmount) internal pure returns (string memory) {
        if (tokenAmount == 0) return "0 tokens";
        
        bool isNegative = tokenAmount < 0;
        uint256 absAmount = uint256(isNegative ? -tokenAmount : tokenAmount);
        
        uint256 tokenPart = absAmount / 1e18; // 18 decimals for output tokens
        uint256 decimalPart = absAmount % 1e18;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (decimalPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(tokenPart), " tokens"));
        } else {
            // Show up to 2 decimal places for tokens
            uint256 decimals = decimalPart / 1e16; // Convert to 2 decimal places
            return string(abi.encodePacked(sign, vm.toString(tokenPart), ".", vm.toString(decimals), " tokens"));
        }
    }

    function setUp() public override {
        super.setUp();
        
        // Derive addresses from private keys
        userSC = vm.addr(userSCPrivKey);
        solverSC = vm.addr(solverSCPrivKey);
        
        // Setup balances
        vm.deal(userSC, 5 ether);             // User has 5 ETH
        outputToken.mint(solverSC, 10000e18); // Solver has 10,000 output tokens
        
        // Setup contract balances (start clean)
        vm.deal(address(localAori), 0 ether);
        
        // Add solver to allowed list
        localAori.addAllowedSolver(solverSC);
    }

    /**
     * @notice Test Native → ERC20 single-chain swap with detailed logging
     * @dev This is the main comprehensive test showing the complete flow
     */
    function testNativeToERC20NoHookWithDetailedLogging() public {
        console.log("=== NATIVE TO ERC20 SINGLE-CHAIN SWAP (NO HOOKS) ===");
        console.log("Flow: User deposits", INPUT_AMOUNT / 1e18, "ETH");
        console.log("      Solver fills with", OUTPUT_AMOUNT / 1e18, "tokens");
        console.log("      Atomic settlement completes");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        _logInitialState();
        
        // === PHASE 1: USER NATIVE DEPOSIT ===
        bytes32 orderId = _executeNativeDepositPhase();
        
        // === PHASE 2: SOLVER FILL WITH ERC20 ===
        _executeFillPhase(orderId);
        
        // === PHASE 3: VERIFY FINAL STATE ===
        _verifyFinalState(orderId);
    }

    /**
     * @notice Helper function to log initial state
     */
    function _logInitialState() internal view {
        console.log("=== PHASE 0: INITIAL STATE ===");
        
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(address(localAori)) / 1e18, "tokens");
        console.log("");
    }

    /**
     * @notice Helper function to execute native deposit phase
     */
    function _executeNativeDepositPhase() internal returns (bytes32 orderId) {
        console.log("=== PHASE 1: USER NATIVE DEPOSIT ===");
        
        vm.chainId(localEid);
        
        // Create order for Native → ERC20
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            NATIVE_TOKEN,                // inputToken (native ETH)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        orderId = localAori.hash(order);

        // User deposits native tokens directly
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Log state after deposit
        console.log("After Native Deposit:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Locked native:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("Order Status:", uint256(localAori.orderStatus(orderId)));
        console.log("");

        // Verify deposit worked correctly
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), INPUT_AMOUNT, "User should have locked native balance");
        assertEq(address(localAori).balance, INPUT_AMOUNT, "Contract should hold the native tokens");
    }

    /**
     * @notice Helper function to execute fill phase
     */
    function _executeFillPhase(bytes32 orderId) internal {
        console.log("=== PHASE 2: SOLVER FILL WITH ERC20 ===");

        console.log("Before Fill:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Locked native:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("  Unlocked native:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("");

        // Solver approves and fills with ERC20 tokens
        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.fill(order);
    }

    /**
     * @notice Helper function to verify final state and run assertions
     */
    function _verifyFinalState(bytes32 orderId) internal {
        console.log("=== PHASE 3: FINAL STATE AFTER ATOMIC SETTLEMENT ===");

        console.log("After Fill & Settlement:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Locked native:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("  Unlocked native:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(address(localAori)) / 1e18, "tokens");
        console.log("");

        // === ATOMIC SETTLEMENT VERIFICATION ===
        console.log("=== ATOMIC SETTLEMENT VERIFICATION ===");
        console.log("Token Flow:");
        console.log("  User gave:", INPUT_AMOUNT / 1e18, "ETH (now locked -> unlocked for solver)");
        console.log("  User received:", OUTPUT_AMOUNT / 1e18, "tokens (direct transfer from solver)");
        console.log("  Solver gave:", OUTPUT_AMOUNT / 1e18, "tokens (direct transfer to user)");
        console.log("  Solver received:", INPUT_AMOUNT / 1e18, "ETH (unlocked balance in contract)");
        console.log("Balance Accounting:");
        console.log("  User locked balance:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Solver unlocked balance:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Contract holds:", address(localAori).balance / 1e18, "ETH");
        console.log("");

        // === FINAL ASSERTIONS ===
        
        // Order should be settled
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled");
        
        // User should receive exact output amount
        assertEq(outputToken.balanceOf(userSC), OUTPUT_AMOUNT, "User should receive exact output amount");
        
        // User should have spent the native tokens (but they're now in solver's unlocked balance)
        assertEq(userSC.balance, 5 ether - INPUT_AMOUNT, "User should have spent native tokens");
        
        // Solver should have unlocked native tokens in the contract
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked native balance");
        
        // Solver should have spent the output tokens
        assertEq(outputToken.balanceOf(solverSC), 10000e18 - OUTPUT_AMOUNT, "Solver should have spent output tokens");
        
        // All locked balances should be cleared
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User should have no locked balance after settlement");
        
        // Contract should still hold the native tokens (they're in solver's unlocked balance)
        assertEq(address(localAori).balance, INPUT_AMOUNT, "Contract should hold native tokens in solver's unlocked balance");

        console.log("[PASS] All assertions passed!");
        console.log("[ATOMIC] Single-chain swap completed atomically without hooks");
        console.log("");
    }

    /**
     * @notice Test basic native to ERC20 swap functionality
     */
    function testBasicNativeToERC20Swap() public {
        vm.chainId(localEid);
        
        // Create order for Native → ERC20
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            NATIVE_TOKEN,                // inputToken (native ETH)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Phase 1: User deposits native tokens
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Verify deposit state
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), INPUT_AMOUNT, "User should have locked native balance");

        // Phase 2: Solver fills with ERC20 tokens
        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        uint256 initialUserTokens = outputToken.balanceOf(userSC);
        uint256 initialSolverTokens = outputToken.balanceOf(solverSC);

        vm.prank(solverSC);
        localAori.fill(order);

        // Verify final state
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled");
        assertEq(outputToken.balanceOf(userSC), initialUserTokens + OUTPUT_AMOUNT, "User should receive output tokens");
        assertEq(outputToken.balanceOf(solverSC), initialSolverTokens - OUTPUT_AMOUNT, "Solver should spend output tokens");
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User locked balance should be cleared");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should get unlocked native tokens");
    }

    /**
     * @notice Test that order status transitions correctly
     */
    function testOrderStatusTransitions() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Initial: Unknown
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Unknown, "Order should start as Unknown");

        // After deposit: Active
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");

        // After fill: Settled (single-chain atomic settlement)
        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.fill(order);

        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled after fill");
    }

    /**
     * @notice Test event emission
     */
    function testEventEmission() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Phase 1: Deposit should emit Deposit event
        vm.expectEmit(true, false, false, true);
        emit IAori.Deposit(orderId, order);

        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Phase 2: Fill should emit Settle event (atomic settlement)
        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.expectEmit(true, false, false, false);
        emit IAori.Settle(orderId);

        vm.prank(solverSC);
        localAori.fill(order);
    }

    /**
     * @notice Test failure when user doesn't send enough native tokens
     */
    function testInsufficientNativeDeposit() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        // Try to deposit less than required
        vm.expectRevert("Incorrect native amount");
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT - 1}(order, signature);
    }

    /**
     * @notice Test failure when solver doesn't have enough tokens
     */
    function testInsufficientSolverTokens() public {
        vm.chainId(localEid);
        
        // Create a new solver with insufficient tokens
        address poorSolver = vm.addr(0xBEEF);
        localAori.addAllowedSolver(poorSolver);
        outputToken.mint(poorSolver, OUTPUT_AMOUNT - 1); // Give 1 less token than needed
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        // User deposits correctly
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Poor solver tries to fill without enough tokens
        vm.prank(poorSolver);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.expectRevert("Insufficient balance");
        vm.prank(poorSolver);
        localAori.fill(order);
    }

    /**
     * @notice Test with different amounts to verify flexibility
     */
    function testDifferentAmounts() public {
        uint128 customInputAmount = 0.5 ether;   // 0.5 ETH
        uint128 customOutputAmount = 1000e18;    // 1,000 tokens
        
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            customInputAmount, customOutputAmount,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        uint256 initialUserNative = userSC.balance;
        uint256 initialUserTokens = outputToken.balanceOf(userSC);

        // User deposits
        vm.prank(userSC);
        localAori.depositNative{value: customInputAmount}(order, signature);

        // Solver fills
        vm.prank(solverSC);
        outputToken.approve(address(localAori), customOutputAmount);

        vm.prank(solverSC);
        localAori.fill(order);

        // Verify correct amounts
        assertEq(
            userSC.balance,
            initialUserNative - customInputAmount,
            "User should have spent custom input amount"
        );
        assertEq(
            outputToken.balanceOf(userSC),
            initialUserTokens + customOutputAmount,
            "User should receive custom output amount"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN),
            customInputAmount,
            "Solver should have unlocked custom input amount"
        );
    }

    /**
     * @notice Test that single-chain swaps are immediately settled (atomic settlement)
     */
    function testAtomicSettlement() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Deposit
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Fill
        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.fill(order);
        
        // Verify order was settled atomically (not just filled)
        assertTrue(
            localAori.orderStatus(orderId) == IAori.OrderStatus.Settled,
            "Single-chain swap should be immediately settled"
        );
        
        // Verify balance accounting is complete
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User should have no locked balance after atomic settlement");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked balance after atomic settlement");
    }

    /**
     * @notice Test withdrawal of unlocked native tokens by solver
     */
    function testSolverWithdrawal() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        // Complete the swap
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        vm.prank(solverSC);
        outputToken.approve(address(localAori), OUTPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.fill(order);

        // Verify solver has unlocked balance
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked native balance");

        // Solver withdraws their native tokens
        uint256 initialSolverNative = solverSC.balance;
        
        vm.prank(solverSC);
        localAori.withdraw(NATIVE_TOKEN, INPUT_AMOUNT);

        // Verify withdrawal
        assertEq(solverSC.balance, initialSolverNative + INPUT_AMOUNT, "Solver should receive withdrawn native tokens");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0, "Solver unlocked balance should be cleared");
        assertEq(address(localAori).balance, 0, "Contract should have no native balance after withdrawal");
    }
}
