// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { Order, OrderStatus, Balance } from "../../types/AoriTypes.sol";
import { AoriStorageData } from "../../storage/AoriStorage.sol";
import { BalanceUtils } from "../internal/BalanceUtils.sol";

/**
 * @title DepositLib
 * @notice External library for deposit and fill post-processing
 * @dev Functions are called via DELEGATECALL
 */
library DepositLib {
    using BalanceUtils for Balance;

    // keccak256(abi.encode(uint256(keccak256("aori.storage.v1")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant AORI_STORAGE_LOCATION = 0x476c06ce9bda338755e203b7f327971f808163bb891bef1bf37f35e88d0aae00;

    event Deposit(bytes32 indexed orderId, Order order, uint16 feeMbps);
    event Fill(bytes32 indexed orderId, Order order);

    function _getAoriStorage() private pure returns (AoriStorageData storage $) {
        assembly {
            $.slot := AORI_STORAGE_LOCATION
        }
    }

    /**
     * @notice Posts a deposit and updates the order status
     */
    function postDeposit(
        address depositToken,
        uint256 depositAmount,
        Order calldata order,
        bytes32 orderId
    ) external {
        AoriStorageData storage $ = _getAoriStorage();
        $.balances[order.offerer][depositToken].lock(SafeCast.toUint128(depositAmount));
        $.orderStatus[orderId] = OrderStatus.Active;
        $.orders[orderId] = order;
        $.orders[orderId].inputToken = depositToken;
        $.orders[orderId].inputAmount = SafeCast.toUint128(depositAmount);

        emit Deposit(orderId, order, order.options.feeMbps);
    }

    /**
     * @notice Processes an order after successful filling
     */
    function postFill(bytes32 orderId, Order calldata order, address filler, uint32 srcEid) external {
        AoriStorageData storage $ = _getAoriStorage();
        $.orderStatus[orderId] = OrderStatus.Filled;
        $.srcEidToFillerFills[srcEid][filler].push(orderId);
        emit Fill(orderId, order);
    }
}
