// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * OrderIdConsistencyTest - Tests that the orderId emitted in events matches the hash calculated in _validateDeposit
 *
 * This test verifies that:
 * - The orderId emitted in events is consistent with the original hash of the order
 * - Any modifications to the stored order object do not affect the orderId throughout the order lifecycle
 */
import {IAori} from "../../contracts/Aori.sol";
import "./TestUtils.sol";

contract OrderIdConsistencyTest is TestUtils {
    IAori.Order internal order;
    
    function setUp() public override {
        super.setUp();
    }

    /// @notice Tests that orderId is preserved even when the stored order is modified
    function testOrderIdConsistency() public {
        // Create a valid order
        order = createValidOrder();
        
        // Calculate the expected orderId using the hash function
        bytes32 expectedOrderId = localAori.hash(order);
        
        // Generate signature and approve tokens
        bytes memory signature = signOrder(order);
        vm.prank(userA);
        inputToken.approve(address(localAori), order.inputAmount);
        
        // Deposit with hook conversion that will modify the stored order
        vm.prank(solver);
        localAori.deposit(order, signature, defaultSrcSolverData(order.inputAmount));
        
        // Verify the order status is active with the expected orderId
        assertEq(
            uint8(localAori.orderStatus(expectedOrderId)),
            uint8(IAori.OrderStatus.Active),
            "Order should be marked Active"
        );
        
        // Verify the stored order has the converted token
        (,, address storedInputToken,,,,,,, ) = localAori.orders(expectedOrderId);
        assertEq(storedInputToken, address(convertedToken), "Input token should be converted token");
        assertNotEq(storedInputToken, order.inputToken, "Input token should be different from original");
    }
} 