// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./BaseScript.sol";

/**
 * @title ConfigurePeers
 * @notice Configure LayerZero peers between Aori deployments across chains
 * @dev Run this script on each chain after all deployments are complete
 *
 * Usage:
 *   # Configure peers on each chain (must run on every chain)
 *   AORI_PROXY_ADDRESS=0x... forge script script/ConfigurePeers.s.sol:ConfigurePeers \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key (must be contract owner)
 *   - AORI_PROXY_ADDRESS: Deployed Aori proxy address
 *   - MAINNET: Set to "true" for mainnet configuration
 *   - REMOTE_AORI_ADDRESS: Remote Aori address (if different from local, optional)
 */
contract ConfigurePeers is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey, address owner, address proxyAddress) = _loadOwnerAndProxy();
        Aori aori = Aori(payable(proxyAddress));
        ChainConfig memory currentConfig = _getCurrentChainConfig();

        console.log("=== Configure Peers ===");
        console.log("Chain:", currentConfig.name);
        console.log("Aori:", proxyAddress);
        console.log("Owner:", owner);

        _requireOwner(aori, owner);

        // Get target chains
        bool isMainnet = vm.envOr("MAINNET", false);
        ChainConfig[] memory allChains = isMainnet ? _getMainnetChains() : _getTestnetChains();

        // Remote Aori address (default to same as local for deterministic deployments)
        address remoteAori = vm.envOr("REMOTE_AORI_ADDRESS", proxyAddress);

        vm.startBroadcast(ownerPrivateKey);

        // Set peers for all other chains
        for (uint256 i = 0; i < allChains.length; i++) {
            if (allChains[i].eid != currentConfig.eid) {
                console.log("Setting peer for", allChains[i].name);
                console.log("  EID:", allChains[i].eid);
                _setPeer(aori, allChains[i].eid, remoteAori);
            }
        }

        vm.stopBroadcast();

        console.log("");
        console.log("=== Peer Configuration Complete ===");
        console.log("Peers configured:", allChains.length - 1);
    }
}

/**
 * @title ConfigureSinglePeer
 * @notice Configure a single peer connection
 * @dev Use when adding a new chain to existing deployment
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key
 *   - AORI_PROXY_ADDRESS: Local Aori proxy address
 *   - REMOTE_EID: Remote chain LayerZero EID
 *   - REMOTE_AORI_ADDRESS: Remote Aori proxy address
 */
contract ConfigureSinglePeer is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey,, address proxyAddress) = _loadOwnerAndProxy();
        uint32 remoteEid = uint32(vm.envUint("REMOTE_EID"));
        address remoteAori = vm.envAddress("REMOTE_AORI_ADDRESS");

        Aori aori = Aori(payable(proxyAddress));

        console.log("=== Configure Single Peer ===");
        console.log("Local Aori:", proxyAddress);
        console.log("Remote EID:", remoteEid);
        console.log("Remote Aori:", remoteAori);

        vm.startBroadcast(ownerPrivateKey);

        _setPeer(aori, remoteEid, remoteAori);
        _addSupportedChain(aori, remoteEid);

        vm.stopBroadcast();

        console.log("Peer configured successfully");
    }
}

/**
 * @title AddSolvers
 * @notice Add solver addresses to whitelist
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key
 *   - AORI_PROXY_ADDRESS: Aori proxy address
 *   - SOLVERS: Comma-separated solver addresses
 */
contract AddSolvers is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey,, address proxyAddress) = _loadOwnerAndProxy();
        string memory solversStr = vm.envString("SOLVERS");

        Aori aori = Aori(payable(proxyAddress));

        string[] memory parts = vm.split(solversStr, ",");

        console.log("=== Add Solvers ===");
        console.log("Aori:", proxyAddress);
        console.log("Solvers to add:", parts.length);

        vm.startBroadcast(ownerPrivateKey);

        for (uint256 i = 0; i < parts.length; i++) {
            address solver = vm.parseAddress(parts[i]);
            aori.addAllowedSolver(solver);
            console.log("Added solver:", solver);
        }

        vm.stopBroadcast();
    }
}

/**
 * @title AddHooks
 * @notice Add hook addresses to whitelist
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key
 *   - AORI_PROXY_ADDRESS: Aori proxy address
 *   - HOOKS: Comma-separated hook addresses
 */
contract AddHooks is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey,, address proxyAddress) = _loadOwnerAndProxy();
        string memory hooksStr = vm.envString("HOOKS");

        Aori aori = Aori(payable(proxyAddress));

        string[] memory parts = vm.split(hooksStr, ",");

        console.log("=== Add Hooks ===");
        console.log("Aori:", proxyAddress);
        console.log("Hooks to add:", parts.length);

        vm.startBroadcast(ownerPrivateKey);

        for (uint256 i = 0; i < parts.length; i++) {
            address hook = vm.parseAddress(parts[i]);
            aori.addAllowedHook(hook);
            console.log("Added hook:", hook);
        }

        vm.stopBroadcast();
    }
}

/**
 * @title AddSupportedChains
 * @notice Add supported chain EIDs
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key
 *   - AORI_PROXY_ADDRESS: Aori proxy address
 *   - CHAIN_EIDS: Comma-separated chain EIDs
 */
contract AddSupportedChains is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey,, address proxyAddress) = _loadOwnerAndProxy();
        string memory eidsStr = vm.envString("CHAIN_EIDS");

        Aori aori = Aori(payable(proxyAddress));

        string[] memory parts = vm.split(eidsStr, ",");

        console.log("=== Add Supported Chains ===");
        console.log("Aori:", proxyAddress);
        console.log("Chains to add:", parts.length);

        vm.startBroadcast(ownerPrivateKey);

        for (uint256 i = 0; i < parts.length; i++) {
            uint32 eid = uint32(vm.parseUint(parts[i]));
            aori.addSupportedChain(eid);
            console.log("Added chain:", eid);
        }

        vm.stopBroadcast();
    }
}
