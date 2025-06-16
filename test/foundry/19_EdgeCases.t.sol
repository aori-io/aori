// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title EdgeCasesTest
 * @notice Tests various edge cases and security scenarios in the Aori protocol
 *
 * This test file verifies that the Aori contract properly handles edge cases and potential
 * security vulnerabilities. It tests scenarios like signature manipulation, fee-on-transfer
 * tokens, and reverting token transfers to ensure the protocol's robustness.
 *
 * Tests:
 * 1. testSignatureManipulation - Tests that the contract rejects orders with manipulated signatures
 * 2. testFeeOnTransferToken - Tests handling of tokens that take a fee on transfer
 * 3. testRevertingTokenInHook - Tests handling of tokens that revert during transfer in hooks
 *
 * Special notes:
 * - These tests use special mock tokens that simulate problematic behavior
 * - The test verifies different security edge cases that could potentially be exploited
 * - Custom mock contracts are used to test specific attack vectors and edge cases
 */
import {TestUtils} from "./TestUtils.sol";
import {IAori} from "../../contracts/Aori.sol";
import "../Mock/MockRevertingToken.sol";
import "../Mock/MockFeeOnTransferToken.sol";
import "../Mock/MockAttacker.sol";
import "../Mock/MockHook.sol";

/**
 * @notice Tests various edge cases and security scenarios in the Aori protocol
 */
contract EdgeCasesTest is TestUtils {
    // Additional tokens for edge case testing
    RevertingToken public revertingToken;
    FeeOnTransferToken public feeToken;

    // Additional test accounts
    address public owner;
    address public maker;
    address public taker;

    // EIP712 signature variables
    uint256 public makerPrivateKey;

    // For reentrancy testing
    ReentrantAttacker public attacker;

    function setUp() public override {
        // Setup parent test environment first (this provides standard tokens, contracts, etc.)
        super.setUp();

        makerPrivateKey = 0x123; // Private key for EIP712 signatures
        maker = vm.addr(makerPrivateKey); // Derive maker address from private key

        owner = makeAddr("owner");
        taker = makeAddr("taker");

        // Deploy edge case testing tokens
        revertingToken = new RevertingToken("Reverting Token", "REVT");
        feeToken = new FeeOnTransferToken("Fee Token", "FEET", 100); // 1% fee

        // Deploy attacker for reentrancy testing
        attacker = new ReentrantAttacker(payable(address(localAori)));

        // Mint tokens to maker, taker, and solver
        revertingToken.mint(maker, 1000 ether);
        feeToken.mint(maker, 1000 ether);
        feeToken.mint(taker, 1000 ether);
        feeToken.mint(solver, 1000 ether);

        // Approve tokens
        vm.startPrank(maker);
        inputToken.approve(address(localAori), type(uint256).max);
        outputToken.approve(address(remoteAori), type(uint256).max);
        revertingToken.approve(address(localAori), type(uint256).max);
        feeToken.approve(address(localAori), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(taker);
        inputToken.approve(address(remoteAori), type(uint256).max);
        outputToken.approve(address(localAori), type(uint256).max);
        feeToken.approve(address(remoteAori), type(uint256).max);
        vm.stopPrank();
    }

    // Test EIP712 signature manipulation
    function testSignatureManipulation() public {
        vm.chainId(localEid);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: localEid,
            dstEid: remoteEid
        });

        // Generate a valid signature
        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);

        // Attempt with manipulated signature (flip a bit in s)
        bytes32 modifiedS = bytes32(uint256(s) ^ 1);
        bytes memory manipulatedSignature = abi.encodePacked(r, modifiedS, v);

        vm.expectRevert("InvalidSignature");
        vm.prank(solver);
        localAori.deposit(order, manipulatedSignature);
    }

    // Test fee-on-transfer tokens
    function testFeeOnTransferToken() public {
        vm.chainId(localEid);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(feeToken),
            outputToken: address(outputToken),
            inputAmount: 10 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // The deposit will succeed but the actual amount locked will be less than order.inputAmount
        vm.prank(solver);
        localAori.deposit(order, signature);

        uint256 lockedBalance = localAori.getLockedBalances(maker, address(feeToken));
        assertEq(lockedBalance, 10 ether, "Locked balance should match input amount");
    }

    // Test reverting token transfer in hook
    function testRevertingTokenInHook() public {
        vm.chainId(localEid);
        IAori.Order memory order = IAori.Order({
            offerer: maker,
            recipient: maker,
            inputToken: address(revertingToken),
            outputToken: address(outputToken),
            inputAmount: 1 ether,
            outputAmount: 1 ether,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp) + 3600,
            srcEid: localEid,
            dstEid: remoteEid
        });

        bytes32 digest = _getOrderDigest(order);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(makerPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        IAori.SrcHook memory data = IAori.SrcHook({
            hookAddress: address(mockHook),
            preferredToken: address(inputToken),
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount for conversion
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(inputToken), 1 ether)
        });

        // Ensure the token will revert on transfer
        revertingToken.setRevertOnTransfer(true);

        vm.expectRevert("ERC20: transfer failed");
        vm.prank(solver);
        localAori.deposit(order, signature, data);
    }

    // Helper function to generate EIP712 digest for signing
    function _getOrderDigest(IAori.Order memory order) internal view returns (bytes32) {
        bytes32 ORDER_TYPEHASH = keccak256(
            "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

        bytes32 structHash = keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.outputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid,
                order.offerer,
                order.recipient
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("0.3.0")),
                address(localAori)
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}
