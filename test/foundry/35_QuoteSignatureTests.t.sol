// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * @title Quote Signature Tests
 * @notice Tests for the solver quote signature validation in depositNative
 * @dev Validates the EIP-712 signature flow that prevents parameter manipulation
 *
 * @dev To run all tests:
 *   forge test --match-contract QuoteSignatureTests -v
 */
import { Aori, IAori } from "../../contracts/Aori.sol";
import { TestUtils } from "./TestUtils.sol";
import { Order, OrderStatus, SrcHook, DstHook, Balance, Options } from "../../contracts/types/AoriTypes.sol";
import { Test } from "forge-std/Test.sol";
import { console } from "forge-std/console.sol";
import { TokenUtils, NATIVE_TOKEN } from "../../contracts/utils/TokenUtils.sol";
import { MockHook } from "../Mock/MockHook.sol";
import "../../contracts/types/AoriErrors.sol";

contract QuoteSignatureTests is TestUtils {
    using TokenUtils for address;

    address public user;
    uint256 public userPrivKey = 0xABCD;

    uint128 public constant INPUT_AMOUNT = 1 ether;
    uint128 public constant OUTPUT_AMOUNT = 2000e18;

    function setUp() public override {
        super.setUp();
        user = vm.addr(userPrivKey);
        vm.deal(user, 10 ether);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               VALID SIGNATURE SUCCESS CASES                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Valid quote from whitelisted solver with options.solver = address(0)
     */
    function testQuoteSig_AnyWhitelistedSolver_Success() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        assertTrue(localAori.orderStatus(localLens.hash(order)) == OrderStatus.Active);
    }

    /**
     * @notice Valid quote from specified solver matching options.solver
     */
    function testQuoteSig_SpecifiedSolver_Success() public {
        Order memory order = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: OUTPUT_AMOUNT,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({
                feeMbps: 0,
                feeRecipient: address(0),
                srcSolver: solver, // Specific solver
                dstSolver: address(0),
                slippageMbps: 0
            })
        });

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook, solverPrivKey);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);

        assertTrue(localAori.orderStatus(localLens.hash(order)) == OrderStatus.Active);
    }

    /**
     * @notice Valid quote with non-empty srcHook
     */
    function testQuoteSig_WithSrcHook_Success() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory srcHook = defaultSrcSolverData(INPUT_AMOUNT);
        bytes memory quoteSig = signQuote(order, srcHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, srcHook, quoteSig);

        assertTrue(localAori.orderStatus(localLens.hash(order)) == OrderStatus.Active);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              INVALID SIGNATURE FAILURE CASES               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Revert when signature is from a non-whitelisted address
     */
    function testQuoteSig_Revert_NonWhitelistedSigner() public {
        uint256 randomPrivKey = 0xBAD;
        // Do NOT whitelist vm.addr(randomPrivKey)

        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook, randomPrivKey);

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);
    }

    /**
     * @notice Revert when specified solver doesn't match signer
     */
    function testQuoteSig_Revert_SolverMismatch() public {
        // Create a second whitelisted solver
        uint256 otherSolverKey = 0xBAD2;
        address otherSolver = vm.addr(otherSolverKey);
        localAori.addAllowedSolver(otherSolver);

        Order memory order = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: OUTPUT_AMOUNT,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({
                feeMbps: 0,
                feeRecipient: address(0),
                srcSolver: solver, // Expects solver to sign
                dstSolver: address(0),
                slippageMbps: 0
            })
        });

        // Sign with otherSolver (whitelisted but not the specified solver)
        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(order, noHook, otherSolverKey);

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, noHook, quoteSig);
    }

    /**
     * @notice Revert when user tampers with order after solver signs
     */
    function testQuoteSig_Revert_TamperedFeeMbps() public {
        Order memory originalOrder = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: OUTPUT_AMOUNT,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({
                feeMbps: 100, // 0.1% fee
                feeRecipient: address(0),
                srcSolver: address(0),
                dstSolver: address(0),
                slippageMbps: 0
            })
        });

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(originalOrder, noHook);

        // User tampers: set feeMbps to 0
        Order memory tamperedOrder = originalOrder;
        tamperedOrder.options.feeMbps = 0;

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(tamperedOrder, noHook, quoteSig);
    }

    /**
     * @notice Revert when user tampers with srcHook after solver signs
     */
    function testQuoteSig_Revert_TamperedSrcHook() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory originalHook = defaultSrcSolverData(INPUT_AMOUNT);
        bytes memory quoteSig = signQuote(order, originalHook);

        // Tamper with the hook instructions
        SrcHook memory tamperedHook = originalHook;
        tamperedHook.minPreferredTokenAmountOut = 0; // Tamper

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, tamperedHook, quoteSig);
    }

    /**
     * @notice Revert when user tampers with output amount
     */
    function testQuoteSig_Revert_TamperedOutputAmount() public {
        Order memory originalOrder = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(originalOrder, noHook);

        // User tampers: increase outputAmount
        Order memory tamperedOrder = originalOrder;
        tamperedOrder.outputAmount = OUTPUT_AMOUNT + 1;

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(tamperedOrder, noHook, quoteSig);
    }

    /**
     * @notice Revert when user tampers with solver field
     */
    function testQuoteSig_Revert_TamperedSolverField() public {
        Order memory originalOrder = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: OUTPUT_AMOUNT,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: remoteEid,
            options: Options({
                feeMbps: 100,
                feeRecipient: address(0),
                srcSolver: solver,
                dstSolver: address(0),
                slippageMbps: 0
            })
        });

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSig = signQuote(originalOrder, noHook);

        // User tampers: change solver to address(0) to bypass fee
        Order memory tamperedOrder = originalOrder;
        tamperedOrder.options.srcSolver = address(0);

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(tamperedOrder, noHook, quoteSig);
    }

    /**
     * @notice Revert with empty signature bytes
     */
    function testQuoteSig_Revert_EmptySignature() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        vm.expectRevert(); // ECDSA.recover reverts on empty bytes
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), "");
    }

    /**
     * @notice Revert with garbage signature bytes
     */
    function testQuoteSig_Revert_GarbageSignature() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        bytes memory garbageSig = abi.encodePacked(bytes32(uint256(1)), bytes32(uint256(2)), uint8(27));

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, emptySrcHook(), garbageSig);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              QUOTE SIGNATURE REPLAY / REUSE                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Quote signature for order A cannot be used for order B
     */
    function testQuoteSig_Revert_CrossOrderReplay() public {
        Order memory orderA = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        Order memory orderB = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT + 1, // Different output amount
            block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory noHook = emptySrcHook();
        bytes memory quoteSigA = signQuote(orderA, noHook);

        // Try to use orderA's signature for orderB
        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(orderB, noHook, quoteSigA);
    }

    /**
     * @notice Quote signature for hookA cannot be used with hookB
     */
    function testQuoteSig_Revert_CrossHookReplay() public {
        Order memory order = createCustomOrder(
            user, user, NATIVE_TOKEN, address(outputToken),
            INPUT_AMOUNT, OUTPUT_AMOUNT, block.timestamp, block.timestamp + 1 hours,
            localEid, remoteEid
        );

        SrcHook memory hookA = defaultSrcSolverData(INPUT_AMOUNT);
        bytes memory quoteSigA = signQuote(order, hookA);

        // Try to use hookA's signature with hookB (different instructions)
        SrcHook memory hookB = defaultSrcSolverData(INPUT_AMOUNT - 1);

        vm.expectRevert(InvalidSolverQuoteSignature.selector);
        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, hookB, quoteSigA);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*               SOLVER RESOLUTION IN ATOMIC SWAPS            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice When options.solver is address(0), the recovered signer is used as solver
     *         for atomic single-chain swaps with srcHook
     */
    function testQuoteSig_SolverResolution_RecoveredSigner() public {
        uint128 hookOutput = OUTPUT_AMOUNT + 100e18; // surplus for solver

        Order memory order = Order({
            offerer: user,
            recipient: user,
            inputToken: NATIVE_TOKEN,
            outputToken: address(outputToken),
            inputAmount: INPUT_AMOUNT,
            outputAmount: OUTPUT_AMOUNT,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 hours),
            srcEid: localEid,
            dstEid: localEid,
            options: Options({
                feeMbps: 0,
                feeRecipient: address(0),
                srcSolver: address(0),
                dstSolver: address(0),
                slippageMbps: 0
            })
        });

        outputToken.mint(address(mockHook), hookOutput);

        SrcHook memory srcHook = SrcHook({
            hookAddress: address(mockHook),
            preferredToken: address(outputToken),
            minPreferredTokenAmountOut: OUTPUT_AMOUNT,
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(outputToken), hookOutput)
        });

        bytes memory quoteSig = signQuote(order, srcHook);

        vm.prank(user);
        localAori.depositNative{ value: INPUT_AMOUNT }(order, srcHook, quoteSig);

        // Surplus should go to the recovered signer (solver from TestUtils)
        uint256 solverUnlocked = localLens.getUnlockedBalances(solver, address(outputToken));
        assertEq(solverUnlocked, hookOutput - OUTPUT_AMOUNT, "Recovered signer should receive surplus");
    }
}
