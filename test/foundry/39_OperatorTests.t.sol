// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.34;

import "forge-std/Test.sol";
import "../../contracts/Aori.sol";
import "../../contracts/AoriLens.sol";
import "../../contracts/interfaces/IAori.sol";
import "./TestUtils.sol";

contract OperatorTests is TestUtils {
    address constant OPERATOR = address(0x4444);
    address constant OPERATOR2 = address(0x5555);
    address constant NON_OWNER = address(0x3333);
    address constant TEST_HOOK = address(0x1111);
    address constant TEST_SOLVER = address(0x2222);
    uint32 constant TEST_EID = 12345;

    event OperatorAdded(address indexed operator);
    event OperatorRemoved(address indexed operator);

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  OPERATOR MANAGEMENT                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testAddOperator_Success() public {
        assertFalse(localAori.isOperator(OPERATOR));
        vm.expectEmit(true, false, false, false);
        emit OperatorAdded(OPERATOR);
        localAori.addOperator(OPERATOR);
        assertTrue(localAori.isOperator(OPERATOR));
    }

    function testAddOperator_OnlyOwner() public {
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.addOperator(OPERATOR);
        assertFalse(localAori.isOperator(OPERATOR));
    }

    function testAddOperator_OperatorCannotAddOperator() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.addOperator(OPERATOR2);
    }

    function testRemoveOperator_Success() public {
        localAori.addOperator(OPERATOR);
        assertTrue(localAori.isOperator(OPERATOR));

        vm.expectEmit(true, false, false, false);
        emit OperatorRemoved(OPERATOR);
        localAori.removeOperator(OPERATOR);
        assertFalse(localAori.isOperator(OPERATOR));
    }

    function testRemoveOperator_OnlyOwner() public {
        localAori.addOperator(OPERATOR);

        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.removeOperator(OPERATOR);
        assertTrue(localAori.isOperator(OPERATOR));
    }

    function testRemoveOperator_OperatorCannotRemoveSelf() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.removeOperator(OPERATOR);
        assertTrue(localAori.isOperator(OPERATOR));
    }

    function testMultipleOperators() public {
        localAori.addOperator(OPERATOR);
        localAori.addOperator(OPERATOR2);

        assertTrue(localAori.isOperator(OPERATOR));
        assertTrue(localAori.isOperator(OPERATOR2));

        localAori.removeOperator(OPERATOR);

        assertFalse(localAori.isOperator(OPERATOR));
        assertTrue(localAori.isOperator(OPERATOR2));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              OPERATOR CAN CALL OPERATIONAL FUNCTIONS          */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testOperator_AddAllowedSolver() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
    }

    function testOperator_RemoveAllowedSolver() public {
        localAori.addOperator(OPERATOR);
        localAori.addAllowedSolver(TEST_SOLVER);

        vm.prank(OPERATOR);
        localAori.removeAllowedSolver(TEST_SOLVER);
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
    }

    function testOperator_AddAllowedHook() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.addAllowedHook(TEST_HOOK);
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
    }

    function testOperator_RemoveAllowedHook() public {
        localAori.addOperator(OPERATOR);
        localAori.addAllowedHook(TEST_HOOK);

        vm.prank(OPERATOR);
        localAori.removeAllowedHook(TEST_HOOK);
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
    }

    function testOperator_AddSupportedChain() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.addSupportedChain(TEST_EID);
        assertTrue(localAori.isSupportedChain(TEST_EID));
    }

    function testOperator_RemoveSupportedChain() public {
        localAori.addOperator(OPERATOR);
        localAori.addSupportedChain(TEST_EID);

        vm.prank(OPERATOR);
        localAori.removeSupportedChain(TEST_EID);
        assertFalse(localAori.isSupportedChain(TEST_EID));
    }

    function testOperator_SetPeer() public {
        localAori.addOperator(OPERATOR);

        bytes32 peer = bytes32(uint256(uint160(address(0xBEEF))));
        vm.prank(OPERATOR);
        localAori.setPeer(TEST_EID, peer);
    }

    function testOperator_SetMaxFillsPerSettle() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.setMaxFillsPerSettle(20);
    }

    function testOperator_SetProtocolFee() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.setProtocolFee(50);
    }

    function testOperator_SetProtocolTreasury() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.setProtocolTreasury(OPERATOR2);
    }

    function testOperator_SetMaxFee() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        localAori.setMaxFee(500);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            OPERATOR CANNOT CALL CRITICAL FUNCTIONS            */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testOperator_CannotPause() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.pause();
    }

    function testOperator_CannotUnpause() public {
        localAori.pause();
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.unpause();
    }

    function testOperator_CannotEmergencyCancel() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.emergencyCancel(bytes32(0), address(this));
    }

    function testOperator_CannotEmergencyWithdraw() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.emergencyWithdraw(address(inputToken), 0, address(this));
    }

    function testOperator_CannotEmergencyWithdrawFromBalance() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.emergencyWithdrawFromBalance(address(inputToken), 0, userA, true, address(this));
    }

    function testOperator_CannotTransferOwnership() public {
        localAori.addOperator(OPERATOR);

        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.transferOwnership(OPERATOR);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*            NON-OWNER NON-OPERATOR CANNOT CALL                */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testNonOwnerNonOperator_CannotCallOperationalFunctions() public {
        vm.startPrank(NON_OWNER);

        vm.expectRevert();
        localAori.addAllowedSolver(TEST_SOLVER);

        vm.expectRevert();
        localAori.removeAllowedSolver(TEST_SOLVER);

        vm.expectRevert();
        localAori.addAllowedHook(TEST_HOOK);

        vm.expectRevert();
        localAori.removeAllowedHook(TEST_HOOK);

        vm.expectRevert();
        localAori.addSupportedChain(TEST_EID);

        vm.expectRevert();
        localAori.removeSupportedChain(TEST_EID);

        vm.expectRevert();
        localAori.setPeer(TEST_EID, bytes32(0));

        vm.expectRevert();
        localAori.setMaxFillsPerSettle(20);

        vm.expectRevert();
        localAori.setProtocolFee(50);

        vm.expectRevert();
        localAori.setProtocolTreasury(NON_OWNER);

        vm.expectRevert();
        localAori.setMaxFee(500);

        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*             OWNER CAN STILL CALL OPERATIONAL                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testOwner_CanStillCallOperationalFunctions() public {
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));

        localAori.addAllowedHook(TEST_HOOK);
        assertTrue(localAori.isAllowedHook(TEST_HOOK));

        localAori.addSupportedChain(TEST_EID);
        assertTrue(localAori.isSupportedChain(TEST_EID));

        localAori.setMaxFillsPerSettle(20);
        localAori.setProtocolFee(50);
        localAori.setProtocolTreasury(address(0xBEEF));
        localAori.setMaxFee(500);
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                REVOKED OPERATOR LOSES ACCESS                 */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testRevokedOperator_LosesAccess() public {
        localAori.addOperator(OPERATOR);

        // Operator can call
        vm.prank(OPERATOR);
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));

        // Revoke operator
        localAori.removeOperator(OPERATOR);

        // Operator can no longer call
        vm.prank(OPERATOR);
        vm.expectRevert();
        localAori.removeAllowedSolver(TEST_SOLVER);

        // Solver still there (revoke didn't affect state)
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                  INITIALIZE WITH OPERATORS                   */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testInitializeWithOperators() public {
        address[] memory operators = new address[](2);
        operators[0] = OPERATOR;
        operators[1] = OPERATOR2;

        Aori impl = new Aori(address(endpoints[localEid]), localEid);
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(
                Aori.initialize, (address(this), MAX_FILLS_PER_SETTLE, new address[](0), new address[](0), new uint32[](0), operators)
            )
        );
        Aori aori = Aori(payable(address(proxy)));

        assertTrue(aori.isOperator(OPERATOR));
        assertTrue(aori.isOperator(OPERATOR2));
        assertFalse(aori.isOperator(NON_OWNER));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*              AORILENS OPERATOR VIEW INTEGRATION              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    function testLens_IsOperator_ReturnsTrue() public {
        localAori.addOperator(OPERATOR);
        assertTrue(localLens.isOperator(OPERATOR));
    }

    function testLens_IsOperator_ReturnsFalse() public {
        assertFalse(localLens.isOperator(OPERATOR));
    }

    function testLens_IsOperator_AfterRemoval() public {
        localAori.addOperator(OPERATOR);
        assertTrue(localLens.isOperator(OPERATOR));

        localAori.removeOperator(OPERATOR);
        assertFalse(localLens.isOperator(OPERATOR));
    }

    function testLens_IsOperator_MatchesAoriDirect() public {
        localAori.addOperator(OPERATOR);
        localAori.addOperator(OPERATOR2);

        assertEq(localLens.isOperator(OPERATOR), localAori.isOperator(OPERATOR));
        assertEq(localLens.isOperator(OPERATOR2), localAori.isOperator(OPERATOR2));
        assertEq(localLens.isOperator(NON_OWNER), localAori.isOperator(NON_OWNER));
    }
}
