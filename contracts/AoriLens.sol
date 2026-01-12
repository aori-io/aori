// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import { Order, OrderStatus, Balance } from "./types/AoriTypes.sol";
import { PayloadSizeUtils, CANCELLATION_PAYLOAD_SIZE } from "./libraries/AoriUtils.sol";

/**
 * @title IAoriMinimal
 * @notice Minimal interface for Aori storage reading
 */
interface IAoriMinimal {
    function readStorage(
        bytes32 slot
    ) external view returns (bytes32);
    function readStorageArray(
        bytes32 slot
    ) external view returns (uint256);
    function endpoint() external view returns (address);
}

interface ILayerZeroEndpoint {
    function quote(
        uint32 _dstEid,
        address _sender,
        bytes calldata _message,
        bytes calldata _options,
        bool _payInLzToken
    ) external view returns (uint256 nativeFee, uint256 lzTokenFee);
}

/**
 * @title AoriLens
 * @notice External view contract for reading Aori state without adding bytecode to Aori
 * @dev Uses storage slot calculations based on ERC-7201 namespaced storage
 */
contract AoriLens {
    // ERC-7201 storage slot for AoriStorage
    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 constant AORI_STORAGE_SLOT = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    // Storage layout offsets within AoriStorageData struct
    uint256 constant BALANCES_OFFSET = 0;
    uint256 constant ORDERS_OFFSET = 1;
    uint256 constant IS_SUPPORTED_CHAIN_OFFSET = 2;
    uint256 constant MAX_FILLS_PER_SETTLE_OFFSET = 3;
    uint256 constant ORDER_STATUS_OFFSET = 4;
    uint256 constant IS_ALLOWED_HOOK_OFFSET = 5;
    uint256 constant IS_ALLOWED_SOLVER_OFFSET = 6;
    uint256 constant SRC_EID_TO_FILLER_FILLS_OFFSET = 7;

    IAoriMinimal public immutable aori;

    constructor(
        address _aori
    ) {
        aori = IAoriMinimal(_aori);
    }

    /**
     * @notice Get order details by order ID
     */
    function orders(
        bytes32 orderId
    )
        external
        view
        returns (
            uint128 inputAmount,
            uint128 outputAmount,
            address inputToken,
            address outputToken,
            uint32 startTime,
            uint32 endTime,
            uint32 srcEid,
            uint32 dstEid,
            address offerer,
            address recipient
        )
    {
        // Order mapping slot: keccak256(orderId, AORI_STORAGE_SLOT + ORDERS_OFFSET)
        bytes32 baseSlot = keccak256(abi.encode(orderId, uint256(AORI_STORAGE_SLOT) + ORDERS_OFFSET));

        // Order struct layout (packed):
        // Slot 0: inputAmount (128) | outputAmount (128)
        // Slot 1: inputToken (160) | startTime (32) | endTime (32) | srcEid (16) | dstEid (16) -- wait this doesn't fit

        // Actually Order struct:
        // uint128 inputAmount;  // slot 0 lower
        // uint128 outputAmount; // slot 0 upper
        // address inputToken;   // slot 1 lower 160 bits
        // address outputToken;  // slot 2 lower 160 bits
        // uint32 startTime;     // slot 3
        // uint32 endTime;       // slot 3 (packed)
        // uint32 srcEid;        // slot 3 (packed)
        // uint32 dstEid;        // slot 3 (packed)
        // address offerer;      // slot 4
        // address recipient;    // slot 5

        bytes32 slot0 = aori.readStorage(baseSlot);
        bytes32 slot1 = aori.readStorage(bytes32(uint256(baseSlot) + 1));
        bytes32 slot2 = aori.readStorage(bytes32(uint256(baseSlot) + 2));
        bytes32 slot3 = aori.readStorage(bytes32(uint256(baseSlot) + 3));
        bytes32 slot4 = aori.readStorage(bytes32(uint256(baseSlot) + 4));
        bytes32 slot5 = aori.readStorage(bytes32(uint256(baseSlot) + 5));

        inputAmount = uint128(uint256(slot0));
        outputAmount = uint128(uint256(slot0) >> 128);
        inputToken = address(uint160(uint256(slot1)));
        outputToken = address(uint160(uint256(slot2)));

        uint256 packedTimes = uint256(slot3);
        startTime = uint32(packedTimes);
        endTime = uint32(packedTimes >> 32);
        srcEid = uint32(packedTimes >> 64);
        dstEid = uint32(packedTimes >> 96);

        offerer = address(uint160(uint256(slot4)));
        recipient = address(uint160(uint256(slot5)));
    }

    /**
     * @notice Get locked balance for a user and token
     */
    function getLockedBalances(
        address user,
        address token
    ) external view returns (uint256) {
        // balances[user][token].locked
        // First level: keccak256(user, AORI_STORAGE_SLOT + BALANCES_OFFSET)
        // Second level: keccak256(token, firstLevelSlot)
        bytes32 firstLevel = keccak256(abi.encode(user, uint256(AORI_STORAGE_SLOT) + BALANCES_OFFSET));
        bytes32 balanceSlot = keccak256(abi.encode(token, firstLevel));

        // Balance struct: locked (128) | unlocked (128) in one slot
        bytes32 value = aori.readStorage(balanceSlot);
        return uint128(uint256(value)); // locked is lower 128 bits
    }

    /**
     * @notice Get unlocked balance for a user and token
     */
    function getUnlockedBalances(
        address user,
        address token
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(user, uint256(AORI_STORAGE_SLOT) + BALANCES_OFFSET));
        bytes32 balanceSlot = keccak256(abi.encode(token, firstLevel));

        bytes32 value = aori.readStorage(balanceSlot);
        return uint128(uint256(value) >> 128); // unlocked is upper 128 bits
    }

    /**
     * @notice Get max fills per settle
     */
    function MAX_FILLS_PER_SETTLE() external view returns (uint16) {
        bytes32 slot = bytes32(uint256(AORI_STORAGE_SLOT) + MAX_FILLS_PER_SETTLE_OFFSET);
        return uint16(uint256(aori.readStorage(slot)));
    }

    /**
     * @notice Get filler fills array element
     */
    function srcEidToFillerFills(
        uint32 srcEid,
        address filler,
        uint256 index
    ) external view returns (bytes32) {
        // srcEidToFillerFills[srcEid][filler][index]
        bytes32 firstLevel = keccak256(abi.encode(srcEid, uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
        bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));

        // Array element slot: keccak256(arraySlot) + index
        bytes32 elementSlot = bytes32(uint256(keccak256(abi.encode(arraySlot))) + index);
        return aori.readStorage(elementSlot);
    }

    /**
     * @notice Get filler fills array length
     */
    function srcEidToFillerFillsLength(
        uint32 srcEid,
        address filler
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(srcEid, uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
        bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));
        return aori.readStorageArray(arraySlot);
    }

    /**
     * @notice Quote LayerZero messaging fee
     */
    function quote(
        uint32 _dstEid,
        uint8 _msgType,
        bytes calldata _options,
        bool _payInLzToken,
        uint32 _srcEid,
        address _filler
    ) external view returns (MessagingFee memory) {
        // Get fills length and max fills
        uint256 fillsLength = this.srcEidToFillerFillsLength(_srcEid, _filler);
        uint16 maxFills = this.MAX_FILLS_PER_SETTLE();

        // Calculate payload size
        uint256 payloadSize = PayloadSizeUtils.calculatePayloadSize(_msgType, fillsLength, maxFills);

        // Quote from endpoint
        address endpoint = aori.endpoint();
        (uint256 nativeFee, uint256 lzTokenFee) =
            ILayerZeroEndpoint(endpoint).quote(_dstEid, address(aori), new bytes(payloadSize), _options, _payInLzToken);

        return MessagingFee(nativeFee, lzTokenFee);
    }
}
