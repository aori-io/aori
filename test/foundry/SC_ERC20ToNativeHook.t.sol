// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain ERC20 → Native with SrcHook
 * @notice Tests the complete flow:
 *   1. User signs order for ERC20 input → Native output (same chain)
 *   2. Solver executes deposit with hook: converts user's ERC20 → Native via hook
 *   3. User receives native tokens, solver gets any surplus from conversion
 *   4. Atomic settlement - everything happens in one transaction
 * @dev Verifies single-chain atomic settlement, balance accounting, and hook integration
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testSingleChainERC20ToNativeSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract SC_ERC20ToNativeHook_Test is TestUtils {
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
     * @notice Helper function to create and execute deposit with hook for single-chain swap
     */
    function _createAndExecuteDepositWithHook() internal {
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

        // Setup hook data for ERC20 → Native conversion
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

        // Solver executes deposit with hook
        vm.prank(solverSC);
        localAori.deposit(order, signature, srcHook);
    }

    /**
     * @notice Test single-chain deposit with hook
     */
    function testSingleChainDepositWithHook() public {
        uint256 initialUserTokens = inputToken.balanceOf(userSC);
        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;

        _createAndExecuteDepositWithHook();

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

        // Verify order status is Settled (atomic settlement for single-chain with hook)
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Full end-to-end test with detailed balance logging
     */
    function testSingleChainERC20ToNativeSuccess() public {
        console.log("=== SINGLE-CHAIN ERC20 TO NATIVE SWAP TEST ===");
        console.log("Flow: User deposits 10,000 tokens -> Hook converts to 1.1 ETH -> User gets 1 ETH, solver gets 0.1 ETH -> Atomic settlement");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        uint256 initialUserTokens = inputToken.balanceOf(userSC);
        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;
        uint256 initialContractNative = address(localAori).balance;
        uint256 initialHookNative = address(mockHook2).balance;
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("User:");
        console.log("  Input tokens:", initialUserTokens / 1e18, "tokens");
        console.log("  Native balance:", initialUserNative / 1e18, "ETH");
        console.log("Solver:");
        console.log("  Native balance:", initialSolverNative / 1e18, "ETH");
        console.log("Contract:");
        console.log("  Native balance:", initialContractNative / 1e18, "ETH");
        console.log("Hook:");
        console.log("  Native balance:", initialHookNative / 1e18, "ETH");
        console.log("");

        // === PHASE 1: DEPOSIT WITH HOOK (ATOMIC SETTLEMENT) ===
        console.log("=== PHASE 1: SOLVER EXECUTES DEPOSIT WITH HOOK (ATOMIC SETTLEMENT) ===");
        _createAndExecuteDepositWithHook();

        uint256 afterDepositUserTokens = inputToken.balanceOf(userSC);
        uint256 afterDepositUserNative = userSC.balance;
        uint256 afterDepositSolverNative = solverSC.balance;
        uint256 afterDepositContractNative = address(localAori).balance;
        uint256 afterDepositHookNative = address(mockHook2).balance;
        
        console.log("After Deposit & Atomic Settlement:");
        console.log("User:");
        console.log("  Input tokens:", afterDepositUserTokens / 1e18, "tokens");
        int256 userTokenChange = int256(afterDepositUserTokens) - int256(initialUserTokens);
        console.log("    Change:", formatTokens(userTokenChange));
        console.log("  Native balance:", afterDepositUserNative / 1e18, "ETH");
        int256 userNativeChange = int256(afterDepositUserNative) - int256(initialUserNative);
        console.log("    Change:", formatETH(userNativeChange));
        
        console.log("Solver:");
        console.log("  Native balance:", afterDepositSolverNative / 1e18, "ETH");
        int256 solverNativeChange = int256(afterDepositSolverNative) - int256(initialSolverNative);
        console.log("    Change:", formatETH(solverNativeChange));
        
        console.log("Contract:");
        console.log("  Native balance:", afterDepositContractNative / 1e18, "ETH");
        int256 contractNativeChange = int256(afterDepositContractNative) - int256(initialContractNative);
        console.log("    Change:", formatETH(contractNativeChange));
        
        console.log("Hook:");
        console.log("  Native balance:", afterDepositHookNative / 1e18, "ETH");
        int256 hookNativeChange = int256(afterDepositHookNative) - int256(initialHookNative);
        console.log("    Change:", formatETH(hookNativeChange));
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        console.log("User Net Changes:");
        console.log("  Input tokens:", formatTokens(userTokenChange));
        console.log("  Native tokens:", formatETH(userNativeChange));
        
        console.log("Solver Net Changes:");
        console.log("  Native tokens:", formatETH(solverNativeChange));
        
        console.log("Hook Net Changes:");
        console.log("  Native tokens:", formatETH(hookNativeChange));
        console.log("");

        // Verify final state
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
        
        // Verify no locked balances remain (atomic settlement)
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after atomic settlement");
    }

    /**
     * @notice Test balance accounting integrity for single-chain swaps with hooks
     */
    function testSingleChainBalanceAccountingIntegrity() public {
        // Initial state - no locked balances
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0);

        // After deposit with hook (atomic settlement)
        _createAndExecuteDepositWithHook();
        
        // After atomic settlement, no locked balances should remain
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0);
        
        // Order should be immediately settled
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");
    }

    /**
     * @notice Test hook mechanics for single-chain swaps
     */
    function testSingleChainHookMechanics() public {
        // Record initial hook balances
        uint256 hookInitialTokens = inputToken.balanceOf(address(mockHook2));
        uint256 hookInitialNative = address(mockHook2).balance;

        _createAndExecuteDepositWithHook();

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
    function testSingleChainHookInsufficientOutput() public {
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

        // Setup hook with insufficient output
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
     * @notice Test with different amounts to verify flexibility
     */
    function testSingleChainDifferentAmounts() public {
        uint128 customInputAmount = 5000e18;   // 5,000 tokens
        uint128 customOutputAmount = 0.5 ether; // 0.5 ETH
        uint128 customHookOutput = 0.6 ether;   // 0.6 ETH (0.1 ETH surplus)
        
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native)
            customInputAmount,           // inputAmount
            customOutputAmount,          // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid
        );

        bytes memory signature = signOrder(order, userSCPrivKey);

        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            minPreferedTokenAmountOut: customOutputAmount,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                customHookOutput
            )
        });

        uint256 initialUserNative = userSC.balance;
        uint256 initialSolverNative = solverSC.balance;

        vm.prank(userSC);
        inputToken.approve(address(localAori), customInputAmount);

        vm.prank(solverSC);
        localAori.deposit(order, signature, srcHook);

        // Verify correct amounts
        assertEq(
            userSC.balance,
            initialUserNative + customOutputAmount,
            "User should receive custom output amount"
        );
        assertEq(
            solverSC.balance,
            initialSolverNative + (customHookOutput - customOutputAmount),
            "Solver should receive surplus"
        );
    }

    /**
     * @notice Test that single-chain swaps are immediately settled (atomic settlement)
     * @dev Single-chain swaps use atomic settlement and don't require LayerZero messaging
     */
    function testSingleChainSwapAtomicSettlement() public {
        // Execute single-chain swap with hook
        _createAndExecuteDepositWithHook();
        
        // Verify order was settled atomically (not just filled)
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "Single-chain swap should be immediately settled"
        );
        
        // Verify no locked balances remain (atomic settlement)
        // For single-chain swaps with deposit hooks, no balance accounting is used
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after atomic settlement");
        assertEq(localAori.getUnlockedBalances(solverSC, NATIVE_TOKEN), 0, "Solver should have no unlocked balance for deposit hook swaps");
        
        // Verify tokens were transferred directly (not through balance accounting)
        // User should have received native tokens directly
        // Solver should have received surplus native tokens directly
    }

    /**
     * @notice Test that multiple single-chain swaps are all immediately settled
     */
    function testMultipleSingleChainSwapsAtomicSettlement() public {
        // Execute first swap
        _createAndExecuteDepositWithHook();
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "First single-chain swap should be immediately settled"
        );

        // Setup and execute second swap with different amounts
        uint128 customInputAmount = 5000e18;
        uint128 customOutputAmount = 0.5 ether;
        uint128 customHookOutput = 0.6 ether;
        
        vm.chainId(localEid);
        
        IAori.Order memory order2 = createCustomOrder(
            userSC,                      // offerer
            userSC,                      // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native)
            customInputAmount,           // inputAmount
            customOutputAmount,          // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid
        );

        bytes memory signature2 = signOrder(order2, userSCPrivKey);

        IAori.SrcHook memory srcHook2 = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN,
            minPreferedTokenAmountOut: customOutputAmount,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                customHookOutput
            )
        });

        vm.prank(userSC);
        inputToken.approve(address(localAori), customInputAmount);

        vm.prank(solverSC);
        localAori.deposit(order2, signature2, srcHook2);

        // Verify both orders were settled immediately
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "First order should be settled"
        );
        assertTrue(
            localAori.orderStatus(localAori.hash(order2)) == IAori.OrderStatus.Settled,
            "Second order should be settled"
        );
        
        // Verify no locked balances remain for either order
        assertEq(localAori.getLockedBalances(userSC, address(inputToken)), 0, "User should have no locked balance after both swaps");
    }
}
   