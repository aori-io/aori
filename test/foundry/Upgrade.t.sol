// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * UpgradeTests - Tests for UUPS upgradeability of Aori
 *
 * Test cases:
 * 1. testInitializationState - Verify proxy initialization set correct state
 * 2. testCannotReinitialize - Verify initialization can only happen once
 * 3. testUpgradeToNewImplementation - Test upgrade to new implementation
 * 4. testStatePreservationAfterUpgrade - Verify state preserved across upgrade
 * 5. testOnlyOwnerCanUpgrade - Test _authorizeUpgrade access control
 * 6. testProxyDelegatesCorrectly - Verify proxy delegates to implementation
 * 7. testImmutableEndpointIdPreserved - Verify ENDPOINT_ID works correctly
 */
import "forge-std/Test.sol";
import {Aori} from "../../contracts/Aori.sol";
import {IAori} from "../../contracts/IAori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockHook} from "../Mock/MockHook.sol";

/**
 * @title MockAoriUpgraded
 * @notice Mock V2 implementation for testing upgrades
 * @dev Adds a simple version function to verify upgrade worked
 */
contract MockAoriUpgraded is Aori {
    uint256 public constant VERSION = 2;

    constructor(address _endpoint, uint32 _eid) Aori(_endpoint, _eid) {}

    function getVersion() external pure returns (uint256) {
        return VERSION;
    }
}

/**
 * @title UpgradeTests
 * @notice Tests for UUPS upgradeability of Aori
 */
contract UpgradeTests is TestHelperOz5 {
    using OptionsBuilder for bytes;

    // Contracts
    Aori public implementation;
    Aori public aori; // proxy cast to Aori
    ERC1967Proxy public proxy;

    // Mock contracts
    MockERC20 public inputToken;
    MockERC20 public outputToken;
    MockHook public mockHook;

    // Addresses
    address public owner;
    address public solver;
    address public nonOwner;
    uint256 public userAPrivKey = 0xBEEF;
    address public userA;

    // Constants
    uint32 public constant LOCAL_EID = 1;
    uint32 public constant REMOTE_EID = 2;
    uint16 public constant MAX_FILLS_PER_SETTLE = 10;

    function setUp() public virtual override {
        owner = address(this);
        solver = address(0x200);
        nonOwner = address(0x300);
        userA = vm.addr(userAPrivKey);

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy implementation
        implementation = new Aori(address(endpoints[LOCAL_EID]), LOCAL_EID);

        // Prepare initialization data
        address[] memory initialSolvers = new address[](1);
        initialSolvers[0] = solver;

        address[] memory initialHooks = new address[](0);
        uint32[] memory supportedChains = new uint32[](1);
        supportedChains[0] = REMOTE_EID;

        // Deploy proxy with initialization
        bytes memory initData = abi.encodeCall(
            Aori.initialize,
            (
                owner,
                MAX_FILLS_PER_SETTLE,
                initialSolvers,
                initialHooks,
                supportedChains
            )
        );

        proxy = new ERC1967Proxy(address(implementation), initData);
        aori = Aori(payable(address(proxy)));

        // Setup test tokens
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");
        inputToken.mint(userA, 1000e18);
        outputToken.mint(solver, 1000e18);

        // Setup mock hook
        mockHook = new MockHook();
        aori.addAllowedHook(address(mockHook));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  DEPLOYMENT & INITIALIZATION               */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Verify proxy initialization set correct state
     */
    function testInitializationState() public view {
        // Verify owner is set correctly
        assertEq(aori.owner(), owner, "Owner should be set");

        // Verify ENDPOINT_ID is correct
        assertEq(aori.ENDPOINT_ID(), LOCAL_EID, "ENDPOINT_ID should be LOCAL_EID");

        // Verify solver is whitelisted
        assertTrue(aori.isAllowedSolver(solver), "Solver should be whitelisted");

        // Verify supported chain is set
        assertTrue(aori.isSupportedChain(REMOTE_EID), "Remote chain should be supported");
        assertTrue(aori.isSupportedChain(LOCAL_EID), "Local chain should be supported");

        // Verify endpoint is set
        assertEq(address(aori.endpoint()), address(endpoints[LOCAL_EID]), "Endpoint should be set");
    }

    /**
     * @notice Test that contract cannot be reinitialized
     */
    function testCannotReinitialize() public {
        address[] memory emptySolvers = new address[](0);
        address[] memory emptyHooks = new address[](0);
        uint32[] memory emptyChains = new uint32[](0);

        vm.expectRevert();
        aori.initialize(
            nonOwner,
            5,
            emptySolvers,
            emptyHooks,
            emptyChains
        );
    }

    /**
     * @notice Test that implementation contract has initializers disabled
     */
    function testImplementationInitializersDisabled() public {
        address[] memory emptySolvers = new address[](0);
        address[] memory emptyHooks = new address[](0);
        uint32[] memory emptyChains = new uint32[](0);

        vm.expectRevert();
        implementation.initialize(
            owner,
            MAX_FILLS_PER_SETTLE,
            emptySolvers,
            emptyHooks,
            emptyChains
        );
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      UPGRADE TESTS                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test upgrading to a new implementation
     */
    function testUpgradeToNewImplementation() public {
        // Verify V1 doesn't have getVersion (call should revert)
        MockAoriUpgraded aoriV2 = MockAoriUpgraded(payable(address(proxy)));
        vm.expectRevert();
        aoriV2.getVersion();

        // Deploy V2 implementation
        MockAoriUpgraded implementationV2 = new MockAoriUpgraded(address(endpoints[LOCAL_EID]), LOCAL_EID);

        // Upgrade (as owner)
        aori.upgradeToAndCall(address(implementationV2), "");

        // Verify upgrade worked - now getVersion returns 2
        assertEq(aoriV2.getVersion(), 2, "Should be V2");
    }

    /**
     * @notice Test that only owner can upgrade
     */
    function testOnlyOwnerCanUpgrade() public {
        MockAoriUpgraded implementationV2 = new MockAoriUpgraded(address(endpoints[LOCAL_EID]), LOCAL_EID);

        // Try to upgrade as non-owner
        vm.prank(nonOwner);
        vm.expectRevert();
        aori.upgradeToAndCall(address(implementationV2), "");

        // Verify original implementation still works
        assertEq(aori.ENDPOINT_ID(), LOCAL_EID, "Should still be V1");
    }

    /**
     * @notice Test that state is preserved across upgrades
     */
    function testStatePreservationAfterUpgrade() public {
        // Add some state before upgrade
        address newSolver = address(0x400);
        aori.addAllowedSolver(newSolver);
        aori.addAllowedHook(address(0x500));
        aori.addSupportedChain(3);

        // Verify state before upgrade
        assertTrue(aori.isAllowedSolver(newSolver), "Solver should be allowed before upgrade");
        assertTrue(aori.isAllowedSolver(solver), "Original solver should be allowed before upgrade");
        assertTrue(aori.isAllowedHook(address(0x500)), "Hook should be allowed before upgrade");
        assertTrue(aori.isSupportedChain(3), "Chain 3 should be supported before upgrade");

        // Deploy and upgrade to V2
        MockAoriUpgraded implementationV2 = new MockAoriUpgraded(address(endpoints[LOCAL_EID]), LOCAL_EID);
        aori.upgradeToAndCall(address(implementationV2), "");

        // Cast to V2
        MockAoriUpgraded aoriV2 = MockAoriUpgraded(payable(address(proxy)));

        // Verify state is preserved
        assertEq(aoriV2.owner(), owner, "Owner should be preserved");
        assertTrue(aoriV2.isAllowedSolver(newSolver), "New solver should still be allowed");
        assertTrue(aoriV2.isAllowedSolver(solver), "Original solver should still be allowed");
        assertTrue(aoriV2.isAllowedHook(address(0x500)), "Hook should still be allowed");
        assertTrue(aoriV2.isSupportedChain(3), "Chain 3 should still be supported");
        assertTrue(aoriV2.isSupportedChain(LOCAL_EID), "Local chain should still be supported");
        assertTrue(aoriV2.isSupportedChain(REMOTE_EID), "Remote chain should still be supported");
        assertEq(address(aoriV2.endpoint()), address(endpoints[LOCAL_EID]), "Endpoint should be preserved");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   PROXY DELEGATION TESTS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test that proxy correctly delegates calls to implementation
     */
    function testProxyDelegatesCorrectly() public {
        // Call owner() through proxy
        assertEq(aori.owner(), owner, "owner() should delegate correctly");

        // Call ENDPOINT_ID through proxy (immutable)
        assertEq(aori.ENDPOINT_ID(), LOCAL_EID, "ENDPOINT_ID should delegate correctly");

        // Test state-changing function through proxy
        address testHook = address(0x600);
        aori.addAllowedHook(testHook);
        assertTrue(aori.isAllowedHook(testHook), "State change should work through proxy");
    }

    /**
     * @notice Test that ENDPOINT_ID immutable works with proxy pattern
     */
    function testImmutableEndpointIdPreserved() public view {
        // The ENDPOINT_ID is stored in the implementation's bytecode
        // When accessed through proxy, it reads from the implementation being delegated to
        assertEq(aori.ENDPOINT_ID(), LOCAL_EID, "ENDPOINT_ID should be LOCAL_EID");

        // Directly check implementation
        assertEq(implementation.ENDPOINT_ID(), LOCAL_EID, "Implementation ENDPOINT_ID should be LOCAL_EID");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 PAUSE/UNPAUSE THROUGH PROXY                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test pause/unpause works through proxy
     */
    function testPauseUnpauseThroughProxy() public {
        // Pause
        aori.pause();
        assertTrue(aori.paused(), "Should be paused");

        // Unpause
        aori.unpause();
        assertFalse(aori.paused(), "Should be unpaused");
    }

    /**
     * @notice Test pause state preserved after upgrade
     */
    function testPauseStatePreservedAfterUpgrade() public {
        // Pause before upgrade
        aori.pause();
        assertTrue(aori.paused(), "Should be paused before upgrade");

        // Upgrade
        MockAoriUpgraded implementationV2 = new MockAoriUpgraded(address(endpoints[LOCAL_EID]), LOCAL_EID);
        aori.upgradeToAndCall(address(implementationV2), "");

        // Verify still paused
        MockAoriUpgraded aoriV2 = MockAoriUpgraded(payable(address(proxy)));
        assertTrue(aoriV2.paused(), "Should still be paused after upgrade");

        // Can unpause after upgrade
        aoriV2.unpause();
        assertFalse(aoriV2.paused(), "Should be unpaused");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              ORDER DEPOSIT/WITHDRAW THROUGH PROXY          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test native deposit works through proxy
     */
    function testNativeDepositThroughProxy() public {
        // Create order for native token
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE, // Native token
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: LOCAL_EID,
            dstEid: REMOTE_EID
        });

        // Deposit native tokens as userA
        vm.deal(userA, 10e18);
        vm.prank(userA);
        aori.depositNative{value: order.inputAmount}(order);

        // Verify locked balance
        assertEq(
            aori.getLockedBalances(userA, order.inputToken),
            order.inputAmount,
            "Native tokens should be locked"
        );
    }

    /**
     * @notice Test withdraw works through proxy
     * @dev Tests the cancel-then-withdrawal flow. Note that cancel() transfers
     *      tokens directly to offerer rather than to unlocked balance.
     */
    function testWithdrawThroughProxy() public {
        // First do a native deposit
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: LOCAL_EID,
            dstEid: LOCAL_EID // Same chain for simplicity
        });

        vm.deal(userA, 10e18);
        uint256 balanceBefore = userA.balance;

        vm.prank(userA);
        aori.depositNative{value: order.inputAmount}(order);

        // Verify locked balance
        assertEq(
            aori.getLockedBalances(userA, order.inputToken),
            order.inputAmount,
            "Native tokens should be locked after deposit"
        );
        assertEq(userA.balance, balanceBefore - order.inputAmount, "User balance should decrease after deposit");

        // Warp time to after order expiry so offerer can cancel
        vm.warp(order.endTime + 1);

        // Cancel the order - this directly transfers tokens back to offerer
        bytes32 orderId = aori.hash(order);
        vm.prank(userA);
        aori.cancel(orderId);

        // Verify locked balance is now 0
        assertEq(
            aori.getLockedBalances(userA, order.inputToken),
            0,
            "Locked balance should be 0 after cancel"
        );

        // Verify tokens were directly transferred back to user
        assertEq(userA.balance, balanceBefore, "User should have full balance back after cancel");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                     EIP-712 THROUGH PROXY                  */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test that order hashing works through proxy
     */
    function testOrderHashingThroughProxy() public view {
        IAori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 1 days),
            srcEid: LOCAL_EID,
            dstEid: REMOTE_EID
        });

        // Hash should work through proxy
        bytes32 orderHash = aori.hash(order);
        assertTrue(orderHash != bytes32(0), "Order hash should not be zero");
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 UPGRADE WITH DIFFERENT ENDPOINT_ID         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test that upgrading to implementation with different ENDPOINT_ID changes the value
     * @dev This demonstrates that ENDPOINT_ID is read from the implementation's bytecode
     */
    function testUpgradeChangesEndpointId() public {
        // Verify initial ENDPOINT_ID
        assertEq(aori.ENDPOINT_ID(), LOCAL_EID, "Initial ENDPOINT_ID should be LOCAL_EID");

        // Deploy V2 with different ENDPOINT_ID
        MockAoriUpgraded implementationV2 = new MockAoriUpgraded(address(endpoints[LOCAL_EID]), 999);

        // Upgrade
        aori.upgradeToAndCall(address(implementationV2), "");

        // Cast to V2
        MockAoriUpgraded aoriV2 = MockAoriUpgraded(payable(address(proxy)));

        // ENDPOINT_ID should now be 999 (from new implementation's bytecode)
        assertEq(aoriV2.ENDPOINT_ID(), 999, "ENDPOINT_ID should be 999 after upgrade to impl with EID=999");
    }
}
