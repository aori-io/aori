// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain ERC20 → Native with SrcHook (Atomic Settlement)
 * @notice Tests Case 11: Single Chain: ERC20 deposit (with srcHook) → Native Token output (Atomic Settlement)
 * @dev Tests the complete flow:
 *   1. User signs order for ERC20 input → Native output (same chain)
 *   2. Solver executes deposit with srcHook: converts user's ERC20 → Native via hook
 *   3. User receives native tokens, solver gets any surplus from conversion
 *   4. Atomic settlement - everything happens in one transaction via deposit() with hook
 * @dev Verifies single-chain atomic settlement, direct token distribution, and hook integration
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testSingleChainERC20ToNativeWithSrcHookSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract SC_ERC20ToNativeSrcHook_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 10000e18;      // ERC20 input tokens (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1 ether;      // Native ETH output (user receives)
    uint128 public constant HOOK_OUTPUT = 1.1 ether;      // Hook converts to this much native ETH
    uint128 public constant EXPECTED_SURPLUS = 0.1 ether; // Surplus returned to solver (1.1 - 1.0 = 0.1)

    // Single-chain addresses
    address public userSC;     // User on single chain
    address public solverSC;   // Solver on single chain

    // Private keys for signing
    uint256 public userSCPrivKey = 0xABCD;
    uint256 public solverSCPrivKey = 0xDEAD;

    // Order details
    IAori.Order private order;
    MockHook2 private mockHook2;

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
        
        uint256 tokenPart = absAmount / 1e18; // 18 decimals for input tokens
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
        
        // Deploy MockHook2
        mockHook2 = new MockHook2();
        
        // Setup token balances
        inputToken.mint(userSC, 20000e18);    // User has 20,000 input tokens
        vm.deal(solverSC, 2 ether);           // Solver has 2 ETH for gas
        
        // Setup contract balances (start clean)
        vm.deal(address(localAori), 0 ether);
        
        // Give hook native tokens to distribute (what hook outputs)
        vm.deal(address(mockHook2), 5 ether); // 5 ETH for hook operations
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        
        // Add solver to allowed list
        localAori.addAllowedSolver(solverSC);
    }

    /**
     * @notice Helper function to create and execute deposit with srcHook for single-chain atomic settlement
     */
    function _createAndExecuteDepositWithSrcHook() internal {
        vm.chainId(localEid);
        
        // Create test order with ERC20 input and native output (same chain)
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient (same as offerer for single-chain)
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native ETH)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        // Generate signature
        bytes memory signature = signOrder(order, userSCPrivKey);

        // Setup srcHook data for ERC20 → Native conversion
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,        // Hook outputs native tokens
            minPreferedTokenAmountOut: OUTPUT_AMOUNT, // Minimum native tokens expected
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,      // Output native tokens
                HOOK_OUTPUT        // Amount of native tokens to output
            )
        });

        // User approves their input tokens to be spent by the contract
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        // Solver executes deposit with srcHook (atomic settlement)
        vm.prank(solverSC);
        localAori.deposit(order, signature, srcHook);
    }

    /**
     * @notice Test single-chain deposit with srcHook (atomic settlement)
     */
    function testSingleChainDepositWithSrcHook() public {
        uint256 initialUserTokens = inputToken.balanceOf(userSC);
        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;

        _createAndExecuteDepositWithSrcHook();

        // Verify token transfers
        assertEq(
            inputToken.balanceOf(userSC),
            initialUserTokens - INPUT_AMOUNT,
            "User should spend input tokens"
        );
        assertEq(
            userSC.balance,
            initialUserNative + OUTPUT_AMOUNT,
            "User should receive native tokens"
        );
        assertEq(
            solverSC.balance,
            initialSolverNative + EXPECTED_SURPLUS,
            "Solver should receive surplus native tokens"
        );

        // Verify order status is Settled (atomic settlement for single-chain with srcHook)
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Full end-to-end test with detailed balance logging
     */
    function testSingleChainERC20ToNativeWithSrcHookSuccess() public {
        console.log("=== SINGLE-CHAIN ERC20 TO NATIVE WITH SRCHOOK TEST ===");
        console.log("Flow: User deposits 10,000 tokens -> SrcHook converts to 1.1 ETH -> User gets 1 ETH, solver gets 0.1 ETH -> Atomic settlement");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("User:");
        console.log("  Input tokens:", inputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("Hook:");
        console.log("  Input tokens:", inputToken.balanceOf(address(mockHook2)) / 1e18, "tokens");
        console.log("  Native balance:", address(mockHook2).balance / 1e18, "ETH");
        console.log("");

        // Store initial balances for calculations
        uint256 initialUserTokens = inputToken.balanceOf(userSC);
        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;
        uint256 initialContractNative = address(localAori).balance;
        uint256 initialHookTokens = inputToken.balanceOf(address(mockHook2));
        uint256 initialHookNative = address(mockHook2).balance;

        // === PHASE 1: DEPOSIT WITH SRCHOOK (ATOMIC SETTLEMENT) ===
        console.log("=== PHASE 1: SOLVER EXECUTES DEPOSIT WITH SRCHOOK (ATOMIC SETTLEMENT) ===");
        _createAndExecuteDepositWithSrcHook();

        console.log("After Deposit & Atomic Settlement:");
        console.log("User:");
        console.log("  Input tokens:", inputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(inputToken.balanceOf(userSC)) - int256(initialUserTokens)));
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(userSC.balance) - int256(initialUserNative)));
        
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(solverSC.balance) - int256(initialSolverNative)));
        
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(address(localAori).balance) - int256(initialContractNative)));
        
        console.log("Hook:");
        console.log("  Input tokens:", inputToken.balanceOf(address(mockHook2)) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(inputToken.balanceOf(address(mockHook2))) - int256(initialHookTokens)));
        console.log("  Native balance:", address(mockHook2).balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(address(mockHook2).balance) - int256(initialHookNative)));
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        console.log("User Net Changes:");
        console.log("  Input tokens:", formatTokens(int256(inputToken.balanceOf(userSC)) - int256(initialUserTokens)));
        console.log("  Native tokens:", formatETH(int256(userSC.balance) - int256(initialUserNative)));
        
        console.log("Solver Net Changes:");
        console.log("  Native tokens:", formatETH(int256(solverSC.balance) - int256(initialSolverNative)));
        
        console.log("Hook Net Changes:");
        console.log("  Input tokens:", formatTokens(int256(inputToken.balanceOf(address(mockHook2))) - int256(initialHookTokens)));
        console.log("  Native tokens:", formatETH(int256(address(mockHook2).balance) - int256(initialHookNative)));
        
        console.log("");
        console.log("=== FINAL CONTRACT BALANCE ACCOUNTING ===");
        console.log("User Contract Balances:");
        console.log("  Locked Input Tokens:", localAori.getLockedBalances(userSC, address(inputToken)) / 1e18, "tokens");
        console.log("  Unlocked Input Tokens:", localAori.getUnlockedBalances(userSC, address(inputToken)) / 1e18, "tokens");
        console.log("  Locked Native:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Unlocked Native:", localAori.getUnlockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        
        console.log("Solver Contract Balances:");
        console.log("  Locked Input Tokens:", localAori.getLockedBalances(solverSC, address(inputToken)) / 1e18, "tokens");
        console.log("  Unlocked Input Tokens:", localAori.getUnlockedBalances(solverSC, address(inputToken)) / 1e18, "tokens");
        console.log("  Locked Native:", localAori.getLockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Unlocked Native:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("");

        // Verify final state
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
        
        // Verify no locked balances remain (atomic settlement with direct distribution)
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after atomic settlement");
        assertEq(localAori.getUnlockedBalances(userSC, address(inputToken)), 0, "User should have no unlocked balance for srcHook swaps");
        assertEq(localAori.getLockedBalances(solverSC, NATIVE_TOKEN), 0, "Solver should have no locked native balance");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0, "Solver should have no unlocked native balance for srcHook swaps");
    }

    /**
     * @notice Test balance accounting integrity for single-chain swaps with srcHooks
     */
    function testSingleChainBalanceAccountingIntegrity() public {
        // Initial state - no locked balances
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0);
        assertEq(localAori.getUnlockedBalances(userSC, address(inputToken)), 0);

        // After deposit with srcHook (atomic settlement)
        _createAndExecuteDepositWithSrcHook();
        
        // After atomic settlement, no locked balances should remain
        // For srcHook single-chain swaps, tokens are distributed directly, not through balance accounting
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0);
        assertEq(localAori.getUnlockedBalances(userSC, address(inputToken)), 0);
        assertEq(localAori.getLockedBalances(solverSC, NATIVE_TOKEN), 0);
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0);
        
        // Order should be immediately settled
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Test hook mechanics for single-chain swaps with srcHook
     */
    function testSingleChainSrcHookMechanics() public {
        // Record initial hook balances
        uint256 hookInitialTokens = inputToken.balanceOf(address(mockHook2));
        uint256 hookInitialNative = address(mockHook2).balance;

        _createAndExecuteDepositWithSrcHook();

        // Verify hook received input tokens and sent native tokens
        uint256 hookFinalTokens = inputToken.balanceOf(address(mockHook2));
        uint256 hookFinalNative = address(mockHook2).balance;

        assertEq(
            hookFinalTokens,
            hookInitialTokens + INPUT_AMOUNT,
            "Hook should receive input tokens"
        );
        assertEq(
            hookFinalNative,
            hookInitialNative - HOOK_OUTPUT,
            "Hook should send native tokens"
        );
    }

    /**
     * @notice Test event emission
     */
    function testSingleChainEventEmission() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 expectedOrderId = localAori.hash(order);

        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                HOOK_OUTPUT
            )
        });

        // User approves tokens
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        // Expect SrcHookExecuted event
        vm.expectEmit(true, true, false, true);
        emit IAori.SrcHookExecuted(expectedOrderId, NATIVE_TOKEN, HOOK_OUTPUT);

        // Expect Settle event (for single-chain atomic settlement)
        vm.expectEmit(true, false, false, false);
        emit IAori.Settle(expectedOrderId);

        vm.prank(solverSC);
        localAori.deposit(order, signature, srcHook);
    }

    /**
     * @notice Test failure when hook doesn't provide enough output
     */
    function testSingleChainSrcHookInsufficientOutput() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        // Setup srcHook with insufficient output
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                OUTPUT_AMOUNT - 1  // Less than required
            )
        });

        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.expectRevert("Insufficient output from hook");
        vm.prank(solverSC);
        localAori.deposit(order, signature, srcHook);
    }

    /**
     * @notice Test that single-chain swaps with srcHook are immediately settled (atomic settlement)
     * @dev Single-chain swaps with srcHook use atomic settlement and don't require LayerZero messaging
     */
    function testSingleChainSrcHookAtomicSettlement() public {
        // Execute single-chain swap with srcHook
        _createAndExecuteDepositWithSrcHook();
        
        // Verify order was settled atomically (not just filled)
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "Single-chain swap with srcHook should be immediately settled"
        );
        
        // Verify no locked balances remain (atomic settlement with direct distribution)
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after atomic settlement");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0, "Solver should have no unlocked balance for srcHook swaps");
        
        // Verify tokens were transferred directly (not through balance accounting)
        // User should have received native tokens directly
        // Solver should have received surplus native tokens directly
    }

    /**
     * @notice Test surplus handling with detailed logging
     * @dev Tests various surplus scenarios to verify solver receives correct surplus amounts
     */
    function testSurplusHandlingWithDetailedLogging() public {
        console.log("=== SURPLUS HANDLING TEST ===");
        console.log("Testing different hook output amounts to verify surplus distribution");
        console.log("");

        // Test Case 1: Large surplus
        uint128 largeHookOutput = 2 ether;      // Hook outputs 2 ETH
        uint128 expectedLargeSurplus = 1 ether; // User gets 1 ETH, solver gets 1 ETH surplus
        
        console.log("=== TEST CASE 1: LARGE SURPLUS ===");
        console.log("Hook Output:", largeHookOutput / 1e18, "ETH");
        console.log("User Expected:", OUTPUT_AMOUNT / 1e18, "ETH");
        console.log("Expected Surplus:", expectedLargeSurplus / 1e18, "ETH");
        
        _testSurplusScenario(largeHookOutput, expectedLargeSurplus, "Large Surplus");
        
        console.log("");
        
        // Test Case 2: Small surplus
        uint128 smallHookOutput = 1.05 ether;     // Hook outputs 1.05 ETH
        uint128 expectedSmallSurplus = 0.05 ether; // User gets 1 ETH, solver gets 0.05 ETH surplus
        
        console.log("=== TEST CASE 2: SMALL SURPLUS ===");
        console.log("Hook Output:", smallHookOutput / 1e18, "ETH");
        console.log("User Expected:", OUTPUT_AMOUNT / 1e18, "ETH");
        console.log("Expected Surplus:", expectedSmallSurplus / 1e18, "ETH");
        
        _testSurplusScenario(smallHookOutput, expectedSmallSurplus, "Small Surplus");
        
        console.log("");
        
        // Test Case 3: Exact amount (no surplus)
        uint128 exactHookOutput = OUTPUT_AMOUNT;   // Hook outputs exactly 1 ETH
        uint128 expectedNoSurplus = 0;             // User gets 1 ETH, solver gets 0 surplus
        
        console.log("=== TEST CASE 3: EXACT AMOUNT (NO SURPLUS) ===");
        console.log("Hook Output:", exactHookOutput / 1e18, "ETH");
        console.log("User Expected:", OUTPUT_AMOUNT / 1e18, "ETH");
        console.log("Expected Surplus:", expectedNoSurplus / 1e18, "ETH");
        
        _testSurplusScenario(exactHookOutput, expectedNoSurplus, "No Surplus");
    }

    /**
     * @notice Helper function to test different surplus scenarios
     */
    function _testSurplusScenario(uint128 hookOutput, uint128 expectedSurplus, string memory scenarioName) internal {
        // Create fresh addresses for this test to avoid state conflicts
        address testUser = vm.addr(0x1234);
        address testSolver = vm.addr(0x5678);
        
        // Setup balances
        inputToken.mint(testUser, 20000e18);
        vm.deal(testSolver, 2 ether);
        vm.deal(address(mockHook2), 10 ether); // Ensure hook has enough
        
        // Add solver to allowed list
        localAori.addAllowedSolver(testSolver);
        
        vm.chainId(localEid);
        
        // Create test order
        IAori.Order memory testOrder = createCustomOrder(
            testUser,                    // offerer
            testUser,                    // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native ETH)
            INPUT_AMOUNT + hookOutput,   // inputAmount (make unique based on hookOutput)
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        // Generate signature
        bytes memory signature = signOrder(testOrder, 0x1234); // Use testUser's private key

        // Setup srcHook with specific output amount
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                hookOutput  // Variable hook output
            )
        });

        // Record initial balances
        uint256 initialUserNative = testUser.balance;
        uint256 initialSolverNative = testSolver.balance;
        uint256 initialHookNative = address(mockHook2).balance;

        console.log("Before Transaction:");
        console.log("  User Native:", initialUserNative / 1e18, "ETH");
        console.log("  Solver Native:", initialSolverNative / 1e18, "ETH");
        console.log("  Hook Native:", initialHookNative / 1e18, "ETH");

        // User approves tokens
        vm.prank(testUser);
        inputToken.approve(address(localAori), testOrder.inputAmount);

        // Solver executes deposit with srcHook
        vm.prank(testSolver);
        localAori.deposit(testOrder, signature, srcHook);

        // Record final balances
        uint256 finalUserNative = testUser.balance;
        uint256 finalSolverNative = testSolver.balance;
        uint256 finalHookNative = address(mockHook2).balance;

        console.log("After Transaction:");
        console.log("  User Native:", finalUserNative / 1e18, "ETH");
        console.log("  Solver Native:", finalSolverNative / 1e18, "ETH");
        console.log("  Hook Native:", finalHookNative / 1e18, "ETH");

        // Calculate actual changes
        uint256 userReceived = finalUserNative - initialUserNative;
        uint256 solverReceived = finalSolverNative - initialSolverNative;
        uint256 hookSent = initialHookNative - finalHookNative;

        console.log("Actual Changes:");
        console.log("  User Received:", userReceived / 1e18, "ETH");
        console.log("  Solver Received:", solverReceived / 1e18, "ETH");
        console.log("  Hook Sent:", hookSent / 1e18, "ETH");

        // Verify surplus calculation
        console.log("Surplus Calculation:");
        console.log("  Hook Output:", hookOutput / 1e18, "ETH");
        console.log("  User Gets:", OUTPUT_AMOUNT / 1e18, "ETH");
        console.log("  Calculated Surplus:", (hookOutput - OUTPUT_AMOUNT) / 1e18, "ETH");
        console.log("  Expected Surplus:", expectedSurplus / 1e18, "ETH");

        // Assertions
        assertEq(userReceived, OUTPUT_AMOUNT, string(abi.encodePacked(scenarioName, ": User should receive exact output amount")));
        assertEq(solverReceived, expectedSurplus, string(abi.encodePacked(scenarioName, ": Solver should receive expected surplus")));
        assertEq(hookSent, hookOutput, string(abi.encodePacked(scenarioName, ": Hook should send expected amount")));
        
        // Verify the math: hookOutput = userReceived + solverReceived
        assertEq(hookOutput, userReceived + solverReceived, string(abi.encodePacked(scenarioName, ": Hook output should equal user + solver amounts")));

        console.log("PASS:", scenarioName, "test passed!");
        console.log("");
    }
}
