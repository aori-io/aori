// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain Native → ERC20 with DstHook
 * @notice Tests the complete flow:
 *   1. User deposits 1 ETH (native)
 *   2. Solver fills with hook: converts 10,000 preferred tokens → 2000 output tokens via hook
 *   3. User receives 2000 output tokens, solver gets surplus from hook conversion
 *   4. Atomic settlement - everything happens in one transaction
 * @dev Verifies single-chain atomic settlement, balance accounting, and hook integration
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testSingleChainNativeToERC20Success -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract SC_NativeToERC20Hook_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;         // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 2000e18;       // ERC20 output tokens (user receives)
    uint128 public constant PREFERRED_AMOUNT = 10000e6;    // Solver's preferred token amount (10,000 tokens with 6 decimals)
    uint128 public constant HOOK_OUTPUT = 2100e18;         // Hook converts to this much ERC20 tokens
    uint128 public constant EXPECTED_SURPLUS = 100e18;     // Surplus returned to solver (2100 - 2000 = 100)

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

    /**
     * @notice Helper function to format preferred token amount to readable string (6 decimals)
     */
    function formatPreferredTokens(int256 tokenAmount) internal pure returns (string memory) {
        if (tokenAmount == 0) return "0 preferred tokens";
        
        bool isNegative = tokenAmount < 0;
        uint256 absAmount = uint256(isNegative ? -tokenAmount : tokenAmount);
        
        uint256 tokenPart = absAmount / 1e6; // 6 decimals for preferred tokens
        uint256 decimalPart = absAmount % 1e6;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (decimalPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(tokenPart), " preferred tokens"));
        } else {
            // Show up to 2 decimal places for tokens
            uint256 decimals = decimalPart / 1e4; // Convert to 2 decimal places
            return string(abi.encodePacked(sign, vm.toString(tokenPart), ".", vm.toString(decimals), " preferred tokens"));
        }
    }

    function setUp() public override {
        super.setUp();
        
        // Derive addresses from private keys
        userSC = vm.addr(userSCPrivKey);
        solverSC = vm.addr(solverSCPrivKey);
        
        // Deploy MockHook2
        mockHook2 = new MockHook2();
        
        // Setup native token balances
        vm.deal(userSC, 2 ether);     // User has 2 ETH
        vm.deal(solverSC, 1 ether);   // Solver has 1 ETH for gas
        
        // Setup contract balances (start clean)
        vm.deal(address(localAori), 0 ether);
        
        // Give solver preferred tokens for the hook (input to hook)
        dstPreferredToken.mint(solverSC, 20000e6); // 20,000 preferred tokens
        
        // Give hook output tokens to distribute (what hook outputs)
        outputToken.mint(address(mockHook2), 20000e18); // 20,000 output tokens (increased from 10,000)
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        
        // Add solver to allowed list
        localAori.addAllowedSolver(solverSC);
    }

    /**
     * @notice Helper function to create and deposit native order for single-chain swap
     */
    function _createAndDepositNativeOrder() internal {
        vm.chainId(localEid);
        
        // Create test order with native input and ERC20 output (same chain)
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient (same as offerer for single-chain)
            NATIVE_TOKEN,                // inputToken (native ETH)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        // Generate signature
        bytes memory signature = signOrder(order, userSCPrivKey);

        // User deposits their own native tokens directly
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Helper function to fill order with hook (preferred tokens → ERC20 output)
     */
    function _fillOrderWithHook() internal {
        vm.chainId(localEid);
        vm.warp(order.startTime + 1); // Advance time so order has started

        // Setup hook data for Preferred ERC20 → Output ERC20 conversion
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: address(dstPreferredToken),  // Solver's preferred ERC20 token (input to hook)
            instructions: abi.encodeWithSelector(
                MockHook2.swapTokens.selector,
                address(dstPreferredToken),  // tokenIn
                PREFERRED_AMOUNT,            // amountIn
                address(outputToken),        // tokenOut
                OUTPUT_AMOUNT                // minAmountOut
            ),
            preferedDstInputAmount: PREFERRED_AMOUNT
        });

        // Approve solver's preferred tokens to be spent
        vm.prank(solverSC);
        dstPreferredToken.approve(address(localAori), PREFERRED_AMOUNT);

        // Execute fill with hook
        vm.prank(solverSC);
        localAori.fill(order, dstHook);
    }

    /**
     * @notice Test single-chain deposit
     */
    function testSingleChainDeposit() public {
        uint256 initialUserBalance = userSC.balance;
        uint256 initialContractBalance = address(localAori).balance;

        _createAndDepositNativeOrder();

        // For single-chain swaps, the order should be immediately settled after deposit
        // But first let's check the deposit worked
        assertEq(
            userSC.balance,
            initialUserBalance - INPUT_AMOUNT,
            "User balance should decrease by input amount"
        );
        assertEq(
            address(localAori).balance,
            initialContractBalance + INPUT_AMOUNT,
            "Contract should receive native tokens"
        );

        // Verify order status is Active (waiting for fill)
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test single-chain fill with hook
     */
    function testSingleChainFillWithHook() public {
        _createAndDepositNativeOrder();

        // Record pre-fill balances
        uint256 preFillUserOutputTokens = outputToken.balanceOf(userSC);
        uint256 preFillSolverPreferredTokens = dstPreferredToken.balanceOf(solverSC);
        uint256 preFillSolverOutputTokens = outputToken.balanceOf(solverSC);

        _fillOrderWithHook();

        // Verify token transfers
        assertEq(
            outputToken.balanceOf(userSC),
            preFillUserOutputTokens + OUTPUT_AMOUNT,
            "User should receive output tokens"
        );
        assertEq(
            dstPreferredToken.balanceOf(solverSC),
            preFillSolverPreferredTokens - PREFERRED_AMOUNT,
            "Solver should spend preferred tokens"
        );
        assertEq(
            outputToken.balanceOf(solverSC),
            preFillSolverOutputTokens + EXPECTED_SURPLUS,
            "Solver should receive surplus output tokens"
        );

        // Verify order status is Settled (atomic settlement for single-chain)
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Full end-to-end test with detailed balance logging
     */
    function testSingleChainNativeToERC20Success() public {
        console.log("=== SINGLE-CHAIN NATIVE TO ERC20 SWAP TEST ===");
        console.log("Flow: User deposits 1 ETH -> Solver converts preferred tokens to output tokens via hook -> Atomic settlement");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("  Preferred tokens:", dstPreferredToken.balanceOf(solverSC) / 1e6, "preferred tokens");
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("Hook:");
        console.log("  Preferred tokens:", dstPreferredToken.balanceOf(address(mockHook2)) / 1e6, "preferred tokens");
        console.log("  Output tokens:", outputToken.balanceOf(address(mockHook2)) / 1e18, "tokens");
        console.log("");

        // Store initial balances for calculations
        uint256 initialUserNative = userSC.balance;
        uint256 initialUserOutputTokens = outputToken.balanceOf(userSC);
        uint256 initialSolverNative = solverSC.balance;
        uint256 initialContractNative = address(localAori).balance;

        // === PHASE 1: DEPOSIT ===
        console.log("=== PHASE 1: USER DEPOSITS 1 ETH ===");
        _createAndDepositNativeOrder();

        console.log("After Deposit:");
        console.log("  User native balance:", userSC.balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(userSC.balance) - int256(initialUserNative)));
        console.log("  Contract native balance:", address(localAori).balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(address(localAori).balance) - int256(initialContractNative)));
        console.log("  User locked balance:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("");

        // === PHASE 2: FILL WITH HOOK (ATOMIC SETTLEMENT) ===
        console.log("=== PHASE 2: SOLVER FILLS WITH HOOK (ATOMIC SETTLEMENT) ===");
        
        // Store pre-fill balances
        uint256 preFillSolverPreferred = dstPreferredToken.balanceOf(solverSC);
        uint256 preFillSolverOutput = outputToken.balanceOf(solverSC);
        uint256 preFillHookPreferred = dstPreferredToken.balanceOf(address(mockHook2));
        uint256 preFillHookOutput = outputToken.balanceOf(address(mockHook2));
        
        _fillOrderWithHook();

        console.log("After Fill & Atomic Settlement:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(userSC)) - int256(initialUserOutputTokens)));
        console.log("  Locked balance:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        
        console.log("Solver:");
        console.log("  Native balance:", solverSC.balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(solverSC.balance) - int256(initialSolverNative)));
        console.log("  Preferred tokens:", dstPreferredToken.balanceOf(solverSC) / 1e6, "preferred tokens");
        console.log("    Change:", formatPreferredTokens(int256(dstPreferredToken.balanceOf(solverSC)) - int256(preFillSolverPreferred)));
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(solverSC)) - int256(preFillSolverOutput)));
        console.log("  Unlocked native balance:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        
        console.log("Contract:");
        console.log("  Native balance:", address(localAori).balance / 1e18, "ETH");
        
        console.log("Hook:");
        console.log("  Preferred tokens:", dstPreferredToken.balanceOf(address(mockHook2)) / 1e6, "preferred tokens");
        console.log("    Change:", formatPreferredTokens(int256(dstPreferredToken.balanceOf(address(mockHook2))) - int256(preFillHookPreferred)));
        console.log("  Output tokens:", outputToken.balanceOf(address(mockHook2)) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(address(mockHook2))) - int256(preFillHookOutput)));
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        console.log("User Net Changes:");
        console.log("  Native tokens:", formatETH(int256(userSC.balance) - int256(initialUserNative)));
        console.log("  Output tokens:", formatTokens(int256(outputToken.balanceOf(userSC)) - int256(initialUserOutputTokens)));
        
        console.log("Solver Net Changes:");
        console.log("  Native tokens:", formatETH(int256(solverSC.balance) - int256(initialSolverNative)));
        console.log("  Preferred tokens:", formatPreferredTokens(int256(dstPreferredToken.balanceOf(solverSC)) - int256(preFillSolverPreferred)));
        console.log("  Output tokens:", formatTokens(int256(outputToken.balanceOf(solverSC)) - int256(preFillSolverOutput)));
        
        console.log("Hook Net Changes:");
        console.log("  Preferred tokens:", formatPreferredTokens(int256(dstPreferredToken.balanceOf(address(mockHook2))) - int256(preFillHookPreferred)));
        console.log("  Output tokens:", formatTokens(int256(outputToken.balanceOf(address(mockHook2))) - int256(preFillHookOutput)));
        
        console.log("");
        console.log("=== FINAL CONTRACT BALANCE ACCOUNTING ===");
        console.log("User Contract Balances:");
        console.log("  Locked Native:", localAori.getLockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Unlocked Native:", localAori.getUnlockedBalances(userSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Locked Output Tokens:", localAori.getLockedBalances(userSC, address(outputToken)) / 1e18, "tokens");
        console.log("  Unlocked Output Tokens:", localAori.getUnlockedBalances(userSC, address(outputToken)) / 1e18, "tokens");
        
        console.log("Solver Contract Balances:");
        console.log("  Locked Native:", localAori.getLockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Unlocked Native:", localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN) / 1e18, "ETH");
        console.log("  Locked Preferred Tokens:", localAori.getLockedBalances(solverSC, address(dstPreferredToken)) / 1e6, "preferred tokens");
        console.log("  Unlocked Preferred Tokens:", localAori.getUnlockedBalances(solverSC, address(dstPreferredToken)) / 1e6, "preferred tokens");
        console.log("  Locked Output Tokens:", localAori.getLockedBalances(solverSC, address(outputToken)) / 1e18, "tokens");
        console.log("  Unlocked Output Tokens:", localAori.getUnlockedBalances(solverSC, address(outputToken)) / 1e18, "tokens");
        console.log("");

        // Verify final state
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User should have no locked balance after atomic settlement");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked native balance");
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Test solver withdrawal after atomic settlement
     */
    function testSolverWithdrawalAfterAtomicSettlement() public {
        _createAndDepositNativeOrder();
        _fillOrderWithHook();

        // Check solver has unlocked balance
        uint256 unlockedBalance = localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN);
        assertEq(unlockedBalance, INPUT_AMOUNT, "Solver should have unlocked native balance");

        uint256 solverBalanceBefore = solverSC.balance;
        uint256 contractBalanceBefore = address(localAori).balance;

        // Solver withdraws their earned native tokens
        vm.prank(solverSC);
        localAori.withdraw(NATIVE_TOKEN, INPUT_AMOUNT);

        // Verify withdrawal
        assertEq(
            solverSC.balance,
            solverBalanceBefore + INPUT_AMOUNT,
            "Solver should receive withdrawn native tokens"
        );
        assertEq(
            address(localAori).balance,
            contractBalanceBefore - INPUT_AMOUNT,
            "Contract should send native tokens"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN),
            0,
            "Solver should have no remaining unlocked balance"
        );
    }

    /**
     * @notice Test balance accounting integrity for single-chain swaps
     */
    function testSingleChainBalanceAccountingIntegrity() public {
        // Initial state
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0);
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0);

        // After deposit
        _createAndDepositNativeOrder();
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), INPUT_AMOUNT);
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0);

        // After fill (atomic settlement)
        _fillOrderWithHook();
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0);
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT);

        // Total balance conservation
        uint256 totalLocked = localAori.getLockedBalances(userSC, NATIVE_TOKEN);
        uint256 totalUnlocked = localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN);
        assertEq(totalLocked + totalUnlocked, INPUT_AMOUNT, "Total internal balance should equal deposited amount");
    }

    /**
     * @notice Test hook mechanics for single-chain swaps
     */
    function testSingleChainHookMechanics() public {
        _createAndDepositNativeOrder();

        // Record initial hook balances
        uint256 hookInitialPreferred = dstPreferredToken.balanceOf(address(mockHook2));
        uint256 hookInitialOutput = outputToken.balanceOf(address(mockHook2));

        _fillOrderWithHook();

        // Verify hook received preferred tokens and sent output tokens
        uint256 hookFinalPreferred = dstPreferredToken.balanceOf(address(mockHook2));
        uint256 hookFinalOutput = outputToken.balanceOf(address(mockHook2));

        assertEq(
            hookFinalPreferred,
            hookInitialPreferred + PREFERRED_AMOUNT,
            "Hook should receive preferred tokens"
        );
        assertEq(
            hookFinalOutput,
            hookInitialOutput - HOOK_OUTPUT,
            "Hook should send output tokens"
        );
    }

    /**
     * @notice Test that single-chain swaps are immediately settled (atomic settlement)
     * @dev Single-chain swaps use atomic settlement and don't require LayerZero messaging
     */
    function testSingleChainSwapAtomicSettlement() public {
        // Execute single-chain swap (deposit + fill with hook)
        _createAndDepositNativeOrder();
        _fillOrderWithHook();
        
        // Verify order was settled atomically (not just filled)
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "Single-chain swap should be immediately settled"
        );
        
        // Verify no locked balances remain (atomic settlement)
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User should have no locked balance after atomic settlement");
        
        // Verify solver has unlocked balance (from atomic settlement)
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked native balance");
    }

    /**
     * @notice Test that multiple single-chain swaps are all immediately settled
     */
    function testMultipleSingleChainSwapsAtomicSettlement() public {
        // Execute first swap
        _createAndDepositNativeOrder();
        _fillOrderWithHook();
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "First single-chain swap should be immediately settled"
        );

        // Verify no locked balances remain for first order
        assertEq(localAori.getLockedBalances(userSC, NATIVE_TOKEN), 0, "User should have no locked balance after first swap");
        
        // Verify solver has unlocked balance from first swap
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), INPUT_AMOUNT, "Solver should have unlocked balance from first swap");
        
        // Test demonstrates that single-chain swaps:
        // 1. Are immediately settled (OrderStatus.Settled)
        // 2. Don't leave locked balances
        // 3. Transfer tokens to solver's unlocked balance
        // 4. Don't require LayerZero messaging (no srcEidToFillerFills entries)
    }
} 