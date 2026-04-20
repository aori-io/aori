// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import { Order, OrderStatus, SrcHook, DstHook, Balance, Options } from "../../contracts/types/AoriTypes.sol";
import "./TestUtils.sol";
import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { Permit2Lib } from "../../contracts/utils/Permit2Lib.sol";
import { DeployPermit2 } from "@permit2/test/utils/DeployPermit2.sol";
import "../../contracts/types/AoriErrors.sol";

/**
 * @title Permit2DepositTest
 * @notice Tests for depositWithPermit2 functionality
 */
contract Permit2DepositTest is TestUtils, DeployPermit2 {
    ISignatureTransfer public permit2;

    // Full typehash for PermitWitnessTransferFrom with Order witness (includes nested Options)
    bytes32 constant FULL_PERMIT_WITNESS_TYPEHASH = keccak256(
        "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)"
        "Options(uint16 feeMbps,uint16 slippageMbps,address feeRecipient,address srcSolver,address dstSolver)"
        "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,"
        "uint32 startTime,uint32 endTime,uint32 srcEid,address outputToken,uint32 dstEid,address offerer,address recipient," "Options options)"
        "TokenPermissions(address token,uint256 amount)"
    );

    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH = keccak256("TokenPermissions(address token,uint256 amount)");

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
        Order memory order,
        uint256 privKey,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory signature) {
        // Hash options first
        bytes32 optionsHash = keccak256(
            abi.encode(
                Permit2Lib.OPTIONS_TYPEHASH,
                order.options.feeMbps,
                order.options.slippageMbps,
                order.options.feeRecipient,
                order.options.srcSolver,
                order.options.dstSolver
            )
        );

        // Hash order inline (same as Permit2Lib.hashOrder but for memory)
        bytes32 witness = keccak256(
            abi.encode(
                Permit2Lib.ORDER_TYPEHASH,
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.outputToken,
                order.dstEid,
                order.offerer,
                order.recipient,
                optionsHash
            )
        );

        bytes32 tokenPermissionsHash = keccak256(abi.encode(TOKEN_PERMISSIONS_TYPEHASH, order.inputToken, order.inputAmount));

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
        Order memory order = createValidOrder();

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
        bytes32 orderId = keccak256(abi.encode(order));
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(OrderStatus.Active));

        // Check locked balance
        assertEq(localLens.getLockedBalances(userA, address(inputToken)), order.inputAmount);
    }

    function testDepositWithPermit2_DifferentNonces() public {
        // First deposit
        Order memory order1 = createValidOrder(1);
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig1 = signPermit2Order(order1, userAPrivKey, 0, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order1, 0, deadline, sig1);

        // Second deposit with different nonce
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signPermit2Order(order2, userAPrivKey, 1, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order2, 1, deadline, sig2);

        // Both orders should be active
        assertEq(uint8(localAori.orderStatus(keccak256(abi.encode(order1)))), uint8(OrderStatus.Active));
        assertEq(uint8(localAori.orderStatus(keccak256(abi.encode(order2)))), uint8(OrderStatus.Active));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      FAILURE TESTS                          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testDepositWithPermit2_ExpiredDeadline() public {
        Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp - 1; // Already expired

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(Permit2SignatureExpired.selector);
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_ReusedNonce() public {
        Order memory order1 = createValidOrder(1);
        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory sig1 = signPermit2Order(order1, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        localAori.depositWithPermit2(order1, nonce, deadline, sig1);

        // Try to use same nonce again with different order
        Order memory order2 = createValidOrder(2);
        bytes memory sig2 = signPermit2Order(order2, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(); // Permit2 will revert on reused nonce
        localAori.depositWithPermit2(order2, nonce, deadline, sig2);
    }

    function testDepositWithPermit2_WrongSigner() public {
        Order memory order = createValidOrder();

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
        Order memory order = createValidOrder();

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
        Order memory order = createValidOrder();

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        // Try to call from non-solver
        vm.prank(userA);
        vm.expectRevert(InvalidSolver.selector);
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_OrderAlreadyExists() public {
        Order memory order = createValidOrder();

        uint256 deadline = block.timestamp + 1 hours;

        // First deposit
        bytes memory sig1 = signPermit2Order(order, userAPrivKey, 0, deadline);
        vm.prank(solver);
        localAori.depositWithPermit2(order, 0, deadline, sig1);

        // Try same order again (different nonce)
        bytes memory sig2 = signPermit2Order(order, userAPrivKey, 1, deadline);
        vm.prank(solver);
        vm.expectRevert(OrderAlreadyExists.selector);
        localAori.depositWithPermit2(order, 1, deadline, sig2);
    }

    function testDepositWithPermit2_NativeTokenNotAllowed() public {
        Order memory order = createValidOrder();
        order.inputToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE; // Native token

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(UseDepositNativeForNativeTokens.selector);
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    function testDepositWithPermit2_UnsupportedDestinationChain() public {
        Order memory order = createValidOrder();
        uint32 unsupportedDstEid = 999;
        order.dstEid = unsupportedDstEid; // Unsupported chain

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(abi.encodeWithSelector(DestinationChainNotSupported.selector, unsupportedDstEid));
        localAori.depositWithPermit2(order, nonce, deadline, signature);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      HOOK TESTS                             */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testDepositWithPermit2_WithHook() public {
        Order memory order = createValidOrder();
        SrcHook memory hook = defaultSrcSolverData(order.inputAmount);

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        uint256 userBalanceBefore = inputToken.balanceOf(userA);

        vm.prank(solver);
        localAori.depositWithPermit2(order, hook, nonce, deadline, signature);

        // Check user's input tokens were transferred
        assertEq(inputToken.balanceOf(userA), userBalanceBefore - order.inputAmount);

        // Check order is stored
        bytes32 orderId = keccak256(abi.encode(order));
        assertEq(uint8(localAori.orderStatus(orderId)), uint8(OrderStatus.Active));

        // Check converted token is locked (hook converts input to convertedToken)
        assertGt(localLens.getLockedBalances(userA, address(convertedToken)), 0);
    }

    function testDepositWithPermit2_WithHook_UnallowedHook() public {
        Order memory order = createValidOrder();
        SrcHook memory hook = defaultSrcSolverData(order.inputAmount);
        hook.hookAddress = address(0x999); // Not whitelisted

        uint256 nonce = 0;
        uint256 deadline = block.timestamp + 1 hours;

        bytes memory signature = signPermit2Order(order, userAPrivKey, nonce, deadline);

        vm.prank(solver);
        vm.expectRevert(InvalidHookAddress.selector);
        localAori.depositWithPermit2(order, hook, nonce, deadline, signature);
    }
}
