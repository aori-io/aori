// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import { ISignatureTransfer } from "permit2/src/interfaces/ISignatureTransfer.sol";
import { IAori } from "../IAori.sol";

/// @title Permit2Lib
/// @notice Library for Permit2 SignatureTransfer integration with Aori orders
/// @dev Uses witness-based signing where the Order struct is included in the Permit2 signature
library Permit2Lib {
    /// @dev Canonical Permit2 address (same on all EVM chains)
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /// @dev Order typehash for witness hashing
    /// keccak256("Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)")
    bytes32 internal constant ORDER_TYPEHASH = 0x16210483e9c961c9c307e53963eafad0795395f2fce68f0c9c294cca1ac5a06a;

    /// @dev Witness type string for permitWitnessTransferFrom
    /// Combined with Permit2's stub: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,"
    /// Results in full typehash: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)Order(...)TokenPermissions(...)"
    /// Alphabetical ordering per EIP-712: Order (O) < TokenPermissions (T)
    string internal constant WITNESS_TYPE_STRING =
        "Order witness)"
        "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
        "TokenPermissions(address token,uint256 amount)";

    /// @notice Hash an order for use as Permit2 witness
    /// @param order The order to hash
    /// @return The keccak256 hash of the order following EIP-712 struct hashing
    function hashOrder(IAori.Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.outputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid,
                order.offerer,
                order.recipient
            )
        );
    }

    /// @notice Build PermitTransferFrom struct from order parameters
    /// @param order The order containing token and amount info
    /// @param nonce Permit2 nonce for replay protection
    /// @param deadline Signature expiration timestamp
    /// @return permit The constructed PermitTransferFrom struct
    function buildPermit(
        IAori.Order calldata order,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (ISignatureTransfer.PermitTransferFrom memory permit) {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({
                token: order.inputToken,
                amount: order.inputAmount
            }),
            nonce: nonce,
            deadline: deadline
        });
    }

    /// @notice Build SignatureTransferDetails struct
    /// @param to Recipient address for the transfer
    /// @param amount Amount to transfer
    /// @return details The constructed SignatureTransferDetails struct
    function buildTransferDetails(
        address to,
        uint256 amount
    ) internal pure returns (ISignatureTransfer.SignatureTransferDetails memory details) {
        details = ISignatureTransfer.SignatureTransferDetails({
            to: to,
            requestedAmount: amount
        });
    }
}
