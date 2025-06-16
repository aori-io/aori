// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAori} from "../../contracts/Aori.sol";
import "./TestUtils.sol";

/**
 * @title DepositTests
 * @notice Comprehensive tests for deposit functionality with full branch coverage
 * @dev Tests both deposit() and deposit(order, signature, hook) functions
 * covering all validation branches and execution paths
 */
contract DepositTests is TestUtils {
    
    // Test addresses
    address public recipient;
    address public testHook;
    address public nonSolver;

    function setUp() public override {
        super.setUp();
        recipient = address(0x300);
        testHook = address(0x400);
        nonSolver = address(0x500);
        
        // Add test hook to whitelist
        localAori.addAllowedHook(testHook);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DEPOSIT WITHOUT HOOK                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful cross-chain deposit
     */
    function testDeposit_CrossChain_Success() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);

        uint256 initialLocked = localAori.getLockedBalances(userA, address(inputToken));
        uint256 initialBalance = inputToken.balanceOf(userA);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify state changes
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), initialLocked + order.inputAmount);
        assertEq(inputToken.balanceOf(userA), initialBalance - order.inputAmount);
        
        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Active));
    }

    /**
     * @notice Test successful single-chain deposit
     */
    function testDeposit_SingleChain_Success() public {
        IAori.Order memory order = createValidTestOrder();
        order.dstEid = localEid; // Make it single-chain
        bytes memory signature = signOrder(order);
        
        uint256 initialLocked = localAori.getLockedBalances(userA, address(inputToken));
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Verify locked balance increased
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), initialLocked + order.inputAmount);
        
        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Active));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 VALIDATION ERROR BRANCHES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit fails when order already exists
     */
    function testDeposit_OrderAlreadyExists() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount * 2);
        
        // First deposit succeeds
        vm.prank(solver);
        localAori.deposit(order, signature);
        
        // Second deposit with same order fails
        vm.prank(solver);
        vm.expectRevert("Order already exists");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails when destination chain not supported
     */
    function testDeposit_DestinationChainNotSupported() public {
        IAori.Order memory order = createValidTestOrder();
        order.dstEid = 99999; // Unsupported chain
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert("Destination chain not supported");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with invalid signature
     */
    function testDeposit_InvalidSignature() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        // Modify order after signing to make signature invalid
        order.inputAmount = order.inputAmount + 1;
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert("InvalidSignature");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with wrong signer
     */
    function testDeposit_WrongSigner() public {
        IAori.Order memory order = createValidTestOrder();
        
        // Sign with wrong private key (different from userA's key)
        uint256 wrongPrivateKey = 0xDEAD;
        bytes memory signature = signOrder(order, wrongPrivateKey);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert("InvalidSignature");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with invalid offerer (zero address)
     * @dev Signature validation happens before offerer validation, so we expect InvalidSignature
     */
    function testDeposit_InvalidOfferer() public {
        IAori.Order memory order = createValidTestOrder();
        order.offerer = address(0);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("InvalidSignature");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with invalid recipient (zero address)
     */
    function testDeposit_InvalidRecipient() public {
        IAori.Order memory order = createValidTestOrder();
        order.recipient = address(0);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid recipient");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with invalid end time (before start time)
     */
    function testDeposit_InvalidEndTime() public {
        IAori.Order memory order = createValidTestOrder();
        order.endTime = order.startTime - 1;
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid end time");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails when order not started yet
     */
    function testDeposit_OrderNotStarted() public {
        IAori.Order memory order = createValidTestOrder();
        order.startTime = uint32(block.timestamp + 1 hours);
        order.endTime = uint32(block.timestamp + 2 hours);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Order not started");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails when order has expired
     */
    function testDeposit_OrderExpired() public {
        IAori.Order memory order = createValidTestOrder();
        // Use warp to move time forward, then set expired times
        vm.warp(block.timestamp + 3 hours);
        order.startTime = uint32(block.timestamp - 2 hours);
        order.endTime = uint32(block.timestamp - 1 hours);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Order has expired");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with zero input amount
     */
    function testDeposit_InvalidInputAmount() public {
        IAori.Order memory order = createValidTestOrder();
        order.inputAmount = 0;
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid input amount");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with zero output amount
     */
    function testDeposit_InvalidOutputAmount() public {
        IAori.Order memory order = createValidTestOrder();
        order.outputAmount = 0;
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid output amount");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with zero input token address
     */
    function testDeposit_InvalidInputToken() public {
        IAori.Order memory order = createValidTestOrder();
        order.inputToken = address(0);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid token");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with zero output token address
     */
    function testDeposit_InvalidOutputToken() public {
        IAori.Order memory order = createValidTestOrder();
        order.outputToken = address(0);
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Invalid token");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails with chain mismatch
     */
    function testDeposit_ChainMismatch() public {
        IAori.Order memory order = createValidTestOrder();
        order.srcEid = remoteEid; // Wrong source chain
        bytes memory signature = signOrder(order);
        
        vm.prank(solver);
        vm.expectRevert("Chain mismatch");
        localAori.deposit(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   ACCESS CONTROL BRANCHES                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit fails when called by non-solver
     */
    function testDeposit_OnlySolver() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(nonSolver);
        vm.expectRevert("Invalid solver");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails when contract is paused
     */
    function testDeposit_WhenPaused() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        // Pause the contract
        localAori.pause();
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert();
        localAori.deposit(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DEPOSIT WITH HOOK                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit with hook fails when hook is missing
     */
    function testDepositWithHook_MissingHook() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: address(0), // Missing hook
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1e18,
            instructions: ""
        });
        
        vm.prank(solver);
        vm.expectRevert("Missing hook");
        localAori.deposit(order, signature, hook);
    }

    /**
     * @notice Test deposit with hook fails when hook not whitelisted
     */
    function testDepositWithHook_InvalidHookAddress() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        address nonWhitelistedHook = address(0x999);
        
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: nonWhitelistedHook,
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1e18,
            instructions: ""
        });
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert("Invalid hook address");
        localAori.deposit(order, signature, hook);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    TOKEN TRANSFER BRANCHES                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit fails when user has insufficient token balance
     */
    function testDeposit_InsufficientBalance() public {
        IAori.Order memory order = createValidTestOrder();
        order.inputAmount = uint128(inputToken.balanceOf(userA) + 1); // More than balance
        bytes memory signature = signOrder(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectRevert("Insufficient balance");
        localAori.deposit(order, signature);
    }

    /**
     * @notice Test deposit fails when user has insufficient allowance
     */
    function testDeposit_InsufficientAllowance() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        
        // Don't approve tokens
        
        vm.prank(solver);
        vm.expectRevert("Allowance exceeded");
        localAori.deposit(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      EVENT TESTING                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit emits correct events
     */
    function testDeposit_EmitsEvents() public {
        IAori.Order memory order = createValidTestOrder();
        bytes memory signature = signOrder(order);
        bytes32 orderId = localAori.hash(order);
        
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        vm.prank(solver);
        vm.expectEmit(true, false, false, true);
        emit Deposit(orderId, order);
        localAori.deposit(order, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                       EDGE CASES                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test deposit at exact start time boundary
     */
    function testDeposit_ExactStartTime() public {
        IAori.Order memory order = createValidTestOrder();
        order.startTime = uint32(block.timestamp);
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Active));
    }

    /**
     * @notice Test deposit just before expiry
     */
    function testDeposit_JustBeforeExpiry() public {
        IAori.Order memory order = createValidTestOrder();
        order.endTime = uint32(block.timestamp + 1);
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Active));
    }

    /**
     * @notice Test deposit with maximum uint128 amounts
     */
    function testDeposit_MaxAmounts() public {
        IAori.Order memory order = createValidTestOrder();
        order.inputAmount = type(uint128).max;
        order.outputAmount = type(uint128).max;
        
        // Mint enough tokens for the test
        inputToken.mint(userA, type(uint128).max);
        
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        bytes32 orderHash = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Active));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        HELPER FUNCTIONS                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Creates a valid order for testing (renamed to avoid conflict)
     */
    function createValidTestOrder() internal view returns (IAori.Order memory) {
        return IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                           EVENTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    event Deposit(bytes32 indexed orderId, IAori.Order order);
    event SrcHookExecuted(bytes32 indexed orderId, address indexed preferredToken, uint256 amountReceived);
    event Settle(bytes32 indexed orderId);
} 