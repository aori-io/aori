// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain ERC20 Deposit → Native with DstHook
 * @notice Tests Case 12: Single-Chain: ERC20 deposit (no Hook) -> NativeToken output (with dstHook)
 * @dev Tests the complete flow:
 *   1. User deposits ERC20 tokens (no srcHook) - tokens get locked in contract
 *   2. Solver fills order with dstHook: converts their preferred tokens → Native via hook
 *   3. User receives native tokens, solver gets any surplus + the locked ERC20 tokens
 *   4. Atomic settlement - locked tokens transferred to solver's unlocked balance
 * @dev Flow: deposit(order) -> fill(order, dstHook)
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCase12_ERC20DepositToDstHookNativeWithSurplus -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract SC_ERC20ToNativeDstHook_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 10000e18;      // ERC20 input tokens (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1 ether;      // Native ETH output (user receives)
    uint128 public constant DST_HOOK_INPUT = 1.2 ether;   // Solver provides to hook
    uint128 public constant DST_HOOK_OUTPUT = 1.2 ether;  // Hook outputs this much native ETH
    uint128 public constant EXPECTED_SURPLUS = 0.2 ether; // Surplus returned to solver (1.2 - 1.0 = 0.2)

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
        vm.deal(solverSC, 5 ether);           // Solver has 5 ETH for gas and hook input
        
        // Setup contract balances (start clean)
        vm.deal(address(localAori), 0 ether);
        
        // Give hook native tokens to distribute (what hook outputs)
        vm.deal(address(mockHook2), 10 ether); // 10 ETH for hook operations
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        
        // Add solver to allowed list
        localAori.addAllowedSolver(solverSC);
    }

    /**
     * @notice Test Case 12: Single-Chain ERC20 deposit (no Hook) → Native Token output (with dstHook)
     * @dev Flow: deposit(order) -> fill(order, dstHook)
     * @dev Tests the two-step process:
     *   1. User deposits ERC20 tokens (no hook) - tokens get locked
     *   2. Solver fills with dstHook to convert their tokens to native output
     *   3. Atomic settlement - locked tokens transferred to solver, user gets native tokens
     */
    function testCase12_ERC20DepositToDstHookNativeWithSurplus() public {
        console.log("=== CASE 12: ERC20 DEPOSIT (NO HOOK) -> NATIVE OUTPUT (WITH DSTHOOK) ===");
        console.log("Flow: User deposits 10,000 tokens -> Solver fills with dstHook (1.2 ETH -> 1 ETH) -> User gets 1 ETH, solver gets 0.2 ETH surplus");
        console.log("");

        // Phase 0: Record initial state
        _logInitialState();
        
        // Phase 1: User deposit
        bytes32 orderId = _executeDepositPhase();
        
        // Phase 2: Solver fill with dstHook
        _executeFillPhase(orderId);
        
        // Phase 3: Verify final state and assertions
        _verifyFinalState(orderId);
    }

    /**
     * @notice Helper function to log initial state
     */
    function _logInitialState() internal view {
        console.log("=== PHASE 0: INITIAL STATE ===");
        
        console.log("User:");
        console.log("  Input tokens:", inputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("Solver:");
        console.log("  Input tokens:", inputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("Contract:");
        console.log("  Input tokens:", inputToken.balanceOf(address(localAori)) / 1e18, "tokens");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("Hook:");
        console.log("  Native balance:", address(mockHook2).balance / 1e18, "ETH");
        console.log("");
    }

    /**
     * @notice Helper function to execute deposit phase
     */
    function _executeDepositPhase() internal returns (bytes32 orderId) {
        console.log("=== PHASE 1: USER DEPOSIT (NO HOOK) ===");
        
        vm.chainId(localEid);
        
        // Create order for ERC20 → Native
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native ETH)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        orderId = localAori.hash(order);

        // User approves and deposits (no hook)
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.deposit(order, signature);

        // Log state after deposit
        console.log("After Deposit:");
        console.log("User:");
        console.log("  Input tokens:", inputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Locked balance:", localAori.getLockedBalances(userSC, address(inputToken)) / 1e18, "tokens");
        console.log("Contract:");
        console.log("  Input tokens:", inputToken.balanceOf(address(localAori)) / 1e18, "tokens");
        console.log("Order Status:", uint256(localAori.orderStatus(orderId)));
        console.log("");

        // Verify deposit worked correctly
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), INPUT_AMOUNT, "User should have locked balance");
    }

    /**
     * @notice Helper function to execute fill phase
     */
    function _executeFillPhase(bytes32 orderId) internal {
        console.log("=== PHASE 2: SOLVER FILL WITH DSTHOOK ===");

        // Setup dstHook for native token conversion
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: DST_HOOK_INPUT,    // Solver provides 1.2 ETH
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                DST_HOOK_OUTPUT  // Hook outputs 1.2 ETH
            )
        });

        console.log("Before Fill:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Locked tokens:", localAori.getLockedBalances(userSC, address(inputToken)) / 1e18, "tokens");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Unlocked tokens:", localAori.getUnlockedBalances(solverSC, address(inputToken)) / 1e18, "tokens");
        console.log("");

        // Solver fills with dstHook (sends native tokens to hook)
        vm.prank(solverSC);
        localAori.fill{value: DST_HOOK_INPUT}(order, dstHook);
    }

    /**
     * @notice Helper function to verify final state and run assertions
     */
    function _verifyFinalState(bytes32 orderId) internal {
        console.log("=== PHASE 3: FINAL STATE AFTER ATOMIC SETTLEMENT ===");

        console.log("After Fill & Settlement:");
        console.log("User:");
        console.log("  Input tokens:", inputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Locked tokens:", localAori.getLockedBalances(userSC, address(inputToken)) / 1e18, "tokens");
        console.log("Solver:");
        console.log("  Input tokens:", inputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Unlocked tokens:", localAori.getUnlockedBalances(solverSC, address(inputToken)) / 1e18, "tokens");
        console.log("Contract:");
        console.log("  Input tokens:", inputToken.balanceOf(address(localAori)) / 1e18, "tokens");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("Hook:");
        console.log("  Native balance:", address(mockHook2).balance / 1e18, "ETH");
        console.log("");

        // === SURPLUS CALCULATION VERIFICATION ===
        console.log("=== SURPLUS CALCULATION BREAKDOWN ===");
        console.log("Hook Configuration:");
        console.log("  Solver sent to hook:", DST_HOOK_INPUT / 1e18, "ETH");
        console.log("  Hook total output:", DST_HOOK_OUTPUT / 1e18, "ETH");
        console.log("Distribution:");
        console.log("  User received:", OUTPUT_AMOUNT / 1e18, "ETH (order amount)");
        console.log("  Surplus to solver:", (DST_HOOK_OUTPUT - OUTPUT_AMOUNT) / 1e18, "ETH");
        console.log("Solver Net Calculation:");
        console.log("  Paid to hook: -", DST_HOOK_INPUT / 1e18, "ETH");
        console.log("  Surplus received: +", (DST_HOOK_OUTPUT - OUTPUT_AMOUNT) / 1e18, "ETH");
        console.log("  Net cost:", (DST_HOOK_INPUT - (DST_HOOK_OUTPUT - OUTPUT_AMOUNT)) / 1e18, "ETH");
        console.log("  (This equals the order output amount of", OUTPUT_AMOUNT / 1e18, "ETH)");
        console.log("");

        // === FINAL ASSERTIONS ===
        
        // Order should be settled
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled");
        
        // User should receive exact output amount
        assertEq(userSC.balance, OUTPUT_AMOUNT, "User should receive exact output amount");
        
        // Solver should have unlocked tokens in the contract (not direct transfer)
        assertEq(localAori.getUnlockedBalances(solverSC, address(inputToken)), INPUT_AMOUNT, "Solver should have unlocked balance equal to input amount");
        
        // All locked balances should be cleared
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after settlement");
        
        // Contract should still hold the tokens (they're in solver's unlocked balance)
        assertEq(inputToken.balanceOf(address(localAori)), INPUT_AMOUNT, "Contract should hold tokens in solver's unlocked balance");

        // Verify the solver's net cost equals the order output amount (they effectively "bought" the tokens for 1 ETH)
        uint256 expectedSolverBalance = 5 ether - OUTPUT_AMOUNT; // Started with 5 ETH, net cost should be 1 ETH
        assertEq(solverSC.balance, expectedSolverBalance, "Solver should have net cost equal to order output amount");

        console.log("[PASS] All assertions passed!");
        console.log("[SURPLUS] Surplus of", (DST_HOOK_OUTPUT - OUTPUT_AMOUNT) / 1e18, "ETH was correctly distributed to solver");
        console.log("");
    }

    /**
     * @notice Helper function to test Case 12 with different surplus amounts
     */
    function testCase12_DifferentSurplusAmounts() public {
        console.log("=== CASE 12: TESTING DIFFERENT SURPLUS AMOUNTS ===");
        console.log("");

        // Test 1: No surplus (exact amount)
        _testCase12Scenario(1.0 ether, 1.0 ether, 0, "No Surplus");
        
        // Test 2: Small surplus  
        _testCase12Scenario(1.05 ether, 1.05 ether, 0.05 ether, "Small Surplus");
        
        // Test 3: Large surplus
        _testCase12Scenario(2.0 ether, 2.0 ether, 1.0 ether, "Large Surplus");
    }

    /**
     * @notice Helper function to test Case 12 scenarios with different surplus amounts
     */
    function _testCase12Scenario(
        uint128 hookInput,
        uint128 hookOutput,
        uint128 expectedSurplus,
        string memory scenarioName
    ) internal {
        console.log("=== SCENARIO:", scenarioName, "===");
        
        // Create fresh addresses to avoid state conflicts (unique for each scenario)
        uint256 scenarioSalt = uint256(keccak256(abi.encodePacked(scenarioName)));
        address testUser = vm.addr(0x9999 + scenarioSalt);
        address testSolver = vm.addr(0x8888 + scenarioSalt);
        
        // Setup balances
        inputToken.mint(testUser, 20000e18);
        vm.deal(testSolver, 5 ether);
        vm.deal(address(mockHook2), 10 ether);
        localAori.addAllowedSolver(testSolver);
        
        vm.chainId(localEid);
        
        // Create order with standard amounts (no need to vary input amount anymore)
        IAori.Order memory testOrder = createCustomOrder(
            testUser,
            testUser,
            address(inputToken),
            NATIVE_TOKEN,
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        bytes memory signature = signOrder(testOrder, 0x9999 + scenarioSalt);
        bytes32 orderId = localAori.hash(testOrder);

        // Phase 1: Deposit
        vm.prank(testUser);
        inputToken.approve(address(localAori), testOrder.inputAmount);

        vm.prank(testSolver);
        localAori.deposit(testOrder, signature);

        // Phase 2: Fill with dstHook
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: hookInput,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                hookOutput
            )
        });

        uint256 initialUserNative = testUser.balance;
        uint256 initialSolverNative = testSolver.balance;

        vm.prank(testSolver);
        localAori.fill{value: hookInput}(testOrder, dstHook);

        // Verify results
        uint256 userReceived = testUser.balance - initialUserNative;
        int256 solverNetChange = int256(testSolver.balance) - int256(initialSolverNative);
        
        console.log("  Hook Input:", hookInput / 1e18, "ETH");
        console.log("  Hook Output:", hookOutput / 1e18, "ETH");
        console.log("  User Received:", userReceived / 1e18, "ETH");
        console.log("  Solver Net Change:", formatETH(solverNetChange));
        console.log("  Expected Surplus:", expectedSurplus / 1e18, "ETH");

        assertEq(userReceived, OUTPUT_AMOUNT, string(abi.encodePacked(scenarioName, ": User should receive output amount")));
        
        // Calculate expected net change: surplus - hook input (can be negative)
        int256 expectedNetChange = int256(uint256(expectedSurplus)) - int256(uint256(hookInput));
        assertEq(solverNetChange, expectedNetChange, string(abi.encodePacked(scenarioName, ": Solver net change should be surplus minus input")));
        
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, string(abi.encodePacked(scenarioName, ": Order should be settled")));
        
        // Check that solver has unlocked tokens in the contract (should be exactly INPUT_AMOUNT)
        assertEq(localAori.getUnlockedBalances(testSolver, address(inputToken)), INPUT_AMOUNT, string(abi.encodePacked(scenarioName, ": Solver should have unlocked tokens")));
        
        console.log("  [PASS]", scenarioName, "passed!");
        console.log("");
    }

    /**
     * @notice Test basic deposit and fill flow without surplus
     */
    function testCase12_BasicDepositAndFill() public {
        vm.chainId(localEid);
        
        // Create order for ERC20 → Native
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native ETH)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Phase 1: User deposits
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.deposit(order, signature);

        // Verify deposit state
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), INPUT_AMOUNT, "User should have locked balance");

        // Phase 2: Solver fills with exact amount (no surplus)
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: OUTPUT_AMOUNT,  // Exact amount
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                OUTPUT_AMOUNT  // Hook outputs exactly what's needed
            )
        });

        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;

        vm.prank(solverSC);
        localAori.fill{value: OUTPUT_AMOUNT}(order, dstHook);

        // Verify final state
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled");
        assertEq(userSC.balance, initialUserNative + OUTPUT_AMOUNT, "User should receive native tokens");
        assertEq(solverSC.balance, initialSolverNative - OUTPUT_AMOUNT, "Solver should pay for hook input");
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User locked balance should be cleared");
        assertEq(localAori.getUnlockedBalances(solverSC, address(inputToken)), INPUT_AMOUNT, "Solver should get unlocked tokens");
    }

    /**
     * @notice Test that order status transitions correctly
     */
    function testCase12_OrderStatusTransitions() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, address(inputToken), NATIVE_TOKEN,
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
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.deposit(order, signature);

        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active after deposit");

        // After fill: Settled (single-chain atomic settlement)
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(MockHook2.handleHook.selector, NATIVE_TOKEN, OUTPUT_AMOUNT)
        });

        vm.prank(solverSC);
        localAori.fill{value: OUTPUT_AMOUNT}(order, dstHook);

        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Settled, "Order should be Settled after fill");
    }

    /**
     * @notice Test event emission for Case 12
     */
    function testCase12_EventEmission() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, address(inputToken), NATIVE_TOKEN,
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);
        bytes32 orderId = localAori.hash(order);

        // Phase 1: Deposit should emit Deposit event
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.expectEmit(true, false, false, true);
        emit IAori.Deposit(orderId, order);

        vm.prank(solverSC);
        localAori.deposit(order, signature);

        // Phase 2: Fill should emit DstHookExecuted and Settle events
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: DST_HOOK_INPUT,
            instructions: abi.encodeWithSelector(MockHook2.handleHook.selector, NATIVE_TOKEN, DST_HOOK_OUTPUT)
        });

        vm.expectEmit(true, true, false, true);
        emit IAori.DstHookExecuted(orderId, NATIVE_TOKEN, DST_HOOK_OUTPUT);

        vm.expectEmit(true, false, false, false);
        emit IAori.Settle(orderId);

        vm.prank(solverSC);
        localAori.fill{value: DST_HOOK_INPUT}(order, dstHook);
    }

    /**
     * @notice Test failure when hook doesn't provide enough output
     */
    function testCase12_InsufficientHookOutput() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC, userSC, address(inputToken), NATIVE_TOKEN,
            INPUT_AMOUNT, OUTPUT_AMOUNT,
            block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        // Deposit first
        vm.prank(userSC);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        vm.prank(solverSC);
        localAori.deposit(order, signature);

        // Try to fill with insufficient hook output
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            preferedDstInputAmount: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                OUTPUT_AMOUNT - 1  // Less than required
            )
        });

        vm.expectRevert("Hook must provide at least the expected output amount");
        vm.prank(solverSC);
        localAori.fill{value: OUTPUT_AMOUNT}(order, dstHook);
    }
}
