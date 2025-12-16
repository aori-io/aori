// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title End-to-End Test: Single-Chain Native Deposit with SrcHook (Atomic Settlement)
 * @notice Tests the new depositNative(order, srcHook) execution path for single-chain swaps
 * @dev Tests the complete flow:
 *   1. User deposits native ETH using depositNative(order, srcHook)
 *   2. SrcHook converts native ETH to output token (e.g., ERC20)
 *   3. User receives outputAmount of output token
 *   4. Solver (specified in hook.solver) receives any surplus from hook conversion
 *   5. Atomic settlement - everything happens in one transaction
 * @dev Verifies single-chain atomic settlement, direct token distribution, surplus to solver
 * 
 * @dev To run with detailed accounting logs:
 *   forge test --match-test testSingleChainNativeWithHookSuccess -vv
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {MockHook2} from "../Mock/MockHook2.sol";
import "../../contracts/AoriUtils.sol";

contract SC_NativeHookAtomicSwap_Test is TestUtils {
    using NativeTokenUtils for address;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;          // Native ETH input (user deposits)
    uint128 public constant OUTPUT_AMOUNT = 1000e18;         // ERC20 output (user receives)
    uint128 public constant HOOK_OUTPUT = 1100e18;           // Hook converts to this much ERC20
    uint128 public constant EXPECTED_SURPLUS = 100e18;       // Surplus returned to solver (1100 - 1000 = 100)

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
        userSC = vm.addr(userSCPrivKey);
        solverSC = vm.addr(solverSCPrivKey);
        
        // Deploy MockHook2
        mockHook2 = new MockHook2();
        
        // Setup native token balances
        vm.deal(userSC, 5 ether);         // User has 5 ETH
        vm.deal(solverSC, 1 ether);       // Solver has 1 ETH for gas
        
        // Setup contract balances (start clean)
        vm.deal(address(localAori), 0 ether);
        
        // Give hook the output tokens to distribute (what hook outputs)
        outputToken.mint(address(mockHook2), 5000e18); // 5000 output tokens for hook operations
        
        // Add MockHook2 to allowed hooks
        localAori.addAllowedHook(address(mockHook2));
        
        // Add solver to allowed list
        localAori.addAllowedSolver(solverSC);
    }

    /**
     * @notice Helper function to create order for native input -> ERC20 output
     */
    function _createOrder() internal {
        vm.chainId(localEid);
        
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
    }

    /**
     * @notice Helper function to create srcHook configuration
     */
    function _createSrcHook() internal view returns (IAori.SrcHook memory) {
        return IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: address(outputToken),     // Hook outputs ERC20 tokens
            minPreferedTokenAmountOut: OUTPUT_AMOUNT, // Minimum tokens expected
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                address(outputToken),  // Output ERC20 tokens
                HOOK_OUTPUT            // Amount of tokens to output
            ),
            solver: solverSC
        });
    }

    /**
     * @notice Helper function to execute depositNative with srcHook
     */
    function _executeDepositNativeWithHook() internal {
        _createOrder();
        IAori.SrcHook memory srcHook = _createSrcHook();

        // User executes depositNative with srcHook
        vm.prank(userSC);
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Test single-chain native deposit with srcHook (atomic settlement)
     */
    function testSingleChainNativeWithHookSuccess() public {
        uint256 initialUserNative = userSC.balance;
        uint256 initialUserTokens = outputToken.balanceOf(userSC);
        uint256 initialSolverTokens = outputToken.balanceOf(solverSC);

        _executeDepositNativeWithHook();

        // Verify user spent native ETH
        assertEq(
            userSC.balance,
            initialUserNative - INPUT_AMOUNT,
            "User should spend native ETH"
        );
        
        // Verify user received output tokens
        assertEq(
            outputToken.balanceOf(userSC),
            initialUserTokens + OUTPUT_AMOUNT,
            "User should receive output tokens"
        );
        
        // Verify solver received surplus
        assertEq(
            outputToken.balanceOf(solverSC),
            initialSolverTokens + EXPECTED_SURPLUS,
            "Solver should receive surplus tokens"
        );

        // Verify order status is Settled
        assertTrue(
            localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled,
            "Order should be Settled"
        );
    }

    /**
     * @notice Test that surplus correctly goes to hook.solver (not msg.sender)
     */
    function testSingleChainNativeHookSurplusToSolver() public {
        uint256 initialSolverTokens = outputToken.balanceOf(solverSC);
        uint256 initialUserTokens = outputToken.balanceOf(userSC);

        _executeDepositNativeWithHook();

        // User is msg.sender, but solver (from hook) should get surplus
        uint256 userTokenGain = outputToken.balanceOf(userSC) - initialUserTokens;
        uint256 solverTokenGain = outputToken.balanceOf(solverSC) - initialSolverTokens;

        assertEq(userTokenGain, OUTPUT_AMOUNT, "User should receive exactly outputAmount");
        assertEq(solverTokenGain, EXPECTED_SURPLUS, "Solver should receive exactly the surplus");
    }

    /**
     * @notice Test revert when hook doesn't provide enough output
     */
    function testSingleChainNativeHookInsufficientOutput() public {
        vm.chainId(localEid);
        
        order = createCustomOrder(
            userSC,
            userSC,
            NATIVE_TOKEN,
            address(outputToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        // Setup srcHook with insufficient output
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                address(outputToken),
                OUTPUT_AMOUNT - 1  // Less than required
            ),
            solver: solverSC
        });

        vm.prank(userSC);
        vm.expectRevert("Insufficient output from hook");
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Test order status becomes Settled for single-chain
     */
    function testSingleChainNativeHookOrderStatus() public {
        _executeDepositNativeWithHook();
        
        bytes32 orderId = localAori.hash(order);
        assertTrue(
            localAori.orderStatus(orderId) == IAori.OrderStatus.Settled,
            "Single-chain swap should be immediately Settled"
        );
    }

    /**
     * @notice Test no locked balances after atomic settlement
     */
    function testSingleChainNativeHookNoLockedBalances() public {
        _executeDepositNativeWithHook();
        
        // No locked balances should remain for atomic settlement
        assertEq(
            localAori.getLockedBalances(userSC, NATIVE_TOKEN),
            0,
            "User should have no locked native balance"
        );
        assertEq(
            localAori.getLockedBalances(userSC, address(outputToken)),
            0,
            "User should have no locked output token balance"
        );
        assertEq(
            localAori.getUnlockedBalances(solverSC, address(outputToken)),
            0,
            "Solver should have no unlocked balance in contract"
        );
    }

    /**
     * @notice Test hook mechanics - verify hook receives native and sends tokens
     */
    function testSingleChainNativeHookMechanics() public {
        uint256 hookInitialNative = address(mockHook2).balance;
        uint256 hookInitialTokens = outputToken.balanceOf(address(mockHook2));

        _executeDepositNativeWithHook();

        // Verify hook received native ETH and sent output tokens
        assertEq(
            address(mockHook2).balance,
            hookInitialNative + INPUT_AMOUNT,
            "Hook should receive native ETH"
        );
        assertEq(
            outputToken.balanceOf(address(mockHook2)),
            hookInitialTokens - HOOK_OUTPUT,
            "Hook should send output tokens"
        );
    }

    /**
     * @notice Test revert when msg.sender is not the offerer
     */
    function testRevertNonOffererCannotDeposit() public {
        _createOrder();
        IAori.SrcHook memory srcHook = _createSrcHook();

        // Try to deposit as solver instead of user
        vm.deal(solverSC, 5 ether);
        vm.prank(solverSC);
        vm.expectRevert("Only offerer can deposit native tokens");
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Test revert when msg.value doesn't match inputAmount
     */
    function testRevertIncorrectNativeAmount() public {
        _createOrder();
        IAori.SrcHook memory srcHook = _createSrcHook();

        vm.prank(userSC);
        vm.expectRevert("Incorrect native amount");
        localAori.depositNative{value: INPUT_AMOUNT - 1}(order, srcHook);
    }

    /**
     * @notice Test revert when order inputToken is not native
     */
    function testRevertNonNativeInputToken() public {
        vm.chainId(localEid);
        
        // Create order with ERC20 input (not native)
        order = createCustomOrder(
            userSC,
            userSC,
            address(inputToken),         // ERC20, not native
            address(outputToken),
            INPUT_AMOUNT,
            OUTPUT_AMOUNT,
            block.timestamp,
            block.timestamp + 1 hours,
            localEid,
            localEid
        );

        IAori.SrcHook memory srcHook = _createSrcHook();

        vm.prank(userSC);
        vm.expectRevert("Order must specify native token");
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Test revert with non-whitelisted solver in hook
     */
    function testRevertNonWhitelistedSolver() public {
        vm.chainId(localEid);
        
        _createOrder();
        
        address nonWhitelistedSolver = makeAddr("nonWhitelistedSolver");
        
        IAori.SrcHook memory srcHook = IAori.SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: address(outputToken),
            minPreferedTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                address(outputToken),
                HOOK_OUTPUT
            ),
            solver: nonWhitelistedSolver  // Not whitelisted
        });

        vm.prank(userSC);
        vm.expectRevert("Invalid solver in hook");
        localAori.depositNative{value: INPUT_AMOUNT}(order, srcHook);
    }

    /**
     * @notice Full end-to-end test with detailed balance logging
     */
    function testSingleChainNativeWithHookFullFlow() public {
        console.log("=== SINGLE-CHAIN NATIVE WITH SRCHOOK TEST ===");
        console.log("Flow: User deposits 1 ETH -> SrcHook converts to 1100 tokens -> User gets 1000 tokens, solver gets 100 tokens -> Atomic settlement");
        console.log("");

        // Store initial balances
        uint256 initialUserNative = userSC.balance;
        uint256 initialUserTokens = outputToken.balanceOf(userSC);
        uint256 initialSolverTokens = outputToken.balanceOf(solverSC);
        uint256 initialHookNative = address(mockHook2).balance;
        uint256 initialHookTokens = outputToken.balanceOf(address(mockHook2));

        console.log("=== PHASE 0: INITIAL STATE ===");
        console.log("User:");
        console.log("  Native balance:", initialUserNative / 1e18, "ETH");
        console.log("  Output tokens:", initialUserTokens / 1e18, "tokens");
        console.log("Solver:");
        console.log("  Output tokens:", initialSolverTokens / 1e18, "tokens");
        console.log("Hook:");
        console.log("  Native balance:", initialHookNative / 1e18, "ETH");
        console.log("  Output tokens:", initialHookTokens / 1e18, "tokens");
        console.log("");

        // Execute deposit
        console.log("=== PHASE 1: USER EXECUTES DEPOSITNATIVE WITH SRCHOOK ===");
        _executeDepositNativeWithHook();

        console.log("After Deposit & Atomic Settlement:");
        console.log("User:");
        console.log("  Native balance:", userSC.balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(userSC.balance) - int256(initialUserNative)));
        console.log("  Output tokens:", outputToken.balanceOf(userSC) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(userSC)) - int256(initialUserTokens)));
        
        console.log("Solver:");
        console.log("  Output tokens:", outputToken.balanceOf(solverSC) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(solverSC)) - int256(initialSolverTokens)));
        
        console.log("Hook:");
        console.log("  Native balance:", address(mockHook2).balance / 1e18, "ETH");
        console.log("    Change:", formatETH(int256(address(mockHook2).balance) - int256(initialHookNative)));
        console.log("  Output tokens:", outputToken.balanceOf(address(mockHook2)) / 1e18, "tokens");
        console.log("    Change:", formatTokens(int256(outputToken.balanceOf(address(mockHook2))) - int256(initialHookTokens)));
        console.log("");

        // Final assertions
        console.log("=== FINAL ASSERTIONS ===");
        
        assertEq(userSC.balance, initialUserNative - INPUT_AMOUNT, "User spent 1 ETH");
        assertEq(outputToken.balanceOf(userSC), initialUserTokens + OUTPUT_AMOUNT, "User received 1000 tokens");
        assertEq(outputToken.balanceOf(solverSC), initialSolverTokens + EXPECTED_SURPLUS, "Solver received 100 token surplus");
        assertEq(address(mockHook2).balance, initialHookNative + INPUT_AMOUNT, "Hook received 1 ETH");
        assertEq(outputToken.balanceOf(address(mockHook2)), initialHookTokens - HOOK_OUTPUT, "Hook sent 1100 tokens");
        
        assertTrue(localAori.orderStatus(localAori.hash(order)) == IAori.OrderStatus.Settled, "Order is Settled");
        
        console.log("All assertions passed!");
    }
}

