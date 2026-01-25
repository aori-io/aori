// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

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
    // PROTOCOL FEE STATE
    uint16 protocolFeeMbps; // in millibasis points (e.g., 100 = 0.1%)
    address protocolTreasury; // receives protocol fees
    mapping(address => uint256) pendingProtocolFees; // Accumulated protocol fees per token
    uint16 maxFeeMbps; // Maximum allowed additional fee in millibasis points
}

/**
 * @title AoriStorage
 * @notice ERC-7201 namespaced storage for the Aori contract
 * @dev This abstract contract defines the storage layout used by Aori and its upgradeable proxies.
 *      Using namespaced storage prevents storage collisions during upgrades.
 */

 // TODO: Compute new storage slot now that struct has changed
abstract contract AoriStorage {
    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    function _getAoriStorage() internal pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }
}
