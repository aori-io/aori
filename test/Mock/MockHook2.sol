// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @notice A mock hook contract that resembles the actual ExampleHook/RouterCore pattern
 * @dev Simplified version for testing that handles both native and ERC20 tokens
 */
contract MockHook2 {
    using SafeERC20 for IERC20;
    
    // Native token constant (same as in ExampleHook)
    address public constant NATIVE = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    
    // Allow contract to receive native tokens
    receive() external payable {}
    
    /**
     * @notice Main swap function that mimics the ExampleHook pattern
     * @param tokenOut The token to output
     * @param amountOut The amount to output
     * @param recipient The recipient of the output tokens
     */
    function swap(
        address tokenOut,
        uint256 amountOut,
        address recipient
    ) external returns (uint256) {
        require(recipient != address(0), "MockHook2: Zero recipient");
        
        // Check we have sufficient balance and transfer
        if (tokenOut == NATIVE) {
            require(address(this).balance >= amountOut, "MockHook2: Insufficient native balance");
            (bool success, ) = payable(recipient).call{value: amountOut}("");
            require(success, "MockHook2: Native transfer failed");
        } else {
            uint256 balance = IERC20(tokenOut).balanceOf(address(this));
            require(balance >= amountOut, "MockHook2: Insufficient token balance");
            IERC20(tokenOut).safeTransfer(recipient, amountOut);
        }
        
        return amountOut;
    }
    
    /**
     * @notice Handle hook function for compatibility with existing tests
     * @dev Simulates a swap: receives ERC20 tokens, converts to native tokens
     * @param tokenToReturn The token to return (should be NATIVE for our test)
     * @param expectedAmount The amount of native tokens to return
     */
    function handleHook(address tokenToReturn, uint256 expectedAmount) external {
        require(msg.sender != address(0), "MockHook2: Zero recipient");
        
        // For our test, we expect the Aori contract to have already sent us ERC20 tokens
        // In a real hook, we'd check our balance of the input token here
        
        // Simulate the swap by sending the requested output tokens
        if (tokenToReturn == NATIVE) {
            require(address(this).balance >= expectedAmount, "MockHook2: Insufficient native balance");
            (bool success, ) = payable(msg.sender).call{value: expectedAmount}("");
            require(success, "MockHook2: Native transfer failed");
        } else {
            uint256 balance = IERC20(tokenToReturn).balanceOf(address(this));
            require(balance >= expectedAmount, "MockHook2: Insufficient token balance");
            IERC20(tokenToReturn).safeTransfer(msg.sender, expectedAmount);
        }
    }
    
    /**
     * @notice Get balance of this contract for a given token
     * @param token The token address (use NATIVE for native tokens)
     * @return The balance
     */
    function balanceOfThis(address token) public view returns (uint256) {
        if (token == NATIVE) {
            return address(this).balance;
        } else {
            return IERC20(token).balanceOf(address(this));
        }
    }
    
    /**
     * @notice Send tokens with limit check (mimics ExampleHook pattern)
     * @param token The token to send
     * @param limit The minimum amount required
     * @param to The recipient
     * @return bal The actual balance sent
     */
    function sendWithLimitCheck(
        address token,
        uint256 limit,
        address to
    ) public returns (uint256 bal) {
        require(to != address(0), "MockHook2: Zero recipient");
        
        if (token == NATIVE) {
            bal = address(this).balance;
            require(bal >= limit, "MockHook2: Insufficient native balance");
            (bool success, ) = payable(to).call{value: bal}("");
            require(success, "MockHook2: Native transfer failed");
        } else {
            bal = IERC20(token).balanceOf(address(this));
            require(bal >= limit, "MockHook2: Insufficient token balance");
            IERC20(token).safeTransfer(to, bal);
        }
    }
    
    /**
     * @notice Execute function for testing (no-op)
     */
    function execute() external {
        // Simple function that can be called to test hooks without token transfers
    }
    
    /**
     * @notice Simulates a proper DEX swap function
     * @param tokenIn The input token address
     * @param amountIn The amount of input tokens
     * @param tokenOut The output token address  
     * @param minAmountOut The minimum amount of output tokens
     * @return amountOut The actual amount of output tokens
     */
    function swapTokens(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 minAmountOut
    ) external payable returns (uint256 amountOut) {
        require(msg.sender != address(0), "MockHook2: Zero caller");
        
        // For this mock, we assume the caller (Aori contract) has already sent us the input tokens
        // via the preferedDstInputAmount mechanism, so we don't need to do transferFrom here.
        // In a real DEX, this would be different, but for our test setup this is how it works.
        
        // Verify we have the expected input tokens (for ERC20 tokens)
        if (tokenIn != NATIVE) {
            uint256 balance = IERC20(tokenIn).balanceOf(address(this));
            require(balance >= amountIn, "MockHook2: Insufficient input token balance");
        } else {
            // For native tokens, check msg.value
            require(msg.value == amountIn, "MockHook2: Incorrect native amount");
        }
        
        // Simulate conversion with different rates based on token types and amounts
        if (amountIn == 10000e6) {
            // Special case for SC_NativeToERC20 test: 10,000 preferred tokens (6 decimals) -> 2,100 output tokens (18 decimals)
            amountOut = 2100e18;
        } else {
            // Default 1:1 conversion for other cases (adjusting for decimal differences)
            if (tokenIn == NATIVE && tokenOut != NATIVE) {
                // Native (18 decimals) to ERC20 (18 decimals) - 1:1
                amountOut = amountIn;
            } else if (tokenIn != NATIVE && tokenOut == NATIVE) {
                // ERC20 to Native - adjust for decimals
                // Assume input token has 6 decimals, native has 18 decimals
                amountOut = amountIn * 1e12; // Scale up from 6 to 18 decimals
            } else if (tokenIn != NATIVE && tokenOut != NATIVE) {
                // ERC20 to ERC20 - assume both have 18 decimals for simplicity
                amountOut = amountIn;
            } else {
                // Native to Native - 1:1
                amountOut = amountIn;
            }
        }
        
        require(amountOut >= minAmountOut, "MockHook2: Insufficient output");
        
        // Send output tokens
        if (tokenOut == NATIVE) {
            require(address(this).balance >= amountOut, "MockHook2: Insufficient native balance");
            (bool success, ) = payable(msg.sender).call{value: amountOut}("");
            require(success, "MockHook2: Native transfer failed");
        } else {
            uint256 balance = IERC20(tokenOut).balanceOf(address(this));
            require(balance >= amountOut, "MockHook2: Insufficient token balance");
            IERC20(tokenOut).safeTransfer(msg.sender, amountOut);
        }
        
        return amountOut;
    }
}
