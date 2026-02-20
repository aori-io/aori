// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "./BaseScript.sol";

/**
 * @title DeployMultichain
 * @notice Deploy Aori to multiple chains with automatic peer wiring
 * @dev This script is designed to be run multiple times, once per chain.
 *      Use the same DEPLOY_SALT across all chains for deterministic proxy addresses.
 *
 * Deployment Strategy:
 *   1. Run this script on each target chain (testnets first, then mainnets)
 *   2. After all deployments, run ConfigurePeers.s.sol to wire peers
 *
 * Usage (testnet deployment):
 *   # Deploy to each testnet
 *   forge script script/DeployMultichain.s.sol:DeployMultichain \
 *     --rpc-url $SEPOLIA_RPC_URL --broadcast --verify
 *   forge script script/DeployMultichain.s.sol:DeployMultichain \
 *     --rpc-url $BASE_SEPOLIA_RPC_URL --broadcast --verify
 *   forge script script/DeployMultichain.s.sol:DeployMultichain \
 *     --rpc-url $ARBITRUM_SEPOLIA_RPC_URL --broadcast --verify
 *   forge script script/DeployMultichain.s.sol:DeployMultichain \
 *     --rpc-url $OPTIMISM_SEPOLIA_RPC_URL --broadcast --verify
 *
 * Usage (mainnet deployment):
 *   MAINNET=true forge script script/DeployMultichain.s.sol:DeployMultichain \
 *     --rpc-url $ETHEREUM_RPC_URL --broadcast --verify
 *
 * Environment Variables:
 *   - PRIVATE_KEY: Deployer private key
 *   - OWNER_ADDRESS: Contract owner address
 *   - MAX_FILLS_PER_SETTLE: Max orders per settlement (default: 100)
 *   - DEPLOY_SALT: Salt for CREATE3 (must be same across all chains)
 *   - MAINNET: Set to "true" for mainnet deployment
 *   - AORI_PROXY_ADDRESS: Expected proxy address (for verification, optional)
 */
contract DeployMultichain is BaseScript {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("=== Aori Multichain Deployment (CREATE3) ===");
        console.log("Deployer:", deployer);
        console.log("Chain ID:", block.chainid);

        // Get chain configuration
        ChainConfig memory config = _getCurrentChainConfig();
        console.log("Chain:", config.name);
        console.log("Is Testnet:", config.isTestnet);
        console.log("LayerZero EID:", config.eid);

        // Determine target chains based on environment
        bool isMainnet = vm.envOr("MAINNET", false);
        ChainConfig[] memory allChains = isMainnet ? _getMainnetChains() : _getTestnetChains();

        // Validate we're on the right network type
        require(config.isTestnet != isMainnet, "Chain type mismatch with MAINNET env var");

        // Load deployment configuration
        (address owner, uint16 maxFillsPerSettle, bytes32 implSalt, bytes32 proxySalt) = _loadDeployConfig();

        // Prepare supported chains (all chains in the deployment set)
        uint32[] memory supportedChains = new uint32[](allChains.length);
        for (uint256 i = 0; i < allChains.length; i++) {
            supportedChains[i] = allChains[i].eid;
        }

        // Empty initial arrays (can be configured post-deployment)
        address[] memory initialSolvers = new address[](0);
        address[] memory initialHooks = new address[](0);

        // Show expected addresses (same on ALL chains!)
        (address expectedImpl, address expectedProxy) = _computeCreate3Addresses(deployer, implSalt, proxySalt);
        console.log("");
        console.log("Expected addresses (same on ALL chains):");
        console.log("  Implementation:", expectedImpl);
        console.log("  Proxy:", expectedProxy);

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
        console.log("Owner:", owner);
        console.log("Max Fills:", maxFillsPerSettle);
        console.log("Supported Chains:", supportedChains.length);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy with CREATE3 for deterministic addresses across ALL chains
        // Split args into locals to avoid stack-too-deep in legacy codegen (coverage builds)
        address endpoint = config.endpoint;
        uint32 eid = config.eid;
        (Aori aori, address implementation) = _deployAoriCreate3(
            endpoint, eid, owner, maxFillsPerSettle, initialSolvers, initialHooks, supportedChains, implSalt, proxySalt
        );

        vm.stopBroadcast();

        // Verify addresses match expected
        require(implementation == expectedImpl, "Implementation address mismatch!");
        require(address(aori) == expectedProxy, "Proxy address mismatch!");

        // Log deployment info
        console.log("");
        console.log("=== Deployment Complete ===");
        console.log("Implementation:", implementation);
        console.log("Proxy (Aori):", address(aori));
        console.log("");
        console.log("IMPORTANT: This address is IDENTICAL on ALL chains!");
        console.log("");
        console.log("Next steps:");
        console.log("1. Deploy to remaining chains using same DEPLOY_SALT");
        console.log("2. Run ConfigurePeers.s.sol to wire peers between chains");
        console.log("   (Since addresses are the same, peers can be pre-configured!)");

        // Output deployment data for peer configuration
        console.log("");
        console.log("=== Peer Configuration Data ===");
        console.log("Chain EID:", config.eid);
        console.log("Aori Address:", address(aori));
        console.log("Peer bytes32:", vm.toString(_addressToBytes32(address(aori))));
    }
}

/**
 * @title PrintDeploymentInfo
 * @notice Utility to print expected deployment addresses before deploying
 * @dev With CREATE3, addresses are IDENTICAL across all chains
 */
contract PrintDeploymentInfo is BaseScript {
    function run() external view {
        console.log("=== Expected Deployment Addresses (CREATE3) ===");

        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        (address owner, uint16 maxFillsPerSettle, bytes32 implSalt, bytes32 proxySalt) = _loadDeployConfig();
        (address expectedImpl, address expectedProxy) = _computeCreate3Addresses(deployer, implSalt, proxySalt);

        console.log("Owner:", owner);
        console.log("Max Fills:", maxFillsPerSettle);
        console.log("");
        console.log("CREATE3 Deterministic Addresses:");
        console.log("  Implementation:", expectedImpl);
        console.log("  Proxy:", expectedProxy);
        console.log("");
        console.log("These addresses will be IDENTICAL on ALL chains!");

        bool isMainnet = vm.envOr("MAINNET", false);
        ChainConfig[] memory chains = isMainnet ? _getMainnetChains() : _getTestnetChains();

        console.log("");
        console.log("Target chains:");
        for (uint256 i = 0; i < chains.length; i++) {
            console.log("  -", chains[i].name);
            console.log("    Chain ID:", chains[i].chainId);
            console.log("    EID:", chains[i].eid);
        }
    }
}

/**
 * @title VerifyDeployments
 * @notice Verify Aori deployments across multiple chains
 * @dev Run on each chain to verify deployment state
 */
contract VerifyDeployments is BaseScript {
    function run() external view {
        address proxyAddress = vm.envAddress("AORI_PROXY_ADDRESS");
        Aori aori = Aori(payable(proxyAddress));

        ChainConfig memory config = _getCurrentChainConfig();

        console.log("=== Verifying Deployment on", config.name, "===");
        console.log("Proxy Address:", proxyAddress);
        console.log("Owner:", aori.owner());
        console.log("ENDPOINT_ID:", aori.ENDPOINT_ID());

        // Check supported chains
        bool isMainnet = vm.envOr("MAINNET", false);
        ChainConfig[] memory allChains = isMainnet ? _getMainnetChains() : _getTestnetChains();

        console.log("");
        console.log("=== Supported Chains ===");
        for (uint256 i = 0; i < allChains.length; i++) {
            bool supported = aori.isSupportedChain(allChains[i].eid);
            console.log(allChains[i].name, ":", supported ? "YES" : "NO");
        }

        console.log("");
        console.log("=== Peer Configuration ===");
        console.log("Note: Peers must be configured separately via ConfigurePeers.s.sol");
    }
}
