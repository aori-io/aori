// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {Script} from "@layerzerolabs/toolbox-foundry/lib/forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IAori} from "../IAori.sol";

// A simple ERC20 for demo purposes:
contract DemoERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "Insufficient allowance");

        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        if (allowed < type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        emit Transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract FillScript is Script {
    using OptionsBuilder for bytes;

    // These are our deployed Aori contract addresses on the respective chains.
    address constant AORI_ARBSEP = 0xD030BfC9649af3f008f8465427Ffffab2DDd20d7;
    address constant AORI_SEP = 0xEA631c222514F6d971571298fd67b83eBd76936c;

    uint256 depositorPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY2"));
    address depositorAddress = vm.addr(depositorPrivateKey);

    uint256 solverPrivateKey = uint256(vm.envBytes32("PRIVATE_KEY"));
    address solverAddress = vm.addr(solverPrivateKey);

    function run() external {
        /// ---------------------- ARB SEP CHAIN (Deposit) ----------------------
        // Adjust the env var / chain as needed:
        vm.createSelectFork(vm.envString("ARBITRUM_SEP_RPC"));
        vm.startBroadcast(depositorPrivateKey);

        // 1. Use existing ERC20 tokens deployed on ArbSep:
        IERC20 arbSepToken = IERC20(0xA0F7Ae56E24A269f71BBF1BF3DeB5b1E741492C9);
        IERC20 sepToken = IERC20(0x6e56e17a9Ac93bd42F5C02613D24025327d0497E);

        // Approve the Aori deposit contract to spend tokens.
        arbSepToken.approve(AORI_ARBSEP, 1e18);

        // Create order – note that srcEid must match the Aori instance's endpoint on this chain
        // and dstEid must match the remote chain's endpoint.
        IAori.Order memory order = IAori.Order({
            offerer: depositorAddress,
            recipient: depositorAddress,
            inputToken: address(arbSepToken),
            outputToken: address(sepToken),
            inputAmount: 1e18,
            outputAmount: 1e18,
            startTime: uint32(block.timestamp - 100),
            endTime: uint32(block.timestamp + 7200), // 2 hours later
            srcEid: 40231,
            dstEid: 40161
        });

        // ============================================================
        // Compute the EIP712 signature for the order
        // ============================================================
        // The Aori contract is initialized using EIP712 with:
        //   name: "Aori" and version: "1"
        // The domain separator is computed as:
        // keccak256(abi.encode(
        //      keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
        //      keccak256(bytes("Aori")),
        //      keccak256(bytes("1")),
        //      AORI_ARBSEP
        // ))
        bytes32 DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("1")),
                AORI_ARBSEP
            )
        );

        // The order type hash must match the one in Aori.sol:
        bytes32 ORDER_TYPEHASH = keccak256(
            "Order(uint256 inputAmount,uint256 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        );

        // Compute the struct hash for the order.
        bytes32 orderStructHash = keccak256(
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

        // Compose the EIP712 digest.
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, orderStructHash));

        // Sign the digest with the depositor's private key.
        // vm.sign returns (v, r, s) which we pack into a 65-byte signature.
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(depositorPrivateKey, digest);
        bytes memory signature = abi.encodePacked(r, s, v);

        // Prepare an empty SrcSolverData so that no extra hook logic is triggered.
        IAori.SrcHook memory srcData = IAori.SrcHook({
            hookAddress: address(0),
            preferredToken: order.inputToken,
            minPreferedTokenAmountOut: order.inputAmount, // For direct deposits, minimum output equals input
            instructions: ""
        });

        // Call deposit with a valid signature and the SrcSolverData.
        IAori(AORI_ARBSEP).deposit{value: 0}(order, signature, srcData);

        vm.stopBroadcast();

        /// ---------------------- SEP CHAIN (Fill & Settle) ----------------------
        vm.createSelectFork(vm.envString("SEP_RPC"));
        vm.startBroadcast(solverPrivateKey);

        // Mint output tokens for the solver so that fill() can transfer them.
        DemoERC20(address(sepToken)).mint(solverAddress, 100e18);

        // Approve the Aori contract on Sepolia to spend the tokens.
        sepToken.approve(AORI_SEP, 100e18);

        // Call fill on the Sepolia Aori instance.
        // This will transfer order.outputAmount from solverAddress to order.recipient.
        IAori(AORI_SEP).fill{value: 0}(order);

        // ---------------------- Settle ----------------------
        // Build your worker/gas options as before.
        uint256 GAS_LIMIT = 200000;
        bytes memory options = OptionsBuilder.newOptions().addExecutorLzReceiveOption(uint128(GAS_LIMIT), 0);

        // // Quote the fee for settlement.
        // uint256 estimatedFee = IAori(AORI_SEP).quote(
        //     40231,
        //     abi.encode(""),
        //     options,
        //     false
        // );

        // Call settle on Sepolia with the provided fee.
        IAori(AORI_SEP).settle{value: 1e17}(40231, solverAddress, options);

        vm.stopBroadcast();
    }
}
