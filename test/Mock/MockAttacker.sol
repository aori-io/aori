// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../../contracts/IAori.sol";
import "../../contracts/Aori.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ReentrantAttacker {
    Aori public aori;
    IAori.Order public targetOrder;

    constructor(address payable _aori) {
        aori = Aori(_aori);
    }

    function setTargetOrder(IAori.Order memory _order) external {
        targetOrder = _order;
    }

    function attack() external {
        // Create a fake signature (doesn't matter since we'll bypass signature check)
        bytes memory signature = new bytes(65);

        // Create solver data
        IAori.SrcHook memory data = IAori.SrcHook({
            hookAddress: address(this), // Use this contract as the hook
            preferredToken: address(0x1234), // Use a different token for conversion
            minPreferedTokenAmountOut: 1000, // Arbitrary minimum amount
            instructions: abi.encodeWithSelector(this.attackHook.selector)
        });

        // Approve tokens first
        IERC20(targetOrder.inputToken).approve(address(aori), targetOrder.inputAmount);

        // Call deposit which will trigger our malicious hook
        aori.deposit(targetOrder, signature, data);
    }

    // This is called during deposit and attempts to reenter
    function attackHook() external {
        // Try to reenter by calling withdraw
        aori.withdraw(targetOrder.inputToken, 0);

        // Make sure hook doesn't revert
        IERC20(targetOrder.inputToken).transfer(address(aori), targetOrder.inputAmount);
    }

    // Allow receiving ETH
    receive() external payable {}
}
