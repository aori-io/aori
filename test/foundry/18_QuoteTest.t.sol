// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {ExecutionUtils, HookUtils, PayloadPackUtils, PayloadUnpackUtils} from "../../contracts/lib/AoriUtils.sol";

/**
 * @title QuoteTest
 * @notice Tests the LayerZero message fee quoting functionality in the Aori protocol
 * These tests verify that the contract properly calculates fees for different message types
 * and payload sizes while maintaining proper whitelist-based solver restrictions.
 */
contract QuoteTest is TestHelperOz5 {
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

    /// @dev Deploy endpoints, contracts, and tokens.
    function setUp() public override {
        // Derive userA from private key
        userA = vm.addr(userAPrivKey);

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy Aori contracts
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

    /// @dev Helper to create and deposit orders
    function createAndDepositOrder(uint256 index) internal returns (IAori.Order memory order, bytes32 orderHash) {
        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp + 1 + index), // Unique start time per order
            endTime: uint32(block.timestamp + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Generate signature
        bytes memory signature = signOrder(order);

        // Approve tokens for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Deposit order using whitelisted solver
        vm.prank(solver);
        localAori.deposit(order, signature);

        // Get order hash
        orderHash = localAori.hash(order);
    }

    /// @dev Helper to sign an order
    function signOrder(IAori.Order memory order) internal view returns (bytes memory) {
        bytes32 orderTypehash = keccak256(
            "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                orderTypehash,
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

    /// @dev Test quoting for cancel message (33 bytes)
    function testQuoteCancelMessage() public view {
        // Get standard LZ options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Get quote for cancel message (msgType 1)
        uint256 cancelFee = localAori.quote(
            remoteEid, // destination endpoint
            1, // message type (1 for cancel)
            options, // LZ options
            false, // payInLzToken
            0, // srcEid (not used for cancel)
            address(0) // filler (not used for cancel)
        );

        // Verify quote is non-zero
        assertGt(cancelFee, 0, "Cancel message fee should be non-zero");
    }

    /// @dev Test quoting for settle message with increasing number of order fills
    function testQuoteSettleMessage() public {
        // Get standard LZ options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Switch to remote chain to fill orders
        vm.chainId(remoteEid);

        // First, let's test an empty settle message (no fills)
        uint256 emptyFee = remoteAori.quote(
            localEid, // destination endpoint
            0, // message type (0 for settle)
            options, // LZ options
            false, // payInLzToken
            localEid, // srcEid
            solver // whitelisted solver
        );

        // Now deposit and fill multiple orders to test quotes with different payload sizes
        vm.chainId(localEid);
        IAori.Order[] memory orders = new IAori.Order[](3);
        bytes32[] memory orderHashes = new bytes32[](3);

        // Create and deposit multiple orders
        for (uint256 i = 0; i < 3; i++) {
            (orders[i], orderHashes[i]) = createAndDepositOrder(i);
        }

        // Switch to remote chain to fill orders
        vm.chainId(remoteEid);
        vm.warp(orders[2].startTime + 1); // Warp to after the latest order's start time

        // Fill each order
        for (uint256 i = 0; i < 3; i++) {
            // Approve tokens for fill
            vm.prank(solver);
            outputToken.approve(address(remoteAori), orders[i].outputAmount);

            // Fill the order using whitelisted solver
            vm.prank(solver);
            remoteAori.fill(orders[i]);

            // Get quote for settle message after each fill
            uint256 settleFee = remoteAori.quote(
                localEid, // destination endpoint
                0, // message type (0 for settle)
                options, // LZ options
                false, // payInLzToken
                localEid, // srcEid
                solver // whitelisted solver
            );

            // Verify fee is non-zero and increases with each additional fill
            assertGt(settleFee, 0, "Settle message fee should be non-zero");
            if (i > 0) {
                // The fee should increase as more hashes are added to the payload
                assertGt(settleFee, emptyFee, "Fee should be higher than base fee");
            }
        }
    }

    /// @dev Test that quotes increase with payload size
    function testQuoteIncreasesWithPayloadSize() public {
        // Get standard LZ options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Create and deposit multiple orders
        vm.chainId(localEid);
        uint256[] memory orderCounts = new uint256[](3);
        orderCounts[0] = 1; // Test with 1 order
        orderCounts[1] = 5; // Test with 5 orders
        orderCounts[2] = 10; // Test with 10 orders (MAX_FILLS_PER_SETTLE)

        uint256[] memory fees = new uint256[](3);

        // For each test case, deposit multiple orders and check quote
        for (uint256 testCase = 0; testCase < 3; testCase++) {
            uint256 numOrders = orderCounts[testCase];

            // Create and deposit orders
            for (uint256 i = 0; i < numOrders; i++) {
                createAndDepositOrder(i + (testCase * 10)); // Ensure unique start times
            }

            // Switch to remote chain to fill orders
            vm.chainId(remoteEid);
            vm.warp(uint32(uint32(block.timestamp) + 100)); // Ensure all orders have started

            // Fill each order
            for (uint256 i = 0; i < numOrders; i++) {
                IAori.Order memory order = IAori.Order({
                    offerer: userA,
                    recipient: userA,
                    inputToken: address(inputToken),
                    outputToken: address(outputToken),
                    inputAmount: 1e18,
                    outputAmount: 2e18,
                    startTime: uint32(block.timestamp - 50 + i + (testCase * 10)),
                    endTime: uint32(block.timestamp + 1 days),
                    srcEid: localEid,
                    dstEid: remoteEid
                });

                // Approve tokens for fill
                vm.prank(solver);
                outputToken.approve(address(remoteAori), order.outputAmount);

                // Fill the order using whitelisted solver
                vm.prank(solver);
                remoteAori.fill(order);
            }

            // Get quote for settle with filled orders
            fees[testCase] = remoteAori.quote(
                localEid, // destination endpoint
                0, // message type (0 for settle)
                options, // LZ options
                false, // payInLzToken
                localEid, // srcEid
                solver // whitelisted solver
            );
            // Reset for next test case
            vm.chainId(localEid);
        }

        // Verify fees increase with payload size
        assertGt(fees[1], fees[0], "Fee should increase with more orders");
        assertGt(fees[2], fees[1], "Fee should increase with more orders");
    }

    /// @dev Compare cancel and settle message fees
    function testCompareQuoteCancelAndSettle() public {
        // Get standard LZ options
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);

        // Get quote for cancel message (33 bytes)
        uint256 cancelFee = localAori.quote(
            remoteEid, // destination endpoint
            1, // message type (1 for cancel)
            options, // LZ options
            false, // payInLzToken
            0, // srcEid
            address(0) // filler
        );

        // Create and fill a single order to get a settle quote
        vm.chainId(localEid);
        (IAori.Order memory order,) = createAndDepositOrder(0);

        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        // Approve tokens for fill
        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Fill the order using whitelisted solver
        vm.prank(solver);
        remoteAori.fill(order);

        // Get quote for settle message with 1 fill (1 + 20 + 2 + 32 = 55 bytes)
        uint256 settleFee = remoteAori.quote(
            localEid, // destination endpoint
            0, // message type (0 for settle)
            options, // LZ options
            false, // payInLzToken
            localEid, // srcEid
            solver // whitelisted solver
        );
        // Settle fee should be greater than cancel fee because the payload is larger
        assertGt(settleFee, cancelFee, "Settle fee should be greater than cancel fee due to larger payload");
    }
}
