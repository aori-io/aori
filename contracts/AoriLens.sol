// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Order } from "../types/AoriTypes.sol";

/**
 * @title IAoriLensTarget
 * @notice Minimal interface for Aori storage reading
 */
interface IAoriLensTarget {
    function readStorage(
        bytes32 slot
    ) external view returns (bytes32);
    function readStorageArray(
        bytes32 slot
    ) external view returns (uint256);
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

    IAoriLensTarget public immutable aori;

    constructor(
        address _aori
    ) {
        aori = IAoriLensTarget(_aori);
    }

    /**
     * @notice Get order details by order ID
     */
    function orders(
        bytes32 orderId
    ) external view returns (Order memory order) {
        bytes32 baseSlot = keccak256(abi.encode(orderId, uint256(AORI_STORAGE_SLOT) + ORDERS_OFFSET));

        bytes32 slot0 = aori.readStorage(baseSlot);
        bytes32 slot1 = aori.readStorage(bytes32(uint256(baseSlot) + 1));
        bytes32 slot2 = aori.readStorage(bytes32(uint256(baseSlot) + 2));
        bytes32 slot3 = aori.readStorage(bytes32(uint256(baseSlot) + 3));
        bytes32 slot4 = aori.readStorage(bytes32(uint256(baseSlot) + 4));
        bytes32 slot5 = aori.readStorage(bytes32(uint256(baseSlot) + 5));

        order.inputAmount = uint128(uint256(slot0));
        order.outputAmount = uint128(uint256(slot0) >> 128);
        order.inputToken = address(uint160(uint256(slot1)));
        order.outputToken = address(uint160(uint256(slot2)));

        uint256 packedTimes = uint256(slot3);
        order.startTime = uint32(packedTimes);
        order.endTime = uint32(packedTimes >> 32);
        order.srcEid = uint32(packedTimes >> 64);
        order.dstEid = uint32(packedTimes >> 96);

        order.offerer = address(uint160(uint256(slot4)));
        order.recipient = address(uint160(uint256(slot5)));
    }

    /**
     * @notice Get locked balance for a user and token
     */
    function getLockedBalances(
        address user,
        address token
    ) external view returns (uint256) {
        bytes32 firstLevel = keccak256(abi.encode(user, uint256(AORI_STORAGE_SLOT) + BALANCES_OFFSET));
        bytes32 balanceSlot = keccak256(abi.encode(token, firstLevel));
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
    function MAX_FILLS_PER_SETTLE() public view returns (uint16) {
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
        bytes32 firstLevel = keccak256(abi.encode(srcEid, uint256(AORI_STORAGE_SLOT) + SRC_EID_TO_FILLER_FILLS_OFFSET));
        bytes32 arraySlot = keccak256(abi.encode(filler, firstLevel));
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

    // Note: quote() is kept in Aori.sol because it needs OApp's internal _quote() function
}
