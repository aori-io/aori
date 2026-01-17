// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { Order } from "../types/AoriTypes.sol";

/**
 * @title IAoriPeriphery
 * @notice Minimal interface for Aori view functions used by periphery
 */
interface IAoriPeriphery {
    function srcEidToFillerFills(
        uint32 srcEid,
        address filler,
        uint256 index
    ) external view returns (bytes32);
    function srcEidToFillerFillsLength(
        uint32 srcEid,
        address filler
    ) external view returns (uint256);
    function orders(
        bytes32 orderId
    ) external view returns (Order memory);
}
