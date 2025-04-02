// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * MultiOrderSuccessTest - Tests the full cross-chain flow for multiple orders with token conversion via hooks
 *
 * Test cases:
 * 1. testPhase1_DepositOrders - Tests depositing multiple orders on the source chain and verifies locked balances
 * 2. testPhase2_FillOrders - Tests filling multiple orders on the destination chain and verifies token transfers
 * 3. testPhase3_Settlement - Tests the settlement process for multiple orders on the destination chain
 * 4. testPhase4_MessageDeliveryAndVerification - Tests the LayerZero message delivery for multiple orders and verifies final state
 * 5. testMultiOrderSuccess - End-to-end test that runs all phases in sequence for multiple orders (deposit, fill, settle, and message delivery)
 *
 * Note: This test creates and processes multiple orders (NUM_ORDERS = 3) in batch to test the system's ability to
 * handle multiple orders simultaneously and efficiently.
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockHook} from "../Mock/MockHook.sol";
import "forge-std/console.sol";
import "./TestUtils.sol";

/**
 * @title MultiOrderSuccessTest
 * @notice Tests the full cross-chain flow for multiple orders with token conversion via hooks
 */
contract MultiOrderSuccessTest is TestUtils {
    using OptionsBuilder for bytes;

    uint256 private constant GAS_LIMIT = 200000;
    uint256 private constant NUM_ORDERS = 3;
    IAori.Order[] private orders;
    uint256 private totalInput;

    function setUp() public override {
        super.setUp();
        orders = new IAori.Order[](NUM_ORDERS);
        totalInput = 0;
    }

    /**
     * @notice Helper function to create and deposit orders
     */
    function _createAndDepositOrders() internal {
        vm.chainId(localEid);
        for (uint256 i = 0; i < NUM_ORDERS; i++) {
            // Use index+1 as salt to ensure each order is unique
            orders[i] = createValidOrder(i + 1);
            totalInput += orders[i].inputAmount;
            bytes memory signature = signOrder(orders[i]);

            // Approve inputToken for deposit.
            vm.prank(userA);
            inputToken.approve(address(localAori), orders[i].inputAmount);

            // Deposit with hook conversion using the order's input amount
            vm.prank(solver);
            localAori.deposit(orders[i], signature, defaultSrcSolverData(orders[i].inputAmount));
        }
    }

    /**
     * @notice Helper function to fill orders
     */
    function _fillOrders() internal {
        vm.chainId(remoteEid);

        // Warp to time after orders have started (orders now have consistent start times)
        vm.warp(uint32(uint32(block.timestamp) + 1 hours + 1));

        for (uint256 i = 0; i < NUM_ORDERS; i++) {
            // Approve remoteAori to spend dstPreferredToken
            vm.prank(solver);
            dstPreferredToken.approve(address(remoteAori), orders[i].outputAmount);

            // Execute fill with dynamic output amount
            vm.prank(solver);
            remoteAori.fill(orders[i], defaultDstSolverData(orders[i].outputAmount));
        }
    }

    /**
     * @notice Helper function to settle orders
     */
    function _settleOrders() internal {
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        vm.prank(solver);
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

    /**
     * @notice Test Phase 1: Deposit multiple orders on source chain
     */
    function testPhase1_DepositOrders() public {
        _createAndDepositOrders();
        // Verify that the locked balance for convertedToken increased.
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(convertedToken));
        assertEq(lockedBalance, totalInput, "Locked balance not increased correctly");
    }

    /**
     * @notice Test Phase 2: Fill all orders on destination chain
     */
    function testPhase2_FillOrders() public {
        _createAndDepositOrders();

        // Record pre-fill balances
        uint256 preFillSolverPreferred = dstPreferredToken.balanceOf(solver);
        uint256 preFillUserOutput = outputToken.balanceOf(userA);

        _fillOrders();

        // Verify token transfers
        uint256 expectedSolverPreferred = preFillSolverPreferred;
        uint256 expectedUserOutput = preFillUserOutput;
        for (uint256 i = 0; i < NUM_ORDERS; i++) {
            expectedSolverPreferred -= orders[i].outputAmount;
            expectedUserOutput += orders[i].outputAmount;
        }
        assertEq(
            dstPreferredToken.balanceOf(solver),
            expectedSolverPreferred,
            "Solver preferred token balance not reduced correctly after fills"
        );
        assertEq(outputToken.balanceOf(userA), expectedUserOutput, "User did not receive the expected output tokens");
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositOrders();
        _fillOrders();
        _settleOrders();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositOrders();
        _fillOrders();
        _settleOrders();

        // Simulate LayerZero message delivery
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");
        uint16 fillCount = uint16(NUM_ORDERS);
        bytes memory settlementPayload = new bytes(23 + uint256(fillCount) * 32);
        settlementPayload[0] = 0x00;
        bytes20 fillerBytes = bytes20(solver);
        for (uint256 i = 0; i < 20; i++) {
            settlementPayload[1 + i] = fillerBytes[i];
        }
        settlementPayload[21] = bytes1(uint8(uint16(fillCount) >> 8));
        settlementPayload[22] = bytes1(uint8(uint16(fillCount)));
        for (uint256 i = 0; i < NUM_ORDERS; i++) {
            bytes32 orderHash = localAori.hash(orders[i]);
            uint256 offset = 23 + i * 32;
            for (uint256 j = 0; j < 32; j++) {
                settlementPayload[offset + j] = orderHash[j];
            }
        }
        vm.prank(address(endpoints[localEid]));
        uint256 gas0 = gasleft();
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            settlementPayload,
            address(0),
            bytes("")
        );
        uint256 gas1 = gasleft();
        console.log("Gas used for lzReceive settlement: %d", gas0 - gas1);

        // Verify final state
        uint256 unlockedBalance = localAori.getUnlockedBalances(solver, address(convertedToken));
        assertEq(unlockedBalance, totalInput, "Solver unlocked token balance incorrect after settlement");
    }

    /**
     * @notice Full test that runs all phases in sequence
     */
    function testMultiOrderSuccess() public {
        _createAndDepositOrders();
        _fillOrders();
        _settleOrders();

        // Simulate LayerZero message delivery
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");
        uint16 fillCount = uint16(NUM_ORDERS);
        bytes memory settlementPayload = new bytes(23 + uint256(fillCount) * 32);
        settlementPayload[0] = 0x00;
        bytes20 fillerBytes = bytes20(solver);
        for (uint256 i = 0; i < 20; i++) {
            settlementPayload[1 + i] = fillerBytes[i];
        }
        settlementPayload[21] = bytes1(uint8(uint16(fillCount) >> 8));
        settlementPayload[22] = bytes1(uint8(uint16(fillCount)));
        for (uint256 i = 0; i < NUM_ORDERS; i++) {
            bytes32 orderHash = localAori.hash(orders[i]);
            uint256 offset = 23 + i * 32;
            for (uint256 j = 0; j < 32; j++) {
                settlementPayload[offset + j] = orderHash[j];
            }
        }
        vm.prank(address(endpoints[localEid]));
        uint256 gas0 = gasleft();
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            settlementPayload,
            address(0),
            bytes("")
        );
        uint256 gas1 = gasleft();
        console.log("Gas used for lzReceive settlement: %d", gas0 - gas1);

        // Verify final state
        uint256 unlockedBalance = localAori.getUnlockedBalances(solver, address(convertedToken));
        assertEq(unlockedBalance, totalInput, "Solver unlocked token balance incorrect after settlement");
    }
}
