// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import "../../contracts/AoriUtils.sol";

/**
 * @title GasReportTest
 * @notice Tests to measure gas costs of various operations in the Aori protocol
 * These tests verify gas efficiency while maintaining proper whitelist-based solver restrictions.
 */
contract GasReportTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    Aori public localAori;
    Aori public remoteAori;
    MockERC20 public inputToken;
    MockERC20 public outputToken;

    // User and whitelisted solver addresses
    uint256 public userAPrivKey = 0xBEEF;
    address public userA;
    // The whitelisted solver address that will be used for testing operations
    address public solver = address(0x200);

    uint32 private constant localEid = 1;
    uint32 private constant remoteEid = 2;
    uint16 private constant MAX_FILLS_PER_SETTLE = 10;

    // Common order that will be used across tests
    IAori.Order public commonOrder;
    bytes public commonSignature;
    IAori.SrcHook public commonSrcData;
    IAori.DstHook public commonDstData;

    function setUp() public override {
        // Derive userA from private key
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

        // Deploy test tokens
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");

        // Mint tokens
        inputToken.mint(userA, 1000e18);
        outputToken.mint(solver, 1000e18);

        vm.deal(userA, 1e18); // Fund the account with 1 ETH

        // Whitelist the solver in both contracts
        localAori.addAllowedSolver(solver);
        remoteAori.addAllowedSolver(solver);

        // Setup common order data
        commonOrder = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp), // Use current time
            endTime: uint32(uint32(block.timestamp) + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });

        commonSignature = signOrder(commonOrder);
        commonSrcData = IAori.SrcHook({
            hookAddress: address(0),
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount since no conversion
            instructions: ""
        });

        commonDstData = IAori.DstHook({
            hookAddress: address(0),
            preferredToken: address(outputToken),
            instructions: "",
            preferedDstInputAmount: 2e18
        });

        // Pre-approve tokens
        vm.prank(userA);
        inputToken.approve(address(localAori), 1e18);
        vm.prank(solver);
        outputToken.approve(address(remoteAori), 2e18);

        // Setup chains as supported
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(localAori.quote.selector, remoteEid, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        vm.mockCall(
            address(remoteAori),
            abi.encodeWithSelector(remoteAori.quote.selector, localEid, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );

        // Add support for chains
        localAori.addSupportedChain(remoteEid);
        remoteAori.addSupportedChain(localEid);
    }

    function testGasDeposit() public {
        // Only measure gas for the deposit operation
        vm.prank(solver); // Use whitelisted solver to deposit
        localAori.deposit(commonOrder, commonSignature);
    }

    function testGasFill() public {
        // Setup: Deposit order first (not measured in gas report)
        vm.prank(solver); // Use whitelisted solver to deposit
        localAori.deposit(commonOrder, commonSignature);

        // Only measure gas for the fill operation
        vm.prank(solver);
        remoteAori.fill(commonOrder);
    }

    function testGasSettle() public {
        // Setup: Deposit and fill order (not measured in gas report)
        vm.prank(solver); // Use whitelisted solver to deposit
        localAori.deposit(commonOrder, commonSignature);
        vm.prank(solver);
        remoteAori.fill(commonOrder);

        // Get LayerZero options and fee for settling
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver);
        vm.deal(solver, fee);

        // Only measure gas for the settle operation
        vm.prank(solver);
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

    // Add new helper function for signing orders for different chains
    function signOrderForChain(IAori.Order memory order, address contractAddress)
        internal
        view
        returns (bytes memory)
    {
        bytes32 typeHash = keccak256(
            "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );
        bytes32 structHash = keccak256(
            abi.encode(
                typeHash,
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
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("0.3.0")),
                contractAddress
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userAPrivKey, digest);
        return abi.encodePacked(r, s, v);
    }

    // Update existing signOrder to use the new helper
    function signOrder(IAori.Order memory order) internal view returns (bytes memory) {
        return signOrderForChain(order, address(localAori));
    }
}
