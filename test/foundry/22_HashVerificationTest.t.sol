// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * HashVerificationTest - Generates reference hash values for cross-language testing
 *
 * This test specifically generates values for verifying signature implementations with
 * the Aori contract on Arbitrum.
 *
 * Important Notes for EIP-712 signatures:
 * 1. The domain separator must include the exact same contract address that's verifying the signature
 * 2. When using Solady's ECDSA library, the signature format is critical:
 *    - Signature must be exactly 65 bytes: [r (32 bytes)][s (32 bytes)][v (1 byte)]
 *    - The v value must be exactly 27 or 28 (NOT 0 or 1)
 *    - The offerer address must match the recovered signer
 * 3. For testing with Foundry:
 *    - Use vm.sign(privateKey, messageHash) to get (v, r, s) values
 *    - For proper signature creation, copy r and s directly
 *    - For v, use either 27 or 28 (depending on what works with ecrecover)
 *    - When generating signatures for cross-language testing, use the same format
 *
 * Running:
 * forge test --match-path test/foundry/22_HashVerificationTest.t.sol -vvv
 */
import "forge-std/Test.sol";
import { Aori, IAori } from "../../contracts/Aori.sol";
import { TestUtils } from "./TestUtils.sol";
import { MockERC20 } from "../Mock/MockERC20.sol";

/**
 * @title HashVerificationTest
 * @notice Generates hash values and signatures for use in cross-language testing
 * @dev Extends TestUtils to ensure proper test environment setup
 */
contract HashVerificationTest is TestUtils {
    // Fixed test values
    address payable public constant ARBITRUM_CONTRACT_ADDRESS = payable(0xFfe691A6dDb5D2645321e0a920C2e7Bdd00dD3D8);
    uint32 public constant ARBITRUM_EID = 30110;
    uint32 public constant ETHEREUM_EID = 30101; // Using mainnet as destination

    string public constant TEST_OFFERER_ADDRESS = "0xCDa498984665A7DA25D6Cb973e1c9533016c990B";
    string public constant TEST_OFFERER_PRIVATE_KEY = "c0b4a772933191e90eadddbb6cade5f6c47abff65c5c7c92869d9444ef18750b";
    uint256 private constant OFFERER_PRIVATE_KEY = 0xc0b4a772933191e90eadddbb6cade5f6c47abff65c5c7c92869d9444ef18750b;

    string public constant TEST_SOLVER_ADDRESS = "0x0999CB4Ead0E01C861c2Bfe4B31130185a3adfA5";
    string public constant TEST_SOLVER_PRIVATE_KEY = "c0b4a772933191e90eadddbb6cade5f6c47abff65c5c7c92869d9444ef18750a";
    uint256 private constant SOLVER_PRIVATE_KEY = 0xc0b4a772933191e90eadddbb6cade5f6c47abff65c5c7c92869d9444ef18750a;
    
    address public testSigner;
    address public solverAddress;

    /**
     * @notice Set up the test environment
     */
    function setUp() public override {
        // Call parent setup to initialize TestUtils environment
        super.setUp();

        // Derive signer address from private key
        testSigner = vm.addr(OFFERER_PRIVATE_KEY);
        solverAddress = vm.addr(SOLVER_PRIVATE_KEY);

        // Warp to specific timestamp for reproducibility
        vm.warp(1740379087);
    }

    /**
     * @notice Generate Arbitrum-specific signature verification values
     */
    function testArbitrumSignature() public {
        // Create a test order that matches the Arbitrum contract's expected chain ID
        IAori.Order memory order = IAori.Order({
            offerer: testSigner,
            recipient: testSigner,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: 1000000,
            outputAmount: 1000000,
            startTime: uint32(block.timestamp),
            endTime: uint32(block.timestamp + 3600),
            srcEid: ARBITRUM_EID,
            dstEid: ETHEREUM_EID
        });

        // Calculate signing hash using the Arbitrum contract address
        // This is the actual hash that would be signed in production
        bytes32 signingHash = calculateSigningHashWithAddress(order, ARBITRUM_CONTRACT_ADDRESS);
        
        // Generate signature using offerer's private key
        (uint8 rawV, bytes32 r, bytes32 s) = vm.sign(OFFERER_PRIVATE_KEY, signingHash);
        
        // Verify signature recovery using ecrecover
        address recovered = ecrecover(signingHash, rawV, r, s);
        assertEq(recovered, testSigner, "Signature recovery failed");
        
        // Create a properly formatted signature - for Solady ECDSA, v must be 27/28
        bytes memory signature = new bytes(65);
        
        // Copy r, s
        for (uint i = 0; i < 32; i++) {
            signature[i] = bytes32ToBytes(r)[i];
            signature[32 + i] = bytes32ToBytes(s)[i];
        }
        
        // Set v (must be 27 or 28 for Solady ECDSA)
        signature[64] = bytes1(rawV);
        
        // Print relevant information
        console.log("\n==== HASH VERIFICATION TEST ====");
        console.log("Expected Signer:        %s", testSigner);
        console.log("Offerer Private Key:    %s", TEST_OFFERER_PRIVATE_KEY);
        console.log("Solver Address:         %s", solverAddress);
        console.log("\n---- ORDER DETAILS ----");
        console.log("Offerer:                %s", order.offerer);
        console.log("Recipient:              %s", order.recipient); 
        console.log("Input Token:            %s", order.inputToken);
        console.log("Output Token:           %s", order.outputToken);
        console.log("Input Amount:           %d", uint256(order.inputAmount));
        console.log("Output Amount:          %d", uint256(order.outputAmount));
        console.log("Start Time:             %d", order.startTime);
        console.log("End Time:               %d", order.endTime);
        console.log("Source EID:             %d", order.srcEid);
        console.log("Destination EID:        %d", order.dstEid);
        
        // ==================== DEPOSIT VERIFICATION STEP ====================
        // We'll deploy a local test contract at the same address as the Arbitrum contract
        // to verify that our signature works correctly for deposits
        console.log("\n---- VERIFYING DEPOSIT WITH TEST CONTRACT ----");
        
        // Get the code for a new contract with Arbitrum's EID
        address layerZeroEndpoint = address(endpoints[1]); // Use test endpoint from TestUtils
        Aori implementation = new Aori(
            layerZeroEndpoint,
            address(this),
            ARBITRUM_EID, // Use Arbitrum's EID to match production
            MAX_FILLS_PER_SETTLE
        );
        
        // Deploy the test contract at the exact Arbitrum address using vm.etch
        // This is critical because EIP-712 signatures include the contract address in the domain separator
        vm.etch(ARBITRUM_CONTRACT_ADDRESS, address(implementation).code);
        
        // Since vm.etch only copies the code, we need to set ourselves as the owner
        // First we prank as the zero address (default owner after etch)
        vm.startPrank(address(0));
        // Then transfer ownership to ourselves (test contract)
        Aori(ARBITRUM_CONTRACT_ADDRESS).transferOwnership(address(this));
        vm.stopPrank();
        
        // ADD THIS CODE HERE - before any deposit operations
        vm.startPrank(address(this));
        // Mark Ethereum destination as supported
        vm.mockCall(
            ARBITRUM_CONTRACT_ADDRESS,
            abi.encodeWithSelector(Aori(ARBITRUM_CONTRACT_ADDRESS).quote.selector, ETHEREUM_EID, 0, bytes(""), false, 0, address(0)),
            abi.encode(1 ether)
        );
        Aori(ARBITRUM_CONTRACT_ADDRESS).addSupportedChain(ETHEREUM_EID);
        vm.stopPrank();
        
        console.log("Test contract: %s", ARBITRUM_CONTRACT_ADDRESS);
        console.log("Test contract EID: %d", ARBITRUM_EID);
        console.log("Signing Hash:           0x%s", toHexString(signingHash));
        console.log("Recovered:       %s", recovered);
        
        // Setup for the deposit
        // Mint tokens to the offerer (signer)
        inputToken.mint(testSigner, order.inputAmount * 2);
        
        // Approve tokens for the deposit
        vm.prank(testSigner);
        inputToken.approve(ARBITRUM_CONTRACT_ADDRESS, order.inputAmount);
        
        // Whitelist solver as an allowed solver
        Aori(ARBITRUM_CONTRACT_ADDRESS).addAllowedSolver(solverAddress);
        
        // Use the original signature that we created for the Arbitrum contract
        console.log("Using signature: 0x%s", toHexString(signature));
        
        // Now attempt the deposit with the solver calling it
        vm.prank(solverAddress);
        Aori(ARBITRUM_CONTRACT_ADDRESS).deposit(order, signature);
        
        // Verify the deposit was successful
        bytes32 orderHash = Aori(ARBITRUM_CONTRACT_ADDRESS).hash(order);
        uint8 status = uint8(Aori(ARBITRUM_CONTRACT_ADDRESS).orderStatus(orderHash));
        
        console.log("\n---- DEPOSIT RESULT ----");
        console.log("Deposit Transaction: SUCCESSFUL");
        console.log("Recovered Signer:    %s", recovered);
        console.log("Transaction Sender:  %s", solverAddress);
        console.log("Order Hash:          0x%s", toHexString(orderHash));
        console.log("Order Status:        %s", status == 1 ? "Active" : "Other");
        
        // Verify the status is Active
        assertEq(status, 1, "Order should be Active after deposit");
        
        console.log("==================================\n");
    }

    /**
     * @notice Calculate the signing hash (EIP-712 digest) for a specific contract address
     */
    function calculateSigningHashWithAddress(
        IAori.Order memory order,
        address contractAddress
    ) public pure returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
                ),
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
                contractAddress
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    /**
     * @notice Helper to convert bytes32 to bytes
     */
    function bytes32ToBytes(bytes32 data) internal pure returns (bytes memory) {
        bytes memory result = new bytes(32);
        assembly {
            mstore(add(result, 32), data)
        }
        return result;
    }

    /**
     * @notice Helper function to convert bytes32 to hex string for logging
     */
    function toHexString(bytes32 value) internal pure returns (string memory) {
        return toHexString(abi.encodePacked(value));
    }

    /**
     * @notice Helper function to convert bytes to hex string for logging
     */
    function toHexString(bytes memory value) internal pure returns (string memory) {
        bytes memory alphabet = "0123456789abcdef";
        bytes memory str = new bytes(2 * value.length);
        for (uint i = 0; i < value.length; i++) {
            str[2 * i] = alphabet[uint8(value[i] >> 4)];
            str[2 * i + 1] = alphabet[uint8(value[i] & 0x0f)];
        }
        return string(str);
    }
}
