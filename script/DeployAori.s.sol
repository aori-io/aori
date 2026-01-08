// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "./BaseScript.sol";

/**
 * @title DeployAori
 * @notice Deploy Aori contract to a single chain with UUPS proxy pattern
 * @dev Uses CREATE3 for deterministic addresses across all chains
 *
 * Usage:
 *   forge script script/DeployAori.s.sol:DeployAori \
 *     --rpc-url $RPC_URL \
 *     --broadcast --verify
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Deployer private key
 *   - OWNER_ADDRESS: Contract owner (multisig recommended)
 *   - MAX_FILLS_PER_SETTLE: Max orders per settlement (default: 100)
 *   - DEPLOY_SALT: Salt for CREATE3 deployment (default: "aori-v1")
 *   - INITIAL_SOLVERS: Comma-separated solver addresses (optional)
 *   - INITIAL_HOOKS: Comma-separated hook addresses (optional)
 *   - SUPPORTED_EIDS: Comma-separated supported chain EIDs (optional)
 */
contract DeployAori is BaseScript {
    function run() external {
        // Load deployer key
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Aori Deployment (CREATE3) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // Get chain configuration
        ChainConfig memory config = _getCurrentChainConfig();
        console.log("Chain:", config.name);
        console.log("LayerZero EID:", config.eid);
        console.log("LZ Endpoint:", config.endpoint);

        // Load deployment configuration
        (address owner, uint16 maxFillsPerSettle, bytes32 implSalt, bytes32 proxySalt) = _loadDeployConfig();
        console.log("Owner:", owner);
        console.log("Max Fills Per Settle:", maxFillsPerSettle);

        // Parse optional arrays from environment
        address[] memory initialSolvers = _parseAddressArray("INITIAL_SOLVERS");
        address[] memory initialHooks = _parseAddressArray("INITIAL_HOOKS");
        uint32[] memory supportedChains = _parseUint32Array("SUPPORTED_EIDS");

        // Add current chain to supported chains if not already included
        supportedChains = _ensureCurrentChainSupported(supportedChains, config.eid);

        // Show expected addresses before deployment (same on ALL chains for same deployer!)
        (address expectedImpl, address expectedProxy) = _computeCreate3Addresses(deployer, implSalt, proxySalt);
        console.log("");
        console.log("Expected Implementation (same on all chains):", expectedImpl);
        console.log("Expected Proxy (same on all chains):", expectedProxy);

        // Check if already deployed - skip if so
        if (_isDeployed(expectedProxy)) {
            console.log("");
            console.log("=== SKIPPING: Already Deployed ===");
            console.log("Proxy already exists at:", expectedProxy);
            console.log("Chain:", config.name);
            console.log("");
            console.log("To force redeploy, use a different DEPLOY_SALT");
            return;
        }

        console.log("");
        console.log("Initial Solvers:", initialSolvers.length);
        console.log("Initial Hooks:", initialHooks.length);
        console.log("Supported Chains:", supportedChains.length);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy with CREATE3 for deterministic addresses across ALL chains
        (Aori aori, address implementation) = _deployAoriCreate3(
            config.endpoint, config.eid, owner, maxFillsPerSettle, initialSolvers, initialHooks, supportedChains, implSalt, proxySalt
        );

        vm.stopBroadcast();

        // Verify addresses match expected
        require(implementation == expectedImpl, "Implementation address mismatch!");
        require(address(aori) == expectedProxy, "Proxy address mismatch!");

        // Log deployment summary
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Implementation:", implementation);
        console.log("Proxy (Aori):", address(aori));
        console.log("Owner:", aori.owner());
        console.log("ENDPOINT_ID:", aori.ENDPOINT_ID());
        console.log("");
        console.log("These addresses will be the SAME on ALL chains with the same DEPLOY_SALT!");
    }

    /// @notice Parse comma-separated address array from environment variable
    function _parseAddressArray(
        string memory envVar
    ) internal view returns (address[] memory) {
        string memory value = vm.envOr(envVar, string(""));
        if (bytes(value).length == 0) {
            return new address[](0);
        }

        // Split by comma and parse addresses
        string[] memory parts = vm.split(value, ",");
        address[] memory addresses = new address[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            addresses[i] = vm.parseAddress(parts[i]);
        }
        return addresses;
    }

    /// @notice Parse comma-separated uint32 array from environment variable
    function _parseUint32Array(
        string memory envVar
    ) internal view returns (uint32[] memory) {
        string memory value = vm.envOr(envVar, string(""));
        if (bytes(value).length == 0) {
            return new uint32[](0);
        }

        // Split by comma and parse uint32s
        string[] memory parts = vm.split(value, ",");
        uint32[] memory values = new uint32[](parts.length);
        for (uint256 i = 0; i < parts.length; i++) {
            values[i] = uint32(vm.parseUint(parts[i]));
        }
        return values;
    }

    /// @notice Ensure current chain EID is in supported chains array
    function _ensureCurrentChainSupported(
        uint32[] memory chains,
        uint32 currentEid
    ) internal pure returns (uint32[] memory) {
        // Check if already included
        for (uint256 i = 0; i < chains.length; i++) {
            if (chains[i] == currentEid) {
                return chains;
            }
        }

        // Add current chain
        uint32[] memory newChains = new uint32[](chains.length + 1);
        for (uint256 i = 0; i < chains.length; i++) {
            newChains[i] = chains[i];
        }
        newChains[chains.length] = currentEid;
        return newChains;
    }
}

/**
 * @title PreviewDeployment
 * @notice Preview expected deployment addresses without deploying
 * @dev Use this to verify addresses before deployment
 */
contract PreviewDeployment is BaseScript {
    function run() external view {
        console.log("=== Preview Deployment Addresses (CREATE3) ===");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        (address owner, uint16 maxFillsPerSettle, bytes32 implSalt, bytes32 proxySalt) = _loadDeployConfig();

        // CREATE3 addresses depend on deployer + salt (factory hashes salt with msg.sender)
        (address expectedImpl, address expectedProxy) = _computeCreate3Addresses(deployer, implSalt, proxySalt);

        console.log("Owner:", owner);
        console.log("Max Fills:", maxFillsPerSettle);
        console.log("");
        console.log("With DEPLOY_SALT from environment:");
        console.log("  Implementation will be at:", expectedImpl);
        console.log("  Proxy will be at:", expectedProxy);
        console.log("");
        console.log("These addresses will be IDENTICAL on ALL chains!");
        console.log("");

        // Show for all chains
        bool isMainnet = vm.envOr("MAINNET", false);
        ChainConfig[] memory chains = isMainnet ? _getMainnetChains() : _getTestnetChains();

        console.log("Target chains:");
        for (uint256 i = 0; i < chains.length; i++) {
            console.log("  -", chains[i].name);
            console.log("    EID:", chains[i].eid);
        }
    }
}
