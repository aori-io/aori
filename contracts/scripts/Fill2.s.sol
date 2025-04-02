// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Script} from "@layerzerolabs/toolbox-foundry/lib/forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAori} from "../IAori.sol";

contract FillScript is Script {
    using OptionsBuilder for bytes;

    // These are our deployed Aori contract addresses on the respective chains.
    address constant AORI_ARB = 0x397411cd0Dd9156ADE29Fe8f65160cf402DF5e5C;
    address constant AORI_BASE = 0xf411498156a6219A97356A5F40170a2313f8653c;

    uint256 depositorPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY2"));
    address depositorAddress = vm.addr(depositorPrivateKey);

    uint256 solverPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address solverAddress = vm.addr(solverPrivateKey);

    function run() external {
        /// ---------------------- ARB SEP CHAIN (Deposit) ----------------------
        // Adjust the env var / chain as needed:
        vm.createSelectFork(vm.envString("ARB_RPC"));
        vm.startBroadcast(depositorPrivateKey);

        // 1. Use existing ERC20 tokens deployed on ArbSep:
        IERC20 ARB_USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
        IERC20 BASE_USDC = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

        // Approve the Aori deposit contract to spend tokens.
        ARB_USDC.approve(AORI_ARB, 1e6);

        // Create order – note that srcEid must match the Aori instance's endpoint on this chain
        // and dstEid must match the remote chain's endpoint.
        IAori.Order memory order = IAori.Order({
            offerer: depositorAddress,
            recipient: depositorAddress,
            inputToken: address(ARB_USDC),
            outputToken: address(BASE_USDC),
            inputAmount: 1e6,
            outputAmount: 1e6,
            startTime: uint32(block.timestamp - 100),
            endTime: uint32(block.timestamp + 7200), // 2 hours later
            srcEid: 30110,
            dstEid: 30184
        });

        // ============================================================
        // Compute the EIP712 signature for the order
        // ============================================================
        // The Aori contract is initialized using EIP712 with:
        //   name: "Aori" and version: "1"
        // The domain separator is computed as:
        // keccak256(abi.encode(
        //      keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
        //      keccak256(bytes("Aori")),
        //      keccak256(bytes("1")),
        //      AORI_ARB
        // ))
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("1")),
                AORI_ARB
            )
        );

        // The order type hash must match the one in Aori.sol:
        bytes32 ORDER_TYPEHASH = keccak256(
            "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

        // Compute the struct hash for the order.
        bytes32 orderStructHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
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

        // Compose the EIP712 digest.
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderStructHash));

        // Sign the digest with the depositor's private key.
        // vm.sign returns (v, r, s) which we pack into a 65-byte signature.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(depositorPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Prepare an empty SrcSolverData so that no extra hook logic is triggered.
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(0),
            preferredToken: order.inputToken,
            minPreferedTokenAmountOut: order.inputAmount, // For direct deposits, minimum output equals input
            instructions: ""
        });

        // Call deposit with a valid signature and the SrcSolverData.
        IAori(AORI_ARB).deposit{value: 0}(order, signature, srcData);

        vm.stopBroadcast();

        /// ---------------------- BASE CHAIN (Fill & Settle) ----------------------
        vm.createSelectFork(vm.envString("BASE_RPC"));
        vm.startBroadcast(solverPrivateKey);

        // Call fill on the Sepolia Aori instance.
        // This will transfer order.outputAmount from solverAddress to order.recipient.
        BASE_USDC.approve(AORI_BASE, 1e6);
        IAori(AORI_BASE).fill{value: 0}(order);

        // ---------------------- Settle ----------------------
        // Build your worker/gas options as before.
        uint256 GAS_LIMIT = 200000;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);

        // // Quote the fee for settlement.
        // uint256 estimatedFee = IAori(AORI_BASE).quote(
        //     30184,
        //     abi.encode(""),
        //     options,
        //     false
        // );

        // Call settle on Sepolia with the provided fee.
        IAori(AORI_BASE).settle{value: 0.01 ether}(30110, solverAddress, options);

        vm.stopBroadcast();
    }
}
