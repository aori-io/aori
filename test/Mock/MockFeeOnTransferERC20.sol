// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import {MockERC20} from "./MockERC20.sol";

/// @notice ERC20 mock that deducts a percentage fee on every transfer (burned, not credited)
contract MockFeeOnTransferERC20 is MockERC20 {
    uint256 public feePercent;

    constructor(string memory _name, string memory _symbol, uint256 _feePercent) MockERC20(_name, _symbol) {
        feePercent = _feePercent;
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        uint256 fee = amount * feePercent / 100;
        uint256 amountAfterFee = amount - fee;
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amountAfterFee;
        totalSupply -= fee;
        emit Transfer(msg.sender, recipient, amountAfterFee);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(balanceOf[sender] >= amount, "Insufficient balance");
        require(allowance[sender][msg.sender] >= amount, "Allowance exceeded");
        uint256 fee = amount * feePercent / 100;
        uint256 amountAfterFee = amount - fee;
        balanceOf[sender] -= amount;
        allowance[sender][msg.sender] -= amount;
        balanceOf[recipient] += amountAfterFee;
        totalSupply -= fee;
        emit Transfer(sender, recipient, amountAfterFee);
        return true;
    }
}
