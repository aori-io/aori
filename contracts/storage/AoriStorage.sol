// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { Order, OrderStatus, Balance } from "../types/AoriTypes.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    ERC-7201 STORAGE                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @custom:storage-location erc7201:aori.storage.v1
struct AoriStorageData {
    // SRC STATE
    mapping(address => mapping(address => Balance)) balances;
    mapping(bytes32 => Order) orders;
    mapping(uint32 => bool) isSupportedChain;
    // DST STATE
    uint16 maxFillsPerSettle;
    mapping(bytes32 => OrderStatus) orderStatus;
    mapping(address => bool) isAllowedHook;
    mapping(address => bool) isAllowedSolver;
    mapping(uint32 => mapping(address => bytes32[])) srcEidToFillerFills;
}

/**
 * @title AoriStorage
 * @notice ERC-7201 namespaced storage for the Aori contract
 * @dev This abstract contract defines the storage layout used by Aori and its upgradeable proxies.
 *      Using namespaced storage prevents storage collisions during upgrades.
 */
abstract contract AoriStorage {
    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION =
        0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    function _getAoriStorage() internal pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }
}
