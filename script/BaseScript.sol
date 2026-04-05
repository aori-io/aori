// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

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

    /// @notice CREATE3 factory runtime bytecode, used with vm.etch when Forge fork doesn't load it
    bytes constant CREATE3_FACTORY_BYTECODE =
        hex"6080604052600436106100295760003560e01c806350f1c4641461002e578063cdcb760a14610077575b600080fd5b34801561003a57600080fd5b5061004e610049366004610489565b61008a565b60405173ffffffffffffffffffffffffffffffffffffffff909116815260200160405180910390f35b61004e6100853660046104fd565b6100ee565b6040517fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606084901b166020820152603481018290526000906054016040516020818303038152906040528051906020012091506100e78261014c565b9392505050565b6040517fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003360601b166020820152603481018390526000906054016040516020818303038152906040528051906020012092506100e78383346102b2565b604080518082018252601081527f67363d3d37363d34f03d5260086018f30000000000000000000000000000000060209182015290517fff00000000000000000000000000000000000000000000000000000000000000918101919091527fffffffffffffffffffffffffffffffffffffffff0000000000000000000000003060601b166021820152603581018290527f21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f60558201526000908190610228906075015b6040516020818303038152906040528051906020012090565b6040517fd69400000000000000000000000000000000000000000000000000000000000060208201527fffffffffffffffffffffffffffffffffffffffff000000000000000000000000606083901b1660228201527f010000000000000000000000000000000000000000000000000000000000000060368201529091506100e79060370161020f565b6000806040518060400160405280601081526020017f67363d3d37363d34f03d5260086018f30000000000000000000000000000000081525090506000858251602084016000f5905073ffffffffffffffffffffffffffffffffffffffff811661037d576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601160248201527f4445504c4f594d454e545f4641494c454400000000000000000000000000000060448201526064015b60405180910390fd5b6103868661014c565b925060008173ffffffffffffffffffffffffffffffffffffffff1685876040516103b091906105d6565b60006040518083038185875af1925050503d80600081146103ed576040519150601f19603f3d011682016040523d82523d6000602084013e6103f2565b606091505b50509050808015610419575073ffffffffffffffffffffffffffffffffffffffff84163b15155b61047f576040517f08c379a000000000000000000000000000000000000000000000000000000000815260206004820152601560248201527f494e495449414c495a4154494f4e5f4641494c454400000000000000000000006044820152606401610374565b5050509392505050565b6000806040838503121561049c57600080fd5b823573ffffffffffffffffffffffffffffffffffffffff811681146104c057600080fd5b946020939093013593505050565b7f4e487b7100000000000000000000000000000000000000000000000000000000600052604160045260246000fd5b6000806040838503121561051057600080fd5b82359150602083013567ffffffffffffffff8082111561052f57600080fd5b818501915085601f83011261054357600080fd5b813581811115610555576105556104ce565b604051601f82017fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe0908116603f0116810190838211818310171561059b5761059b6104ce565b816040528281528860208487010111156105b457600080fd5b8260208601602083013760006020848301015280955050505050509250929050565b6000825160005b818110156105f757602081860181015185830152016105dd565b50600092019182525091905056fea26469706673582212205ab6ef39bc142c87ba390066141e2f3c24f0eb24586885ac84e6b0747ed2e83664736f6c63430008140033";

    /// @notice LayerZero EndpointV2 address on mostmainnets
    address constant LZ_ENDPOINT_MAINNET = 0x1a44076050125825900e736c501f859c50fE728c;

    /// @notice LayerZero EndpointV2 address on other mainnets
    address constant LZ_ENDPOINT_2_MAINNET = 0x6F475642a6e85809B1c36Fa62763669b1b48DD5B;

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
            name: "ethereum",
            chainId: 1,
            eid: 30101,
            endpoint: LZ_ENDPOINT_MAINNET,
            rpcEnvVar: "ETHEREUM_RPC_URL",
            isTestnet: false
        });

        chains[1] = ChainConfig({
            name: "base",
            chainId: 8453,
            eid: 30184,
            endpoint: LZ_ENDPOINT_MAINNET,
            rpcEnvVar: "BASE_RPC_URL",
            isTestnet: false
        });

        chains[2] = ChainConfig({
            name: "arbitrum",
            chainId: 42161,
            eid: 30110,
            endpoint: LZ_ENDPOINT_MAINNET,
            rpcEnvVar: "ARBITRUM_RPC_URL",
            isTestnet: false
        });

        chains[3] = ChainConfig({
            name: "optimism",
            chainId: 10,
            eid: 30111,
            endpoint: LZ_ENDPOINT_MAINNET,
            rpcEnvVar: "OPTIMISM_RPC_URL",
            isTestnet: false
        });

        chains[4] =
            ChainConfig({ name: "bsc", chainId: 56, eid: 30102, endpoint: LZ_ENDPOINT_MAINNET, rpcEnvVar: "BSC_RPC_URL", isTestnet: false });

        chains[5] = ChainConfig({
            name: "plasma",
            chainId: 9745,
            eid: 30383,
            endpoint: LZ_ENDPOINT_2_MAINNET,
            rpcEnvVar: "PLASMA_RPC_URL",
            isTestnet: false
        });

        chains[6] = ChainConfig({
            name: "monad",
            chainId: 143,
            eid: 30390,
            endpoint: LZ_ENDPOINT_2_MAINNET,
            rpcEnvVar: "MONAD_RPC_URL",
            isTestnet: false
        });

        chains[7] = ChainConfig({
            name: "stable",
            chainId: 988,
            eid: 30396,
            endpoint: LZ_ENDPOINT_2_MAINNET,
            rpcEnvVar: "STABLE_RPC_URL",
            isTestnet: false
        });

        return chains;
    }

    /// @notice Get all testnet chain configurations
    function _getTestnetChains() internal pure returns (ChainConfig[] memory) {
        ChainConfig[] memory chains = new ChainConfig[](4);

        chains[0] = ChainConfig({
            name: "sepolia",
            chainId: 11155111,
            eid: 40161,
            endpoint: LZ_ENDPOINT_TESTNET,
            rpcEnvVar: "SEPOLIA_RPC_URL",
            isTestnet: true
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
        string memory saltStr = vm.envString("DEPLOY_SALT");

        // Two salts: one for implementation, one for proxy (both via CREATE3)
        implSalt = keccak256(abi.encodePacked(saltStr, "-impl"));
        proxySalt = keccak256(abi.encodePacked(saltStr, "-proxy"));
    }

    /// @notice Load owner private key and proxy address from environment (for admin scripts)
    function _loadOwnerAndProxy() internal view returns (uint256 privateKey, address owner, address proxy) {
        privateKey = vm.envUint("PRIVATE_KEY");
        owner = vm.addr(privateKey);
        proxy = vm.envAddress("AORI_PROXY_ADDRESS");
    }

    /// @notice Verify caller is contract owner
    function _requireOwner(Aori aori, address caller) internal view {
        require(aori.owner() == caller, "Caller is not owner");
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
    function _deployCreate3(bytes32 salt, bytes memory bytecode) internal returns (address deployed) {
        // Aori CREATE3 factory interface: deploy(bytes32 salt, bytes memory creationCode) returns (address)
        (bool success, bytes memory result) = CREATE3_FACTORY.call(abi.encodeWithSignature("deploy(bytes32,bytes)", salt, bytecode));
        if (!success) {
            // Propagate the actual revert reason from the factory
            if (result.length > 0) {
                assembly { revert(add(result, 32), mload(result)) }
            }
            revert("CREATE3 deployment failed");
        }
        deployed = abi.decode(result, (address));
    }

    /// @notice Compute the deterministic address for a CREATE3 deployment
    /// @dev Pure Solidity implementation of the CREATE3 address derivation algorithm.
    ///      Matches the factory's getDeployed() logic without requiring a call to the factory.
    ///      Algorithm: factory namespaces salt with deployer, deploys a proxy via CREATE2,
    ///      then the proxy deploys the actual contract via CREATE (nonce 1).
    /// @param deployer The deployer address (msg.sender during deploy)
    /// @param salt The deployment salt
    /// @return The address where the contract will be deployed
    function _computeCreate3Address(address deployer, bytes32 salt) internal view returns (address) {
        // Aori CREATE3 factory: getDeployed(address deployer, bytes32 salt) returns (address)
        (bool success, bytes memory result) =
            CREATE3_FACTORY.staticcall(abi.encodeWithSignature("getDeployed(address,bytes32)", deployer, salt));
        require(success, "getDeployed call failed");
        return abi.decode(result, (address));
    }

    /// @notice Check if contract is already deployed at address
    function _isDeployed(
        address addr
    ) internal view returns (bool) {
        uint256 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }

    /// @notice Check if an Aori proxy is already deployed at address
    /// @dev Uses vm.rpc to query eth_getCode directly from the RPC, bypassing Forge's fork cache.
    ///      Some Forge nightly builds return extcodesize=0 on certain chain forks despite code existing.
    function _isAoriDeployed(
        address proxy
    ) internal returns (bool) {
        string memory addrStr = vm.toLowercase(vm.toString(proxy));
        string memory params = string(abi.encodePacked("[\"", addrStr, "\",\"latest\"]"));
        bytes memory rpcResult = vm.rpc("eth_getCode", params);
        // Empty code returns "0x" (4 bytes as abi-encoded string), deployed code is longer
        return rpcResult.length > 4;
    }

    /// @notice Ensure external dependencies have code visible in the fork
    /// @dev Some Forge nightly builds fail to load contract code on certain chain forks.
    ///      This uses vm.etch to set known bytecode where needed. Only affects simulation -
    ///      real broadcasts use the actual on-chain contracts.
    function _ensureForkDependencies(
        address endpoint
    ) internal {
        // Etch CREATE3 factory if fork doesn't see it
        if (!_isDeployed(CREATE3_FACTORY)) {
            console.log("Warning: CREATE3 factory not visible in fork, using vm.etch");
            vm.etch(CREATE3_FACTORY, CREATE3_FACTORY_BYTECODE);
        }
        // Etch LZ endpoint with minimal pass-through bytecode if fork doesn't see it.
        // Aori.initialize() calls endpoint.setDelegate() which needs code at this address.
        // Bytecode: PUSH1 0x01, PUSH0, MSTORE, PUSH1 0x20, PUSH0, RETURN (returns true)
        if (!_isDeployed(endpoint)) {
            console.log("Warning: LZ endpoint not visible in fork, using vm.etch");
            vm.etch(endpoint, hex"600160005260206000f3");
        }
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
        _ensureForkDependencies(endpoint);

        // Deploy implementation via CREATE3
        bytes memory implBytecode = abi.encodePacked(type(Aori).creationCode, abi.encode(endpoint, eid));
        implementation = _deployCreate3(implSalt, implBytecode);
        console.log("Implementation deployed via CREATE3 at:", implementation);

        // Deploy proxy via CREATE3
        bytes memory initData = abi.encodeCall(Aori.initialize, (owner, maxFillsPerSettle, initialSolvers, initialHooks, supportedChains, new address[](0)));
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
    function _setPeer(Aori aori, uint32 remoteEid, address remoteAori) internal {
        aori.setPeer(remoteEid, _addressToBytes32(remoteAori));
        console.log("Set peer for EID", remoteEid, "to", remoteAori);
    }

    /// @notice Add supported chain
    function _addSupportedChain(Aori aori, uint32 eid) internal {
        aori.addSupportedChain(eid);
        console.log("Added supported chain:", eid);
    }
}
