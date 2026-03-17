// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { ISignatureTransfer } from "@permit2/src/interfaces/ISignatureTransfer.sol";
import { Order, Options } from "../types/AoriTypes.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                          PERMIT2                            */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/**
 * @notice Library for Permit2 SignatureTransfer integration with Aori orders
 * @dev Uses witness-based signing where the Order struct is included in the Permit2 signature
 */
library Permit2Lib {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         CONSTANTS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @dev Canonical Permit2 address (same on all EVM chains)
     */
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    /**
     * @dev Options typehash for witness hashing
     */
    bytes32 internal constant OPTIONS_TYPEHASH =
        keccak256("Options(uint16 feeMbps,uint16 slippageMbps,address feeRecipient,address srcSolver,address dstSolver)");

    /**
     * @dev Order typehash for witness hashing (includes nested Options)
     */
    bytes32 internal constant ORDER_TYPEHASH = keccak256(
        "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,uint32 startTime,"
        "uint32 endTime,uint32 srcEid,address outputToken,uint32 dstEid,address offerer,address recipient," "Options options)"
        "Options(uint16 feeMbps,uint16 slippageMbps,address feeRecipient,address srcSolver,address dstSolver)"
    );

    /**
     * @dev Witness type string for permitWitnessTransferFrom
     * Combined with Permit2's stub: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,"
     * Results in full typehash: "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,Order witness)Options(...)Order(...)TokenPermissions(...)"
     * Alphabetical ordering per EIP-712: Options (O) < Order (O) < TokenPermissions (T)
     */
    string internal constant WITNESS_TYPE_STRING = "Order witness)"
        "Options(uint16 feeMbps,uint16 slippageMbps,address feeRecipient,address srcSolver,address dstSolver)"
        "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,uint32 startTime,"
        "uint32 endTime,uint32 srcEid,address outputToken,uint32 dstEid,address offerer,address recipient," "Options options)"
        "TokenPermissions(address token,uint256 amount)";

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                         FUNCTIONS                           */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Hash Options for Permit2 witness
     * @param options The options to hash
     * @return The keccak256 hash of the options following EIP-712 struct hashing
     */
    function hashOptions(
        Options calldata options
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(OPTIONS_TYPEHASH, options.feeMbps, options.slippageMbps, options.feeRecipient, options.srcSolver, options.dstSolver));
    }

    /**
     * @notice Hash an order for use as Permit2 witness
     * @param order The order to hash
     * @return The keccak256 hash of the order following EIP-712 struct hashing
     */
    /* forgefmt: disable-next-item */
    function hashOrder(Order calldata order) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                ORDER_TYPEHASH,
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.outputToken,
                order.dstEid,
                order.offerer,
                order.recipient,
                hashOptions(order.options)
            )
        );
    }

    /**
     * @notice Build PermitTransferFrom struct from order parameters
     * @param order The order containing token and amount info
     * @param nonce Permit2 nonce for replay protection
     * @param deadline Signature expiration timestamp
     * @return permit The constructed PermitTransferFrom struct
     */
    function buildPermit(
        Order calldata order,
        uint256 nonce,
        uint256 deadline
    ) internal pure returns (ISignatureTransfer.PermitTransferFrom memory permit) {
        permit = ISignatureTransfer.PermitTransferFrom({
            permitted: ISignatureTransfer.TokenPermissions({ token: order.inputToken, amount: order.inputAmount }),
            nonce: nonce,
            deadline: deadline
        });
    }

    /**
     * @notice Build SignatureTransferDetails struct
     * @param to Recipient address for the transfer
     * @param amount Amount to transfer
     * @return details The constructed SignatureTransferDetails struct
     */
    function buildTransferDetails(
        address to,
        uint256 amount
    ) internal pure returns (ISignatureTransfer.SignatureTransferDetails memory details) {
        details = ISignatureTransfer.SignatureTransferDetails({ to: to, requestedAmount: amount });
    }

    /**
     * @notice Execute Permit2 witness transfer
     * @param order The order (used as witness)
     * @param to Transfer recipient
     * @param nonce Permit2 nonce
     * @param deadline Signature deadline
     * @param signature User's signature
     */
    function executeTransfer(Order calldata order, address to, uint256 nonce, uint256 deadline, bytes calldata signature) internal {
        ISignatureTransfer.PermitTransferFrom memory permit = buildPermit(order, nonce, deadline);
        ISignatureTransfer.SignatureTransferDetails memory transferDetails = buildTransferDetails(to, order.inputAmount);
        bytes32 witness = hashOrder(order);
        ISignatureTransfer(PERMIT2).permitWitnessTransferFrom(
            permit, transferDetails, order.offerer, witness, WITNESS_TYPE_STRING, signature
        );
    }
}
