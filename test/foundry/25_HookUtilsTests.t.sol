// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * HookUtilsTest - Tests for the HookUtils library in AoriUtils.sol
 *
 * Test cases:
 * 1. test_isSome_SrcHook_zeroAddress - Tests isSome with zero address for SrcHook
 * 2. test_isSome_SrcHook_nonZeroAddress - Tests isSome with non-zero address for SrcHook
 * 3. test_isSome_DstHook_zeroAddress - Tests isSome with zero address for DstHook
 * 4. test_isSome_DstHook_nonZeroAddress - Tests isSome with non-zero address for DstHook
 * 5. test_integration_SrcHook_ValidInvalid - Tests multiple SrcHook scenarios
 * 6. test_integration_DstHook_ValidInvalid - Tests multiple DstHook scenarios
 *
 * This test file verifies that the HookUtils library correctly identifies valid hooks 
 * (those with non-zero addresses) for both SrcHook and DstHook struct types. These utility 
 * functions are critical for validating hook operations within the Aori protocol.
 */
import "forge-std/Test.sol";
import "./TestUtils.sol";
import "../../contracts/AoriUtils.sol";
import "../../contracts/IAori.sol";

/**
 * @title HookTestWrapper
 * @notice Test wrapper for the HookUtils library functions
 */
contract HookTestWrapper {
    using HookUtils for IAori.SrcHook;
    using HookUtils for IAori.DstHook;
    
    /**
     * @notice Checks if a SrcHook is defined (has a non-zero address)
     * @param hook The SrcHook struct to check
     * @return Whether the hook has a non-zero address
     */
    function isSomeSrcHook(IAori.SrcHook calldata hook) external pure returns (bool) {
        return hook.isSome();
    }
    
    /**
     * @notice Checks if a DstHook is defined (has a non-zero address)
     * @param hook The DstHook struct to check
     * @return Whether the hook has a non-zero address
     */
    function isSomeDstHook(IAori.DstHook calldata hook) external pure returns (bool) {
        return hook.isSome();
    }
}

/**
 * @title HookUtilsTest
 * @notice Test suite for the HookUtils library functions in AoriUtils.sol
 */
contract HookUtilsTest is Test {
    // Test wrapper
    HookTestWrapper public wrapper;
    
    // Test addresses
    address constant ZERO_ADDRESS = address(0);
    address constant TEST_ADDRESS = address(0x1234567890123456789012345678901234567890);
    
    function setUp() public {
        wrapper = new HookTestWrapper();
    }
    
    /**********************************/
    /*     SrcHook Tests             */
    /**********************************/
    
    /// @dev Tests isSome with zero address for SrcHook
    /// @notice Covers line 208 in AoriUtils.sol
    function test_isSome_SrcHook_zeroAddress() public view {
        // Arrange
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: ZERO_ADDRESS,
            preferredToken: address(0),
            minPreferedTokenAmountOut: 0,
            instructions: bytes("")
        });
        
        // Act
        bool result = wrapper.isSomeSrcHook(hook);
        
        // Assert
        assertFalse(result, "Zero address should return false");
    }
    
    /// @dev Tests isSome with non-zero address for SrcHook
    /// @notice Covers line 208 in AoriUtils.sol
    function test_isSome_SrcHook_nonZeroAddress() public view {
        // Arrange
        IAori.SrcHook memory hook = IAori.SrcHook({
            hookAddress: TEST_ADDRESS,
            preferredToken: address(0),
            minPreferedTokenAmountOut: 0,
            instructions: bytes("")
        });
        
        // Act
        bool result = wrapper.isSomeSrcHook(hook);
        
        // Assert
        assertTrue(result, "Non-zero address should return true");
    }
    
    /**********************************/
    /*     DstHook Tests             */
    /**********************************/
    
    /// @dev Tests isSome with zero address for DstHook
    /// @notice Covers line 217 in AoriUtils.sol
    function test_isSome_DstHook_zeroAddress() public view {
        // Arrange
        IAori.DstHook memory hook = IAori.DstHook({
            hookAddress: ZERO_ADDRESS,
            preferredToken: address(0),
            preferedDstInputAmount: 0,
            instructions: bytes("")
        });
        
        // Act
        bool result = wrapper.isSomeDstHook(hook);
        
        // Assert
        assertFalse(result, "Zero address should return false");
    }
    
    /// @dev Tests isSome with non-zero address for DstHook
    /// @notice Covers line 217 in AoriUtils.sol
    function test_isSome_DstHook_nonZeroAddress() public view {
        // Arrange
        IAori.DstHook memory hook = IAori.DstHook({
            hookAddress: TEST_ADDRESS,
            preferredToken: address(0),
            preferedDstInputAmount: 0,
            instructions: bytes("")
        });
        
        // Act
        bool result = wrapper.isSomeDstHook(hook);
        
        // Assert
        assertTrue(result, "Non-zero address should return true");
    }
    
    /**********************************/
    /*     Integration Tests         */
    /**********************************/
    
    /// @dev Tests multiple SrcHook scenarios
    function test_integration_SrcHook_ValidInvalid() public view {
        // Test various hook addresses
        address[] memory addresses = new address[](3);
        addresses[0] = ZERO_ADDRESS;
        addresses[1] = TEST_ADDRESS;
        addresses[2] = address(0xDEAD);
        
        bool[] memory expected = new bool[](3);
        expected[0] = false;  // Zero address
        expected[1] = true;   // Normal address
        expected[2] = true;   // Another normal address
        
        for (uint i = 0; i < addresses.length; i++) {
            IAori.SrcHook memory hook = IAori.SrcHook({
                hookAddress: addresses[i],
                preferredToken: address(0),
                minPreferedTokenAmountOut: 0,
                instructions: bytes("")
            });
            
            bool result = wrapper.isSomeSrcHook(hook);
            assertEq(result, expected[i], string(abi.encodePacked("SrcHook test failed for address: ", addresses[i])));
        }
    }
    
    /// @dev Tests multiple DstHook scenarios
    function test_integration_DstHook_ValidInvalid() public view {
        // Test various hook addresses
        address[] memory addresses = new address[](3);
        addresses[0] = ZERO_ADDRESS;
        addresses[1] = TEST_ADDRESS;
        addresses[2] = address(0xDEAD);
        
        bool[] memory expected = new bool[](3);
        expected[0] = false;  // Zero address
        expected[1] = true;   // Normal address
        expected[2] = true;   // Another normal address
        
        for (uint i = 0; i < addresses.length; i++) {
            IAori.DstHook memory hook = IAori.DstHook({
                hookAddress: addresses[i],
                preferredToken: address(0),
                preferedDstInputAmount: 0,
                instructions: bytes("")
            });
            
            bool result = wrapper.isSomeDstHook(hook);
            assertEq(result, expected[i], string(abi.encodePacked("DstHook test failed for address: ", addresses[i])));
        }
    }
}