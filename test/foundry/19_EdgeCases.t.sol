// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import "./Mock/MockERC20.sol";
import "./Mock/MockHook.sol";
import "./Mock/MockRevertingToken.sol";
import "./Mock/MockFeeOnTransferToken.sol";
import "./Mock/MockAttacker.sol";
import {ExecutionUtils, HookUtils, PayloadPackUtils, PayloadUnpackUtils} from "../../contracts/lib/AoriUtils.sol";

/**
 * @title EdgeCasesTest
 * @notice Tests various edge cases and security scenarios in the Aori protocol
 * These tests verify that the contract properly handles edge cases while maintaining
 * proper whitelist-based solver restrictions.
 */
contract EdgeCasesTest is TestHelperOz5 {
    using OptionsBuilder for bytes;

    Aori public srcAori;
    Aori public dstAori;

    MockERC20 public tokenA;
    MockERC20 public tokenB;
    RevertingToken public revertingToken;
    FeeOnTransferToken public feeToken;

    address public owner;
    address public maker;
    address public taker;
    // The whitelisted solver address that will be used for testing operations
    address public solver = address(0x200);

    uint32 public constant SRC_EID = 1;
    uint32 public constant DST_EID = 2;
    uint16 public constant MAX_FILLS_PER_SETTLE = 10;
    uint256 private constant GAS_LIMIT = 200000;

    // EIP712 signature variables
    uint256 public makerPrivateKey;

    MockHook public mockHook;
    ReentrantAttacker public attacker;

    function setUp() public override {
        makerPrivateKey = 0x123; // Private key for EIP712 signatures
        maker = vm.addr(makerPrivateKey); // Derive maker address from private key

        owner = makeAddr("owner");
        taker = makeAddr("taker");

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        vm.startPrank(owner);

        // Deploy Aori contracts
        srcAori = new Aori(address(endpoints[SRC_EID]), owner, SRC_EID, MAX_FILLS_PER_SETTLE);
        dstAori = new Aori(address(endpoints[DST_EID]), owner, DST_EID, MAX_FILLS_PER_SETTLE);

        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(srcAori);
        aoriInstances[1] = address(dstAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        srcAori.setPeer(DST_EID, bytes32(uint256(uint160(address(dstAori)))));
        dstAori.setPeer(SRC_EID, bytes32(uint256(uint160(address(srcAori)))));

        // Deploy tokens
        tokenA = new MockERC20("Token A", "TOKENA");
        tokenB = new MockERC20("Token B", "TOKENB");
        revertingToken = new RevertingToken("Reverting Token", "REVT");
        feeToken = new FeeOnTransferToken("Fee Token", "FEET", 100); // 1% fee

        // Deploy hooks - use the constructor without arguments
        mockHook = new MockHook();

        // Whitelist hooks and solver
        srcAori.addAllowedHook(address(mockHook));
        dstAori.addAllowedHook(address(mockHook));
        srcAori.addAllowedSolver(solver);
        dstAori.addAllowedSolver(solver);

        // Deploy attacker
        attacker = new ReentrantAttacker(address(srcAori));

        vm.stopPrank();

        // Mint tokens to maker, taker, and solver
        vm.startPrank(address(tokenA));
        tokenA.mint(maker, 1000 ether);
        tokenA.mint(taker, 1000 ether);
        tokenA.mint(solver, 1000 ether);
        vm.stopPrank();

        vm.startPrank(address(tokenB));
        tokenB.mint(maker, 1000 ether);
        tokenB.mint(taker, 1000 ether);
        tokenB.mint(solver, 1000 ether);
        vm.stopPrank();

        vm.startPrank(address(revertingToken));
        revertingToken.mint(maker, 1000 ether);
        vm.stopPrank();

        vm.startPrank(address(feeToken));
        feeToken.mint(maker, 1000 ether);
        feeToken.mint(taker, 1000 ether);
        feeToken.mint(solver, 1000 ether);
        vm.stopPrank();

        // Approve tokens
        vm.startPrank(maker);
        tokenA.approve(address(srcAori), type(uint256).max);
        tokenB.approve(address(dstAori), type(uint256).max);
        revertingToken.approve(address(srcAori), type(uint256).max);
        feeToken.approve(address(srcAori), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        tokenA.approve(address(dstAori), type(uint256).max);
        tokenB.approve(address(srcAori), type(uint256).max);
        feeToken.approve(address(dstAori), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(solver);
        tokenA.approve(address(srcAori), type(uint256).max);
        tokenB.approve(address(dstAori), type(uint256).max);
        feeToken.approve(address(srcAori), type(uint256).max);
        vm.stopPrank();
    }

    // Test EIP712 signature manipulation
    function testSignatureManipulation() public {
        vm.chainId(SRC_EID);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(tokenA),
            outputToken: address(tokenB),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: SRC_EID,
            dstEid: DST_EID
        });

        // Generate a valid signature
        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);

        // Attempt with manipulated signature (flip a bit in s)
        bytes32 modifiedS = bytes32(uint256(s) ^ 1);
        bytes memory manipulatedSignature = abi.encodePacked(r, modifiedS, v);

        vm.expectRevert("InvalidSignature");
        vm.prank(solver);
        srcAori.deposit(order, manipulatedSignature);
    }

    // Test fee-on-transfer tokens
    function testFeeOnTransferToken() public {
        vm.chainId(SRC_EID);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(feeToken),
            outputToken: address(tokenB),
            inputAmount: 10 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: SRC_EID,
            dstEid: DST_EID
        });

        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The deposit will succeed but the actual amount locked will be less than order.inputAmount
        vm.prank(solver);
        srcAori.deposit(order, signature);

        uint256 lockedBalance = srcAori.getLockedBalances(maker, address(feeToken));
        assertEq(lockedBalance, 10 ether);
    }

    // Test reverting token transfer in hook
    function testRevertingTokenInHook() public {
        vm.chainId(SRC_EID);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(revertingToken),
            outputToken: address(tokenB),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: SRC_EID,
            dstEid: DST_EID
        });

        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        IAori.SrcHook memory data = IAori.SrcHook({
            hookAddress: address(mockHook),
            preferredToken: address(tokenA),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(tokenA), 1 ether)
        });

        // Ensure the token will revert on transfer
        revertingToken.setRevertOnTransfer(true);

        vm.expectRevert("ERC20: transfer failed");
        vm.prank(solver);
        srcAori.deposit(order, signature, data);
    }

    // Helper function to generate EIP712 digest for signing
    function _getOrderDigest(IAori.Order memory order) internal view returns (bytes32) {
        bytes32 ORDER_TYPEHASH = keccak256(
            "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
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
                address(srcAori)
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
