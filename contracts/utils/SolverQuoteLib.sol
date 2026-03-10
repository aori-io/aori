// SPDX-License-Identifier: MIT
pragma solidity 0.8.34;

import { SignatureCheckerLib } from "solady/src/utils/SignatureCheckerLib.sol";
import { ECDSA } from "solady/src/utils/ECDSA.sol";
import { Order, SrcHook } from "../types/AoriTypes.sol";
import "../types/AoriErrors.sol";

/**
 * @title SolverQuoteLib
 * @notice Library for validating solver quote signatures for native deposits
 * @dev Implements EIP-712 signature validation to prevent users from manipulating
 *      order options and srcHook parameters in atomic native swaps.
 */
library SolverQuoteLib {
    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    EIP-712 TYPEHASHES                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @dev SrcHook typehash for EIP-712 struct hashing
     */
    bytes32 internal constant SRCHOOK_TYPEHASH = keccak256(
        "SrcHook(address hookAddress,address preferredToken,uint256 minPreferredTokenAmountOut,bytes instructions)"
    );

    /**
     * @dev SolverQuote typehash for EIP-712 struct hashing (includes nested SrcHook)
     * Format: SolverQuote(bytes32 orderId, SrcHook srcHook)
     */
    bytes32 internal constant SOLVER_QUOTE_TYPEHASH = keccak256(
        "SolverQuote(bytes32 orderId,SrcHook srcHook)"
        "SrcHook(address hookAddress,address preferredToken,uint256 minPreferredTokenAmountOut,bytes instructions)"
    );

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    HASHING FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Hash a SrcHook struct following EIP-712 struct hashing
     * @param hook The SrcHook to hash
     * @return The keccak256 hash of the SrcHook
     */
    function hashSrcHook(SrcHook calldata hook) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                SRCHOOK_TYPEHASH,
                hook.hookAddress,
                hook.preferredToken,
                hook.minPreferredTokenAmountOut,
                keccak256(hook.instructions)
            )
        );
    }

    /**
     * @notice Hash a SolverQuote (orderId + SrcHook) following EIP-712 struct hashing
     * @param orderId The order hash
     * @param hook The SrcHook containing swap parameters
     * @return The keccak256 hash of the complete solver quote
     */
    function hashSolverQuote(bytes32 orderId, SrcHook calldata hook) internal pure returns (bytes32) {
        return keccak256(abi.encode(SOLVER_QUOTE_TYPEHASH, orderId, hashSrcHook(hook)));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  SIGNATURE VALIDATION                      */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Validates that the solver quote signature is valid
     * @dev Verifies that the signature was created by a whitelisted solver over the exact
     *      order and srcHook parameters. Prevents users from manipulating quote terms.
     *      The signature commits to both the orderId and srcHook, preventing quote reuse.
     *      If order.options.srcSolver is specified, the signer must match that address.
     * @param orderId The computed order hash from the submitted order (keccak256(abi.encode(order)))
     * @param order The order details
     * @param hook The source hook configuration
     * @param signature The EIP-712 signature from the solver
     * @param hashTypedData Function pointer to compute EIP-712 digest
     * @param isAllowedSolver Function pointer to check if address is whitelisted solver
     */
    function validateSolverQuote(
        bytes32 orderId,
        Order calldata order,
        SrcHook calldata hook,
        bytes calldata signature,
        function(bytes32) internal view returns (bytes32) hashTypedData,
        function(address) external view returns (bool) isAllowedSolver
    ) internal view {
        // Hash the solver quote (orderId + srcHook)
        // NOTE: The orderId passed here is from the submitted order, and is included in the hash.
        // This binds the signature to both the specific order AND the srcHook.
        bytes32 quoteHash = hashSolverQuote(orderId, hook);

        // Get EIP-712 digest
        bytes32 digest = hashTypedData(quoteHash);

        // Recover signer from signature
        address signer = ECDSA.recoverCalldata(digest, signature);

        // If order specifies a solver, signer must match that solver
        if (order.options.srcSolver != address(0)) {
            if (signer != order.options.srcSolver) revert InvalidSolverQuoteSignature();
        }

        // Signer must be a whitelisted solver
        if (!isAllowedSolver(signer)) revert InvalidSolverQuoteSignature();
    }
}
