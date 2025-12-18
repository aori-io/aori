// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./TestUtils.sol";
import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { Permit2Lib } from "../../contracts/libraries/Permit2Lib.sol";
import { DeployPermit2 } from "@permit2/test/utils/DeployPermit2.sol";

/**
 * @title Permit2DepositTest
 * @notice Tests for depositWithPermit2 functionality
 */
contract Permit2DepositTest is TestUtils, DeployPermit2 {
    ISignatureTransfer public permit2;

    // Full typehash for PermitWitnessTransferFrom with Order witness
    bytes32 constant FULL_PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)TokenPermissions(address token,uint256 amount)"
    );

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256(
        "TokenPermissions(address token,uint256 amount)"
    );

    function setUp() public override {
        super.setUp();

        // Deploy Permit2 at canonical address
        deployPermit2();
        permit2 = ISignatureTransfer(Permit2Lib.PERMIT2);

        // Approve Permit2 for test tokens (users approve Permit2, not Aori)
        vm.prank(userA);
        inputToken.approve(address(permit2), type(uint256).max);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HELPER FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Signs a Permit2 transfer with Order as witness
     */
    function signPermit2Order(
        IAori.Order memory order,
        uint256 privKey,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory signature) {
        // Hash order inline (same as Permit2Lib.hashOrder but for memory)
        bytes32 witness = keccak256(
            abi.encode(
                Permit2Lib.ORDER_TYPEHASH,
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.outputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid,
                order.offerer,
                order.recipient
            )
        );

        bytes32 tokenPermissionsHash = keccak256(
            abi.encode(
                TOKEN_PERMISSIONS_TYPEHASH,
                order.inputToken,
                order.inputAmount
            )
        );

        bytes32 msgHash = keccak256(
            abi.encodePacked(
                "\x19\x01",
                permit2.DOMAIN_SEPARATOR(),
                keccak256(
                    abi.encode(
                        FULL_PERMIT_WITNESS_TYPEHASH,
                        tokenPermissionsHash,
                        address(localAori), // spender
                        nonce,
                        deadline,
                        witness
                    )
                )
            )
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, msgHash);
        signature = abi.encodePacked(r, s, v);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      SUCCESS TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testDepositWithPermit2_Success() public {
        IAori.Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        uint256 userBalanceBefore = inputToken.balanceOf(userA);
        uint256 aoriBalanceBefore = inputToken.balanceOf(address(localAori));

        vm.prank(solver);
        localAori.depositWithPermit2(order, nonce, deadline, signature);

        // Check balances
        assertEq(inputToken.balanceOf(userA), userBalanceBefore - order.inputAmount);
        assertEq(inputToken.balanceOf(address(localAori)), aoriBalanceBefore + order.inputAmount);

        // Check order is stored
        bytes32 orderId = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active));

        // Check locked balance
        assertEq(localAori.getLockedBalances(userA, address(inputToken)), order.inputAmount);
    }

    function testDepositWithPermit2_DifferentNonces() public {
        // First deposit
        IAori.Order memory order1 = createValidOrder(1);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig1 = signPermit2Order(order1, userAPrivKey, 0, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order1, 0, deadline, sig1);

        // Second deposit with different nonce
        IAori.Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signPermit2Order(order2, userAPrivKey, 1, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order2, 1, deadline, sig2);

        // Both orders should be active
        assertEq(uint8(localAori.orderStatus(localAori.hash(order1))), uint8(IAori.OrderStatus.Active));
        assertEq(uint8(localAori.orderStatus(localAori.hash(order2))), uint8(IAori.OrderStatus.Active));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FAILURE TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testDepositWithPermit2_ExpiredDeadline() public {
        IAori.Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Already expired

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert("Permit2 signature expired");
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_ReusedNonce() public {
        IAori.Order memory order1 = createValidOrder(1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig1 = signPermit2Order(order1, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        localAori.depositWithPermit2(order1, nonce, deadline, sig1);

        // Try to use same nonce again with different order
        IAori.Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signPermit2Order(order2, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(); // Permit2 will revert on reused nonce
        localAori.depositWithPermit2(order2, nonce, deadline, sig2);
    }

    function testDepositWithPermit2_WrongSigner() public {
        IAori.Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign with different key (solver's key)
        uint256 wrongPrivKey = 0xDEAD;
        bytes memory signature = signPermit2Order(order, wrongPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(); // Permit2 will revert on invalid signature
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_ModifiedOrder() public {
        IAori.Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        // Sign the original order
        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        // Modify order after signing
        order.inputAmount = order.inputAmount + 1;

        vm.prank(solver);
        vm.expectRevert(); // Permit2 will revert - witness hash won't match
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_OnlySolver() public {
        IAori.Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        // Try to call from non-solver
        vm.prank(userA);
        vm.expectRevert("Invalid solver");
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_OrderAlreadyExists() public {
        IAori.Order memory order = createValidOrder();

        uint256 deadline = block.timestamp + 1 hours;

        // First deposit
        bytes memory sig1 = signPermit2Order(order, userAPrivKey, 0, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order, 0, deadline, sig1);

        // Try same order again (different nonce)
        bytes memory sig2 = signPermit2Order(order, userAPrivKey, 1, deadline);
        vm.prank(solver);
        vm.expectRevert("Order already exists");
        localAori.depositWithPermit2(order, 1, deadline, sig2);
    }

    function testDepositWithPermit2_NativeTokenNotAllowed() public {
        IAori.Order memory order = createValidOrder();
        order.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // Native token

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert("Use depositNative for native tokens");
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_UnsupportedDestinationChain() public {
        IAori.Order memory order = createValidOrder();
        order.dstEid = 999; // Unsupported chain

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert("Destination chain not supported");
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HOOK TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testDepositWithPermit2_WithHook() public {
        IAori.Order memory order = createValidOrder();
        IAori.SrcHook memory hook = defaultSrcSolverData(order.inputAmount);

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        uint256 userBalanceBefore = inputToken.balanceOf(userA);

        vm.prank(solver);
        localAori.depositWithPermit2(order, hook, nonce, deadline, signature);

        // Check user's input tokens were transferred
        assertEq(inputToken.balanceOf(userA), userBalanceBefore - order.inputAmount);

        // Check order is stored
        bytes32 orderId = localAori.hash(order);
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(IAori.OrderStatus.Active));

        // Check converted token is locked (hook converts input to convertedToken)
        assertGt(localAori.getLockedBalances(userA, address(convertedToken)), 0);
    }

    function testDepositWithPermit2_WithHook_UnallowedHook() public {
        IAori.Order memory order = createValidOrder();
        IAori.SrcHook memory hook = defaultSrcSolverData(order.inputAmount);
        hook.hookAddress = address(0x999); // Not whitelisted

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert("Invalid hook address");
        localAori.depositWithPermit2(order, hook, nonce, deadline, signature);
    }
}
