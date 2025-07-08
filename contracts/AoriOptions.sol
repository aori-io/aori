// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { OAppOptionsType3, EnforcedOptionParam } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OAppOptionsType3.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title AoriOptions
 * @dev Abstract contract that provides LayerZero enforced options functionality for Aori protocol
 * @notice This contract implements LayerZero's enforced options pattern to ensure reliable cross-chain
 * message delivery. It supports two message types: settlement and cancellation messages.
 */
abstract contract AoriOptions is OAppOptionsType3 {
    
    /// @notice Message types for LayerZero operations
    uint16 public constant SETTLEMENT_MSG_TYPE = 1;
    uint16 public constant CANCELLATION_MSG_TYPE = 2;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                 ENFORCED OPTIONS MANAGEMENT                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Sets enforced options for settlement messages to a specific destination
     * @param dstEid The destination endpoint ID
     * @param options The enforced options (e.g., gas limit, msg.value)
     * @dev Only callable by the contract owner
     */
    function setEnforcedSettlementOptions(uint32 dstEid, bytes calldata options) external onlyOwner {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: dstEid,
            msgType: SETTLEMENT_MSG_TYPE,
            options: options
        });
        _setEnforcedOptions(enforcedOptions);
    }

    /**
     * @notice Sets enforced options for cancellation messages to a specific destination
     * @param dstEid The destination endpoint ID
     * @param options The enforced options (e.g., gas limit, msg.value)
     * @dev Only callable by the contract owner
     */
    function setEnforcedCancellationOptions(uint32 dstEid, bytes calldata options) external onlyOwner {
        EnforcedOptionParam[] memory enforcedOptions = new EnforcedOptionParam[](1);
        enforcedOptions[0] = EnforcedOptionParam({
            eid: dstEid,
            msgType: CANCELLATION_MSG_TYPE,
            options: options
        });
        _setEnforcedOptions(enforcedOptions);
    }

    /**
     * @notice Sets enforced options for multiple destinations and message types
     * @param enforcedOptions Array of enforced option parameters
     * @dev Only callable by the contract owner. Allows batch configuration.
     */
    function setEnforcedOptionsMultiple(EnforcedOptionParam[] calldata enforcedOptions) external onlyOwner {
        _setEnforcedOptions(enforcedOptions);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      VIEW FUNCTIONS                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Gets the enforced options for a specific endpoint and message type
     * @param eid The endpoint ID
     * @param msgType The message type (0 for settlement, 1 for cancellation)
     * @return The enforced options bytes
     */
    function getEnforcedOptions(uint32 eid, uint8 msgType) external view returns (bytes memory) {
        uint16 lzMsgType = _convertToLzMsgType(msgType);
        return enforcedOptions[eid][lzMsgType];
    }

    /**
     * @notice Gets the enforced options for settlement messages to a specific destination
     * @param eid The destination endpoint ID
     * @return The enforced options bytes for settlement messages
     */
    function getEnforcedSettlementOptions(uint32 eid) external view returns (bytes memory) {
        return enforcedOptions[eid][SETTLEMENT_MSG_TYPE];
    }

    /**
     * @notice Gets the enforced options for cancellation messages to a specific destination
     * @param eid The destination endpoint ID
     * @return The enforced options bytes for cancellation messages
     */
    function getEnforcedCancellationOptions(uint32 eid) external view returns (bytes memory) {
        return enforcedOptions[eid][CANCELLATION_MSG_TYPE];
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTERNAL FUNCTIONS                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Gets enforced options for settlement messages to a specific destination
     * @param dstEid The destination endpoint ID
     * @return enforcedOptions The enforced options (empty bytes if none set)
     */
    function _getSettlementOptions(uint32 dstEid) internal view returns (bytes memory) {
        return enforcedOptions[dstEid][SETTLEMENT_MSG_TYPE];
    }

    /**
     * @notice Gets enforced options for cancellation messages to a specific destination
     * @param dstEid The destination endpoint ID
     * @return enforcedOptions The enforced options (empty bytes if none set)
     */
    function _getCancellationOptions(uint32 dstEid) internal view returns (bytes memory) {
        return enforcedOptions[dstEid][CANCELLATION_MSG_TYPE];
    }

    /**
     * @notice Converts public API message type to LayerZero message type
     * @param msgType The public API message type (0 for settlement, 1 for cancellation)
     * @return The LayerZero message type constant
     */
    function _convertToLzMsgType(uint8 msgType) internal pure returns (uint16) {
        if (msgType == 0) {
            return SETTLEMENT_MSG_TYPE;
        } else if (msgType == 1) {
            return CANCELLATION_MSG_TYPE;
        } else {
            revert("Invalid message type");
        }
    }
} 