// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "../Mock/MockERC20.sol";

contract FeeOnTransferToken is MockERC20 {
    uint256 public feeInBasisPoints; // 100 = 1%

    constructor(string memory name, string memory symbol, uint256 _feeInBasisPoints) MockERC20(name, symbol) {
        feeInBasisPoints = _feeInBasisPoints;
    }

    function transfer(address to, uint256 amount) external override returns (bool) {
        uint256 fee = (amount * feeInBasisPoints) / 10000;
        uint256 netAmount = amount - fee;

        // Burn the fee
        _burn(msg.sender, fee);

        // Transfer the rest
        balanceOf[msg.sender] -= netAmount;
        balanceOf[to] += netAmount;
        emit Transfer(msg.sender, to, netAmount);

        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external override returns (bool) {
        require(allowance[from][msg.sender] >= amount, "Allowance exceeded");

        uint256 fee = (amount * feeInBasisPoints) / 10000;
        uint256 netAmount = amount - fee;

        // Burn the fee
        _burn(from, fee);

        // Transfer the rest
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= netAmount;
        balanceOf[to] += netAmount;
        emit Transfer(from, to, netAmount);

        return true;
    }
}
