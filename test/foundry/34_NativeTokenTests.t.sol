// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * @title Native Token Tests
 * @notice Comprehensive tests for depositNative function covering all branches and failure cases
 * @dev Tests all validation requirements from depositNative, validateDeposit, and validateCommonOrderParams
 *
 * @dev To run all tests:
 *   forge test --match-contract NativeTokenTests -v
 * @dev To run specific test categories:
 *   forge test --match-test testDepositNative -v
 */
import { Aori, IAori } from "../../contracts/Aori.sol";
import { TestUtils } from "./TestUtils.sol";
import { Order, OrderStatus, SrcHook, DstHook, Balance } from "../../contracts/types/AoriTypes.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenUtils, NATIVE_TOKEN } from "../../contracts/utils/TokenUtils.sol";
import "../../contracts/types/AoriErrors.sol";

contract NativeTokenTests is TestUtils {
    using TokenUtils for address;

    // Test addresses
    address public user;
    address public recipient;
    address public wrongSigner;

    // Private keys for signing
    uint256 public userPrivKey = 0xABCD;
    uint256 public wrongSignerPrivKey = 0xDEAD;

    // Test amounts
    uint128 public constant INPUT_AMOUNT = 1 ether;
    uint128 public constant OUTPUT_AMOUNT = 1 ether;

    function setUp() public override {
        super.setUp();

        // Derive addresses from private keys
        user = vm.addr(userPrivKey);
        wrongSigner = vm.addr(wrongSignerPrivKey);
        recipient = makeAddr("recipient");

        // Setup native token balances
        vm.deal(user, 5 ether);
        vm.deal(wrongSigner, 1 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    SUCCESS CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful native token deposit for cross-chain order
     */
    function testDepositNative_CrossChain_Success() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        uint256 initialBalance = user.balance;
        uint256 initialContractBalance = address(localAori).balance;
        uint256 initialLocked = localLens.getLockedBalances(user, NATIVE_TOKEN);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        assertEq(user.balance, initialBalance - INPUT_AMOUNT, "User balance should decrease");
        assertEq(address(localAori).balance, initialContractBalance + INPUT_AMOUNT, "Contract should receive ETH");
        assertEq(localLens.getLockedBalances(user, NATIVE_TOKEN), initialLocked + INPUT_AMOUNT, "Locked balance should increase");

        bytes32 orderId = localLens.hash(order);
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test successful native token deposit for single-chain order
     */
    function testDepositNative_SingleChain_Success() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, localEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        bytes32 orderId = localLens.hash(order);
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test successful native token deposit with native output token
     */
    function testDepositNative_NativeToNative_Success() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, NATIVE_TOKEN,
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              DEPOSITNATIVE SPECIFIC FAILURES               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when order doesn't specify native token as input
     */
    function testDepositNative_Revert_NonNativeInputToken() public {
        Order memory order = createCustomOrder(
            user, recipient, address(inputToken), address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(OrderMustSpecifyNativeToken.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when msg.value doesn't match order.inputAmount
     */
    function testDepositNative_Revert_IncorrectNativeAmount_TooLow() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(IncorrectNativeAmount.selector, INPUT_AMOUNT, INPUT_AMOUNT - 1));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT - 1 }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when msg.value doesn't match order.inputAmount (too high)
     */
    function testDepositNative_Revert_IncorrectNativeAmount_TooHigh() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(IncorrectNativeAmount.selector, INPUT_AMOUNT, INPUT_AMOUNT + 1));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT + 1 }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when caller is not the order offerer
     */
    function testDepositNative_Revert_NotOfferer() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(OnlyOffererCanDepositNativeTokens.selector);
        vm.prank(wrongSigner);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                VALIDATEDEPOSIT FAILURES                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when order already exists
     */
    function testDepositNative_Revert_OrderAlreadyExists() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        vm.deal(user, 2 ether);
        vm.expectRevert(OrderAlreadyExists.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);
    }

    /**
     * @notice Test failure when destination chain is not supported
     */
    function testDepositNative_Revert_DestinationChainNotSupported() public {
        uint32 unsupportedEid = 999;

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, unsupportedEid
        );

        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotSupported.selector, unsupportedEid));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when source chain doesn't match current chain
     */
    function testDepositNative_Revert_ChainMismatch() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            remoteEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(ChainMismatch.selector, localEid, remoteEid));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            VALIDATECOMMONORDERPARAMS FAILURES              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure with invalid offerer (zero address)
     */
    function testDepositNative_Revert_InvalidOfferer() public {
        Order memory order = createCustomOrder(
            address(0), recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(OnlyOffererCanDepositNativeTokens.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure with invalid recipient (zero address)
     */
    function testDepositNative_Revert_InvalidRecipient() public {
        Order memory order = createCustomOrder(
            user, address(0), NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(InvalidRecipient.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure with invalid end time (before start time)
     */
    function testDepositNative_Revert_InvalidEndTime() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);
        uint32 endTime = uint32(block.timestamp);

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, startTime, endTime,
            localEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(InvalidEndTime.selector, startTime, endTime));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when order hasn't started yet
     */
    function testDepositNative_Revert_OrderNotStarted() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, futureTime, futureTime + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(OrderNotStarted.selector, futureTime, block.timestamp));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure when order has expired
     */
    function testDepositNative_Revert_OrderExpired() public {
        vm.warp(10000);

        uint32 currentTime = uint32(block.timestamp);
        uint32 pastStartTime = currentTime - 7200;
        uint32 pastEndTime = currentTime - 3600;

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, pastStartTime, pastEndTime,
            localEid, remoteEid
        );

        vm.expectRevert(abi.encodeWithSelector(OrderExpired.selector, pastEndTime, currentTime));
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure with zero input amount
     */
    function testDepositNative_Revert_InvalidInputAmount() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            0, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(InvalidInputAmount.selector);
        vm.prank(user);
        localAori.depositNative{ value: 0 }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure with zero output amount
     */
    function testDepositNative_Revert_InvalidOutputAmount() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, 0, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(InvalidOutputAmount.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Test failure with invalid output token (zero address)
     */
    function testDepositNative_Revert_InvalidOutputToken() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(0),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(InvalidToken.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   MODIFIER FAILURES                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when contract is paused
     */
    function testDepositNative_Revert_WhenPaused() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        localAori.pause();

        vm.expectRevert();
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EDGE CASES                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test with maximum uint128 amounts
     */
    function testDepositNative_MaxAmounts() public {
        uint128 maxAmount = type(uint128).max;
        vm.deal(user, maxAmount);

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            maxAmount, maxAmount, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: maxAmount }(order, noHook, quoteSig);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test with minimum valid amounts (1 wei)
     */
    function testDepositNative_MinAmounts() public {
        uint128 minAmount = 1;

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            minAmount, minAmount, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: minAmount }(order, noHook, quoteSig);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test order that starts and ends at exact timestamps
     */
    function testDepositNative_ExactTimeBoundaries() public {
        uint32 currentTime = uint32(block.timestamp);

        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, currentTime, currentTime + 1,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        bytes32 orderId = keccak256(abi.encode(order));
        assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTEGRATION TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test multiple successful deposits from same user
     */
    function testDepositNative_MultipleDeposits() public {
        for (uint256 i = 0; i < 3; i++) {
            Order memory order = createCustomOrder(
                user, recipient, NATIVE_TOKEN, address(outputToken),
                INPUT_AMOUNT, OUTPUT_AMOUNT + uint128(i),
                block.timestamp, block.timestamp + 1 hours,
                localEid, remoteEid
            );

            SrcHook memory noHook = emptySrcHook();
            bytes memory quoteSig = signQuote(order, noHook);

            vm.prank(user);
            localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

            bytes32 orderId = keccak256(abi.encode(order));
            assertTrue(localAori.orderStatus(orderId) == OrderStatus.Active, "Order should be Active");
        }

        assertEq(localLens.getLockedBalances(user, NATIVE_TOKEN), INPUT_AMOUNT * 3, "Total locked should be 3x input amount");
    }

    /**
     * @notice Test event emission
     */
    function testDepositNative_EventEmission() public {
        Order memory order = createCustomOrder(
            user, recipient, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);
        bytes32 expectedOrderId = localLens.hash(order);

        vm.expectEmit(true, false, false, true);
        emit IAori.Deposit(expectedOrderId, order, address(0), 0);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);
    }
}
