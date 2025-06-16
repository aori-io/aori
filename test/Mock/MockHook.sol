// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice A simple mock hook contract.
 *
 * It is designed so that when its "handleHook" function is called (via a low‑level call)
 * with a token address and an expected amount, it transfers that expected amount of
 * the specified token from its own balance to the caller (which in our use‑cases
 * is the Aori contract). This simulates a 1:1 conversion or pass‑through.
 */
contract MockHook {
    address public sourceToken;
    address public targetToken;
    
    // Native token address constant
    address constant NATIVE_TOKEN = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    constructor() {
        sourceToken = address(0);
        targetToken = address(0);
    }

    function handleHook(address tokenToReturn, uint256 expectedAmount) external {
        if (tokenToReturn == NATIVE_TOKEN) {
            // Handle native token
            uint256 available = address(this).balance;
            require(available >= expectedAmount, "Insufficient native funds in hook");
            (bool success, ) = payable(msg.sender).call{value: expectedAmount}("");
            require(success, "Native transfer failed");
        } else {
            // Handle ERC20 token
            uint256 available = IERC20(tokenToReturn).balanceOf(address(this));
            require(available >= expectedAmount, "Insufficient funds in hook");
            IERC20(tokenToReturn).transfer(msg.sender, expectedAmount);
        }
    }

    function execute() external {
        // Simple function that can be called to test hooks without token transfers
        // This doesn't need to do anything for our test cases
    }
    
    // Allow the contract to receive native tokens
    receive() external payable {}
}
