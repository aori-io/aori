// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice A specialized mock for testing ExecutionUtils
 * This mock directly interacts with ERC20 tokens and manipulates balances
 * to test the observeBalChg function
 */
contract ExecutionMockHook {
    // We need to make sure the transfers are happening DURING the call
    // that observeBalChg is monitoring
    
    function increaseBalance(address token, address account, uint256 amount) external {
        // Transfer tokens TO the caller (which is the contract using observeBalChg)
        // Important: This is the transfer that observeBalChg should detect
        IERC20(token).transfer(account, amount);
    }
    
    function decreaseBalance(address token, address account, uint256 amount) external {
        // Transfer tokens FROM the caller to this contract
        // Important: For negative changes, since observeBalChg uses unsigned math,
        // it should return 0 for any balance decrease
        IERC20(token).transferFrom(account, address(this), amount);
    }
    
    function noChange(address token) external view {
        // Just check balance, no changes
        IERC20(token).balanceOf(address(this));
    }
    
    // Helper to set up the mock with initial token balance
    function seedToken(address token, uint256 amount) external {
        // For testing purposes, assume any address can mint tokens
        // In real tests, we'd use a real MockERC20 with a mint function
    }
    
    // Function that always reverts
    function revertingFunction() external pure {
        revert("Reverting as requested");
    }
}