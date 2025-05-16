// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * SingleOrderSuccessTest - Tests the full cross-chain flow with token conversion via hooks
 *
 * Test cases:
 * 1. testPhase1_Deposit - Tests the deposit functionality on the source chain and verifies locked balance
 * 2. testPhase2_Fill - Tests the fill functionality on the destination chain and verifies token transfers
 * 3. testPhase3_Settlement - Tests the settlement process on the destination chain
 * 4. testPhase4_MessageDeliveryAndVerification - Tests the LayerZero message delivery and verifies final state
 * 5. testSingleOrderSuccess - End-to-end test that runs all phases in sequence (deposit, fill, settle, and message delivery)
 */
import {Aori, IAori} from "../../contracts/Aori.sol";
import {Origin} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestUtils} from "./TestUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

contract SingleOrderSuccessTest is TestUtils {
    IAori.Order private order;

    function setUp() public override {
        super.setUp();
    }

    /**
     * @notice Helper function to create and deposit order
     */
    function _createAndDepositOrder() internal {
        vm.chainId(localEid);
        order = createValidOrder();

        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit with hook conversion using the order's input amount
        vm.prank(solver);
        localAori.deposit(order, signature, defaultSrcSolverData(order.inputAmount));
    }

    /**
     * @notice Helper function to fill order
     */
    function _fillOrder() internal {
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1); // Advance time so order has started

        // Approve and fill order
        vm.prank(solver);
        dstPreferredToken.approve(address(remoteAori), order.outputAmount);

        vm.prank(solver);
        remoteAori.fill(order, defaultDstSolverData(order.outputAmount));
    }


    /**
     * @notice Helper function to settle order
     */
    function _settleOrder() internal {
        bytes memory options = defaultOptions();
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);
        vm.prank(solver);
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

    /**
     * @notice Helper function to simulate LayerZero message delivery
     */
    function _simulateLzMessageDelivery() internal {
        vm.chainId(localEid);
        bytes32 guid = keccak256("mock-guid");
        bytes memory settlementPayload = abi.encodePacked(
            uint8(0), // message type 0 for settlement
            solver, // filler address
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
     * @notice Test Phase 1: Deposit on source chain
     */
    function testPhase1_Deposit() public {
        uint256 initialLocked = localAori.getLockedBalances(userA, address(convertedToken));

        _createAndDepositOrder();

        // Verify locked balance increased
        assertEq(
            localAori.getLockedBalances(userA, address(convertedToken)),
            initialLocked + order.inputAmount,
            "Locked balance not increased for user"
        );
    }

    /**
     * @notice Test Phase 2: Fill on destination chain
     */
    function testPhase2_Fill() public {
        _createAndDepositOrder();

        // Record pre-fill balances
        uint256 preFillSolverPreferred = dstPreferredToken.balanceOf(solver);
        uint256 preFillUserOutput = outputToken.balanceOf(userA);

        _fillOrder();

        // Verify token transfers
        assertEq(
            dstPreferredToken.balanceOf(solver),
            preFillSolverPreferred - order.outputAmount,
            "Solver preferred token balance not reduced by fill"
        );
        assertEq(
            outputToken.balanceOf(userA),
            preFillUserOutput + order.outputAmount,
            "User did not receive the expected output tokens"
        );
    }

    /**
     * @notice Test Phase 3: Settlement on destination chain
     */
    function testPhase3_Settlement() public {
        _createAndDepositOrder();
        _fillOrder();
        _settleOrder();
    }

    /**
     * @notice Test Phase 4: LayerZero message delivery and verification
     */
    function testPhase4_MessageDeliveryAndVerification() public {
        _createAndDepositOrder();
        _fillOrder();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state
        assertEq(
            localAori.getUnlockedBalances(solver, address(convertedToken)),
            order.inputAmount,
            "Solver unlocked token balance incorrect after settlement"
        );
    }

    /**
     * @notice Full test that runs all phases in sequence
     */
    function testSingleOrderSuccess() public {
        _createAndDepositOrder();
        _fillOrder();
        _settleOrder();
        _simulateLzMessageDelivery();

        // Verify final state
        assertEq(
            localAori.getUnlockedBalances(solver, address(convertedToken)),
            order.inputAmount,
            "Solver unlocked token balance incorrect after settlement"
        );
    }
}
