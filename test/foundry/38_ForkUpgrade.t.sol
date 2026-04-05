// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

/**
 * ForkUpgradeTests - Tests UUPS upgrade against live deployed proxies via mainnet forks
 *
 * Uses vm.createFork + vm.prank(owner) to simulate upgrades on real on-chain state.
 * No private key needed - impersonates the multisig owner.
 * Reuses chain configs from BaseScript to stay DRY.
 *
 * Deploys a MockAoriUpgraded (with a new getVersion() function) and upgrades the proxy.
 * Proves the upgrade actually took effect by calling the new function — which would
 * revert if the implementation hadn't changed.
 */
import "forge-std/Test.sol";
import { Aori } from "../../contracts/Aori.sol";
import { BaseScript } from "../../script/BaseScript.sol";
import { MockAoriUpgraded } from "./36_Upgrade.t.sol";

contract ForkUpgradeTests is Test, BaseScript {
    /// @notice Default deployed proxy address (same on all chains via CREATE3)
    address constant DEFAULT_PROXY = 0x7572F9CaC44b2Ed2567Ccd23A3d3dBdf165Cd8af;

    /// @notice Default on-chain owner
    address constant DEFAULT_OWNER = 0x9a19fbC43b65D02E6ccf6b56Af492A3389DF51AB;

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
        string memory rpcUrl = vm.envOr(config.rpcEnvVar, string(""));
        if (bytes(rpcUrl).length == 0) {
            emit log_string(string.concat("Skipping ", config.name, ": ", config.rpcEnvVar, " not set"));
            return;
        }
        uint256 forkId = vm.createFork(rpcUrl);
        vm.selectFork(forkId);

        Aori aori = Aori(payable(PROXY));

        // --- Pre-upgrade state snapshot ---
        address onChainOwner = aori.owner();
        uint32 preEndpointId = aori.ENDPOINT_ID();
        bool prePaused = aori.paused();

        assertEq(onChainOwner, OWNER, string.concat(config.name, ": env OWNER doesn't match on-chain owner"));
        assertEq(preEndpointId, config.eid, string.concat(config.name, ": ENDPOINT_ID mismatch"));
        assertFalse(prePaused, string.concat(config.name, ": should not be paused"));

        // V2 function must not exist before upgrade
        (bool preSuccess,) = PROXY.staticcall(abi.encodeWithSignature("getVersion()"));
        assertFalse(preSuccess, string.concat(config.name, ": getVersion() should not exist before upgrade"));

        // Read implementation slot before upgrade (ERC1967)
        bytes32 implSlot = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
        address oldImpl = address(uint160(uint256(vm.load(PROXY, implSlot))));
        assertTrue(oldImpl != address(0), string.concat(config.name, ": old impl should not be zero"));

        // --- Deploy V2 and upgrade ---
        MockAoriUpgraded newImpl = new MockAoriUpgraded(config.endpoint, config.eid);
        address newImplAddr = address(newImpl);

        vm.prank(onChainOwner);
        aori.upgradeToAndCall(newImplAddr, "");

        // --- Post-upgrade: V2 function must work ---
        MockAoriUpgraded v2 = MockAoriUpgraded(payable(PROXY));
        assertEq(v2.getVersion(), 2, string.concat(config.name, ": getVersion() should return 2 after upgrade"));

        // Implementation slot updated
        address actualImpl = address(uint160(uint256(vm.load(PROXY, implSlot))));
        assertEq(actualImpl, newImplAddr, string.concat(config.name, ": impl slot not updated"));

        // State preserved
        assertEq(aori.owner(), onChainOwner, string.concat(config.name, ": owner changed after upgrade"));
        assertEq(aori.ENDPOINT_ID(), config.eid, string.concat(config.name, ": ENDPOINT_ID changed after upgrade"));
        assertFalse(aori.paused(), string.concat(config.name, ": paused state changed after upgrade"));
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
