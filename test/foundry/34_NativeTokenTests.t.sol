// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

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
import {Aori, IAori} from "../../contracts/Aori.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import "../../contracts/AoriUtils.sol";

contract NativeTokenTests is TestUtils {
    using NativeTokenUtils for address;

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
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid (cross-chain)
        );

        bytes memory signature = signOrder(order, userPrivKey);

        uint256 initialBalance = user.balance;
        uint256 initialContractBalance = address(localAori).balance;
        uint256 initialLocked = localAori.getLockedBalances(user, NATIVE_TOKEN);

        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Verify balances
        assertEq(user.balance, initialBalance - INPUT_AMOUNT, "User balance should decrease");
        assertEq(address(localAori).balance, initialContractBalance + INPUT_AMOUNT, "Contract should receive ETH");
        assertEq(localAori.getLockedBalances(user, NATIVE_TOKEN), initialLocked + INPUT_AMOUNT, "Locked balance should increase");
        
        // Verify order status
        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test successful native token deposit for single-chain order
     */
    function testDepositNative_SingleChain_Success() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken (ERC20)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            localEid                     // dstEid (same chain)
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Verify order status
        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test successful native token deposit with native output token
     */
    function testDepositNative_NativeToNative_Success() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            NATIVE_TOKEN,                // outputToken (native)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              DEPOSITNATIVE SPECIFIC FAILURES               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when order doesn't specify native token as input
     */
    function testDepositNative_Revert_NonNativeInputToken() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            address(inputToken),         // inputToken (ERC20, not native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Order must specify native token");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure when msg.value doesn't match order.inputAmount
     */
    function testDepositNative_Revert_IncorrectNativeAmount_TooLow() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Incorrect native amount");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT - 1}(order, signature); // Send less than required
    }

    /**
     * @notice Test failure when msg.value doesn't match order.inputAmount (too high)
     */
    function testDepositNative_Revert_IncorrectNativeAmount_TooHigh() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Incorrect native amount");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT + 1}(order, signature); // Send more than required
    }

    /**
     * @notice Test failure when caller is not the order offerer
     */
    function testDepositNative_Revert_NotOfferer() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Only offerer can deposit native tokens");
        vm.prank(wrongSigner); // Wrong caller
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                VALIDATEDEPOSIT FAILURES                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when order already exists
     */
    function testDepositNative_Revert_OrderAlreadyExists() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        // First deposit should succeed
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        // Second deposit should fail
        vm.deal(user, 2 ether); // Give user more ETH
        vm.expectRevert("Order already exists");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure when destination chain is not supported
     */
    function testDepositNative_Revert_DestinationChainNotSupported() public {
        uint32 unsupportedEid = 999;
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            unsupportedEid               // dstEid (unsupported)
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Destination chain not supported");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure with invalid signature
     */
    function testDepositNative_Revert_InvalidSignature() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory wrongSignature = signOrder(order, wrongSignerPrivKey); // Wrong signer

        vm.expectRevert("InvalidSignature");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, wrongSignature);
    }

    /**
     * @notice Test failure when source chain doesn't match current chain
     */
    function testDepositNative_Revert_ChainMismatch() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            remoteEid,                   // srcEid (wrong chain)
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Chain mismatch");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            VALIDATECOMMONORDERPARAMS FAILURES              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure with invalid offerer (zero address)
     */
    function testDepositNative_Revert_InvalidOfferer() public {
        IAori.Order memory order = createCustomOrder(
            address(0),                  // offerer (invalid)
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        // The "Only offerer can deposit native tokens" check happens before validateDeposit
        vm.expectRevert("Only offerer can deposit native tokens");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure with invalid recipient (zero address)
     */
    function testDepositNative_Revert_InvalidRecipient() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            address(0),                  // recipient (invalid)
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Invalid recipient");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure with invalid end time (before start time)
     */
    function testDepositNative_Revert_InvalidEndTime() public {
        uint32 startTime = uint32(block.timestamp + 1 hours);
        uint32 endTime = uint32(block.timestamp); // End before start
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            startTime,                   // startTime
            endTime,                     // endTime (invalid)
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Invalid end time");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure when order hasn't started yet
     */
    function testDepositNative_Revert_OrderNotStarted() public {
        uint32 futureTime = uint32(block.timestamp + 1 hours);
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            futureTime,                  // startTime (future)
            futureTime + 1 hours,        // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Order not started");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure when order has expired
     */
    function testDepositNative_Revert_OrderExpired() public {
        // Set a specific timestamp to avoid underflow issues
        vm.warp(10000); // Set block.timestamp to 10000
        
        uint32 currentTime = uint32(block.timestamp);
        uint32 pastStartTime = currentTime - 7200; // 2 hours ago
        uint32 pastEndTime = currentTime - 3600;   // 1 hour ago
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            pastStartTime,               // startTime (past)
            pastEndTime,                 // endTime (past)
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Order has expired");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure with zero input amount
     */
    function testDepositNative_Revert_InvalidInputAmount() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            0,                           // inputAmount (invalid)
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Invalid input amount");
        vm.prank(user);
        localAori.depositNative{value: 0}(order, signature);
    }

    /**
     * @notice Test failure with zero output amount
     */
    function testDepositNative_Revert_InvalidOutputAmount() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            0,                           // outputAmount (invalid)
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Invalid output amount");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /**
     * @notice Test failure with invalid output token (zero address)
     */
    function testDepositNative_Revert_InvalidOutputToken() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(0),                  // outputToken (invalid)
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.expectRevert("Invalid token");
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   MODIFIER FAILURES                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test failure when contract is paused
     */
    function testDepositNative_Revert_WhenPaused() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        // Pause the contract
        localAori.pause();

        vm.expectRevert(); // OpenZeppelin's Pausable uses custom errors
        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EDGE CASES                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test with maximum uint128 amounts
     */
    function testDepositNative_MaxAmounts() public {
        uint128 maxAmount = type(uint128).max;
        
        // Give user enough ETH (this will likely fail due to gas limits in practice)
        vm.deal(user, maxAmount);
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            maxAmount,                   // inputAmount (max)
            maxAmount,                   // outputAmount (max)
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.prank(user);
        localAori.depositNative{value: maxAmount}(order, signature);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test with minimum valid amounts (1 wei)
     */
    function testDepositNative_MinAmounts() public {
        uint128 minAmount = 1;
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            minAmount,                   // inputAmount (1 wei)
            minAmount,                   // outputAmount (1 wei)
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.prank(user);
        localAori.depositNative{value: minAmount}(order, signature);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /**
     * @notice Test order that starts and ends at exact timestamps
     */
    function testDepositNative_ExactTimeBoundaries() public {
        uint32 currentTime = uint32(block.timestamp);
        
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            currentTime,                 // startTime (exact current time)
            currentTime + 1,             // endTime (1 second later)
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);

        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

        bytes32 orderId = localAori.hash(order);
        assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTEGRATION TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test multiple successful deposits from same user
     */
    function testDepositNative_MultipleDeposits() public {
        for (uint256 i = 0; i < 3; i++) {
            IAori.Order memory order = createCustomOrder(
                user,                        // offerer
                recipient,                   // recipient
                NATIVE_TOKEN,                // inputToken (native)
                address(outputToken),        // outputToken
                INPUT_AMOUNT,                // inputAmount
                OUTPUT_AMOUNT + uint128(i),  // outputAmount (different to make unique orders)
                block.timestamp,             // startTime
                block.timestamp + 1 hours,   // endTime
                localEid,                    // srcEid
                remoteEid                    // dstEid
            );

            bytes memory signature = signOrder(order, userPrivKey);

            vm.prank(user);
            localAori.depositNative{value: INPUT_AMOUNT}(order, signature);

            bytes32 orderId = localAori.hash(order);
            assertTrue(localAori.orderStatus(orderId) == IAori.OrderStatus.Active, "Order should be Active");
        }

        // Verify total locked balance
        assertEq(localAori.getLockedBalances(user, NATIVE_TOKEN), INPUT_AMOUNT * 3, "Total locked should be 3x input amount");
    }

    /**
     * @notice Test event emission
     */
    function testDepositNative_EventEmission() public {
        IAori.Order memory order = createCustomOrder(
            user,                        // offerer
            recipient,                   // recipient
            NATIVE_TOKEN,                // inputToken (native)
            address(outputToken),        // outputToken
            INPUT_AMOUNT,                // inputAmount
            OUTPUT_AMOUNT,               // outputAmount
            block.timestamp,             // startTime
            block.timestamp + 1 hours,   // endTime
            localEid,                    // srcEid
            remoteEid                    // dstEid
        );

        bytes memory signature = signOrder(order, userPrivKey);
        bytes32 expectedOrderId = localAori.hash(order);

        vm.expectEmit(true, false, false, true);
        emit IAori.Deposit(expectedOrderId, order);

        vm.prank(user);
        localAori.depositNative{value: INPUT_AMOUNT}(order, signature);
    }
}
