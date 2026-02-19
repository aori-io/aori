// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

/**
 * ForkUpgradeTests - Tests UUPS upgrade against live deployed proxies via mainnet forks
 *
 * Uses vm.createFork + vm.prank(owner) to simulate upgrades on real on-chain state.
 * No private key needed - impersonates the multisig owner.
 * Reuses chain configs from BaseScript to stay DRY.
 *
 * Loops through all mainnet chains, deploying a new implementation and upgrading
 * the proxy on each fork. Verifies state preservation and access control.
 */
import "forge-std/Test.sol";
import { Aori } from "../../contracts/Aori.sol";
import { BaseScript } from "../../script/BaseScript.sol";

contract ForkUpgradeTests is Test, BaseScript {
    /// @notice Default deployed proxy address (same on all chains via CREATE3)
    address constant DEFAULT_PROXY = 0x7417dE230d7635C7906fEb6aE73d0C551e2aF339;

    /// @notice Default on-chain owner (multisig)
    address constant DEFAULT_OWNER = 0x1c6DDEbD6C7BAf821395bBeBDc8B3678B98950e5;

    /// @notice Resolved addresses (from env or defaults)
    address internal PROXY;
    address internal OWNER;

    function setUp() public {
        PROXY = vm.envOr("AORI_PROXY_ADDRESS", DEFAULT_PROXY);
        OWNER = vm.envOr("OWNER_ADDRESS", DEFAULT_OWNER);
    }

    /// @notice Core upgrade test logic run against a forked chain
    function _testForkUpgrade(ChainConfig memory config) internal {
        // Create fork
        string memory rpcUrl = vm.envString(config.rpcEnvVar);
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        Aori aori = Aori(payable(PROXY));

        // --- Pre-upgrade state snapshot ---
        address onChainOwner = aori.owner();
        uint32 preEndpointId = aori.ENDPOINT_ID();
        bool prePaused = aori.paused();

        // If OWNER was set from env/default, verify it matches on-chain
        assertEq(onChainOwner, OWNER, string.concat(config.name, ": env OWNER doesn't match on-chain owner"));
        assertEq(preEndpointId, config.eid, string.concat(config.name, ": ENDPOINT_ID mismatch"));
        assertFalse(prePaused, string.concat(config.name, ": should not be paused"));

        // Read implementation slot before upgrade (ERC1967)
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address oldImpl = address(uint160(uint256(vm.load(PROXY, implSlot))));
        assertTrue(oldImpl != address(0), string.concat(config.name, ": old impl should not be zero"));

        // --- Deploy new implementation ---
        Aori newImpl = new Aori(config.endpoint, config.eid);
        address newImplAddr = address(newImpl);
        assertTrue(newImplAddr != oldImpl, string.concat(config.name, ": new impl should differ from old"));

        // --- Perform upgrade as owner ---
        vm.prank(onChainOwner);
        aori.upgradeToAndCall(newImplAddr, "");

        // --- Post-upgrade verification ---

        // Implementation slot updated
        address actualImpl = address(uint160(uint256(vm.load(PROXY, implSlot))));
        assertEq(actualImpl, newImplAddr, string.concat(config.name, ": impl slot not updated"));

        // State preserved
        assertEq(aori.owner(), onChainOwner, string.concat(config.name, ": owner changed after upgrade"));
        assertEq(aori.ENDPOINT_ID(), config.eid, string.concat(config.name, ": ENDPOINT_ID changed after upgrade"));
        assertFalse(aori.paused(), string.concat(config.name, ": paused state changed after upgrade"));

        // Supported chains still work
        assertTrue(aori.isSupportedChain(config.eid), string.concat(config.name, ": local chain not supported after upgrade"));

        // Non-owner cannot upgrade
        vm.prank(address(0xdead));
        vm.expectRevert();
        aori.upgradeToAndCall(oldImpl, "");
    }

    function testForkUpgrade_AllMainnets() public {
        ChainConfig[] memory chains = _getMainnetChains();
        for (uint256 i = 0; i < chains.length; i++) {
            _testForkUpgrade(chains[i]);
        }
    }
}
