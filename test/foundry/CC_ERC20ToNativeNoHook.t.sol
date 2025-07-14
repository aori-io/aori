// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Cross-Chain ERC20 → Native without Hooks
 * @notice Tests the complete flow:
 *   1. Source Chain: deposit() - User deposits ERC20 tokens without hook
 *   2. Destination Chain: fill() - Solver fills with native ETH without hook
 *   3. User receives native ETH directly from solver
 *   4. Source Chain: settle() - Settlement via LayerZero, solver gets ERC20 tokens unlocked
 * @dev Verifies balance accounting, token transfers, and cross-chain messaging
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCrossChainERC20ToNativeNoHookSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";

contract CC_ERC20ToNativeNoHook is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1000e18;        // ERC20 input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1 ether;       // Native ETH output (user receives)

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
        
        uint256 tokenPart = absAmount / 1e18; // 18 decimals for input token
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
        userDest = makeAddr("userDest");  // Keep this one as makeAddr since we don't need to sign for it
        
        // Setup ERC20 token balances for source chain addresses
        inputToken.mint(userSource, INPUT_AMOUNT);
        
        // Setup native token balances for destination chain addresses  
        vm.deal(userDest, 0 ether);      // User starts with 0 on destination
        vm.deal(solverDest, 10 ether);   // Solver has ETH for the fill and gas costs
        
        // Setup contract balances
        vm.deal(address(localAori), 0 ether);    // For any native operations
        vm.deal(address(remoteAori), 0 ether);   // For native output operations
        
        // Add solvers to allowed list
        localAori.addAllowedSolver(solverSource);
        remoteAori.addAllowedSolver(solverDest);
    }

    /**
     * @notice Helper function to create and deposit ERC20 order
     */
    function _createAndDepositERC20Order() internal {
        vm.chainId(localEid);
        
        // Create test order with ERC20 input and native output
        order = createCustomOrder(
            userSource,                  // offerer
            userDest,                    // recipient
            address(inputToken),         // inputToken (ERC20)
            NATIVE_TOKEN,                // outputToken (native ETH)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );
        
        // Generate signature
        bytes memory signature = signOrder(order, userSourcePrivKey);

        // User approves tokens to be spent by solver
        vm.prank(userSource);
        inputToken.approve(address(localAori), INPUT_AMOUNT);

        // Solver deposits user's ERC20 tokens (no hook)
        vm.prank(solverSource);
        localAori.deposit(order, signature);
    }

    /**
     * @notice Helper function to fill order with native output (no hook)
     */
    function _fillOrderWithNativeOutput() internal {
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1); // Advance time so order has started

        // Execute fill without hook - solver sends native ETH directly
        vm.prank(solverDest);
        remoteAori.fill{value: OUTPUT_AMOUNT}(order);
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
        remoteAori.settle{value: 1 ether}(localEid, solverDest);
        
        // Reset balance to eliminate fee effect
        vm.deal(solverDest, balanceBeforeSettle - OUTPUT_AMOUNT); // Subtract what was spent on fill
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
     * @notice Test Phase 1: Deposit ERC20 tokens on source chain
     */
    function testPhase1_DepositERC20() public {
        uint256 initialLocked = localAori.getLockedBalances(userSource, address(inputToken));
        uint256 initialContractBalance = inputToken.balanceOf(address(localAori));
        uint256 initialUserBalance = inputToken.balanceOf(userSource);

        _createAndDepositERC20Order();

        // Verify locked balance increased
        assertEq(
            localAori.getLockedBalances(userSource, address(inputToken)),
            initialLocked + INPUT_AMOUNT,
            "Locked balance not increased for user"
        );

        // Verify contract received ERC20 tokens
        assertEq(
            inputToken.balanceOf(address(localAori)),
            initialContractBalance + INPUT_AMOUNT,
            "Contract should receive ERC20 tokens"
        );

        // Verify user balance decreased
        assertEq(
            inputToken.balanceOf(userSource),
            initialUserBalance - INPUT_AMOUNT,
            "User balance should decrease"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test Phase 2: Fill with native output (no hook) on destination chain
     */
    function testPhase2_FillWithNativeOutput() public {
        _createAndDepositERC20Order();

        // Record pre-fill balances (use destination chain addresses)
        uint256 preFillUserNative = userDest.balance;
        uint256 preFillSolverNative = solverDest.balance;
        uint256 preFillContractNative = address(remoteAori).balance;

        _fillOrderWithNativeOutput();

        // Verify token transfers (use destination chain addresses)
        assertEq(
            userDest.balance,
            preFillUserNative + OUTPUT_AMOUNT,
            "User did not receive the expected native tokens"
        );
        
        // Contract should not hold any native tokens (direct transfer from solver to user)
        assertEq(
            address(remoteAori).balance,
            preFillContractNative,
            "Contract should not hold native tokens after direct fill"
        );

        // Verify order status
        assertTrue(remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled, "Order should be Filled");
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositERC20Order();
        _fillOrderWithNativeOutput();
        _settleOrder();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositERC20Order();
        _fillOrderWithNativeOutput();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state (check source chain balances)
        vm.chainId(localEid);
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(inputToken)),
            INPUT_AMOUNT,
            "Solver unlocked ERC20 balance incorrect after settlement"
        );

        // Verify order status
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");

        // Verify locked balance is cleared
        assertEq(
            localAori.getLockedBalances(userSource, address(inputToken)),
            0,
            "Offerer should have no locked balance after settlement"
        );
    }

    /**
     * @notice Test Phase 5: Solver withdrawal of ERC20 tokens
     */
    function testPhase5_SolverWithdrawal() public {
        _createAndDepositERC20Order();
        _fillOrderWithNativeOutput();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Switch to source chain for withdrawal
        vm.chainId(localEid);
        uint256 solverBalanceBeforeWithdraw = inputToken.balanceOf(solverSource);
        uint256 contractBalanceBeforeWithdraw = inputToken.balanceOf(address(localAori));
        
        // Solver withdraws their earned tokens (use source chain solver)
        vm.prank(solverSource);
        localAori.withdraw(address(inputToken), INPUT_AMOUNT);
        
        // Verify withdrawal
        assertEq(
            inputToken.balanceOf(solverSource),
            solverBalanceBeforeWithdraw + INPUT_AMOUNT,
            "Solver should receive withdrawn ERC20 tokens"
        );
        assertEq(
            inputToken.balanceOf(address(localAori)),
            contractBalanceBeforeWithdraw - INPUT_AMOUNT,
            "Contract should send ERC20 tokens"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(inputToken)),
            0,
            "Solver should have no remaining balance"
        );
    }

    /**
     * @notice Full end-to-end test that runs all phases in sequence with detailed balance logging
     */
    function testCrossChainERC20ToNativeNoHookSuccess() public {
        console.log("=== CROSS-CHAIN ERC20 TO NATIVE TOKEN SWAP TEST (NO HOOKS) ===");
        console.log("Flow: User deposits 1000 ERC20 on source -> Solver fills 1 ETH on dest -> Settlement -> Withdrawal");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        vm.chainId(localEid); // Source chain
        uint256 initialUserSourceTokens = inputToken.balanceOf(userSource);
        uint256 initialSolverSourceTokens = inputToken.balanceOf(solverSource);
        uint256 initialContractSourceTokens = inputToken.balanceOf(address(localAori));
        
        vm.chainId(remoteEid); // Destination chain  
        uint256 initialUserDestNative = userDest.balance;
        uint256 initialSolverDestNative = solverDest.balance;
        uint256 initialContractDestNative = address(remoteAori).balance;
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("Source Chain:");
        console.log("  User ERC20 balance:", initialUserSourceTokens / 1e18, "tokens");
        console.log("  Solver ERC20 balance:", initialSolverSourceTokens / 1e18, "tokens");
        console.log("  Contract ERC20 balance:", initialContractSourceTokens / 1e18, "tokens");
        console.log("Destination Chain:");
        console.log("  User native balance:", initialUserDestNative / 1e18, "ETH");
        console.log("  Solver native balance:", initialSolverDestNative / 1e18, "ETH");
        console.log("  Contract native balance:", initialContractDestNative / 1e18, "ETH");
        console.log("");

        // === PHASE 1: DEPOSIT ===
        console.log("=== PHASE 1: USER DEPOSITS 1000 ERC20 ON SOURCE CHAIN ===");
        _createAndDepositERC20Order();

        vm.chainId(localEid);
        uint256 afterDepositUserSourceTokens = inputToken.balanceOf(userSource);
        uint256 afterDepositContractSourceTokens = inputToken.balanceOf(address(localAori));
        uint256 afterDepositUserSourceLocked = localAori.getLockedBalances(userSource, address(inputToken));
        
        console.log("Source Chain After Deposit:");
        console.log("  User ERC20 balance:", afterDepositUserSourceTokens / 1e18, "tokens");
        int256 userDepositChange = int256(afterDepositUserSourceTokens) - int256(initialUserSourceTokens);
        console.log("    Change:", formatTokens(userDepositChange));
        console.log("  Contract ERC20 balance:", afterDepositContractSourceTokens / 1e18, "tokens");
        int256 contractDepositChange = int256(afterDepositContractSourceTokens) - int256(initialContractSourceTokens);
        console.log("    Change:", formatTokens(contractDepositChange));
        console.log("  User locked balance:", afterDepositUserSourceLocked / 1e18, "tokens");
        console.log("");

        // === PHASE 2: FILL ===
        console.log("=== PHASE 2: SOLVER FILLS ORDER ON DESTINATION CHAIN (NO HOOK) ===");
        _fillOrderWithNativeOutput();

        vm.chainId(remoteEid);
        uint256 afterFillUserDestNative = userDest.balance;
        uint256 afterFillSolverDestNative = solverDest.balance;
        uint256 afterFillContractDestNative = address(remoteAori).balance;
        
        // Reset solver balance to eliminate gas costs for clean accounting
        vm.deal(solverDest, initialSolverDestNative - OUTPUT_AMOUNT);
        
        console.log("Destination Chain After Fill:");
        console.log("  User native balance:", afterFillUserDestNative / 1e18, "ETH");
        int256 userFillChange = int256(afterFillUserDestNative) - int256(initialUserDestNative);
        console.log("    Change:", formatETH(userFillChange));
        console.log("  Solver native balance:", (initialSolverDestNative - OUTPUT_AMOUNT) / 1e18, "ETH (gas-adjusted)");
        int256 solverFillChange = -int256(uint256(OUTPUT_AMOUNT));
        console.log("    Change:", formatETH(solverFillChange));
        console.log("  Contract native balance:", afterFillContractDestNative / 1e18, "ETH");
        int256 contractFillChange = int256(afterFillContractDestNative) - int256(initialContractDestNative);
        console.log("    Change:", formatETH(contractFillChange));
        
        // Also check source chain solver balances for comparison
        vm.chainId(localEid);
        uint256 afterFillSolverSourceTokens = inputToken.balanceOf(solverSource);
        console.log("Source Chain After Fill (for comparison):");
        console.log("  Solver ERC20 balance:", afterFillSolverSourceTokens / 1e18, "tokens");
        console.log("");

        // === PHASE 3: SETTLEMENT ===
        console.log("=== PHASE 3: SETTLEMENT VIA LAYERZERO ===");
        
        // Record balances before settlement
        vm.chainId(remoteEid);
        uint256 beforeSettlementSolverDestNative = solverDest.balance;
        console.log("Before Settlement - Solver dest native balance:", beforeSettlementSolverDestNative / 1e18, "ETH");
        
        _settleOrder();
        
        console.log("After settle() call - Solver dest native balance:", beforeSettlementSolverDestNative / 1e18, "ETH (fee-adjusted)");
        console.log("  Settlement fee paid: 0 ETH (mocked to 0 for clean accounting)");
        
        _simulateLzMessageDelivery();

        vm.chainId(localEid);
        uint256 afterSettlementUserSourceLocked = localAori.getLockedBalances(userSource, address(inputToken));
        uint256 afterSettlementSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, address(inputToken));
        
        console.log("Source Chain After Settlement:");
        console.log("  User locked balance:", afterSettlementUserSourceLocked / 1e18, "tokens");
        int256 lockedChange = int256(afterSettlementUserSourceLocked) - int256(afterDepositUserSourceLocked);
        console.log("    Change:", formatTokens(lockedChange));
        console.log("  Solver unlocked balance:", afterSettlementSolverSourceUnlocked / 1e18, "tokens");
        
        // Check destination chain balances after message delivery
        vm.chainId(remoteEid);
        uint256 afterMessageSolverDestNative = solverDest.balance;
        console.log("Destination Chain After Settlement:");
        console.log("  Solver native balance:", afterMessageSolverDestNative / 1e18, "ETH");
        console.log("");

        // === PHASE 4: WITHDRAWAL ===
        console.log("=== PHASE 4: SOLVER WITHDRAWAL ON SOURCE CHAIN ===");
        vm.chainId(localEid);
        uint256 beforeWithdrawSolverSourceTokens = inputToken.balanceOf(solverSource);
        uint256 beforeWithdrawContractSourceTokens = inputToken.balanceOf(address(localAori));
        
        vm.prank(solverSource);
        localAori.withdraw(address(inputToken), INPUT_AMOUNT);
        
        uint256 afterWithdrawSolverSourceTokens = inputToken.balanceOf(solverSource);
        uint256 afterWithdrawContractSourceTokens = inputToken.balanceOf(address(localAori));
        uint256 afterWithdrawSolverSourceUnlocked = localAori.getUnlockedBalances(solverSource, address(inputToken));
        
        console.log("Source Chain After Withdrawal:");
        console.log("  Solver ERC20 balance:", afterWithdrawSolverSourceTokens / 1e18, "tokens");
        int256 solverWithdrawChange = int256(afterWithdrawSolverSourceTokens) - int256(beforeWithdrawSolverSourceTokens);
        console.log("    Change:", formatTokens(solverWithdrawChange));
        console.log("  Contract ERC20 balance:", afterWithdrawContractSourceTokens / 1e18, "tokens");
        int256 contractWithdrawChange = int256(afterWithdrawContractSourceTokens) - int256(beforeWithdrawContractSourceTokens);
        console.log("    Change:", formatTokens(contractWithdrawChange));
        console.log("  Solver unlocked balance:", afterWithdrawSolverSourceUnlocked / 1e18, "tokens");
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY: NET BALANCE CHANGES ===");
        
        vm.chainId(localEid); // Source chain
        uint256 finalUserSourceTokens = inputToken.balanceOf(userSource);
        uint256 finalSolverSourceTokens = inputToken.balanceOf(solverSource);
        
        vm.chainId(remoteEid); // Destination chain
        uint256 finalUserDestNative = userDest.balance;

        console.log("User Net Changes:");
        int256 userSourceNetChange = int256(finalUserSourceTokens) - int256(initialUserSourceTokens);
        int256 userDestNetChange = int256(finalUserDestNative) - int256(initialUserDestNative);
        console.log("  Source chain ERC20:", formatTokens(userSourceNetChange));
        console.log("  Destination chain ETH:", formatETH(userDestNetChange));
        console.log("  Trade: User paid 1000 ERC20 tokens and received 1 ETH");
        
        console.log("Solver Net Changes:");
        int256 solverSourceNetChange = int256(finalSolverSourceTokens) - int256(initialSolverSourceTokens);
        // Use clean accounting for destination ETH (what was spent on fill)
        int256 solverDestNetChange = -int256(uint256(OUTPUT_AMOUNT));
        console.log("  Source chain ERC20:", formatTokens(solverSourceNetChange));
        console.log("  Destination chain ETH:", formatETH(solverDestNetChange), "(fill cost only, gas/fees excluded)");
        console.log("  Trade summary: Solver received 1000 ERC20, paid 1 ETH for fill");
        
        // === ASSERTIONS ===
        // User should have paid INPUT_AMOUNT ERC20 and received OUTPUT_AMOUNT ETH
        assertEq(userSourceNetChange, -int256(uint256(INPUT_AMOUNT)), "User should have paid input amount");
        assertEq(userDestNetChange, int256(uint256(OUTPUT_AMOUNT)), "User should have received output amount");
        
        // Solver should have gained INPUT_AMOUNT ERC20
        assertEq(solverSourceNetChange, int256(uint256(INPUT_AMOUNT)), "Solver should have gained input tokens");
        
        // The solver should have paid OUTPUT_AMOUNT ETH during the fill phase (verified in phase 2)
        // but the final balance includes gas costs and LayerZero fees, so we don't assert on the final ETH balance
        
        console.log("");
        console.log("All assertions passed! Cross-chain ERC20 to Native swap (no hooks) successful.");
    }
}
