// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Cross-Chain Native → ERC20 with Destination Hook
 * @notice Tests the complete flow:
 *   1. Source Chain: depositNative() - User deposits native ETH without hook
 *   2. Destination Chain: fill(order, dstHook) - Solver fills using hook to convert preferred token to ERC20 output
 *   3. Hook converts solver's preferred token to required ERC20 output tokens
 *   4. User receives ERC20 tokens, solver gets any surplus from hook conversion
 *   5. Source Chain: settle() - Settlement via LayerZero, solver gets native ETH unlocked
 * @dev Verifies balance accounting, hook execution, token transfers, and cross-chain messaging
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCrossChainNativeToERC20DstHookSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";
import {MockHook2} from "../Mock/MockHook2.sol";

contract CC_NativeToERC20DstHook is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;         // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 2000e18;        // ERC20 output (user receives)
    uint128 public constant PREFERRED_INPUT = 2100e18;      // Preferred token input (solver provides to hook)

    // Cross-chain addresses
    address public userSource;     // User on source chain
    address public userDest;       // User on destination chain  
    address public solverSource;   // Solver on source chain
    address public solverDest;     // Solver on destination chain

    // Private keys for signing
    uint256 public userSourcePrivKey = 0xABCD;
    uint256 public solverSourcePrivKey = 0xDEAD;
    uint256 public solverDestPrivKey = 0xBEEF;

    // Order details
    IAori.Order private order;
    
    // Mock hook for token conversion (override from TestUtils)
    MockHook2 public dstHook;

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
        
        uint256 tokenPart = absAmount / 1e18; // 18 decimals for tokens
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
        userSource = vm.addr(userSourcePrivKey);
        solverSource = vm.addr(solverSourcePrivKey);
        solverDest = vm.addr(solverDestPrivKey);
        userDest = makeAddr("userDest");
        
        // Setup native token balances for source chain addresses
        vm.deal(userSource, 2 ether);    // User has ETH to deposit
        vm.deal(solverSource, 1 ether);  // Solver has ETH for gas costs
        
        // Setup preferred token balances for destination chain solver
        inputToken.mint(solverDest, PREFERRED_INPUT); // Solver has preferred tokens for hook
        
        // Setup contract balances
        vm.deal(address(localAori), 0 ether);
        vm.deal(address(remoteAori), 0 ether);
        
        // Deploy and setup mock hook
        dstHook = new MockHook2();
        
        // Give the hook sufficient output tokens to convert
        outputToken.mint(address(dstHook), 3000e18); // More than enough for conversions
        
        // Add hook to whitelist
        remoteAori.addAllowedHook(address(dstHook));
        
        // Add solvers to allowed list
        localAori.addAllowedSolver(solverSource);
        remoteAori.addAllowedSolver(solverDest);
    }

    /**
     * @notice Helper function to create and deposit native order
     */
    function _createAndDepositNativeOrder() internal {
        vm.chainId(localEid);
        
        // Create test order with native input and ERC20 output
        order = createCustomOrder(
            userSource,                  // offerer
            userDest,                    // recipient
            NATIVE_TOKEN,                // inputToken (native ETH)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );
        
        // Generate signature
        bytes memory signature = signOrder(order, userSourcePrivKey);

        // User deposits their own native tokens directly
        vm.prank(userSource);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Helper function to fill order with destination hook
     */
    function _fillOrderWithDstHook() internal {
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1); // Advance time so order has started

        // Create destination hook configuration
        IAori.DstHook memory dstHookConfig = IAori.DstHook({
            hookAddress: address(dstHook),
            preferredToken: address(inputToken),        // Solver's preferred token
            preferedDstInputAmount: PREFERRED_INPUT,    // Amount solver will provide
            instructions: abi.encodeWithSignature(
                "swapTokens(address,uint256,address,uint256)",
                address(inputToken),    // tokenIn
                PREFERRED_INPUT,        // amountIn
                address(outputToken),   // tokenOut
                OUTPUT_AMOUNT           // minAmountOut
            )
        });

        // Approve solver's preferred tokens to be spent by the contract
        vm.prank(solverDest);
        inputToken.approve(address(remoteAori), PREFERRED_INPUT);

        // Execute fill with destination hook
        vm.prank(solverDest);
        remoteAori.fill(order, dstHookConfig);
    }

    /**
     * @notice Helper function to settle order
     */
    function _settleOrder() internal {
        bytes memory options = defaultOptions();
        
        // For clean accounting, just send 1 ether as fee and reset balance after
        uint256 balanceBeforeSettle = solverDest.balance;
        vm.deal(solverDest, balanceBeforeSettle + 1 ether); // Give extra ETH for fees
        
        vm.prank(solverDest);
        remoteAori.settle{value: 1 ether}(localEid, solverDest, options);
        
        // Reset balance to eliminate fee effect
        vm.deal(solverDest, balanceBeforeSettle);
    }

    /**
     * @notice Helper function to simulate LayerZero message delivery
     */
    function _simulateLzMessageDelivery() internal {
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");
        bytes memory settlementPayload = abi.encodePacked(
            uint8(0), // message type 0 for settlement
            solverSource, // filler address (should be source chain solver for settlement)
            uint16(1), // fill count
            localAori.hash(order) // order hash
        );

        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            settlementPayload,
            address(0),
            bytes("")
        );
    }

    /**
     * @notice Test Phase 1: Deposit native tokens on source chain
     */
    function testPhase1_DepositNative() public {
        uint256 initialLocked = localAori.getLockedBalances(userSource, NATIVE_TOKEN);
        uint256 initialContractBalance = address(localAori).balance;
        uint256 initialUserBalance = userSource.balance;

        _createAndDepositNativeOrder();

        // Verify locked balance increased
        assertEq(
            localAori.getLockedBalances(userSource, NATIVE_TOKEN),
            initialLocked + INPUT_AMOUNT,
            "Locked balance not increased for user"
        );

        // Verify contract received native tokens
        assertEq(
            address(localAori).balance,
            initialContractBalance + INPUT_AMOUNT,
            "Contract should receive native tokens"
        );

        // Verify user balance decreased
        assertEq(
            userSource.balance,
            initialUserBalance - INPUT_AMOUNT,
            "User balance should decrease"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test Phase 2: Fill with destination hook on destination chain
     */
    function testPhase2_FillWithDstHook() public {
        _createAndDepositNativeOrder();

        // Record pre-fill balances
        uint256 preFillUserOutputTokens = outputToken.balanceOf(userDest);
        uint256 preFillSolverInputTokens = inputToken.balanceOf(solverDest);
        uint256 preFillSolverOutputTokens = outputToken.balanceOf(solverDest);
        uint256 preFillContractOutputTokens = outputToken.balanceOf(address(remoteAori));

        _fillOrderWithDstHook();

        // Calculate expected amounts from MockHook2's swapTokens function
        // MockHook2 does 1:1 conversion for ERC20 to ERC20 (both 18 decimals)
        uint256 expectedHookOutput = PREFERRED_INPUT; // 1:1 conversion
        uint256 expectedSurplus = expectedHookOutput - OUTPUT_AMOUNT;

        // Verify token transfers
        assertEq(
            outputToken.balanceOf(userDest),
            preFillUserOutputTokens + OUTPUT_AMOUNT,
            "User should receive exact output amount"
        );
        
        assertEq(
            inputToken.balanceOf(solverDest),
            preFillSolverInputTokens - PREFERRED_INPUT,
            "Solver should spend preferred input amount"
        );
        
        assertEq(
            outputToken.balanceOf(solverDest),
            preFillSolverOutputTokens + expectedSurplus,
            "Solver should receive surplus from hook conversion"
        );
        
        // Contract should not hold any tokens after hook execution
        assertEq(
            outputToken.balanceOf(address(remoteAori)),
            preFillContractOutputTokens,
            "Contract should not hold output tokens after hook fill"
        );

        // Verify order status
        assertTrue(remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled, "Order should be Filled");
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositNativeOrder();
        _fillOrderWithDstHook();
        _settleOrder();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositNativeOrder();
        _fillOrderWithDstHook();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state (check source chain balances)
        vm.chainId(localEid);
        assertEq(
            localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN),
            INPUT_AMOUNT,
            "Solver unlocked native balance incorrect after settlement"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");

        // Verify locked balance is cleared
        assertEq(
            localAori.getLockedBalances(userSource, NATIVE_TOKEN),
            0,
            "Offerer should have no locked balance after settlement"
        );
    }

    /**
     * @notice Test Phase 5: Solver withdrawal of native tokens
     */
    function testPhase5_SolverWithdrawal() public {
        _createAndDepositNativeOrder();
        _fillOrderWithDstHook();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Switch to source chain for withdrawal
        vm.chainId(localEid);
        uint256 solverBalanceBeforeWithdraw = solverSource.balance;
        uint256 contractBalanceBeforeWithdraw = address(localAori).balance;
        
        // Solver withdraws their earned tokens (use source chain solver)
        vm.prank(solverSource);
        localAori.withdraw(NATIVE_TOKEN, INPUT_AMOUNT);
        
        // Verify withdrawal
        assertEq(
            solverSource.balance,
            solverBalanceBeforeWithdraw + INPUT_AMOUNT,
            "Solver should receive withdrawn native tokens"
        );
        assertEq(
            address(localAori).balance,
            contractBalanceBeforeWithdraw - INPUT_AMOUNT,
            "Contract should send native tokens"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN),
            0,
            "Solver should have no remaining balance"
        );
    }

    /**
     * @notice Full end-to-end test that runs all phases in sequence with detailed balance logging
     */
    function testCrossChainNativeToERC20DstHookSuccess() public {
        console.log("=== CROSS-CHAIN NATIVE TO ERC20 TOKEN SWAP TEST (WITH DESTINATION HOOK) ===");
        console.log("Flow: User deposits 1 ETH -> Solver uses hook (2100 preferred -> 2100 output) -> User gets 2000, solver gets 100 surplus");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        vm.chainId(localEid); // Source chain
        uint256 initialUserSourceNative = userSource.balance;
        uint256 initialSolverSourceNative = solverSource.balance;
        uint256 initialContractSourceNative = address(localAori).balance;
        
        vm.chainId(remoteEid); // Destination chain  
        uint256 initialUserDestOutputTokens = outputToken.balanceOf(userDest);
        uint256 initialSolverDestInputTokens = inputToken.balanceOf(solverDest);
        uint256 initialSolverDestOutputTokens = outputToken.balanceOf(solverDest);
        uint256 initialContractDestOutputTokens = outputToken.balanceOf(address(remoteAori));
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("Source Chain:");
        console.log("  User native balance:", initialUserSourceNative / 1e18, "ETH");
        console.log("  Solver native balance:", initialSolverSourceNative / 1e18, "ETH");
        console.log("  Contract native balance:", initialContractSourceNative / 1e18, "ETH");
        console.log("Destination Chain:");
        console.log("  User output tokens:", initialUserDestOutputTokens / 1e18, "tokens");
        console.log("  Solver preferred tokens:", initialSolverDestInputTokens / 1e18, "tokens");
        console.log("  Solver output tokens:", initialSolverDestOutputTokens / 1e18, "tokens");
        console.log("  Contract output tokens:", initialContractDestOutputTokens / 1e18, "tokens");
        console.log("");

        // === PHASE 1: DEPOSIT ===
        console.log("=== PHASE 1: USER DEPOSITS 1 ETH ON SOURCE CHAIN ===");
        _createAndDepositNativeOrder();

        vm.chainId(localEid);
        uint256 afterDepositUserSourceNative = userSource.balance;
        uint256 afterDepositContractSourceNative = address(localAori).balance;
        uint256 afterDepositUserSourceLocked = localAori.getLockedBalances(userSource, NATIVE_TOKEN);
        
        console.log("Source Chain After Deposit:");
        console.log("  User native balance:", afterDepositUserSourceNative / 1e18, "ETH");
        int256 userDepositChange = int256(afterDepositUserSourceNative) - int256(initialUserSourceNative);
        console.log("    Change:", formatETH(userDepositChange));
        console.log("  Contract native balance:", afterDepositContractSourceNative / 1e18, "ETH");
        int256 contractDepositChange = int256(afterDepositContractSourceNative) - int256(initialContractSourceNative);
        console.log("    Change:", formatETH(contractDepositChange));
        console.log("  User locked balance:", afterDepositUserSourceLocked / 1e18, "ETH");
        console.log("");

        // === PHASE 2: FILL WITH DESTINATION HOOK ===
        console.log("=== PHASE 2: SOLVER FILLS ORDER WITH DESTINATION HOOK ===");
        console.log("Hook conversion: 2100 preferred tokens -> 2100 output tokens (1:1 rate)");
        console.log("User gets: 2000 tokens, Solver surplus: 100 tokens");
        _fillOrderWithDstHook();

        vm.chainId(remoteEid);
        uint256 afterFillUserDestOutputTokens = outputToken.balanceOf(userDest);
        uint256 afterFillSolverDestInputTokens = inputToken.balanceOf(solverDest);
        uint256 afterFillSolverDestOutputTokens = outputToken.balanceOf(solverDest);
        uint256 afterFillContractDestOutputTokens = outputToken.balanceOf(address(remoteAori));
        
        console.log("Destination Chain After Fill:");
        console.log("  User output tokens:", afterFillUserDestOutputTokens / 1e18, "tokens");
        int256 userFillChange = int256(afterFillUserDestOutputTokens) - int256(initialUserDestOutputTokens);
        console.log("    Change:", formatTokens(userFillChange));
        console.log("  Solver preferred tokens:", afterFillSolverDestInputTokens / 1e18, "tokens");
        int256 solverInputChange = int256(afterFillSolverDestInputTokens) - int256(initialSolverDestInputTokens);
        console.log("    Change:", formatTokens(solverInputChange));
        console.log("  Solver output tokens:", afterFillSolverDestOutputTokens / 1e18, "tokens");
        int256 solverOutputChange = int256(afterFillSolverDestOutputTokens) - int256(initialSolverDestOutputTokens);
        console.log("    Change:", formatTokens(solverOutputChange));
        console.log("  Contract output tokens:", afterFillContractDestOutputTokens / 1e18, "tokens");
        int256 contractFillChange = int256(afterFillContractDestOutputTokens) - int256(initialContractDestOutputTokens);
        console.log("    Change:", formatTokens(contractFillChange));
        console.log("");

        // === PHASE 3: SETTLEMENT ===
        console.log("=== PHASE 3: SETTLEMENT VIA LAYERZERO ===");
        
        _settleOrder();
        _simulateLzMessageDelivery();

        vm.chainId(localEid);
        uint256 afterSettlementUserSourceLocked = localAori.getLockedBalances(userSource, NATIVE_TOKEN);
        uint256 afterSettlementSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN);
        
        console.log("Source Chain After Settlement:");
        console.log("  User locked balance:", afterSettlementUserSourceLocked / 1e18, "ETH");
        int256 lockedChange = int256(afterSettlementUserSourceLocked) - int256(afterDepositUserSourceLocked);
        console.log("    Change:", formatETH(lockedChange));
        console.log("  Solver unlocked balance:", afterSettlementSolverSourceUnlocked / 1e18, "ETH");
        console.log("");

        // === PHASE 4: WITHDRAWAL ===
        console.log("=== PHASE 4: SOLVER WITHDRAWAL ON SOURCE CHAIN ===");
        vm.chainId(localEid);
        uint256 beforeWithdrawSolverSourceNative = solverSource.balance;
        uint256 beforeWithdrawContractSourceNative = address(localAori).balance;
        
        vm.prank(solverSource);
        localAori.withdraw(NATIVE_TOKEN, INPUT_AMOUNT);
        
        uint256 afterWithdrawSolverSourceNative = solverSource.balance;
        uint256 afterWithdrawContractSourceNative = address(localAori).balance;
        uint256 afterWithdrawSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN);
        
        console.log("Source Chain After Withdrawal:");
        console.log("  Solver native balance:", afterWithdrawSolverSourceNative / 1e18, "ETH");
        int256 solverWithdrawChange = int256(afterWithdrawSolverSourceNative) - int256(beforeWithdrawSolverSourceNative);
        console.log("    Change:", formatETH(solverWithdrawChange));
        console.log("  Contract native balance:", afterWithdrawContractSourceNative / 1e18, "ETH");
        int256 contractWithdrawChange = int256(afterWithdrawContractSourceNative) - int256(beforeWithdrawContractSourceNative);
        console.log("    Change:", formatETH(contractWithdrawChange));
        console.log("  Solver unlocked balance:", afterWithdrawSolverSourceUnlocked / 1e18, "ETH");
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        vm.chainId(localEid); // Source chain
        uint256 finalUserSourceNative = userSource.balance;
        uint256 finalSolverSourceNative = solverSource.balance;
        
        vm.chainId(remoteEid); // Destination chain
        uint256 finalUserDestOutputTokens = outputToken.balanceOf(userDest);
        uint256 finalSolverDestInputTokens = inputToken.balanceOf(solverDest);
        uint256 finalSolverDestOutputTokens = outputToken.balanceOf(solverDest);

        console.log("User Net Changes:");
        int256 userSourceNetChange = int256(finalUserSourceNative) - int256(initialUserSourceNative);
        int256 userDestNetChange = int256(finalUserDestOutputTokens) - int256(initialUserDestOutputTokens);
        console.log("  Source chain ETH:", formatETH(userSourceNetChange));
        console.log("  Destination chain output tokens:", formatTokens(userDestNetChange));
        console.log("  Trade: User paid 1 ETH and received 2000 output tokens");
        
        console.log("Solver Net Changes:");
        int256 solverSourceNetChange = int256(finalSolverSourceNative) - int256(initialSolverSourceNative);
        int256 solverDestInputNetChange = int256(finalSolverDestInputTokens) - int256(initialSolverDestInputTokens);
        int256 solverDestOutputNetChange = int256(finalSolverDestOutputTokens) - int256(initialSolverDestOutputTokens);
        console.log("  Source chain ETH:", formatETH(solverSourceNetChange));
        console.log("  Destination chain preferred tokens:", formatTokens(solverDestInputNetChange));
        console.log("  Destination chain output tokens:", formatTokens(solverDestOutputNetChange));
        console.log("  Trade summary: Solver received 1 ETH, paid 2100 preferred tokens, got 100 output token surplus");
        
        // === ASSERTIONS ===
        // User should have paid INPUT_AMOUNT ETH and received OUTPUT_AMOUNT tokens
        assertEq(userSourceNetChange, -int256(uint256(INPUT_AMOUNT)), "User should have paid input amount");
        assertEq(userDestNetChange, int256(uint256(OUTPUT_AMOUNT)), "User should have received output amount");
        
        // Solver should have gained INPUT_AMOUNT ETH, paid PREFERRED_INPUT preferred tokens, and gained surplus
        assertEq(solverSourceNetChange, int256(uint256(INPUT_AMOUNT)), "Solver should have gained input ETH");
        assertEq(solverDestInputNetChange, -int256(uint256(PREFERRED_INPUT)), "Solver should have paid preferred tokens");
        
        // Calculate expected surplus from hook conversion (1:1 rate)
        uint256 expectedHookOutput = PREFERRED_INPUT; // 1:1 conversion
        uint256 expectedSurplus = expectedHookOutput - OUTPUT_AMOUNT;
        assertEq(solverDestOutputNetChange, int256(expectedSurplus), "Solver should have received expected surplus");
        
        console.log("");
        console.log("All assertions passed! Cross-chain Native to ERC20 swap (with destination hook) successful.");
    }
}
