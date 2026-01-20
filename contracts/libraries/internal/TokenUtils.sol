// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../types/AoriErrors.sol";

// Native token address constant
address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

/**
 * @notice Library for token operations (native ETH and ERC20)
 * @dev Provides utilities for handling native ETH alongside ERC20 tokens
 */
library TokenUtils {
    using SafeERC20 for IERC20;

    /**
     * @notice Checks if a token address represents native ETH
     * @param token The token address to check
     * @return True if the token is the native token address
     */
    /* forgefmt: disable-next-item */
    function isNativeToken(address token) internal pure returns (bool) { return token == NATIVE_TOKEN; }

    /**
     * @notice Safely transfers tokens (native or ERC20) to a recipient
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransfer(
        address token,
        address to,
        uint256 amount
    ) internal {
        if (isNativeToken(token)) {
            (bool success,) = payable(to).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
    }

    /**
     * @notice Gets the balance of a token for a specific address
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param account The account to check balance for
     * @return The token balance
     */
    function balanceOf(
        address token,
        address account
    ) internal view returns (uint256) {
        if (isNativeToken(token)) {
            return account.balance;
        } else {
            return IERC20(token).balanceOf(account);
        }
    }

    /**
     * @notice Validates that the contract has sufficient balance for a transfer
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param amount The amount to validate
     */
    function validateSufficientBalance(
        address token,
        uint256 amount
    ) internal view {
        if (isNativeToken(token)) {
            if (address(this).balance < amount) revert InsufficientContractBalance(NATIVE_TOKEN);
        } else {
            if (IERC20(token).balanceOf(address(this)) < amount) revert InsufficientContractBalance(token);
        }
    }

    /**
     * @notice Validates msg.value matches expected amount for token type
     * @param token The token address (use NATIVE_TOKEN for ETH)
     * @param expectedAmount The expected amount
     * @param msgValue The msg.value to validate
     */
    function validateMsgValue(
        address token,
        uint256 expectedAmount,
        uint256 msgValue
    ) internal pure {
        if (isNativeToken(token)) {
            if (msgValue != expectedAmount) revert IncorrectNativeAmount(expectedAmount, msgValue);
        } else {
            if (msgValue != 0) revert UnexpectedNativeTokens();
        }
    }

    /**
     * @notice Transfers tokens from sender, handling native vs ERC20
     * @param token The token address
     * @param from The sender address
     * @param to The recipient address
     * @param amount The amount to transfer
     */
    function safeTransferFrom(
        address token,
        address from,
        address to,
        uint256 amount
    ) internal {
        if (isNativeToken(token)) {
            (bool success,) = payable(to).call{ value: amount }("");
            if (!success) revert NativeTransferFailed();
        } else {
            IERC20(token).safeTransferFrom(from, to, amount);
        }
    }
}
