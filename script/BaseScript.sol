// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "forge-std/Script.sol";
import { Aori } from "../contracts/Aori.sol";
import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**
 * @title BaseScript
 * @notice Shared configuration and utilities for Aori deployment scripts
 * @dev Contains chain configs for mainnet and testnet deployments
 *
 * ## Cross-Chain Deterministic Deployment
 *
 * This script uses CREATE3 to deploy contracts at the same address across all chains.
 * CREATE3 derives the address only from the salt, not the bytecode, allowing different
 * bytecode (with chain-specific immutables like ENDPOINT_ID) to be deployed at the same address.
 *
 * How it works:
 * 1. Deploy a minimal proxy via CREATE2 (same address everywhere)
 * 2. That proxy deploys the actual contract via CREATE (nonce-based)
 * 3. Since proxy address is deterministic and nonce is always 1, final address is deterministic
 */
abstract contract BaseScript is Script {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Aori CREATE3 factory for deterministic cross-chain deployments
    /// @dev Deployed at same address on 48+ chains: https://github.com/aori-io/create3-factory
    address constant CREATE3_FACTORY = 0x2Dfcc7415D89af828cbef005F0d072D8b3F23183;

    /// @notice LayerZero EndpointV2 address on mainnets
    address constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;

    /// @notice LayerZero EndpointV2 address on testnets
    address constant LZ_ENDPOINT_TESTNET = 0x6EDCE65403992e310A62460808c4b910D972f10f;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     CHAIN CONFIGURATION                    */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    struct ChainConfig {
        string name;
        uint256 chainId;
        uint32 eid;
        address endpoint;
        string rpcEnvVar;
        bool isTestnet;
    }

    /// @notice Get all mainnet chain configurations
    /// @dev Chains from https://docs.aori.io/protocol/deployments
    function _getMainnetChains() internal pure returns (ChainConfig[] memory) {
        ChainConfig[] memory chains = new ChainConfig[](8);

        chains[0] = ChainConfig({
            name: "ethereum", chainId: 1, eid: 30101, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "ETHEREUM_RPC_URL", isTestnet: false
        });

        chains[1] = ChainConfig({
            name: "base", chainId: 8453, eid: 30184, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "BASE_RPC_URL", isTestnet: false
        });

        chains[2] = ChainConfig({
            name: "arbitrum", chainId: 42161, eid: 30110, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "ARBITRUM_RPC_URL", isTestnet: false
        });

        chains[3] = ChainConfig({
            name: "optimism", chainId: 10, eid: 30111, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "OPTIMISM_RPC_URL", isTestnet: false
        });

        chains[4] = ChainConfig({
            name: "bsc", chainId: 56, eid: 30102, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "BSC_RPC_URL", isTestnet: false
        });

        chains[5] = ChainConfig({
            name: "plasma",
            chainId: 9745,
            eid: 30383,
            endpoint: LZ_ENDPOINT_MAINNET, // TODO: Verify endpoint address
            rpcEnvVar: "PLASMA_RPC_URL",
            isTestnet: false
        });

        chains[6] = ChainConfig({
            name: "monad",
            chainId: 143,
            eid: 30390,
            endpoint: LZ_ENDPOINT_MAINNET, // TODO: Verify endpoint address
            rpcEnvVar: "MONAD_RPC_URL",
            isTestnet: false
        });

        chains[7] = ChainConfig({
            name: "stable",
            chainId: 988,
            eid: 30396,
            endpoint: LZ_ENDPOINT_MAINNET, // TODO: Verify endpoint address
            rpcEnvVar: "STABLE_RPC_URL",
            isTestnet: false
        });

        return chains;
    }

    /// @notice Get all testnet chain configurations
    function _getTestnetChains() internal pure returns (ChainConfig[] memory) {
        ChainConfig[] memory chains = new ChainConfig[](4);

        chains[0] = ChainConfig({
            name: "sepolia", chainId: 11155111, eid: 40161, endpoint: LZ_ENDPOINT_TESTNET, rpcEnvVar: "SEPOLIA_RPC_URL", isTestnet: true
        });

        chains[1] = ChainConfig({
            name: "base-sepolia",
            chainId: 84532,
            eid: 40245,
            endpoint: LZ_ENDPOINT_TESTNET,
            rpcEnvVar: "BASE_SEPOLIA_RPC_URL",
            isTestnet: true
        });

        chains[2] = ChainConfig({
            name: "arbitrum-sepolia",
            chainId: 421614,
            eid: 40231,
            endpoint: LZ_ENDPOINT_TESTNET,
            rpcEnvVar: "ARBITRUM_SEPOLIA_RPC_URL",
            isTestnet: true
        });

        chains[3] = ChainConfig({
            name: "optimism-sepolia",
            chainId: 11155420,
            eid: 40232,
            endpoint: LZ_ENDPOINT_TESTNET,
            rpcEnvVar: "OPTIMISM_SEPOLIA_RPC_URL",
            isTestnet: true
        });

        return chains;
    }

    /// @notice Get chain config by chain ID
    function _getChainConfig(
        uint256 chainId
    ) internal pure returns (ChainConfig memory) {
        // Check mainnets
        ChainConfig[] memory mainnets = _getMainnetChains();
        for (uint256 i = 0; i < mainnets.length; i++) {
            if (mainnets[i].chainId == chainId) {
                return mainnets[i];
            }
        }

        // Check testnets
        ChainConfig[] memory testnets = _getTestnetChains();
        for (uint256 i = 0; i < testnets.length; i++) {
            if (testnets[i].chainId == chainId) {
                return testnets[i];
            }
        }

        revert("Chain not supported");
    }

    /// @notice Get current chain config based on block.chainid
    function _getCurrentChainConfig() internal view returns (ChainConfig memory) {
        return _getChainConfig(block.chainid);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    DEPLOYMENT HELPERS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Load deployment configuration from environment variables
    function _loadDeployConfig() internal view returns (address owner, uint16 maxFillsPerSettle, bytes32 implSalt, bytes32 proxySalt) {
        owner = vm.envAddress("OWNER_ADDRESS");
        maxFillsPerSettle = uint16(vm.envOr("MAX_FILLS_PER_SETTLE", uint256(200)));
        string memory saltStr = vm.envOr("DEPLOY_SALT", string("aori-v1"));

        // Two salts: one for implementation, one for proxy (both via CREATE3)
        implSalt = keccak256(abi.encodePacked(saltStr, "-impl"));
        proxySalt = keccak256(abi.encodePacked(saltStr, "-proxy"));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CREATE3 DEPLOYMENT                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Deploy contract using CREATE3 for deterministic cross-chain addresses
    /// @dev Address depends on deployer + salt, not bytecode - allows same address with different bytecode
    ///      Note: Aori factory hashes salt with msg.sender for namespacing
    /// @param salt Unique salt for this deployment
    /// @param bytecode Contract creation bytecode (can differ per chain)
    /// @return deployed The deployed contract address (same on all chains for same deployer + salt)
    function _deployCreate3(
        bytes32 salt,
        bytes memory bytecode
    ) internal returns (address deployed) {
        // Aori CREATE3 factory interface: deploy(bytes32 salt, bytes memory creationCode) returns (address)
        (bool success, bytes memory result) = CREATE3_FACTORY.call(abi.encodeWithSignature("deploy(bytes32,bytes)", salt, bytecode));
        require(success, "CREATE3 deployment failed");
        deployed = abi.decode(result, (address));
    }

    /// @notice Compute the deterministic address for a CREATE3 deployment
    /// @dev Uses factory's getDeployed function since salt is hashed with deployer
    /// @param deployer The deployer address (msg.sender during deploy)
    /// @param salt The deployment salt
    /// @return The address where the contract will be deployed
    function _computeCreate3Address(
        address deployer,
        bytes32 salt
    ) internal view returns (address) {
        // Aori CREATE3 factory: getDeployed(address deployer, bytes32 salt) returns (address)
        (bool success, bytes memory result) =
            CREATE3_FACTORY.staticcall(abi.encodeWithSignature("getDeployed(address,bytes32)", deployer, salt));
        require(success, "getDeployed call failed");
        return abi.decode(result, (address));
    }

    /// @notice Check if CREATE3 factory is deployed on this chain
    function _isCreate3Available() internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(0x2Dfcc7415D89af828cbef005F0d072D8b3F23183) }
        return size > 0;
    }

    /// @notice Check if contract is already deployed at address
    function _isDeployed(
        address addr
    ) internal view returns (bool) {
        uint256 size;
        assembly { size := extcodesize(addr) }
        return size > 0;
    }

    /// @notice Full deployment with CREATE3 for deterministic addresses across ALL chains
    /// @dev CREATE3 derives address from salt only, not bytecode.
    ///      This enables the same address on ALL chains regardless of endpoint/eid differences.
    function _deployAoriCreate3(
        address endpoint,
        uint32 eid,
        address owner,
        uint16 maxFillsPerSettle,
        address[] memory initialSolvers,
        address[] memory initialHooks,
        uint32[] memory supportedChains,
        bytes32 implSalt,
        bytes32 proxySalt
    ) internal returns (Aori aori, address implementation) {
        require(_isCreate3Available(), "CREATE3 factory not deployed on this chain");

        // Deploy implementation via CREATE3
        bytes memory implBytecode = abi.encodePacked(type(Aori).creationCode, abi.encode(endpoint, eid));
        implementation = _deployCreate3(implSalt, implBytecode);
        console.log("Implementation deployed via CREATE3 at:", implementation);

        // Deploy proxy via CREATE3
        bytes memory initData = abi.encodeCall(Aori.initialize, (owner, maxFillsPerSettle, initialSolvers, initialHooks, supportedChains));
        bytes memory proxyBytecode = abi.encodePacked(type(ERC1967Proxy).creationCode, abi.encode(implementation, initData));
        address proxy = _deployCreate3(proxySalt, proxyBytecode);
        console.log("Proxy deployed via CREATE3 at:", proxy);

        aori = Aori(payable(proxy));
    }

    /// @notice Compute expected CREATE3 addresses for deterministic deployment
    /// @dev CREATE3 addresses depend only on the salt, not the bytecode
    /// @param implSalt Salt for implementation deployment
    /// @param proxySalt Salt for proxy deployment
    /// @return expectedImpl Expected implementation address (same on all chains)
    /// @return expectedProxy Expected proxy address (same on all chains)
    function _computeCreate3Addresses(
        address deployer,
        bytes32 implSalt,
        bytes32 proxySalt
    ) internal view returns (address expectedImpl, address expectedProxy) {
        expectedImpl = _computeCreate3Address(deployer, implSalt);
        expectedProxy = _computeCreate3Address(deployer, proxySalt);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     PEER CONFIGURATION                     */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /// @notice Convert address to bytes32 peer format
    function _addressToBytes32(
        address addr
    ) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(addr)));
    }

    /// @notice Set peer for a remote chain
    function _setPeer(
        Aori aori,
        uint32 remoteEid,
        address remoteAori
    ) internal {
        aori.setPeer(remoteEid, _addressToBytes32(remoteAori));
        console.log("Set peer for EID", remoteEid, "to", remoteAori);
    }

    /// @notice Add supported chain
    function _addSupportedChain(
        Aori aori,
        uint32 eid
    ) internal {
        aori.addSupportedChain(eid);
        console.log("Added supported chain:", eid);
    }
}
