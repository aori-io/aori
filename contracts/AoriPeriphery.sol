// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAori} from "./IAori.sol";

interface IAoriReader {
    function srcEidToFillerFills(
        uint32 srcEid,
        address filler,
        uint256 index
    ) external view returns (bytes32);
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
        );
}

/**
 * @title AoriPeriphery
 * @notice A periphery contract that aggregates fill statistics per endpoint ID
 * @dev Provides view functions to get order counts and input token sums for fillers
 */
contract AoriPeriphery {
    /// @notice The Aori contract to read from
    IAoriReader public immutable aori;

    /// @notice Statistics for a filler on a specific source endpoint
    struct FillerStats {
        uint256 orderCount;
        uint256 totalInputAmount;
    }

    /// @notice Detailed statistics broken down by input token
    struct TokenStats {
        address inputToken;
        uint256 orderCount;
        uint256 totalInputAmount;
    }

    constructor(address _aori) {
        require(_aori != address(0), "Invalid Aori address");
        aori = IAoriReader(_aori);
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
            bytes32[] memory temp = new bytes32[](100);
            uint256 count = 0;

            for (uint256 i = 0; i < 100; i++) {
                try aori.srcEidToFillerFills(srcEids[j], filler, i) returns (
                    bytes32 orderId
                ) {
                    temp[count++] = orderId;
                } catch {
                    break;
                }
            }

            // Copy to correctly sized array
            orderHashesPerEid[j] = new bytes32[](count);
            for (uint256 i = 0; i < count; i++) {
                orderHashesPerEid[j][i] = temp[i];
            }
        }
    }

    /**
     * @notice Get total input amounts grouped by input token for a list of order hashes
     * @param orderHashes Array of order hashes to query
     * @return inputTokens Array of unique input token addresses
     * @return totalAmounts Array of total input amounts corresponding to each token
     */
    function getOrdersInputTotals(
        bytes32[] calldata orderHashes
    )
        external
        view
        returns (address[] memory inputTokens, uint256[] memory totalAmounts)
    {
        // Use small fixed buffer - realistically won't have more than 20 unique tokens
        address[] memory tempTokens = new address[](20);
        uint256[] memory tempAmounts = new uint256[](20);
        uint256 uniqueCount = 0;

        for (uint256 i = 0; i < orderHashes.length; i++) {
            (uint128 inputAmount, , address inputToken, , , , , , , ) = aori
                .orders(orderHashes[i]);

            // Check if token already exists
            bool found = false;
            for (uint256 k = 0; k < uniqueCount; k++) {
                if (tempTokens[k] == inputToken) {
                    tempAmounts[k] += inputAmount;
                    found = true;
                    break;
                }
            }

            if (!found && uniqueCount < 20) {
                tempTokens[uniqueCount] = inputToken;
                tempAmounts[uniqueCount] = inputAmount;
                uniqueCount++;
            }
        }

        // Resize arrays using assembly (no copy needed)
        assembly {
            mstore(tempTokens, uniqueCount)
            mstore(tempAmounts, uniqueCount)
        }

        return (tempTokens, tempAmounts);
    }
}
