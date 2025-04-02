// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../Mock/MockERC20.sol";

contract RevertingToken is MockERC20 {
    bool public revertOnTransfer;

    constructor(string memory name, string memory symbol) MockERC20(name, symbol) {
        revertOnTransfer = false;
    }

    function setRevertOnTransfer(bool _revert) external {
        revertOnTransfer = _revert;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        if (revertOnTransfer) {
            revert("ERC20: transfer failed");
        }

        // Implement the transfer logic directly
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        if (revertOnTransfer) {
            revert("ERC20: transfer failed");
        }

        // Implement the transferFrom logic directly
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");
        balanceOf[from] -= amount;
        allowance[from][msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
