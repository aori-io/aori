// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "../../contracts/types/AoriTypes.sol";

contract SolanaDerivationTest is Test {
    /// @notice Derivation function: Solana pubkey (32 bytes) → EVM address (20 bytes)
    function derive(bytes32 solanaPubkey) internal pure returns (address) {
        return address(bytes20(keccak256(abi.encodePacked(solanaPubkey))));
    }

    /// @notice Alternative using uint160 (takes LOW-order bytes) — NOT what we want
    function deriveAlt(bytes32 solanaPubkey) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(solanaPubkey)))));
    }

    function test_derivation_byte_ordering() public {
        // Known Solana pubkey (example: 32 random bytes)
        bytes32 solanaPubkey = hex"7C9e73d4C71dae564d41F78d56439bB4ba87592f1234567890abcdef12345678";

        bytes32 fullHash = keccak256(abi.encodePacked(solanaPubkey));

        // bytes20() takes HIGH-order (first) 20 bytes
        address derivedHigh = address(bytes20(fullHash));

        // uint160(uint256()) takes LOW-order (last) 20 bytes
        address derivedLow = address(uint160(uint256(fullHash)));

        // These should be DIFFERENT (proving the byte selection matters)
        assertTrue(derivedHigh != derivedLow, "high and low should differ");

        // Our derive() function should match the HIGH-order approach
        address derived = derive(solanaPubkey);
        assertEq(derived, derivedHigh, "derive() should use high-order bytes");

        // Log the test vector
        emit log_named_bytes32("Solana pubkey", solanaPubkey);
        emit log_named_bytes32("keccak256 hash", fullHash);
        emit log_named_address("derived (HIGH bytes20)", derivedHigh);
        emit log_named_address("derived (LOW uint160)", derivedLow);
    }

    function test_derivation_zero_address_probability() public pure {
        // Verify that derive(x) != address(0) for a handful of inputs
        bytes32[5] memory testKeys = [
            bytes32(hex"0000000000000000000000000000000000000000000000000000000000000001"),
            bytes32(hex"0000000000000000000000000000000000000000000000000000000000000002"),
            bytes32(hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
            bytes32(hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef"),
            bytes32(hex"7C9e73d4C71dae564d41F78d56439bB4ba87592f1234567890abcdef12345678")
        ];

        for (uint256 i = 0; i < testKeys.length; i++) {
            address derived = derive(testKeys[i]);
            assertTrue(derived != address(0), "derived should not be zero address");
        }
    }

    function test_abi_encode_order_layout() public {
        // Use makeAddr-style addresses with proper checksums
        address inputToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48; // USDC
        address outputToken = 0x1234567890AbcdEF1234567890aBcdef12345678;
        address offerer = 0xaAaAaAaaAaAaAaaAaAAAAAAAAaaaAaAaAaaAaaAa;
        address recipient = 0xbBbBBBBbbBBBbbbBbbBbbbbBBbBbbbbBbBbbBBbB;
        address feeRecipient = 0xCcCCccccCCCCcCCCCCCcCcCccCcCCCcCcccccccC;
        address srcSolver = 0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd;
        address dstSolver = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        Order memory order = Order({
            inputAmount: 1000e6,
            outputAmount: 999e6,
            inputToken: inputToken,
            startTime: 1700000000,
            endTime: 1700003600,
            srcEid: 30101,
            outputToken: outputToken,
            dstEid: 30168,
            offerer: offerer,
            recipient: recipient,
            options: Options({
                feeMbps: 50,
                slippageMbps: 0,
                feeRecipient: feeRecipient,
                srcSolver: srcSolver,
                dstSolver: dstSolver
            })
        });

        bytes memory encoded = abi.encode(order);

        // Verify total size: 15 fields × 32 bytes = 480 bytes
        // (Order has 10 fields, Options has 5 fields, nested struct encoded inline)
        assertEq(encoded.length, 480, "ABI encoded order should be 480 bytes");

        // Log the full encoding for cross-chain verification
        emit log_named_uint("encoded length", encoded.length);
        emit log_named_bytes32("orderId", keccak256(encoded));

        // Verify individual field positions by decoding
        // Field 0 (offset 0): inputAmount
        uint256 slot0;
        assembly { slot0 := mload(add(encoded, 32)) }
        assertEq(slot0, 1000e6, "slot 0 should be inputAmount");

        // Field 1 (offset 32): outputAmount
        uint256 slot1;
        assembly { slot1 := mload(add(encoded, 64)) }
        assertEq(slot1, 999e6, "slot 1 should be outputAmount");

        // Field 2 (offset 64): inputToken (left-padded address)
        address slot2;
        assembly { slot2 := mload(add(encoded, 96)) }
        assertEq(slot2, inputToken, "slot 2 should be inputToken");

        // Field 3 (offset 96): startTime
        uint256 slot3;
        assembly { slot3 := mload(add(encoded, 128)) }
        assertEq(slot3, 1700000000, "slot 3 should be startTime");

        // Field 4 (offset 128): endTime
        uint256 slot4;
        assembly { slot4 := mload(add(encoded, 160)) }
        assertEq(slot4, 1700003600, "slot 4 should be endTime");

        // Field 5 (offset 160): srcEid
        uint256 slot5;
        assembly { slot5 := mload(add(encoded, 192)) }
        assertEq(slot5, 30101, "slot 5 should be srcEid");

        // Field 6 (offset 192): outputToken
        address slot6;
        assembly { slot6 := mload(add(encoded, 224)) }
        assertEq(slot6, outputToken, "slot 6 should be outputToken");

        // Field 7 (offset 224): dstEid
        uint256 slot7;
        assembly { slot7 := mload(add(encoded, 256)) }
        assertEq(slot7, 30168, "slot 7 should be dstEid");

        // Field 8 (offset 256): offerer
        address slot8;
        assembly { slot8 := mload(add(encoded, 288)) }
        assertEq(slot8, offerer, "slot 8 should be offerer");

        // Field 9 (offset 288): recipient
        address slot9;
        assembly { slot9 := mload(add(encoded, 320)) }
        assertEq(slot9, recipient, "slot 9 should be recipient");

        // Field 10 (offset 320): options.feeMbps
        uint256 slot10;
        assembly { slot10 := mload(add(encoded, 352)) }
        assertEq(slot10, 50, "slot 10 should be feeMbps");

        // Field 11 (offset 352): options.slippageMbps
        uint256 slot11;
        assembly { slot11 := mload(add(encoded, 384)) }
        assertEq(slot11, 0, "slot 11 should be slippageMbps");

        // Field 12 (offset 384): options.feeRecipient
        address slot12;
        assembly { slot12 := mload(add(encoded, 416)) }
        assertEq(slot12, feeRecipient, "slot 12 should be feeRecipient");

        // Field 13 (offset 416): options.srcSolver
        address slot13;
        assembly { slot13 := mload(add(encoded, 448)) }
        assertEq(slot13, srcSolver, "slot 13 should be srcSolver");

        // Field 14 (offset 448): options.dstSolver
        address slot14;
        assembly { slot14 := mload(add(encoded, 480)) }
        assertEq(slot14, dstSolver, "slot 14 should be dstSolver");
    }

    function test_settlement_payload_sizes() public {
        // Settlement payload: 1 byte type + 20 bytes filler + 2 bytes count + N * 32 bytes hashes
        // Solana transaction limit: 1232 bytes
        // How many fills fit?

        uint256 headerSize = 1 + 20 + 2; // 23 bytes
        uint256 solanaMaxPayload = 1232;
        uint256 maxFills = (solanaMaxPayload - headerSize) / 32;

        emit log_named_uint("Settlement header size", headerSize);
        emit log_named_uint("Max fills in 1232 bytes", maxFills);
        emit log_named_uint("Payload at 10 fills", headerSize + 10 * 32);
        emit log_named_uint("Payload at 20 fills", headerSize + 20 * 32);
        emit log_named_uint("Payload at 37 fills", headerSize + 37 * 32);
        emit log_named_uint("Payload at 38 fills", headerSize + 38 * 32);

        // 37 fills = 23 + 37*32 = 23 + 1184 = 1207 bytes (fits)
        // 38 fills = 23 + 38*32 = 23 + 1216 = 1239 bytes (exceeds 1232)
        assertTrue(headerSize + 37 * 32 <= 1232, "37 fills should fit");
        assertTrue(headerSize + 38 * 32 > 1232, "38 fills should not fit");
    }

    function test_native_token_collision() public pure {
        // The NATIVE_TOKEN sentinel is 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE
        // Verify no reasonable Solana pubkey derives to this
        address nativeToken = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

        // Test a few pubkeys
        bytes32[3] memory testKeys = [
            bytes32(hex"0000000000000000000000000000000000000000000000000000000000000001"),
            bytes32(hex"ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"),
            bytes32(hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef")
        ];

        for (uint256 i = 0; i < testKeys.length; i++) {
            address derived = derive(testKeys[i]);
            assertTrue(derived != nativeToken, "derived should not match NATIVE_TOKEN");
        }
    }
}
