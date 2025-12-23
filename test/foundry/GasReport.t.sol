// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OAppUpgradeable, Origin, MessagingFee} from "@layerzerolabs/oapp-evm-upgradeable/contracts/oapp/OAppUpgradeable.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {TestUtils} from "./TestUtils.sol";
import "../../contracts/AoriUtils.sol";

/**
 * @title GasReportTest
 * @notice Tests to measure gas costs of various operations in the Aori protocol
 * These tests verify gas efficiency while maintaining proper whitelist-based solver restrictions.
 */
contract GasReportTest is TestUtils {
    using OptionsBuilder for bytes;

    // Common order that will be used across tests
    IAori.Order public commonOrder;
    bytes public commonSignature;
    IAori.SrcHook public commonSrcData;
    IAori.DstHook public commonDstData;

    function setUp() public override {
        // Use parent setUp for common infrastructure
        super.setUp();

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
            instructions: "",
            solver: solver
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
        uint256 fee = remoteAori.quote(localEid, 0, options, false, localEid, solver).nativeFee;
        vm.deal(solver, fee);

        // Only measure gas for the settle operation
        vm.prank(solver);
        remoteAori.settle{value: fee}(localEid, solver, options);
    }

}
