// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Cross-Chain Native + SrcHook → Direct Fill (No DstHook)
 * @notice Tests the complete flow:
 *   1. Source Chain: depositNative(order, srcHook) - User deposits native ETH with srcHook
 *   2. Source Chain: SrcHook converts ETH to preferred token (e.g., USDC)
 *   3. Destination Chain: fill(order) - Solver fills directly with ERC20 tokens (no hook)
 *   4. Settlement: LayerZero message unlocks preferred tokens for solver on source chain
 *   5. Solver withdraws preferred tokens on source chain
 * @dev Verifies balance accounting, token transfers, and cross-chain messaging
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testCrossChainNativeHookToDirectFillSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract CC_NativeHookToDirectFill_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;           // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1000e18;          // ERC20 output (user receives on dest)
    uint128 public constant HOOK_CONVERTED_AMOUNT = 1500e18;  // srcHook converts ETH to this many tokens
    uint128 public constant MIN_PREFERRED_OUT = 1400e18;      // Minimum acceptable from hook

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
            uint256 decimals = weiPart / 1e12;
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
        
        uint256 tokenPart = absAmount / 1e18;
        uint256 decimalPart = absAmount % 1e18;
        
        string memory sign = isNegative ? "-" : "+";
        
        if (decimalPart == 0) {
            return string(abi.encodePacked(sign, vm.toString(tokenPart), " tokens"));
        } else {
            uint256 decimals = decimalPart / 1e16;
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
        
        // Deploy MockHook2
        mockHook2 = new MockHook2();
        
        // Setup native token balances for source chain
        vm.deal(userSource, 5 ether);
        vm.deal(solverSource, 1 ether);
        
        // Setup destination chain balances
        vm.deal(userDest, 0 ether);
        vm.deal(solverDest, 1 ether);
        
        // Setup contract balances
        vm.deal(address(localAori), 0 ether);
        vm.deal(address(remoteAori), 0 ether);
        
        // Give hook the preferred token to output (what srcHook converts to)
        convertedToken.mint(address(mockHook2), 5000e18);
        
        // Give solver ERC20 output tokens to fill with on destination
        outputToken.mint(solverDest, 5000e18);
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        remoteAori.addAllowedHook(address(mockHook2));
        
        // Add solvers to allowed list
        localAori.addAllowedSolver(solverSource);
        remoteAori.addAllowedSolver(solverDest);
    }

    /**
     * @notice Helper to create order for native input -> ERC20 output
     */
    function _createOrder() internal {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSource,                      // offerer
            userDest,                        // recipient (different chain)
            NATIVE_TOKEN,                    // inputToken (native ETH)
            address(outputToken),            // outputToken (ERC20)
            INPUT_AMOUNT,                    // inputAmount
            OUTPUT_AMOUNT,                   // outputAmount
            block.timestamp,                 // startTime
            block.timestamp + 1 hours,       // endTime
            localEid,                        // srcEid
            remoteEid                        // dstEid (cross-chain)
        );
    }

    /**
     * @notice Helper to create srcHook that converts native ETH to preferred token
     */
    function _createSrcHook() internal view returns (IAori.SrcHook memory) {
        return IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: address(convertedToken),   // Hook outputs this ERC20
            minPreferedTokenAmountOut: MIN_PREFERRED_OUT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                address(convertedToken),       // Output converted token
                HOOK_CONVERTED_AMOUNT          // Amount of tokens to output
            ),
            solver: solverSource
        });
    }

    /**
     * @notice Helper to deposit native with srcHook
     */
    function _depositNativeWithSrcHook() internal {
        _createOrder();
        IAori.SrcHook memory srcHook = _createSrcHook();

        vm.prank(userSource);
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Helper to fill order directly (no hook)
     */
    function _fillOrderDirectly() internal {
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        // Approve output tokens
        vm.prank(solverDest);
        outputToken.approve(address(remoteAori), OUTPUT_AMOUNT);
        
        // Fill directly without hook
        vm.prank(solverDest);
        remoteAori.fill(order);
    }

    /**
     * @notice Helper to settle order via LayerZero
     */
    function _settleOrder() internal {
        bytes memory options = defaultOptions();
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solverDest);
        vm.deal(solverDest, fee);
        vm.prank(solverDest);
        remoteAori.settle{value: fee}(localEid, solverDest, options);
    }

    /**
     * @notice Helper to simulate LayerZero message delivery
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
     * @notice Test Phase 1: Deposit native with srcHook
     */
    function testPhase1_DepositNativeWithSrcHook() public {
        uint256 initialUserNative = userSource.balance;
        
        _depositNativeWithSrcHook();
        
        // Verify user spent native ETH
        assertEq(
            userSource.balance,
            initialUserNative - INPUT_AMOUNT,
            "User should spend native ETH"
        );
        
        // Verify converted tokens are locked
        assertEq(
            localAori.getLockedBalances(userSource, address(convertedToken)),
            HOOK_CONVERTED_AMOUNT,
            "Converted tokens should be locked for user"
        );
        
        // Verify order status
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active,
            "Order should be Active"
        );
    }

    /**
     * @notice Test Phase 2: Fill directly without hook
     */
    function testPhase2_FillWithoutHook() public {
        _depositNativeWithSrcHook();
        
        uint256 initialUserOutput = outputToken.balanceOf(userDest);
        uint256 initialSolverOutput = outputToken.balanceOf(solverDest);
        
        _fillOrderDirectly();
        
        // Verify user received output tokens
        assertEq(
            outputToken.balanceOf(userDest),
            initialUserOutput + OUTPUT_AMOUNT,
            "User should receive output tokens"
        );
        
        // Verify solver spent output tokens
        assertEq(
            outputToken.balanceOf(solverDest),
            initialSolverOutput - OUTPUT_AMOUNT,
            "Solver should spend output tokens"
        );
        
        // Verify order status
        assertTrue(
            remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled,
            "Order should be Filled"
        );
    }

    /**
     * @notice Test Phase 3: Settlement via LayerZero
     */
    function testPhase3_Settlement() public {
        _depositNativeWithSrcHook();
        _fillOrderDirectly();
        _settleOrder();
        _simulateLzMessageDelivery();
        
        // Verify order status on source chain
        vm.chainId(localEid);
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "Order should be Settled"
        );
        
        // Verify locked balance is cleared
        assertEq(
            localAori.getLockedBalances(userSource, address(convertedToken)),
            0,
            "User should have no locked balance after settlement"
        );
        
        // Verify solver has unlocked balance
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(convertedToken)),
            HOOK_CONVERTED_AMOUNT,
            "Solver should have unlocked converted tokens"
        );
    }

    /**
     * @notice Test Phase 4: Solver withdrawal
     */
    function testPhase4_SolverWithdrawal() public {
        _depositNativeWithSrcHook();
        _fillOrderDirectly();
        _settleOrder();
        _simulateLzMessageDelivery();
        
        // Switch to source chain for withdrawal
        vm.chainId(localEid);
        
        uint256 solverBalanceBefore = convertedToken.balanceOf(solverSource);
        
        // Solver withdraws earned tokens
        vm.prank(solverSource);
        localAori.withdraw(address(convertedToken), HOOK_CONVERTED_AMOUNT);
        
        // Verify withdrawal
        assertEq(
            convertedToken.balanceOf(solverSource),
            solverBalanceBefore + HOOK_CONVERTED_AMOUNT,
            "Solver should receive withdrawn tokens"
        );
        
        assertEq(
            localAori.getUnlockedBalances(solverSource, address(convertedToken)),
            0,
            "Solver should have no remaining unlocked balance"
        );
    }

    /**
     * @notice Full end-to-end test with detailed logging
     */
    function testCrossChainNativeHookToDirectFillSuccess() public {
        console.log("=== CROSS-CHAIN NATIVE + SRCHOOK TO DIRECT FILL TEST ===");
        console.log("Flow: User deposits 1 ETH + srcHook (converts to 1500 tokens) -> Solver fills 1000 tokens directly -> Settlement -> Solver withdraws");
        console.log("");

        // === PHASE 0: INITIAL STATE ===
        vm.chainId(localEid);
        uint256 initialUserNative = userSource.balance;
        uint256 initialSolverConvertedTokens = convertedToken.balanceOf(solverSource);
        uint256 initialContractConvertedTokens = convertedToken.balanceOf(address(localAori));
        
        vm.chainId(remoteEid);
        uint256 initialUserOutput = outputToken.balanceOf(userDest);
        uint256 initialSolverOutput = outputToken.balanceOf(solverDest);
        
        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("Source Chain:");
        console.log("  User native balance:", initialUserNative / 1e18, "ETH");
        console.log("  Solver converted token balance:", initialSolverConvertedTokens / 1e18, "tokens");
        console.log("Destination Chain:");
        console.log("  User output tokens:", initialUserOutput / 1e18, "tokens");
        console.log("  Solver output tokens:", initialSolverOutput / 1e18, "tokens");
        console.log("");

        // === PHASE 1: DEPOSIT WITH SRCHOOK ===
        console.log("=== PHASE 1: USER DEPOSITS NATIVE ETH WITH SRCHOOK ===");
        _depositNativeWithSrcHook();
        
        vm.chainId(localEid);
        uint256 afterDepositUserNative = userSource.balance;
        uint256 afterDepositLockedTokens = localAori.getLockedBalances(userSource, address(convertedToken));
        uint256 afterDepositContractTokens = convertedToken.balanceOf(address(localAori));
        
        console.log("After Deposit:");
        console.log("  User native balance:", afterDepositUserNative / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(afterDepositUserNative) - int256(initialUserNative)));
        console.log("  User locked (converted) tokens:", afterDepositLockedTokens / 1e18, "tokens");
        console.log("  Contract converted token balance:", afterDepositContractTokens / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(afterDepositContractTokens) - int256(initialContractConvertedTokens)));
        console.log("  Hook conversion: 1 ETH -> 1500 converted tokens");
        console.log("");
        
        // Verify deposit state
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Active, "Order should be Active");

        // === PHASE 2: FILL DIRECTLY (NO HOOK) ===
        console.log("=== PHASE 2: SOLVER FILLS DIRECTLY ON DESTINATION (NO HOOK) ===");
        _fillOrderDirectly();
        
        vm.chainId(remoteEid);
        uint256 afterFillUserOutput = outputToken.balanceOf(userDest);
        uint256 afterFillSolverOutput = outputToken.balanceOf(solverDest);
        
        console.log("After Fill:");
        console.log("  User output tokens:", afterFillUserOutput / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(afterFillUserOutput) - int256(initialUserOutput)));
        console.log("  Solver output tokens:", afterFillSolverOutput / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(afterFillSolverOutput) - int256(initialSolverOutput)));
        console.log("");
        
        // Verify fill state
        assertTrue(remoteAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Filled, "Order should be Filled");

        // === PHASE 3: SETTLEMENT ===
        console.log("=== PHASE 3: SETTLEMENT VIA LAYERZERO ===");
        _settleOrder();
        _simulateLzMessageDelivery();
        
        vm.chainId(localEid);
        uint256 afterSettleLockedTokens = localAori.getLockedBalances(userSource, address(convertedToken));
        uint256 afterSettleUnlockedTokens = localAori.getUnlockedBalances(solverSource, address(convertedToken));
        
        console.log("After Settlement:");
        console.log("  User locked tokens:", afterSettleLockedTokens / 1e18, "tokens (should be 0)");
        console.log("  Solver unlocked tokens:", afterSettleUnlockedTokens / 1e18, "tokens");
        console.log("");
        
        // Verify settlement state
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order should be Settled");

        // === PHASE 4: WITHDRAWAL ===
        console.log("=== PHASE 4: SOLVER WITHDRAWS EARNED TOKENS ===");
        
        uint256 beforeWithdrawSolverTokens = convertedToken.balanceOf(solverSource);
        vm.prank(solverSource);
        localAori.withdraw(address(convertedToken), HOOK_CONVERTED_AMOUNT);
        
        uint256 afterWithdrawSolverTokens = convertedToken.balanceOf(solverSource);
        uint256 afterWithdrawUnlockedTokens = localAori.getUnlockedBalances(solverSource, address(convertedToken));
        
        console.log("After Withdrawal:");
        console.log("  Solver converted token balance:", afterWithdrawSolverTokens / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(afterWithdrawSolverTokens) - int256(beforeWithdrawSolverTokens)));
        console.log("  Solver unlocked balance:", afterWithdrawUnlockedTokens / 1e18, "tokens (should be 0)");
        console.log("");

        // === FINAL SUMMARY ===
        console.log("=== FINAL SUMMARY ===");
        console.log("User:");
        console.log("  Spent:", INPUT_AMOUNT / 1e18, "ETH on source chain");
        console.log("  Received:", OUTPUT_AMOUNT / 1e18, "output tokens on destination chain");
        console.log("Solver:");
        console.log("  Spent:", OUTPUT_AMOUNT / 1e18, "output tokens on destination chain");
        console.log("  Received:", HOOK_CONVERTED_AMOUNT / 1e18, "converted tokens on source chain");
        console.log("  Profit:", (HOOK_CONVERTED_AMOUNT - OUTPUT_AMOUNT) / 1e18, "tokens (1500 - 1000 = 500)");
        console.log("");

        // Final assertions
        assertEq(userSource.balance, initialUserNative - INPUT_AMOUNT, "User spent 1 ETH");
        assertEq(outputToken.balanceOf(userDest), initialUserOutput + OUTPUT_AMOUNT, "User received 1000 output tokens");
        assertEq(convertedToken.balanceOf(solverSource), initialSolverConvertedTokens + HOOK_CONVERTED_AMOUNT, "Solver received 1500 converted tokens");
        assertEq(outputToken.balanceOf(solverDest), initialSolverOutput - OUTPUT_AMOUNT, "Solver spent 1000 output tokens");
        
        console.log("All assertions passed!");
    }

    /**
     * @notice Test revert when srcHook output is insufficient
     */
    function testRevertInsufficientSrcHookOutput() public {
        _createOrder();
        
        // Create hook that outputs less than minimum
        IAori.SrcHook memory badHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: MIN_PREFERRED_OUT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                address(convertedToken),
                MIN_PREFERRED_OUT - 1  // Less than minimum
            ),
            solver: solverSource
        });

        vm.prank(userSource);
        vm.expectRevert("Insufficient output from hook");
        localAori.depositNative{value: INPUT_AMOUNT}(order, badHook);
    }
}

