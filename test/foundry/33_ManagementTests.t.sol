// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import "../../contracts/Aori.sol";
import "../../contracts/IAori.sol";
import "./TestUtils.sol";

/**
 * @title ManagementTests
 * @notice Comprehensive tests for all owner-only management functions
 * @dev Tests all possible branches for pause, hook management, solver management, and chain management
 */
contract ManagementTests is TestUtils {
    
    // Test addresses
    address constant TEST_HOOK = address(0x1111);
    address constant TEST_SOLVER = address(0x2222);
    address constant NON_OWNER = address(0x3333);
    uint32 constant TEST_EID = 12345;

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                      PAUSE FUNCTIONS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful pause by owner
     */
    function testPause_Success() public {
        // Verify contract is not paused initially
        assertFalse(localAori.paused());
        
        // Owner pauses the contract
        vm.prank(address(this));
        localAori.pause();
        
        // Verify contract is now paused
        assertTrue(localAori.paused());
    }

    /**
     * @notice Test pause fails when called by non-owner
     */
    function testPause_OnlyOwner() public {
        // Non-owner attempts to pause
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.pause();
        
        // Verify contract is still not paused
        assertFalse(localAori.paused());
    }

    /**
     * @notice Test successful unpause by owner
     */
    function testUnpause_Success() public {
        // First pause the contract
        vm.prank(address(this));
        localAori.pause();
        assertTrue(localAori.paused());
        
        // Owner unpauses the contract
        vm.prank(address(this));
        localAori.unpause();
        
        // Verify contract is no longer paused
        assertFalse(localAori.paused());
    }

    /**
     * @notice Test unpause fails when called by non-owner
     */
    function testUnpause_OnlyOwner() public {
        // First pause the contract
        vm.prank(address(this));
        localAori.pause();
        assertTrue(localAori.paused());
        
        // Non-owner attempts to unpause
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.unpause();
        
        // Verify contract is still paused
        assertTrue(localAori.paused());
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    HOOK MANAGEMENT                         */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful addition of allowed hook by owner
     */
    function testAddAllowedHook_Success() public {
        // Verify hook is not allowed initially
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
        
        // Owner adds the hook
        vm.prank(address(this));
        localAori.addAllowedHook(TEST_HOOK);
        
        // Verify hook is now allowed
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
    }

    /**
     * @notice Test adding hook fails when called by non-owner
     */
    function testAddAllowedHook_OnlyOwner() public {
        // Non-owner attempts to add hook
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.addAllowedHook(TEST_HOOK);
        
        // Verify hook is still not allowed
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
    }

    /**
     * @notice Test adding zero address as hook
     */
    function testAddAllowedHook_ZeroAddress() public {
        // Owner adds zero address as hook
        vm.prank(address(this));
        localAori.addAllowedHook(address(0));
        
        // Verify zero address is now allowed (this is valid behavior)
        assertTrue(localAori.isAllowedHook(address(0)));
    }

    /**
     * @notice Test adding already allowed hook (idempotent operation)
     */
    function testAddAllowedHook_AlreadyAllowed() public {
        // First add the hook
        vm.prank(address(this));
        localAori.addAllowedHook(TEST_HOOK);
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
        
        // Add the same hook again
        vm.prank(address(this));
        localAori.addAllowedHook(TEST_HOOK);
        
        // Verify hook is still allowed
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
    }

    /**
     * @notice Test successful removal of allowed hook by owner
     */
    function testRemoveAllowedHook_Success() public {
        // First add the hook
        vm.prank(address(this));
        localAori.addAllowedHook(TEST_HOOK);
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
        
        // Owner removes the hook
        vm.prank(address(this));
        localAori.removeAllowedHook(TEST_HOOK);
        
        // Verify hook is no longer allowed
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
    }

    /**
     * @notice Test removing hook fails when called by non-owner
     */
    function testRemoveAllowedHook_OnlyOwner() public {
        // First add the hook
        vm.prank(address(this));
        localAori.addAllowedHook(TEST_HOOK);
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
        
        // Non-owner attempts to remove hook
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.removeAllowedHook(TEST_HOOK);
        
        // Verify hook is still allowed
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
    }

    /**
     * @notice Test removing non-existent hook (idempotent operation)
     */
    function testRemoveAllowedHook_NotAllowed() public {
        // Verify hook is not allowed initially
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
        
        // Owner removes non-existent hook
        vm.prank(address(this));
        localAori.removeAllowedHook(TEST_HOOK);
        
        // Verify hook is still not allowed
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                   SOLVER MANAGEMENT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful addition of allowed solver by owner
     */
    function testAddAllowedSolver_Success() public {
        // Verify solver is not allowed initially
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
        
        // Owner adds the solver
        vm.prank(address(this));
        localAori.addAllowedSolver(TEST_SOLVER);
        
        // Verify solver is now allowed
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /**
     * @notice Test adding solver fails when called by non-owner
     */
    function testAddAllowedSolver_OnlyOwner() public {
        // Non-owner attempts to add solver
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.addAllowedSolver(TEST_SOLVER);
        
        // Verify solver is still not allowed
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /**
     * @notice Test adding zero address as solver
     */
    function testAddAllowedSolver_ZeroAddress() public {
        // Owner adds zero address as solver
        vm.prank(address(this));
        localAori.addAllowedSolver(address(0));
        
        // Verify zero address is now allowed (this is valid behavior)
        assertTrue(localAori.isAllowedSolver(address(0)));
    }

    /**
     * @notice Test adding already allowed solver (idempotent operation)
     */
    function testAddAllowedSolver_AlreadyAllowed() public {
        // First add the solver
        vm.prank(address(this));
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
        
        // Add the same solver again
        vm.prank(address(this));
        localAori.addAllowedSolver(TEST_SOLVER);
        
        // Verify solver is still allowed
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /**
     * @notice Test successful removal of allowed solver by owner
     */
    function testRemoveAllowedSolver_Success() public {
        // First add the solver
        vm.prank(address(this));
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
        
        // Owner removes the solver
        vm.prank(address(this));
        localAori.removeAllowedSolver(TEST_SOLVER);
        
        // Verify solver is no longer allowed
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /**
     * @notice Test removing solver fails when called by non-owner
     */
    function testRemoveAllowedSolver_OnlyOwner() public {
        // First add the solver
        vm.prank(address(this));
        localAori.addAllowedSolver(TEST_SOLVER);
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
        
        // Non-owner attempts to remove solver
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.removeAllowedSolver(TEST_SOLVER);
        
        // Verify solver is still allowed
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /**
     * @notice Test removing non-existent solver (idempotent operation)
     */
    function testRemoveAllowedSolver_NotAllowed() public {
        // Verify solver is not allowed initially
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
        
        // Owner removes non-existent solver
        vm.prank(address(this));
        localAori.removeAllowedSolver(TEST_SOLVER);
        
        // Verify solver is still not allowed
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    CHAIN MANAGEMENT                        */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test successful addition of supported chain by owner
     */
    function testAddSupportedChain_Success() public {
        // Verify chain is not supported initially
        assertFalse(localAori.isSupportedChain(TEST_EID));
        
        // Owner adds the chain
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(TEST_EID);
        localAori.addSupportedChain(TEST_EID);
        
        // Verify chain is now supported
        assertTrue(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test adding supported chain fails when called by non-owner
     */
    function testAddSupportedChain_OnlyOwner() public {
        // Non-owner attempts to add chain
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.addSupportedChain(TEST_EID);
        
        // Verify chain is still not supported
        assertFalse(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test adding already supported chain (idempotent operation)
     */
    function testAddSupportedChain_AlreadySupported() public {
        // First add the chain
        vm.prank(address(this));
        localAori.addSupportedChain(TEST_EID);
        assertTrue(localAori.isSupportedChain(TEST_EID));
        
        // Add the same chain again
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(TEST_EID);
        localAori.addSupportedChain(TEST_EID);
        
        // Verify chain is still supported
        assertTrue(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test adding zero EID as supported chain
     */
    function testAddSupportedChain_ZeroEID() public {
        // Owner adds zero EID
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(0);
        localAori.addSupportedChain(0);
        
        // Verify zero EID is now supported
        assertTrue(localAori.isSupportedChain(0));
    }

    /**
     * @notice Test successful batch addition of supported chains
     */
    function testAddSupportedChains_Success() public {
        uint32[] memory eids = new uint32[](3);
        eids[0] = 111;
        eids[1] = 222;
        eids[2] = 333;
        
        // Verify chains are not supported initially
        assertFalse(localAori.isSupportedChain(111));
        assertFalse(localAori.isSupportedChain(222));
        assertFalse(localAori.isSupportedChain(333));
        
        // Owner adds multiple chains
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(111);
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(222);
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(333);
        
        bool[] memory results = localAori.addSupportedChains(eids);
        
        // Verify all chains are now supported
        assertTrue(localAori.isSupportedChain(111));
        assertTrue(localAori.isSupportedChain(222));
        assertTrue(localAori.isSupportedChain(333));
        
        // Verify all results are true
        assertEq(results.length, 3);
        assertTrue(results[0]);
        assertTrue(results[1]);
        assertTrue(results[2]);
    }

    /**
     * @notice Test batch addition fails when called by non-owner
     */
    function testAddSupportedChains_OnlyOwner() public {
        uint32[] memory eids = new uint32[](2);
        eids[0] = 111;
        eids[1] = 222;
        
        // Non-owner attempts to add chains
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.addSupportedChains(eids);
        
        // Verify chains are still not supported
        assertFalse(localAori.isSupportedChain(111));
        assertFalse(localAori.isSupportedChain(222));
    }

    /**
     * @notice Test batch addition with empty array
     */
    function testAddSupportedChains_EmptyArray() public {
        uint32[] memory eids = new uint32[](0);
        
        // Owner adds empty array
        vm.prank(address(this));
        bool[] memory results = localAori.addSupportedChains(eids);
        
        // Verify empty results array
        assertEq(results.length, 0);
    }

    /**
     * @notice Test batch addition with single element
     */
    function testAddSupportedChains_SingleElement() public {
        uint32[] memory eids = new uint32[](1);
        eids[0] = TEST_EID;
        
        // Verify chain is not supported initially
        assertFalse(localAori.isSupportedChain(TEST_EID));
        
        // Owner adds single chain
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainSupported(TEST_EID);
        bool[] memory results = localAori.addSupportedChains(eids);
        
        // Verify chain is now supported
        assertTrue(localAori.isSupportedChain(TEST_EID));
        assertEq(results.length, 1);
        assertTrue(results[0]);
    }

    /**
     * @notice Test successful removal of supported chain by owner
     */
    function testRemoveSupportedChain_Success() public {
        // First add the chain
        vm.prank(address(this));
        localAori.addSupportedChain(TEST_EID);
        assertTrue(localAori.isSupportedChain(TEST_EID));
        
        // Owner removes the chain
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainRemoved(TEST_EID);
        localAori.removeSupportedChain(TEST_EID);
        
        // Verify chain is no longer supported
        assertFalse(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test removing supported chain fails when called by non-owner
     */
    function testRemoveSupportedChain_OnlyOwner() public {
        // First add the chain
        vm.prank(address(this));
        localAori.addSupportedChain(TEST_EID);
        assertTrue(localAori.isSupportedChain(TEST_EID));
        
        // Non-owner attempts to remove chain
        vm.prank(NON_OWNER);
        vm.expectRevert();
        localAori.removeSupportedChain(TEST_EID);
        
        // Verify chain is still supported
        assertTrue(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test removing non-existent chain (idempotent operation)
     */
    function testRemoveSupportedChain_NotSupported() public {
        // Verify chain is not supported initially
        assertFalse(localAori.isSupportedChain(TEST_EID));
        
        // Owner removes non-existent chain
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainRemoved(TEST_EID);
        localAori.removeSupportedChain(TEST_EID);
        
        // Verify chain is still not supported
        assertFalse(localAori.isSupportedChain(TEST_EID));
    }

    /**
     * @notice Test removing the local chain (edge case)
     */
    function testRemoveSupportedChain_LocalChain() public {
        // Local chain should be supported by default
        assertTrue(localAori.isSupportedChain(localEid));
        
        // Owner removes local chain
        vm.prank(address(this));
        vm.expectEmit(true, false, false, false);
        emit ChainRemoved(localEid);
        localAori.removeSupportedChain(localEid);
        
        // Verify local chain is no longer supported
        assertFalse(localAori.isSupportedChain(localEid));
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                    INTEGRATION TESTS                       */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    /**
     * @notice Test multiple management operations in sequence
     */
    function testManagementOperations_Integration() public {
        vm.startPrank(address(this));
        
        // Add hook and solver
        localAori.addAllowedHook(TEST_HOOK);
        localAori.addAllowedSolver(TEST_SOLVER);
        localAori.addSupportedChain(TEST_EID);
        
        // Verify all are added
        assertTrue(localAori.isAllowedHook(TEST_HOOK));
        assertTrue(localAori.isAllowedSolver(TEST_SOLVER));
        assertTrue(localAori.isSupportedChain(TEST_EID));
        
        // Pause contract
        localAori.pause();
        assertTrue(localAori.paused());
        
        // Management operations should still work when paused
        localAori.removeAllowedHook(TEST_HOOK);
        localAori.removeAllowedSolver(TEST_SOLVER);
        localAori.removeSupportedChain(TEST_EID);
        
        // Verify all are removed
        assertFalse(localAori.isAllowedHook(TEST_HOOK));
        assertFalse(localAori.isAllowedSolver(TEST_SOLVER));
        assertFalse(localAori.isSupportedChain(TEST_EID));
        
        // Unpause contract
        localAori.unpause();
        assertFalse(localAori.paused());
        
        vm.stopPrank();
    }

    /**
     * @notice Test that management functions don't interfere with each other
     */
    function testManagementOperations_Independence() public {
        vm.startPrank(address(this));
        
        // Add multiple hooks and solvers
        address hook1 = address(0x1001);
        address hook2 = address(0x1002);
        address solver1 = address(0x2001);
        address solver2 = address(0x2002);
        
        localAori.addAllowedHook(hook1);
        localAori.addAllowedHook(hook2);
        localAori.addAllowedSolver(solver1);
        localAori.addAllowedSolver(solver2);
        
        // Remove one hook, verify others remain
        localAori.removeAllowedHook(hook1);
        assertFalse(localAori.isAllowedHook(hook1));
        assertTrue(localAori.isAllowedHook(hook2));
        assertTrue(localAori.isAllowedSolver(solver1));
        assertTrue(localAori.isAllowedSolver(solver2));
        
        // Remove one solver, verify others remain
        localAori.removeAllowedSolver(solver1);
        assertFalse(localAori.isAllowedHook(hook1));
        assertTrue(localAori.isAllowedHook(hook2));
        assertFalse(localAori.isAllowedSolver(solver1));
        assertTrue(localAori.isAllowedSolver(solver2));
        
        vm.stopPrank();
    }

    /*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
    /*                        EVENTS                              */
    /*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

    // Events from IAori interface
    event ChainSupported(uint32 indexed eid);
    event ChainRemoved(uint32 indexed eid);
}
