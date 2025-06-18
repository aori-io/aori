// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Cross-Chain ERC20 (with srcHook) → Native (with dstHook)
 * @notice Tests the complete flow:
 *   1. Source Chain: deposit(order, srcHook) - User deposits ERC20, hook converts to srcPreferred token
 *   2. Destination Chain: fill(order, dstHook) - Solver uses dstHook to convert dstPreferred token to native ETH
 *   3. Both hooks use different preferred tokens for comprehensive testing
 *   4. Solver gets surplus from efficient destination hook conversion
 *   5. Source Chain: settle() - Settlement via LayerZero, solver gets srcPreferred tokens unlocked
 * @dev Verifies dual hook execution, balance accounting, token transfers, and cross-chain messaging
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCrossChainERC20ToNativeHookSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import {MockERC20} from "../Mock/MockERC20.sol";

contract CC_ERC20ToNativeHook is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1000e18;          // ERC20 input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1 ether;         // Native ETH output (user receives)
    uint128 public constant SRC_PREFERRED_OUTPUT = 1000e18;  // srcHook converts input -> srcPreferred (1:1 rate)
    uint128 public constant DST_PREFERRED_INPUT = 1100e6;    // dstHook input (solver provides, 6 decimals)

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
    
    // Mock hooks for token conversion (different preferred tokens)
    MockHook2 public srcHook;      // Source chain hook
    MockHook2 public dstHook;      // Destination chain hook
    
    // Additional tokens for different preferred tokens (override from TestUtils)
    MockERC20 public srcHookPreferredToken;  // Source hook preferred token (18 decimals)
    MockERC20 public dstHookPreferredToken;  // Destination hook preferred token (6 decimals)

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
    function formatTokens(int256 tokenAmount, uint8 decimals) internal pure returns (string memory) {
        if (tokenAmount == 0) return "0 tokens";
        
        bool isNegative = tokenAmount < 0;
        uint256 absAmount = uint256(isNegative ? -tokenAmount : tokenAmount);
        
        uint256 divisor = 10**decimals;
        uint256 tokenPart = absAmount / divisor;
        uint256 decimalPart = absAmount % divisor;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (decimalPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(tokenPart), " tokens"));
        } else {
            // Show up to 2 decimal places for tokens
            uint256 decimalsToShow = decimalPart / (divisor / 100); // Convert to 2 decimal places
            return string(abi.encodePacked(sign, vm.toString(tokenPart), ".", vm.toString(decimalsToShow), " tokens"));
        }
    }

    /**
     * @notice Helper function to format 18-decimal tokens
     */
    function formatTokens18(int256 tokenAmount) internal pure returns (string memory) {
        return formatTokens(tokenAmount, 18);
    }

    /**
     * @notice Helper function to format 6-decimal tokens
     */
    function formatTokens6(int256 tokenAmount) internal pure returns (string memory) {
        return formatTokens(tokenAmount, 6);
    }

    function setUp() public override {
        super.setUp();
        
        // Derive addresses from private keys
        userSource = vm.addr(userSourcePrivKey);
        solverSource = vm.addr(solverSourcePrivKey);
        solverDest = vm.addr(solverDestPrivKey);
        userDest = makeAddr("userDest");
        
        // Create additional preferred tokens with different decimals
        srcHookPreferredToken = new MockERC20("SrcPreferred", "SRCPREF"); // 18 decimals
        dstHookPreferredToken = new MockERC20("DstPreferred", "DSTPREF"); // Will override to 6 decimals
        
        // Override decimals for dstHookPreferredToken to 6
        vm.mockCall(
            address(dstHookPreferredToken),
            abi.encodeWithSelector(dstHookPreferredToken.decimals.selector),
            abi.encode(uint8(6))
        );
        
        // Setup ERC20 input token balances for source chain addresses
        inputToken.mint(userSource, INPUT_AMOUNT); // User has input tokens to deposit
        
        // Setup destination chain solver with preferred tokens and native ETH
        dstHookPreferredToken.mint(solverDest, DST_PREFERRED_INPUT); // Solver has preferred tokens for dst hook
        vm.deal(solverDest, 0 ether); // Start with no ETH, hook will provide it
        
        // Setup contract balances
        vm.deal(address(localAori), 0 ether);
        vm.deal(address(remoteAori), 0 ether);
        
        // Deploy and setup source hook
        srcHook = new MockHook2();
        srcHookPreferredToken.mint(address(srcHook), SRC_PREFERRED_OUTPUT); // Hook has preferred tokens to convert to
        localAori.addAllowedHook(address(srcHook));
        
        // Deploy and setup destination hook  
        dstHook = new MockHook2();
        vm.deal(address(dstHook), 1200 ether); // Give hook enough ETH to convert to (1100 + surplus)
        remoteAori.addAllowedHook(address(dstHook));
        
        // Add solvers to allowed list
        localAori.addAllowedSolver(solverSource);
        remoteAori.addAllowedSolver(solverDest);
    }

    /**
     * @notice Helper function to create and deposit ERC20 order with source hook
     */
    function _createAndDepositERC20OrderWithSrcHook() internal {
        vm.chainId(localEid);
        
        // Create test order with ERC20 input and native output
        order = createCustomOrder(
            userSource,                     // offerer
            userDest,                       // recipient
            address(inputToken),            // inputToken (ERC20)
            NATIVE_TOKEN,                   // outputToken (native ETH)
            INPUT_AMOUNT,                   // inputAmount
            OUTPUT_AMOUNT,                  // outputAmount
            block.timestamp,                // startTime
            block.timestamp + 1 hours,      // endTime
            localEid,                       // srcEid
            remoteEid                       // dstEid
        );
        
        // Generate signature
        bytes memory signature = signOrder(order, userSourcePrivKey);

        // Create source hook configuration
        IAori.SrcHook memory srcHookConfig = IAori.SrcHook({
            hookAddress: address(srcHook),
            preferredToken: address(srcHookPreferredToken),     // Hook converts to srcPreferred tokens
            minPreferedTokenAmountOut: SRC_PREFERRED_OUTPUT, // Minimum output expected
            instructions: abi.encodeWithSignature(
                "swapTokens(address,uint256,address,uint256)",
                address(inputToken),            // tokenIn
                INPUT_AMOUNT,                   // amountIn
                address(srcHookPreferredToken),     // tokenOut
                SRC_PREFERRED_OUTPUT            // minAmountOut
            )
        });

        // Approve user's input tokens to be spent by the contract
        vm.prank(userSource);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        // Execute deposit with source hook
        vm.prank(solverSource);
        localAori.deposit(order, signature, srcHookConfig);
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
            preferredToken: address(dstHookPreferredToken),     // Solver's preferred token (6 decimals)
            preferedDstInputAmount: DST_PREFERRED_INPUT,    // Amount solver will provide
            instructions: abi.encodeWithSignature(
                "swapTokens(address,uint256,address,uint256)",
                address(dstHookPreferredToken), // tokenIn (6 decimals)
                DST_PREFERRED_INPUT,        // amountIn
                NATIVE_TOKEN,               // tokenOut (native ETH)
                OUTPUT_AMOUNT               // minAmountOut
            )
        });

        // Approve solver's preferred tokens to be spent by the contract
        vm.prank(solverDest);
        dstHookPreferredToken.approve(address(remoteAori), DST_PREFERRED_INPUT);

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
     * @notice Test Phase 1: Deposit ERC20 tokens with source hook on source chain
     */
    function testPhase1_DepositERC20WithSrcHook() public {
        uint256 initialUserInputTokens = inputToken.balanceOf(userSource);
        uint256 initialContractSrcPreferred = srcHookPreferredToken.balanceOf(address(localAori));
        uint256 initialUserSourceLocked = localAori.getLockedBalances(userSource, address(srcHookPreferredToken));

        _createAndDepositERC20OrderWithSrcHook();

        // Verify user's input tokens were spent
        assertEq(
            inputToken.balanceOf(userSource),
            initialUserInputTokens - INPUT_AMOUNT,
            "User should have spent input tokens"
        );

        // Verify contract received srcPreferred tokens from hook
        assertEq(
            srcHookPreferredToken.balanceOf(address(localAori)),
            initialContractSrcPreferred + SRC_PREFERRED_OUTPUT,
            "Contract should receive srcPreferred tokens from hook"
        );

        // Verify locked balance increased with srcPreferred tokens
        assertEq(
            localAori.getLockedBalances(userSource, address(srcHookPreferredToken)),
            initialUserSourceLocked + SRC_PREFERRED_OUTPUT,
            "Locked balance should increase with srcPreferred tokens"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test Phase 2: Fill with destination hook on destination chain
     */
    function testPhase2_FillWithDstHook() public {
        _createAndDepositERC20OrderWithSrcHook();

        // Record pre-fill balances
        uint256 preFillUserNative = userDest.balance;
        uint256 preFillSolverDstPreferred = dstHookPreferredToken.balanceOf(solverDest);
        uint256 preFillSolverNative = solverDest.balance;

        _fillOrderWithDstHook();

        // Calculate expected amounts from MockHook2's swapTokens function
        // MockHook2 scales from 6 decimals to 18 decimals (multiply by 1e12)
        uint256 expectedHookOutput = DST_PREFERRED_INPUT * 1e12; // Scale from 6 to 18 decimals
        uint256 expectedSurplus = expectedHookOutput - OUTPUT_AMOUNT;

        // Verify token transfers
        assertEq(
            userDest.balance,
            preFillUserNative + OUTPUT_AMOUNT,
            "User should receive exact native output amount"
        );
        
        assertEq(
            dstHookPreferredToken.balanceOf(solverDest),
            preFillSolverDstPreferred - DST_PREFERRED_INPUT,
            "Solver should spend dstPreferred input amount"
        );
        
        assertEq(
            solverDest.balance,
            preFillSolverNative + expectedSurplus,
            "Solver should receive surplus from hook conversion"
        );

        // Verify order status
        assertTrue(remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled, "Order should be Filled");
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositERC20OrderWithSrcHook();
        _fillOrderWithDstHook();
        _settleOrder();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositERC20OrderWithSrcHook();
        _fillOrderWithDstHook();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state (check source chain balances)
        vm.chainId(localEid);
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(srcHookPreferredToken)),
            SRC_PREFERRED_OUTPUT,
            "Solver unlocked srcPreferred balance incorrect after settlement"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");

        // Verify locked balance is cleared
        assertEq(
            localAori.getLockedBalances(userSource, address(srcHookPreferredToken)),
            0,
            "Offerer should have no locked balance after settlement"
        );
    }

    /**
     * @notice Test Phase 5: Solver withdrawal of srcPreferred tokens
     */
    function testPhase5_SolverWithdrawal() public {
        _createAndDepositERC20OrderWithSrcHook();
        _fillOrderWithDstHook();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Switch to source chain for withdrawal
        vm.chainId(localEid);
        uint256 solverBalanceBeforeWithdraw = srcHookPreferredToken.balanceOf(solverSource);
        uint256 contractBalanceBeforeWithdraw = srcHookPreferredToken.balanceOf(address(localAori));
        
        // Solver withdraws their earned tokens (use source chain solver)
        vm.prank(solverSource);
        localAori.withdraw(address(srcHookPreferredToken), SRC_PREFERRED_OUTPUT);
        
        // Verify withdrawal
        assertEq(
            srcHookPreferredToken.balanceOf(solverSource),
            solverBalanceBeforeWithdraw + SRC_PREFERRED_OUTPUT,
            "Solver should receive withdrawn srcPreferred tokens"
        );
        assertEq(
            srcHookPreferredToken.balanceOf(address(localAori)),
            contractBalanceBeforeWithdraw - SRC_PREFERRED_OUTPUT,
            "Contract should send srcPreferred tokens"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(srcHookPreferredToken)),
            0,
            "Solver should have no remaining balance"
        );
    }

    /**
     * @notice Full end-to-end test that runs all phases in sequence with detailed balance logging
     */
    function testCrossChainERC20ToNativeHookSuccess() public {
        console.log("=== CROSS-CHAIN ERC20 TO NATIVE TOKEN SWAP TEST (WITH DUAL HOOKS) ===");
        console.log("Flow: User deposits 1000 ERC20 -> srcHook (1000 ERC20 -> 1000 srcPref) -> dstHook (1100 dstPref -> 1100 ETH) -> User gets 1 ETH, solver gets 1099 ETH surplus");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        vm.chainId(localEid); // Source chain
        uint256 initialUserSourceInputTokens = inputToken.balanceOf(userSource);
        uint256 initialSolverSourceSrcPreferred = srcHookPreferredToken.balanceOf(solverSource);
        uint256 initialContractSourceSrcPreferred = srcHookPreferredToken.balanceOf(address(localAori));
        
        vm.chainId(remoteEid); // Destination chain  
        uint256 initialUserDestNative = userDest.balance;
        uint256 initialSolverDestDstPreferred = dstHookPreferredToken.balanceOf(solverDest);
        uint256 initialSolverDestNative = solverDest.balance;
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("Source Chain:");
        console.log("  User input tokens (18 dec):", initialUserSourceInputTokens / 1e18, "tokens");
        console.log("  Solver srcPreferred tokens (18 dec):", initialSolverSourceSrcPreferred / 1e18, "tokens");
        console.log("  Contract srcPreferred tokens (18 dec):", initialContractSourceSrcPreferred / 1e18, "tokens");
        console.log("Destination Chain:");
        console.log("  User native balance:", initialUserDestNative / 1e18, "ETH");
        console.log("  Solver dstPreferred tokens (6 dec):", initialSolverDestDstPreferred / 1e6, "tokens");
        console.log("  Solver native balance:", initialSolverDestNative / 1e18, "ETH");
        console.log("");

        // === PHASE 1: DEPOSIT WITH SOURCE HOOK ===
        console.log("=== PHASE 1: USER DEPOSITS 1000 ERC20 WITH SOURCE HOOK ===");
        console.log("SrcHook conversion: 1000 input tokens -> 1000 srcPreferred tokens (1:1 rate)");
        _createAndDepositERC20OrderWithSrcHook();

        vm.chainId(localEid);
        uint256 afterDepositUserSourceInputTokens = inputToken.balanceOf(userSource);
        uint256 afterDepositContractSourceSrcPreferred = srcHookPreferredToken.balanceOf(address(localAori));
        uint256 afterDepositUserSourceLocked = localAori.getLockedBalances(userSource, address(srcHookPreferredToken));
        
        console.log("Source Chain After Deposit:");
        console.log("  User input tokens (18 dec):", afterDepositUserSourceInputTokens / 1e18, "tokens");
        int256 userInputChange = int256(afterDepositUserSourceInputTokens) - int256(initialUserSourceInputTokens);
        console.log("    Change:", formatTokens18(userInputChange));
        console.log("  Contract srcPreferred tokens (18 dec):", afterDepositContractSourceSrcPreferred / 1e18, "tokens");
        int256 contractSrcPrefChange = int256(afterDepositContractSourceSrcPreferred) - int256(initialContractSourceSrcPreferred);
        console.log("    Change:", formatTokens18(contractSrcPrefChange));
        console.log("  User locked srcPreferred balance:", afterDepositUserSourceLocked / 1e18, "tokens");
        console.log("");

        // === PHASE 2: FILL WITH DESTINATION HOOK ===
        console.log("=== PHASE 2: SOLVER FILLS ORDER WITH DESTINATION HOOK ===");
        console.log("DstHook conversion: 1100 dstPreferred tokens (6 dec) -> 1100 ETH (18 dec)");
        console.log("User gets: 1 ETH, Solver surplus: 1099 ETH");
        _fillOrderWithDstHook();

        vm.chainId(remoteEid);
        uint256 afterFillUserDestNative = userDest.balance;
        uint256 afterFillSolverDestDstPreferred = dstHookPreferredToken.balanceOf(solverDest);
        uint256 afterFillSolverDestNative = solverDest.balance;
        
        console.log("Destination Chain After Fill:");
        console.log("  User native balance:", afterFillUserDestNative / 1e18, "ETH");
        int256 userNativeChange = int256(afterFillUserDestNative) - int256(initialUserDestNative);
        console.log("    Change:", formatETH(userNativeChange));
        console.log("  Solver dstPreferred tokens (6 dec):", afterFillSolverDestDstPreferred / 1e6, "tokens");
        int256 solverDstPrefChange = int256(afterFillSolverDestDstPreferred) - int256(initialSolverDestDstPreferred);
        console.log("    Change:", formatTokens6(solverDstPrefChange));
        console.log("  Solver native balance:", afterFillSolverDestNative / 1e18, "ETH");
        int256 solverNativeChange = int256(afterFillSolverDestNative) - int256(initialSolverDestNative);
        console.log("    Change:", formatETH(solverNativeChange));
        console.log("");

        // === PHASE 3: SETTLEMENT ===
        console.log("=== PHASE 3: SETTLEMENT VIA LAYERZERO ===");
        
        _settleOrder();
        _simulateLzMessageDelivery();

        vm.chainId(localEid);
        uint256 afterSettlementUserSourceLocked = localAori.getLockedBalances(userSource, address(srcHookPreferredToken));
        uint256 afterSettlementSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, address(srcHookPreferredToken));
        
        console.log("Source Chain After Settlement:");
        console.log("  User locked srcPreferred balance:", afterSettlementUserSourceLocked / 1e18, "tokens");
        int256 lockedChange = int256(afterSettlementUserSourceLocked) - int256(afterDepositUserSourceLocked);
        console.log("    Change:", formatTokens18(lockedChange));
        console.log("  Solver unlocked srcPreferred balance:", afterSettlementSolverSourceUnlocked / 1e18, "tokens");
        console.log("");

        // === PHASE 4: WITHDRAWAL ===
        console.log("=== PHASE 4: SOLVER WITHDRAWAL ON SOURCE CHAIN ===");
        vm.chainId(localEid);
        uint256 beforeWithdrawSolverSourceSrcPreferred = srcHookPreferredToken.balanceOf(solverSource);
        uint256 beforeWithdrawContractSourceSrcPreferred = srcHookPreferredToken.balanceOf(address(localAori));
        
        vm.prank(solverSource);
        localAori.withdraw(address(srcHookPreferredToken), SRC_PREFERRED_OUTPUT);
        
        uint256 afterWithdrawSolverSourceSrcPreferred = srcHookPreferredToken.balanceOf(solverSource);
        uint256 afterWithdrawContractSourceSrcPreferred = srcHookPreferredToken.balanceOf(address(localAori));
        uint256 afterWithdrawSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, address(srcHookPreferredToken));
        
        console.log("Source Chain After Withdrawal:");
        console.log("  Solver srcPreferred tokens (18 dec):", afterWithdrawSolverSourceSrcPreferred / 1e18, "tokens");
        int256 solverSrcPrefWithdrawChange = int256(afterWithdrawSolverSourceSrcPreferred) - int256(beforeWithdrawSolverSourceSrcPreferred);
        console.log("    Change:", formatTokens18(solverSrcPrefWithdrawChange));
        console.log("  Contract srcPreferred tokens (18 dec):", afterWithdrawContractSourceSrcPreferred / 1e18, "tokens");
        int256 contractSrcPrefWithdrawChange = int256(afterWithdrawContractSourceSrcPreferred) - int256(beforeWithdrawContractSourceSrcPreferred);
        console.log("    Change:", formatTokens18(contractSrcPrefWithdrawChange));
        console.log("  Solver unlocked srcPreferred balance:", afterWithdrawSolverSourceUnlocked / 1e18, "tokens");
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        vm.chainId(localEid); // Source chain
        uint256 finalUserSourceInputTokens = inputToken.balanceOf(userSource);
        uint256 finalSolverSourceSrcPreferred = srcHookPreferredToken.balanceOf(solverSource);
        
        vm.chainId(remoteEid); // Destination chain
        uint256 finalUserDestNative = userDest.balance;
        uint256 finalSolverDestDstPreferred = dstHookPreferredToken.balanceOf(solverDest);
        uint256 finalSolverDestNative = solverDest.balance;

        console.log("User Net Changes:");
        int256 userInputNetChange = int256(finalUserSourceInputTokens) - int256(initialUserSourceInputTokens);
        int256 userNativeNetChange = int256(finalUserDestNative) - int256(initialUserDestNative);
        console.log("  Source chain input tokens (18 dec):", formatTokens18(userInputNetChange));
        console.log("  Destination chain native ETH:", formatETH(userNativeNetChange));
        console.log("  Trade: User paid 1000 input tokens and received 1 ETH");
        
        console.log("Solver Net Changes:");
        int256 solverSrcPrefNetChange = int256(finalSolverSourceSrcPreferred) - int256(initialSolverSourceSrcPreferred);
        int256 solverDstPrefNetChange = int256(finalSolverDestDstPreferred) - int256(initialSolverDestDstPreferred);
        int256 solverNativeNetChange = int256(finalSolverDestNative) - int256(initialSolverDestNative);
        console.log("  Source chain srcPreferred tokens (18 dec):", formatTokens18(solverSrcPrefNetChange));
        console.log("  Destination chain dstPreferred tokens (6 dec):", formatTokens6(solverDstPrefNetChange));
        console.log("  Destination chain native ETH:", formatETH(solverNativeNetChange));
        console.log("  Trade summary: Solver received 1000 srcPreferred tokens, paid 1100 dstPreferred tokens, got 1099 ETH surplus");
        
        // === ASSERTIONS ===
        // User should have paid INPUT_AMOUNT tokens and received OUTPUT_AMOUNT ETH
        assertEq(userInputNetChange, -int256(uint256(INPUT_AMOUNT)), "User should have paid input amount");
        assertEq(userNativeNetChange, int256(uint256(OUTPUT_AMOUNT)), "User should have received output amount");
        
        // Solver should have gained srcPreferred tokens, paid dstPreferred tokens, and gained surplus
        assertEq(solverSrcPrefNetChange, int256(uint256(SRC_PREFERRED_OUTPUT)), "Solver should have gained srcPreferred tokens");
        assertEq(solverDstPrefNetChange, -int256(uint256(DST_PREFERRED_INPUT)), "Solver should have paid dstPreferred tokens");
        
        // Calculate expected surplus from dstHook conversion (6 decimals -> 18 decimals scaling)
        uint256 expectedDstHookOutput = DST_PREFERRED_INPUT * 1e12; // Scale from 6 to 18 decimals
        uint256 expectedSurplus = expectedDstHookOutput - OUTPUT_AMOUNT;
        assertEq(solverNativeNetChange, int256(expectedSurplus), "Solver should have received expected surplus");
        
        console.log("");
        console.log("All assertions passed! Cross-chain ERC20 to Native swap (with dual hooks) successful.");
    }
}
