// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {Script, console} from "@layerzerolabs/toolbox-foundry/lib/forge-std/Script.sol";
import {Aori} from "../Aori.sol";

/**
 * @title WhitelistHookScript
 * @notice This script whitelists hook addresses on Aori contracts across multiple chains
 * @dev Set the PRIVATE_KEY environment variable to the owner's private key
 */
contract WhitelistHookScript is Script {
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

    // Hook address to whitelist
    address hookAddress;

    function run() external {
        // Get hook address from environment variable or use a default
        string memory hookAddressStr = vm.envOr("HOOK_ADDRESS", string(""));
        if (bytes(hookAddressStr).length > 0) {
            hookAddress = vm.parseAddress(hookAddressStr);
        } else {
            hookAddress = 0x0000000000000000000000000000000000000000; 
            console.log("Using default hook address:", hookAddress);
        }

        require(hookAddress != address(0), "Invalid hook address");
        console.log("Whitelisting hook:", hookAddress);
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
        console.log("Whitelisting hook on %s", chainName);
        console.log("Aori contract: %s", aoriAddress);

        try vm.createSelectFork(vm.envString(rpcEnvVar)) {
            vm.startBroadcast(ownerPrivateKey);

            try Aori(aoriAddress).addAllowedHook(hookAddress) {
                console.log("[SUCCESS] Successfully whitelisted hook on %s", chainName);
            } catch Error(string memory reason) {
                console.log("[ERROR] Failed to whitelist hook on %s: %s", chainName, reason);
            } catch {
                console.log("[ERROR] Failed to whitelist hook on %s (unknown error)", chainName);
            }

            vm.stopBroadcast();
        } catch {
            console.log("[ERROR] Failed to connect to %s RPC", chainName);
        }
    }
} 