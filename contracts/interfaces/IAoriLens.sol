// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { Order } from "../types/AoriTypes.sol";

/**
 * @title IAoriLens
 * @notice Interface for external view contract that reads Aori state
 */
interface IAoriLens {
    /**
     * @notice Get the target Aori contract address
     * @return The Aori contract that this lens reads from
     */
    function aori() external view returns (address);

    /**
     * @notice Get order details by order ID
     * @param orderId The unique order identifier
     * @return order The complete order struct
     */
    function orders(
        bytes32 orderId
    ) external view returns (Order memory order);

    /**
     * @notice Get locked balance for a user and token
     * @param user The user address
     * @param token The token address
     * @return The locked balance amount
     */
    function getLockedBalances(address user, address token) external view returns (uint256);

    /**
     * @notice Get unlocked balance for a user and token
     * @param user The user address
     * @param token The token address
     * @return The unlocked balance amount
     */
    function getUnlockedBalances(address user, address token) external view returns (uint256);

    /**
     * @notice Get max fills per settle
     * @return The maximum number of fills allowed per settlement
     */
    function MAX_FILLS_PER_SETTLE() external view returns (uint16);

    /**
     * @notice Get filler fills array element
     * @param srcEid The source endpoint ID
     * @param filler The filler address
     * @param index The array index
     * @return The order ID at the specified index
     */
    function srcEidToFillerFills(uint32 srcEid, address filler, uint256 index) external view returns (bytes32);

    /**
     * @notice Get filler fills array length
     * @param srcEid The source endpoint ID
     * @param filler The filler address
     * @return The number of fills for the filler on the source chain
     */
    function srcEidToFillerFillsLength(uint32 srcEid, address filler) external view returns (uint256);

    /**
     * @notice Get all order hashes for a filler across multiple source endpoints
     * @param srcEids Array of source endpoint IDs to query
     * @param filler The filler address
     * @return orderHashesPerEid Array of order hash arrays, one per source endpoint
     */
    function getPendingSettle(uint32[] calldata srcEids, address filler) external view returns (bytes32[][] memory orderHashesPerEid);

    /**
     * @notice Get total input amounts grouped by input token for a list of order hashes
     * @param orderHashes Array of order hashes to query
     * @return inputTokens Array of unique input token addresses
     * @return totalAmounts Array of total input amounts corresponding to each token
     */
    function getOrdersInputTotals(
        bytes32[] calldata orderHashes
    ) external view returns (address[] memory inputTokens, uint256[] memory totalAmounts);
}
