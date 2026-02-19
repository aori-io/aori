// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./BaseScript.sol";

/**
 * @title UpgradeAori
 * @notice Upgrade Aori proxy to a new implementation
 * @dev Uses UUPS upgradeToAndCall pattern
 *
 * Usage:
 *   AORI_PROXY_ADDRESS=0x... forge script script/UpgradeAori.s.sol:UpgradeAori \
 *     --rpc-url $RPC_URL --broadcast --verify
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Owner private key (must be contract owner)
 *   - AORI_PROXY_ADDRESS: Current Aori proxy address
 *   - NEW_IMPLEMENTATION: New implementation address (optional, deploys new if not set)
 *   - UPGRADE_CALL_DATA: Optional calldata for upgradeToAndCall (for V2 initialization)
 */
contract UpgradeAori is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey, address owner, address proxyAddress) = _loadOwnerAndProxy();
        Aori aori = Aori(payable(proxyAddress));
        ChainConfig memory config = _getCurrentChainConfig();

        console.log("=== Aori Upgrade ===");
        console.log("Chain:", config.name);
        console.log("Proxy:", proxyAddress);
        console.log("Current Owner:", aori.owner());
        console.log("Caller:", owner);

        _requireOwner(aori, owner);

        // Get or deploy new implementation
        address newImplementation = vm.envOr("NEW_IMPLEMENTATION", address(0));

        vm.startBroadcast(ownerPrivateKey);

        if (newImplementation == address(0)) {
            // Deploy new implementation
            console.log("Deploying new implementation...");
            Aori newImpl = new Aori(config.endpoint, config.eid);
            newImplementation = address(newImpl);
            console.log("New implementation deployed:", newImplementation);
        } else {
            console.log("Using provided implementation:", newImplementation);
        }

        // Get optional upgrade call data
        bytes memory upgradeCallData = vm.envOr("UPGRADE_CALL_DATA", bytes(""));

        // Perform upgrade
        console.log("Upgrading proxy...");
        aori.upgradeToAndCall(newImplementation, upgradeCallData);

        vm.stopBroadcast();

        console.log("");
        console.log("=== Upgrade Complete ===");
        console.log("New Implementation:", newImplementation);
        console.log("Proxy:", proxyAddress);
    }
}

/**
 * @title PrepareUpgrade
 * @notice Deploy new implementation without upgrading (for testing/verification)
 * @dev Use this to deploy and verify new implementation before upgrading
 */
contract PrepareUpgrade is BaseScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        ChainConfig memory config = _getCurrentChainConfig();

        console.log("=== Prepare Upgrade ===");
        console.log("Chain:", config.name);
        console.log("Endpoint:", config.endpoint);
        console.log("EID:", config.eid);

        vm.startBroadcast(deployerPrivateKey);

        Aori newImpl = new Aori(config.endpoint, config.eid);

        vm.stopBroadcast();

        console.log("");
        console.log("=== New Implementation Deployed ===");
        console.log("Address:", address(newImpl));
        console.log("");
        console.log("To upgrade, run UpgradeAori with:");
        console.log("  NEW_IMPLEMENTATION=", address(newImpl));
    }
}

/**
 * @title VerifyUpgrade
 * @notice Verify upgrade was successful
 * @dev Check that proxy points to expected implementation
 */
contract VerifyUpgrade is BaseScript {
    function run() external view {
        address proxyAddress = vm.envAddress("AORI_PROXY_ADDRESS");
        address expectedImpl = vm.envOr("EXPECTED_IMPLEMENTATION", address(0));

        Aori aori = Aori(payable(proxyAddress));
        ChainConfig memory config = _getCurrentChainConfig();

        console.log("=== Verify Upgrade ===");
        console.log("Chain:", config.name);
        console.log("Proxy:", proxyAddress);
        console.log("Owner:", aori.owner());
        console.log("ENDPOINT_ID:", aori.ENDPOINT_ID());

        // Read implementation slot (ERC1967)
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        bytes32 implBytes = vm.load(proxyAddress, implSlot);
        address currentImpl = address(uint160(uint256(implBytes)));

        console.log("Current Implementation:", currentImpl);

        if (expectedImpl != address(0)) {
            if (currentImpl == expectedImpl) {
                console.log("Implementation matches expected!");
            } else {
                console.log("WARNING: Implementation mismatch!");
                console.log("Expected:", expectedImpl);
            }
        }
    }
}

/**
 * @title UpgradeMultichain
 * @notice Upgrade Aori on multiple chains
 * @dev Run on each chain - deploys new impl and upgrades
 */
contract UpgradeMultichain is BaseScript {
    function run() external {
        (uint256 ownerPrivateKey, address owner, address proxyAddress) = _loadOwnerAndProxy();
        Aori aori = Aori(payable(proxyAddress));
        ChainConfig memory config = _getCurrentChainConfig();

        console.log("=== Multichain Upgrade ===");
        console.log("Chain:", config.name);
        console.log("Proxy:", proxyAddress);

        _requireOwner(aori, owner);

        vm.startBroadcast(ownerPrivateKey);

        // Deploy new implementation for this chain
        Aori newImpl = new Aori(config.endpoint, config.eid);
        console.log("New implementation:", address(newImpl));

        // Upgrade
        aori.upgradeToAndCall(address(newImpl), "");

        vm.stopBroadcast();

        console.log("Upgrade complete on", config.name);
        console.log("");
        console.log("Run this script on remaining chains to complete multichain upgrade.");
    }
}
