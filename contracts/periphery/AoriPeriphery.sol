// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import "../types/AoriErrors.sol";
import { Order } from "../types/AoriTypes.sol";
import { IAoriPeriphery } from "../interfaces/IAoriPeriphery.sol";

/**
 * @title AoriPeriphery
 * @notice A periphery contract that aggregates fill statistics per endpoint ID
 * @dev Provides view functions to get order counts and input token sums for fillers
 *      Now reads from AoriLens instead of Aori directly to reduce Aori bytecode
 */
contract AoriPeriphery {
    /// @notice The AoriLens contract to read from
    IAoriPeriphery public immutable lens;

    /* forgefmt: disable-next-item */
    constructor(address _lens) {
        if (_lens == address(0)) revert InvalidAoriAddress();
        lens = IAoriPeriphery(_lens);
    }

    /**
     * @notice Get all order hashes for a filler across multiple source endpoints
     * @param srcEids Array of source endpoint IDs to query
     * @param filler The filler address
     * @return orderHashesPerEid Array of order hash arrays, one per source endpoint
     */
    function getPendingSettle(
        uint32[] calldata srcEids,
        address filler
    ) external view returns (bytes32[][] memory orderHashesPerEid) {
        orderHashesPerEid = new bytes32[][](srcEids.length);

        for (uint256 j = 0; j < srcEids.length; j++) {
            uint256 length = lens.srcEidToFillerFillsLength(srcEids[j], filler);
            bytes32[] memory fills = new bytes32[](length);

            for (uint256 i = 0; i < length; i++) {
                fills[i] = lens.srcEidToFillerFills(srcEids[j], filler, i);
            }

            orderHashesPerEid[j] = fills;
        }
    }

    /**
     * @notice Get total input amounts grouped by input token for a list of order hashes
     * @param orderHashes Array of order hashes to query
     * @return inputTokens Array of unique input token addresses
     * @return totalAmounts Array of total input amounts corresponding to each token
     */
    /* forgefmt: disable-next-item */
    function getOrdersInputTotals(bytes32[] calldata orderHashes) external view returns (address[] memory inputTokens, uint256[] memory totalAmounts) {
        address[] memory tempTokens = new address[](20);
        uint256[] memory tempAmounts = new uint256[](20);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < orderHashes.length; i++) {
            Order memory order = lens.orders(orderHashes[i]);

            bool found = false;
            for (uint256 k = 0; k < uniqueCount; k++) {
                if (tempTokens[k] == order.inputToken) {
                    tempAmounts[k] += order.inputAmount;
                    found = true;
                    break;
                }
            }

            if (!found && uniqueCount < 20) {
                tempTokens[uniqueCount] = order.inputToken;
                tempAmounts[uniqueCount] = order.inputAmount;
                uniqueCount++;
            }
        }

        assembly {
            mstore(tempTokens, uniqueCount)
            mstore(tempAmounts, uniqueCount)
        }
        return (tempTokens, tempAmounts);
    }
}
