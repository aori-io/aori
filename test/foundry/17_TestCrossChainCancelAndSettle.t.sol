// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {ExecutionUtils, HookUtils, PayloadPackUtils, PayloadUnpackUtils} from "../../contracts/lib/AoriUtils.sol";

/**
 * @title CrossChainCancelAndSettleTest
 * @notice Tests cross-chain cancellation and settlement flows in the Aori protocol
 * These tests verify that the contract properly handles cross-chain operations
 * while maintaining proper whitelist-based solver restrictions.
 */
contract CrossChainCancelAndSettleTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    Aori public localAori;
    Aori public remoteAori;
    MockERC20 public inputToken;
    MockERC20 public outputToken;

    // User and solver addresses
    uint256 public userAPrivKey = 0xBEEF;
    address public userA;
    // The whitelisted solver address that will be used for testing operations
    address public solver = address(0x200);

    uint32 private constant localEid = 1;
    uint32 private constant remoteEid = 2;
    uint16 private constant MAX_FILLS_PER_SETTLE = 10;
    uint256 private constant GAS_LIMIT = 200000;

    function setUp() public override {
        // Derive userA
        userA = vm.addr(userAPrivKey);

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy local and remote Aori contracts
        localAori = new Aori(address(endpoints[localEid]), address(this), localEid, MAX_FILLS_PER_SETTLE);
        remoteAori = new Aori(address(endpoints[remoteEid]), address(this), remoteEid, MAX_FILLS_PER_SETTLE);

        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(localAori);
        aoriInstances[1] = address(remoteAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        localAori.setPeer(remoteEid, bytes32(uint256(uint160(address(remoteAori)))));
        remoteAori.setPeer(localEid, bytes32(uint256(uint160(address(localAori)))));

        // Setup test tokens
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");

        // Mint tokens
        inputToken.mint(userA, 1000e18);
        outputToken.mint(solver, 1000e18);

        // Whitelist the solver in both contracts to allow it to perform operations
        localAori.addAllowedSolver(solver);
        remoteAori.addAllowedSolver(solver);
    }

    /**
     * @dev Returns a valid order for testing
     */
    function createValidOrder() internal view returns (IAori.Order memory order) {
        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(uint32(block.timestamp) + 1),
            endTime: uint32(uint32(block.timestamp) + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });
    }

    /**
     * @dev Creates EIP712 signature for the provided order
     */
    function signOrder(IAori.Order memory order) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
                ),
                order.offerer,
                order.recipient,
                order.inputToken,
                order.outputToken,
                order.inputAmount,
                order.outputAmount,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("1")),
                address(localAori)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userAPrivKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // /**
    //  * @notice Test that unauthorized addresses cannot cancel orders
    //  * Before endTime: only whitelisted solver can cancel
    //  * After endTime: only whitelisted solver or offerer can cancel
    //  */
    // function testCancelRevertForUnauthorizedAddress() public {
    //     // PHASE 1: Deposit on Source Chain
    //     vm.chainId(localEid);
    //     IAori.Order memory order = createValidOrder();

    //     // Advance to startTime
    //     vm.warp(order.startTime + 1);

    //     // Sign the order
    //     bytes memory signature = signOrder(order);

    //     // Prepare SrcSolverData with no hook conversion
    //     SrcHook memory srcData = SrcHook({
    //         hookAddress: address(0),
    //         preferredToken: address(inputToken),
    //         minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount since no conversion
    //         instructions: ""
    //     });

    //     // Approve and deposit the order
    //     vm.prank(userA);
    //     inputToken.approve(address(localAori), order.inputAmount);

    //     vm.prank(solver);
    //     localAori.deposit(order, signature, srcData);

    //     // PHASE 2: Try to cancel on Destination Chain as unauthorized address
    //     vm.chainId(remoteEid);

    //     // Set up the order on the destination chain
    //     bytes32 orderHash = remoteAori.hash(order);
    //     remoteAori.orders(orderHash); // This will create the order in storage

    //     // Try to cancel before endTime
    //     bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
    //     uint256 fee = remoteAori.quote(localEid, 1, options, false, localEid, address(0x123));
    //     vm.deal(address(0x123), fee);

    //     vm.prank(address(0x123));
    //     vm.expectRevert("Only whitelisted solver or offerer can cancel");
    //     remoteAori.dstCancel{value: fee}(orderHash, order, options);

    //     // Try to cancel after endTime
    //     vm.warp(order.endTime + 1);
    //     vm.prank(address(0x123));
    //     vm.expectRevert("Only whitelisted solver or offerer can cancel");
    //     remoteAori.dstCancel{value: fee}(orderHash, order, options);
    // }

    /**
     * @notice Test that whitelisted solver can cancel before endTime
     */
    function testDestinationCancelBySolver() public {
        // PHASE 1: Deposit on Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();

        // Advance to startTime
        vm.warp(order.startTime + 1);

        // Sign the order
        bytes memory signature = signOrder(order);

        // Approve and deposit the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        // PHASE 2: Cancel on Destination Chain as whitelisted solver
        vm.chainId(remoteEid);

        // Set up the order on the destination chain
        bytes32 orderHash = remoteAori.hash(order);
        remoteAori.orders(orderHash); // This will create the order in storage

        // Calculate LZ message fee
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 fee = remoteAori.quote(localEid, 1, options, false, localEid, solver);
        vm.deal(solver, fee);

        // Cancel as whitelisted solver before endTime
        vm.prank(solver);
        remoteAori.dstCancel{value: fee}(orderHash, order, options);

        // Verify order is cancelled
        assertEq(uint256(remoteAori.orderStatus(orderHash)), uint8(IAori.OrderStatus.Cancelled), "Order not cancelled");
    }

    /**
     * @notice Test that offerer can cancel after endTime
     */
    function testDestinationCancelByUser() public {
        // PHASE 1: Deposit on Source Chain
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();

        // Advance to startTime
        vm.warp(order.startTime + 1);

        // Sign the order
        bytes memory signature = signOrder(order);

        // Approve and deposit the order
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        vm.prank(solver);
        localAori.deposit(order, signature);

        // Verify the order is locked
        uint256 lockedBalance = localAori.getLockedBalances(userA, address(inputToken));
        assertEq(lockedBalance, order.inputAmount, "Locked balance not increased correctly");

        // PHASE 2: Cancel on Destination Chain
        vm.chainId(remoteEid);

        // Set up the order on the destination chain
        bytes32 orderHash = remoteAori.hash(order);
        remoteAori.orders(orderHash); // This will create the order in storage

        // Warp past endTime
        vm.warp(order.endTime + 1);

        // Calculate LZ message fee
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);
        uint256 fee = remoteAori.quote(localEid, 1, options, false, localEid, userA);
        vm.deal(userA, fee);

        // Cancel as offerer after endTime
        vm.prank(userA);
        remoteAori.dstCancel{value: fee}(orderHash, order, options);

        // PHASE 3: Simulate LZ message delivery to Source Chain
        vm.chainId(localEid);

        // Prepare cancellation payload (msg type 0x01 followed by order hash)
        bytes memory cancellationPayload = new bytes(33); // 1 byte msg type + 32 bytes hash
        cancellationPayload[0] = 0x01; // Cancellation message type

        // Copy order hash into payload
        for (uint256 i = 0; i < 32; i++) {
            cancellationPayload[i + 1] = orderHash[i];
        }

        // Simulate LZ message delivery
        bytes32 guid = keccak256("mock-guid");
        vm.prank(address(endpoints[localEid]));
        localAori.lzReceive(
            Origin(remoteEid, bytes32(uint256(uint160(address(remoteAori)))), 1),
            guid,
            cancellationPayload,
            address(0),
            bytes("")
        );

        // PHASE 4: Verification
        // The order should now be cancelled on the source chain, unlocking the deposit
        uint256 lockedAfter = localAori.getLockedBalances(userA, address(inputToken));
        uint256 unlockedAfter = localAori.getUnlockedBalances(userA, address(inputToken));

        assertEq(lockedAfter, 0, "Order not unlocked after remote cancellation");
        assertEq(unlockedAfter, order.inputAmount, "Funds not credited to user after cancellation");

        // Withdraw the unlocked funds
        uint256 initialBalance = inputToken.balanceOf(userA);
        vm.prank(userA);
        localAori.withdraw(address(inputToken));

        // Verify withdrawal
        uint256 finalBalance = inputToken.balanceOf(userA);
        assertEq(finalBalance, initialBalance + order.inputAmount, "Withdrawal failed after cancellation");
    }
}
