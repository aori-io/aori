// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * @title Test: Native ETH as preferredToken in depositNative with hook
 * @notice Verifies that balance accounting is correct when a hook converts
 *         native ETH input into native ETH output (preferredToken = NATIVE_TOKEN).
 *         This exercises the executeHook balance delta normalization.
 */
import { Aori, IAori } from "../../contracts/Aori.sol";
import { TestUtils } from "./TestUtils.sol";
import { Order, OrderStatus, SrcHook, Options } from "../../contracts/types/AoriTypes.sol";
import { Test } from "forge-std/Test.sol";
import { MockHook2 } from "../Mock/MockHook2.sol";
import { TokenUtils, NATIVE_TOKEN } from "../../contracts/utils/TokenUtils.sol";
import "../../contracts/types/AoriErrors.sol";

contract NativePreferredToken_Test is TestUtils {
    uint128 public constant INPUT_AMOUNT = 1 ether;
    uint128 public constant HOOK_OUTPUT = 1.5 ether; // hook returns more ETH than input (simulates yield/swap)

    address public user;
    address public solverAddr;

    uint256 public userPrivKey = 0xABCD;
    uint256 public solverKey = 0xDEAD;

    Order private order;
    MockHook2 private mockHook2;

    function setUp() public override {
        super.setUp();

        user = vm.addr(userPrivKey);
        solverAddr = vm.addr(solverKey);

        mockHook2 = new MockHook2();

        vm.deal(user, 5 ether);
        vm.deal(solverAddr, 1 ether);
        vm.deal(address(localAori), 0);
        // Fund hook with extra ETH so it can return more than it receives
        vm.deal(address(mockHook2), 10 ether);

        localAori.addAllowedHook(address(mockHook2));
        localAori.addAllowedSolver(solverAddr);
    }

    /**
     * @notice Cross-chain deposit where hook converts ETH -> ETH (preferredToken = NATIVE)
     *         This tests the balance delta normalization in executeHook.
     *         Without the fix, amountReceived = balAfter - balBefore undercounts by inputAmount
     *         because balBefore includes msg.value which is then sent out with the hook call.
     */
    function testDepositNativeWithNativePreferredToken() public {
        vm.chainId(localEid);

        order = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: 1000e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid, // cross-chain so it takes the executeHook path
            options: Options({
                feeMbps: 0,
                slippageMbps: 0,
                feeRecipient: address(0),
                srcSolver: solverAddr,
                dstSolver: address(0)
            })
        });

        SrcHook memory srcHook = SrcHook({
            hookAddress: address(mockHook2),
            preferredToken: NATIVE_TOKEN, // native as preferred token
            minPreferredTokenAmountOut: HOOK_OUTPUT,
            instructions: abi.encodeWithSelector(
                MockHook2.handleHook.selector,
                NATIVE_TOKEN,
                HOOK_OUTPUT
            )
        });

        bytes32 orderId = keccak256(abi.encode(order));

        uint256 userBalBefore = user.balance;
        uint256 hookBalBefore = address(mockHook2).balance;

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, srcHook, signQuote(order, srcHook, solverKey));

        // User spent exactly INPUT_AMOUNT
        assertEq(user.balance, userBalBefore - INPUT_AMOUNT, "User should spend exactly inputAmount");

        // Order should be active (cross-chain, awaiting fill on dst)
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(OrderStatus.Active), "Order should be Active");

        // The locked balance should reflect the hook output (1.5 ETH), not 0 or some wrong value
        uint256 lockedBal = localLens.getLockedBalances(user, NATIVE_TOKEN);
        assertEq(lockedBal, HOOK_OUTPUT, "Locked balance should equal hook output amount");
    }
}
