// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Script} from "@layerzerolabs/toolbox-foundry/lib/forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAori} from "../interfaces/IAori.sol";

contract WithdrawalScript is Script {
    using OptionsBuilder for bytes;

    address constant AORI_ARB = 0x397411cd0Dd9156ADE29Fe8f65160cf402DF5e5C;
    address constant AORI_BASE = 0xf411498156a6219A97356A5F40170a2313f8653c;

    uint256 depositorPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY2"));
    address depositorAddress = vm.addr(depositorPrivateKey);

    uint256 solverPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address solverAddress = vm.addr(solverPrivateKey);

    function run() external {
        // Adjust the env var / chain as needed:
        vm.createSelectFork(vm.envString("ARB_RPC"));

        vm.startBroadcast(solverPrivateKey);

        // 1. Deploy a demo ERC20 & mint tokens:
        IERC20 ARB_USDC = IERC20(0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
        // IERC20 sepToken = IERC20(0x6e56e17a9Ac93bd42F5C02613D24025327d0497E);

        IAori(AORI_ARB).withdraw(address(ARB_USDC));

        vm.stopBroadcast();
    }
}
