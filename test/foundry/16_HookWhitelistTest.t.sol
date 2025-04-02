// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {MockERC20} from "./Mock/MockERC20.sol";
import {MockHook} from "./Mock/MockHook.sol";
import {ExecutionUtils, HookUtils, PayloadPackUtils, PayloadUnpackUtils} from "../../contracts/lib/AoriUtils.sol";

/**
 * @title HookWhitelistTest
 * @notice Tests the hook whitelist functionality in the Aori contract
 * These tests verify that only whitelisted hooks can be used for token conversions
 * and that the whitelist system properly restricts access to non-whitelisted hooks.
 */
contract HookWhitelistTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    Aori public localAori;
    Aori public remoteAori;
    MockERC20 public inputToken;
    MockERC20 public outputToken;
    MockERC20 public convertedToken;
    MockHook public whitelistedHook;
    MockHook public nonWhitelistedHook;

    // User and solver addresses
    uint256 public userAPrivKey = 0xBEEF;
    address public userA;
    // The whitelisted solver address that will be used for testing operations
    address public solver = address(0x200);

    uint32 private constant localEid = 1;
    uint32 private constant remoteEid = 2;
    uint16 private constant MAX_FILLS_PER_SETTLE = 10;

    function setUp() public override {
        // Derive userA
        userA = vm.addr(userAPrivKey);

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy local and remote Aori contracts
        localAori = new Aori(address(endpoints[localEid]), address(this), localEid, MAX_FILLS_PER_SETTLE);
        remoteAori = new Aori(address(endpoints[remoteEid]), address(this), remoteEid, MAX_FILLS_PER_SETTLE);

        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(localAori);
        aoriInstances[1] = address(remoteAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        localAori.setPeer(remoteEid, bytes32(uint256(uint160(address(remoteAori)))));
        remoteAori.setPeer(localEid, bytes32(uint256(uint160(address(localAori)))));

        // Setup test tokens
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");
        convertedToken = new MockERC20("Converted", "CONV");

        // Mint tokens
        inputToken.mint(userA, 1000e18);
        outputToken.mint(solver, 1000e18);

        // Deploy hook contracts
        whitelistedHook = new MockHook();
        nonWhitelistedHook = new MockHook();

        // Fund hooks with tokens
        convertedToken.mint(address(whitelistedHook), 1000e18);
        convertedToken.mint(address(nonWhitelistedHook), 1000e18);

        // Only whitelist one hook
        localAori.addAllowedHook(address(whitelistedHook));
        remoteAori.addAllowedHook(address(whitelistedHook));

        // The nonWhitelistedHook is intentionally NOT added to the whitelist

        // Whitelist the solver in both contracts to allow it to perform operations
        localAori.addAllowedSolver(solver);
        remoteAori.addAllowedSolver(solver);
    }

    /**
     * @dev Returns a valid order for testing
     */
    function createValidOrder() internal view returns (IAori.Order memory order) {
        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1e18,
            outputAmount: 2e18,
            startTime: uint32(uint32(block.timestamp) + 1),
            endTime: uint32(uint32(block.timestamp) + 1 days),
            srcEid: localEid,
            dstEid: remoteEid
        });
    }

    /**
     * @dev Creates EIP712 signature for the provided order
     */
    function signOrder(IAori.Order memory order) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
                ),
                order.offerer,
                order.recipient,
                order.inputToken,
                order.outputToken,
                order.inputAmount,
                order.outputAmount,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("1")),
                address(localAori)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(userAPrivKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Test that deposit reverts when using a non-whitelisted hook
     * Verifies that the contract properly prevents the use of non-whitelisted hooks
     * for token conversions during deposit operations
     */
    function testRevertDepositNonWhitelistedHook() public {
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Create SrcSolverData with a non-whitelisted hook
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(nonWhitelistedHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), order.inputAmount)
        });

        // The deposit should revert with "Invalid hook address"
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid hook address"));
        localAori.deposit(order, signature, srcData);
    }

    /**
     * @notice Test that the same deposit with a whitelisted hook succeeds
     * Verifies that the contract allows the use of whitelisted hooks
     * for token conversions during deposit operations
     */
    function testDepositWithWhitelistedHook() public {
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        // Approve inputToken for deposit
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        // Create SrcSolverData with the whitelisted hook
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(whitelistedHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), order.inputAmount)
        });

        // The deposit should succeed with the whitelisted hook
        vm.prank(solver);
        localAori.deposit(order, signature, srcData);

        // Verify the locked balance is updated
        assertEq(
            localAori.getLockedBalances(userA, address(convertedToken)),
            order.inputAmount,
            "Locked balance not increased for user"
        );
    }

    /**
     * @notice Test that fill reverts when using a non-whitelisted hook
     * Verifies that the contract properly prevents the use of non-whitelisted hooks
     * for token conversions during fill operations
     */
    function testRevertFillNonWhitelistedHook() public {
        // First deposit with whitelisted hook
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(whitelistedHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), order.inputAmount)
        });

        vm.prank(solver);
        localAori.deposit(order, signature, srcData);

        // Now try to fill on destination chain with non-whitelisted hook
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(nonWhitelistedHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(outputToken), order.outputAmount),
            preferedDstInputAmount: order.outputAmount
        });

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Fill should revert with "Invalid hook address"
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid hook address"));
        remoteAori.fill(order, dstData);
    }

    /**
     * @notice Test that the same fill with a whitelisted hook succeeds
     * Verifies that the contract allows the use of whitelisted hooks
     * for token conversions during fill operations
     */
    function testFillWithWhitelistedHook() public {
        // First deposit with whitelisted hook
        vm.chainId(localEid);
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(whitelistedHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), order.inputAmount)
        });

        vm.prank(solver);
        localAori.deposit(order, signature, srcData);

        // Now fill on destination chain with whitelisted hook
        vm.chainId(remoteEid);
        vm.warp(order.startTime + 1);

        IAori.DstHook memory dstData = IAori.DstHook({
            hookAddress: address(whitelistedHook),
            preferredToken: address(outputToken),
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(outputToken), order.outputAmount),
            preferedDstInputAmount: order.outputAmount
        });

        vm.prank(solver);
        outputToken.approve(address(remoteAori), order.outputAmount);

        // Fill should succeed with the whitelisted hook
        vm.prank(solver);
        remoteAori.fill(order, dstData);

        // Verify user received output tokens
        assertEq(outputToken.balanceOf(userA), order.outputAmount, "User did not receive the expected output tokens");
    }

    /**
     * @notice Test that adding and removing hooks works correctly
     * Verifies that the hook whitelist can be properly managed and that
     * the contract correctly enforces whitelist restrictions after changes
     */
    function testHookWhitelistManagement() public {
        vm.chainId(localEid);

        // Initially the nonWhitelistedHook should not be in the whitelist
        assertEq(localAori.isAllowedHook(address(nonWhitelistedHook)), false);

        // Add the hook to the whitelist
        localAori.addAllowedHook(address(nonWhitelistedHook));

        // Now it should be whitelisted
        assertEq(localAori.isAllowedHook(address(nonWhitelistedHook)), true);

        // Now operations with this hook should work
        IAori.Order memory order = createValidOrder();
        bytes memory signature = signOrder(order);

        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);

        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(nonWhitelistedHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), order.inputAmount)
        });

        // This should now work since we whitelisted the hook
        vm.prank(solver);
        localAori.deposit(order, signature, srcData);

        // Remove the hook from the whitelist
        localAori.removeAllowedHook(address(nonWhitelistedHook));

        // Now it should no longer be whitelisted
        assertEq(localAori.isAllowedHook(address(nonWhitelistedHook)), false);

        // Create a new order
        IAori.Order memory order2 = createValidOrder();
        order2.startTime = uint32(uint32(block.timestamp) + 10); // make it unique
        bytes memory signature2 = signOrder(order2);

        vm.prank(userA);
        inputToken.approve(address(localAori), order2.inputAmount);

        // Using the same hook should now fail again
        vm.prank(solver);
        vm.expectRevert(bytes("Invalid hook address"));
        localAori.deposit(order2, signature2, srcData);
    }
}
