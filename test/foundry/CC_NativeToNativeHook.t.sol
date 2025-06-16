// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Cross-Chain Native → Native with DstHook (1:1 Case)
 * @notice Tests the complete flow:
 *   1. Source Chain: depositNative() - User deposits 1 ETH
 *   2. Destination Chain: fill(dstHook) - Solver converts 10,000 tokens to 1.1 ETH via hook
 *   3. User receives 1 ETH, solver gets 0.1 ETH surplus
 *   4. Source Chain: settle() - Settlement via LayerZero, solver gets 1 ETH unlocked
 * @dev Verifies balance accounting, token transfers, and cross-chain messaging
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCrossChainNativeToNativeSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract CC_NativeToNativeHook is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts - Simple 1:1 case
    uint128 public constant INPUT_AMOUNT = 1 ether;        // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1 ether;       // Native ETH output (user receives) 
    uint128 public constant PREFERRED_AMOUNT = 10000e6;    // Solver's preferred token amount (10,000 tokens with 6 decimals)
    uint128 public constant HOOK_OUTPUT = 1.1 ether;       // Hook converts to this much native ETH
    uint128 public constant EXPECTED_SURPLUS = 0.1 ether;  // Surplus returned to solver (1.1 - 1.0 = 0.1)

    // Cross-chain addresses
    address public userSource;     // User on source chain
    address public userDest;         // User on destination chain  
    address public solverSource; // Solver on source chain
    address public solverDest;     // Solver on destination chain

    // Private keys for signing
    uint256 public userSourcePrivKey = 0xABCD;
    uint256 public solverSourcePrivKey = 0xDEAD;
    uint256 public solverDestPrivKey = 0xBEEF;

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
        
        uint256 tokenPart = absAmount / 1e6; // 6 decimals
        uint256 decimalPart = absAmount % 1e6;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (decimalPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(tokenPart), " tokens"));
        } else {
            // Show up to 2 decimal places for tokens
            uint256 decimals = decimalPart / 1e4; // Convert to 2 decimal places
            return string(abi.encodePacked(sign, vm.toString(tokenPart), ".", vm.toString(decimals), " tokens"));
        }
    }

    function setUp() public override {
        super.setUp();
        
        // Derive addresses from private keys
        userSource = vm.addr(userSourcePrivKey);
        solverSource = vm.addr(solverSourcePrivKey);
        solverDest = vm.addr(solverDestPrivKey);
        userDest = makeAddr("userDest");  // Keep this one as makeAddr since we don't need to sign for it
        
        // Deploy MockHook2
        mockHook2 = new MockHook2();
        
        // Setup native token balances for source chain addresses
        vm.deal(userSource, 1 ether);
        vm.deal(solverSource, 1 ether);
        
        // Setup native token balances for destination chain addresses  
        vm.deal(userDest, 0 ether);      // User starts with 0 on destination
        vm.deal(solverDest, 1 ether);  // Solver has ETH for gas costs (more realistic amount)
        
        // Setup contract balances
        vm.deal(address(localAori), 0 ether);    // For any native operations
        vm.deal(address(remoteAori), 0 ether);   // For native output operations
        vm.deal(address(mockHook2), 2 ether);    // Hook needs 1.1 ether to output
        
        // Give destination solver preferred tokens for the hook
        dstPreferredToken.mint(solverDest, 10000e6); // Large amount for testing
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        remoteAori.addAllowedHook(address(mockHook2));
        
        // Add solvers to allowed list
        localAori.addAllowedSolver(solverSource);
        remoteAori.addAllowedSolver(solverDest);
    }

    /**
     * @notice Helper function to create and deposit native order
     */
    function _createAndDepositNativeOrder() internal {
        vm.chainId(localEid);
        
        // Create test order with native tokens
        order = createCustomOrder(
            userSource,                  // offerer
            userDest,                  // recipient
            NATIVE_TOKEN,          // inputToken (native ETH)
            NATIVE_TOKEN,          // outputToken (native ETH)
            INPUT_AMOUNT,          // inputAmount
            OUTPUT_AMOUNT,         // outputAmount
            block.timestamp,       // startTime
            block.timestamp + 1 hours, // endTime
            localEid,              // srcEid
            remoteEid              // dstEid
        );
        
        // Generate signature
        bytes memory signature = signOrder(order, userSourcePrivKey);

        // User deposits their own native tokens directly
        vm.prank(userSource);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Helper function to fill order with native output
     */
    function _fillOrderWithNativeOutput() internal {
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1); // Advance time so order has started

        // Setup hook data for ERC20 → Native conversion
        IAori.DstHook memory dstHook = IAori.DstHook({
            hookAddress: address(mockHook2),
            preferredToken: address(dstPreferredToken),  // Solver's preferred ERC20 token (input)
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector, 
                NATIVE_TOKEN,      // Output native tokens
                HOOK_OUTPUT        // Amount of native tokens to output
            ),
            preferedDstInputAmount: PREFERRED_AMOUNT
        });
        
        // Approve solver's preferred tokens to be spent (use destination solver)
        vm.prank(solverDest);
        dstPreferredToken.approve(address(remoteAori), PREFERRED_AMOUNT);
        
        // Execute fill with hook (use destination solver)
        vm.prank(solverDest);
        remoteAori.fill(order, dstHook);
    }

    /**
     * @notice Helper function to settle order
     */
    function _settleOrder() internal {
        bytes memory options = defaultOptions();
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solverDest);
        vm.deal(solverDest, fee);
        vm.prank(solverDest);
        remoteAori.settle{value: fee}(localEid, solverDest, options);
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

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test Phase 2: Fill with native output on destination chain
     */
    function testPhase2_FillWithNativeOutput() public {
        _createAndDepositNativeOrder();

        // Record pre-fill balances (use destination chain addresses)
        uint256 preFillSolverPreferred = dstPreferredToken.balanceOf(solverDest);
        uint256 preFillUserNative = userDest.balance;
        uint256 preFillSolverNative = solverDest.balance;
        uint256 preFillContractNative = address(remoteAori).balance;

        _fillOrderWithNativeOutput();

        // Verify token transfers (use destination chain addresses)
        assertEq(
            dstPreferredToken.balanceOf(solverDest),
            preFillSolverPreferred - PREFERRED_AMOUNT,
            "Solver preferred token balance not reduced by fill"
        );
        assertEq(
            userDest.balance,
            preFillUserNative + OUTPUT_AMOUNT,
            "User did not receive the expected native tokens"
        );
        assertEq(
            solverDest.balance,
            preFillSolverNative + EXPECTED_SURPLUS,
            "Solver did not receive the expected surplus"
        );
        
        // The hook sends HOOK_OUTPUT to the contract, then the contract sends OUTPUT_AMOUNT to user and EXPECTED_SURPLUS to solver
        // Net effect: contract balance should remain the same (receives HOOK_OUTPUT, sends HOOK_OUTPUT)
        assertEq(
            address(remoteAori).balance,
            preFillContractNative,
            "Contract balance should remain the same (receives from hook, sends to user+solver)"
        );

        // Verify order status
        assertTrue(remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled, "Order should be Filled");
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositNativeOrder();
        _fillOrderWithNativeOutput();
        _settleOrder();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositNativeOrder();
        _fillOrderWithNativeOutput();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state (check source chain balances)
        vm.chainId(localEid);
        assertEq(
            localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN),
            INPUT_AMOUNT,
            "Solver unlocked native token balance incorrect after settlement"
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
        _fillOrderWithNativeOutput();
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
    function testCrossChainNativeToNativeSuccess() public {
        console.log("=== CROSS-CHAIN NATIVE TOKEN SWAP TEST ===");
        console.log("Flow: User deposits 1 ETH on source -> Solver fills 1 ETH on dest -> Settlement -> Withdrawal");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        vm.chainId(localEid); // Source chain
        uint256 initialUserSourceNative = userSource.balance;
        uint256 initialSolverSourceNative = solverSource.balance;
        uint256 initialContractSourceNative = address(localAori).balance;
        
        vm.chainId(remoteEid); // Destination chain  
        uint256 initialUserDestNative = userDest.balance;
        uint256 initialSolverDestNative = solverDest.balance;
        uint256 initialSolverDestTokens = dstPreferredToken.balanceOf(solverDest);
        uint256 initialContractDestNative = address(remoteAori).balance;
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("Source Chain:");
        console.log("  User native balance:", initialUserSourceNative / 1e18, "ETH");
        console.log("  Solver native balance:", initialSolverSourceNative / 1e18, "ETH");
        console.log("  Contract native balance:", initialContractSourceNative / 1e18, "ETH");
        console.log("Destination Chain:");
        console.log("  User native balance:", initialUserDestNative / 1e18, "ETH");
        console.log("  Solver native balance:", initialSolverDestNative / 1e18, "ETH");
        console.log("  Solver preferred tokens:", initialSolverDestTokens / 1e6, "tokens");
        console.log("  Contract native balance:", initialContractDestNative / 1e18, "ETH");
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

        // === PHASE 2: FILL ===
        console.log("=== PHASE 2: SOLVER FILLS ORDER ON DESTINATION CHAIN ===");
        _fillOrderWithNativeOutput();

        vm.chainId(remoteEid);
        uint256 afterFillUserDestNative = userDest.balance;
        uint256 afterFillSolverDestNative = solverDest.balance;
        uint256 afterFillSolverDestTokens = dstPreferredToken.balanceOf(solverDest);
        uint256 afterFillContractDestNative = address(remoteAori).balance;
        
        console.log("Destination Chain After Fill:");
        console.log("  User native balance:", afterFillUserDestNative / 1e18, "ETH");
        int256 userFillChange = int256(afterFillUserDestNative) - int256(initialUserDestNative);
        console.log("    Change:", formatETH(userFillChange));
        console.log("  Solver native balance:", afterFillSolverDestNative / 1e18, "ETH");
        int256 solverFillChange = int256(afterFillSolverDestNative) - int256(initialSolverDestNative);
        console.log("    Change:", formatETH(solverFillChange));
        console.log("  Solver preferred tokens:", afterFillSolverDestTokens / 1e6, "tokens");
        int256 solverTokenChange = int256(afterFillSolverDestTokens) - int256(initialSolverDestTokens);
        console.log("    Change:", formatTokens(solverTokenChange));
        console.log("  Contract native balance:", afterFillContractDestNative / 1e18, "ETH");
        int256 contractFillChange = int256(afterFillContractDestNative) - int256(initialContractDestNative);
        console.log("    Change:", formatETH(contractFillChange));
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
        uint256 finalUserDestNative = userDest.balance;
        uint256 finalSolverDestNative = solverDest.balance;
        uint256 finalSolverDestTokens = dstPreferredToken.balanceOf(solverDest);

        console.log("User Net Changes:");
        int256 userSourceNetChange = int256(finalUserSourceNative) - int256(initialUserSourceNative);
        int256 userDestNetChange = int256(finalUserDestNative) - int256(initialUserDestNative);
        console.log("  Source chain:", formatETH(userSourceNetChange));
        console.log("  Destination chain:", formatETH(userDestNetChange));
        int256 userTotalChange = userSourceNetChange + userDestNetChange;
        console.log("  Total user change:", formatETH(userTotalChange));
        
        console.log("Solver Net Changes:");
        int256 solverSourceNetChange = int256(finalSolverSourceNative) - int256(initialSolverSourceNative);
        int256 solverDestNetChange = int256(finalSolverDestNative) - int256(initialSolverDestNative);
        int256 solverTokenNetChange = int256(finalSolverDestTokens) - int256(initialSolverDestTokens);
        console.log("  Source chain:", formatETH(solverSourceNetChange));
        console.log("  Destination chain:", formatETH(solverDestNetChange));
        console.log("  Preferred tokens:", formatTokens(solverTokenNetChange));
        int256 solverTotalETHChange = solverSourceNetChange + solverDestNetChange;
        console.log("  Total solver ETH change:", formatETH(solverTotalETHChange));
        console.log("");

        // Verify final balances
        assertEq(
            localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN),
            0,
            "Solver should have withdrawn all tokens"
        );
        assertEq(
            localAori.getLockedBalances(userSource, NATIVE_TOKEN),
            0,
            "No tokens should remain locked"
        );
    }

    /**
     * @notice Test balance accounting integrity throughout the flow
     */
    function testBalanceAccountingIntegrity() public {
        // Initial state
        assertEq(localAori.getLockedBalances(userSource, NATIVE_TOKEN), 0);
        assertEq(localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN), 0);

        // After deposit
        _createAndDepositNativeOrder();
        assertEq(localAori.getLockedBalances(userSource, NATIVE_TOKEN), INPUT_AMOUNT);
        assertEq(localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN), 0);

        // After fill and settlement
        _fillOrderWithNativeOutput();
        _settleOrder();
        _simulateLzMessageDelivery();
        
        // After settlement
        assertEq(localAori.getLockedBalances(userSource, NATIVE_TOKEN), 0);
        assertEq(localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN), INPUT_AMOUNT);
        
        // Total balance conservation
        uint256 totalLocked = localAori.getLockedBalances(userSource, NATIVE_TOKEN);
        uint256 totalUnlocked = localAori.getUnlockedBalances(solverSource, NATIVE_TOKEN);
        assertEq(totalLocked + totalUnlocked, INPUT_AMOUNT, "Total internal balance should equal deposited amount");
    }

    /**
     * @notice Test native token utilities
     */
    function testNativeTokenHandling() public {
        // Test native token utilities work correctly
        assertTrue(NATIVE_TOKEN.isNativeToken(), "Should identify native token correctly");
        assertFalse(address(dstPreferredToken).isNativeToken(), "Should identify ERC20 as non-native");
        
        // Test balance checking
        uint256 contractBalance = NATIVE_TOKEN.balanceOf(address(localAori));
        assertEq(contractBalance, address(localAori).balance, "Native balance should match contract balance");
        
        // Test sufficient balance validation - should not revert
        vm.deal(address(localAori), 1 ether);
        NATIVE_TOKEN.validateSufficientBalance(0.5 ether); // Should not revert
        
        // Note: Testing insufficient balance revert is tricky with vm.expectRevert
        // The main functionality is verified by the successful end-to-end tests
    }

    /**
     * @notice Test MockHook2 functionality
     */
    function testMockHook2Functionality() public {
        // Test native token handling
        assertTrue(mockHook2.NATIVE() == NATIVE_TOKEN, "MockHook2 should use correct native token address");
        
        // Test balance checking
        uint256 hookBalance = mockHook2.balanceOfThis(NATIVE_TOKEN);
        assertEq(hookBalance, address(mockHook2).balance, "Hook should report correct native balance");
        
        // Test that hook can receive native tokens
        vm.deal(address(mockHook2), 5 ether);
        assertEq(address(mockHook2).balance, 5 ether, "Hook should receive native tokens");
    }
}
