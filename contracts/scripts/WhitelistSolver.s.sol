// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script, console} from "@layerzerolabs/toolbox-foundry/lib/forge-std/Script.sol";
import {Aori} from "../Aori.sol";

/**
 * @title WhitelistSolverScript
 * @notice This script whitelists solver addresses on Aori contracts across multiple chains
 * @dev Set the PRIVATE_KEY environment variable to the owner's private key
 */
contract WhitelistSolverScript is Script {
    // Deployed Aori contract addresses on respective chains
    address constant AORI_ARBITRUM = 0xb665455EF24811023EA1EdA2620Bf95581Fa4906; // Replace with actual address
    address constant AORI_BASE = 0xD43E1c73da58bDe9cAD8e1c95B9529C6dE1C559b; // Replace with actual address
    address constant AORI_OPTIMISM = 0x90001c17B056FbaBd4304b20b4E7FD379bD2B6C5; // Replace with actual address
    address constant AORI_MAINNET = 0xcf283cEfc46781eb91C70403DED05887B3cD953b; // Replace with actual address

    // Chain IDs for reference
    uint256 constant ARBITRUM_CHAIN_ID = 42161;  // Arbitrum
    uint256 constant BASE_CHAIN_ID = 8453; // Base
    uint256 constant OPTIMISM_CHAIN_ID = 10; // Optimism 
    uint256 constant MAINNET_CHAIN_ID = 1; // Ethereum Mainnet

    // The owner's private key and address
    uint256 ownerPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address ownerAddress = vm.addr(ownerPrivateKey);

    // Solver address to whitelist
    address solverAddress;

    function run() external {
        // Get solver address from environment variable or use a default
        string memory solverAddressStr = vm.envOr("SOLVER_ADDRESS", string(""));
        if (bytes(solverAddressStr).length > 0) {
            solverAddress = vm.parseAddress(solverAddressStr);
        } else {
            // Default to a specific address if not provided
            solverAddress = 0x2002d368c670f5dB65f732152F8887677933D830; // Replace with your default solver address
            console.log("Using default solver address:", solverAddress);
        }

        require(solverAddress != address(0), "Invalid solver address");
        console.log("Whitelisting solver:", solverAddress);
        console.log("Owner address:", ownerAddress);

        // Whitelist on Arbitrum
        whitelistOnChain("ARBITRUM_RPC", AORI_ARBITRUM, "Arbitrum");

        // Whitelist on Base
        whitelistOnChain("BASE_RPC", AORI_BASE, "Base");

        // Whitelist on Optimism
        whitelistOnChain("OPTIMISM_RPC", AORI_OPTIMISM, "Optimism");

        // Whitelist on Mainnet
        whitelistOnChain("MAINNET_RPC", AORI_MAINNET, "Ethereum Mainnet");
    }

    function whitelistOnChain(string memory rpcEnvVar, address aoriAddress, string memory chainName) internal {
        if (aoriAddress == address(0)) {
            console.log("Skipping %s - contract address not set", chainName);
            return;
        }

        console.log("------------------------------");
        console.log("Whitelisting on %s", chainName);
        console.log("Aori contract: %s", aoriAddress);

        try vm.createSelectFork(vm.envString(rpcEnvVar)) {
            vm.startBroadcast(ownerPrivateKey);

            try Aori(aoriAddress).addAllowedSolver(solverAddress) {
                console.log("[SUCCESS] Successfully whitelisted solver on %s", chainName);
            } catch Error(string memory reason) {
                console.log("[ERROR] Failed to whitelist on %s: %s", chainName, reason);
            } catch {
                console.log("[ERROR] Failed to whitelist on %s (unknown error)", chainName);
            }

            vm.stopBroadcast();
        } catch {
            console.log("[ERROR] Failed to connect to %s RPC", chainName);
        }
    }
} 