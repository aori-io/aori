// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
// Helper contract for testing hook failures

contract FailingHook {
    function alwaysFail() external pure {
        revert("Hook deliberately failed");
    }
}
