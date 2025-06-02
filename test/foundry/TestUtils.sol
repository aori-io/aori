// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * TestUtils - Common test utilities for Aori contract tests
 *
 * This utility contract sets up the testing environment for Aori contract tests with the following:
 *
 * Setup:
 * - Deploys two Aori instances: one on a local chain and one on a remote chain
 * - Configures LayerZero endpoints and wires the Aori instances together
 * - Creates mock tokens for testing (input, output, converted, and dstPreferred tokens)
 * - Deploys a mock hook for token conversion
 * - Whitelists the mock hook and solver in both Aori instances
 * - Mints initial token supplies for test users
 *
 * Utility Functions:
 * - createValidOrder - Creates orders with randomized but reasonable parameters
 * - createCustomOrder - Creates orders with fully customizable parameters
 * - signOrder - Signs orders using EIP712 standard for authentication
 * - defaultSrcSolverData - Creates source hook data for token conversion during deposit
 * - defaultDstSolverData - Creates destination hook data for token conversion during fill
 * - defaultOptions - Sets up standard LayerZero options for cross-chain messages
 *
 * Test users:
 * - userA: Main user who creates orders (private key 0xBEEF)
 * - solver: Whitelisted solver who can fill orders (address 0x200)
 *
 * The environment uses LayerZero's test helpers to simulate cross-chain communication
 * between two separate environments (localEid = 1, remoteEid = 2)
 */
import "forge-std/Test.sol";
import {Aori, IAori} from "../../contracts/Aori.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {OApp, Origin, MessagingFee} from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";
import {TestHelperOz5} from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
import {OptionsBuilder} from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";
import {PayloadType} from "../../contracts/AoriUtils.sol";
import {MockERC20} from "../Mock/MockERC20.sol";
import {MockHook} from "../Mock/MockHook.sol";

/**
 * @title TestUtils
 * @notice Common test utilities for Aori contract tests
 */
contract TestUtils is TestHelperOz5 {
    using OptionsBuilder for bytes;

    // Common state
    Aori public localAori;
    Aori public remoteAori;
    MockERC20 public inputToken;
    MockERC20 public outputToken;
    MockERC20 public convertedToken; // token returned from deposit hook conversion
    MockERC20 public dstPreferredToken; // token used for fill hook conversion
    MockHook public mockHook; // mock hook for token conversion

    // Common addresses
    uint256 public userAPrivKey = 0xBEEF;
    address public userA;
    address public solver = address(0x200);

    // Common constants
    uint32 public constant localEid = 1;
    uint32 public constant remoteEid = 2;
    uint16 public constant MAX_FILLS_PER_SETTLE = 10;

    /**
     * @notice Common setup function for all tests
     */
    function setUp() public virtual override {
        // Derive userA
        userA = vm.addr(userAPrivKey);

        // Setup LayerZero endpoints
        setUpEndpoints(2, LibraryType.UltraLightNode);

        // Deploy local and remote Aori contracts
        localAori = new Aori(address(endpoints[localEid]), address(this), localEid, MAX_FILLS_PER_SETTLE);
        remoteAori = new Aori(address(endpoints[remoteEid]), address(this), remoteEid, MAX_FILLS_PER_SETTLE);

        // Wire the OApps together
        address[] memory aoriInstances = new address[](2);
        aoriInstances[0] = address(localAori);
        aoriInstances[1] = address(remoteAori);
        wireOApps(aoriInstances);

        // Set peers between chains
        localAori.setPeer(remoteEid, bytes32(uint256(uint160(address(remoteAori)))));
        remoteAori.setPeer(localEid, bytes32(uint256(uint160(address(localAori)))));

        // Setup chains as supported (local already done in constructor)
        // Mock the quote call for remote chain
        vm.mockCall(
            address(localAori),
            abi.encodeWithSelector(
                localAori.quote.selector,
                remoteEid,
                uint8(PayloadType.Settlement),
                bytes(""),
                false,
                0,
                address(0)
            ),
            abi.encode(1 ether) // Return a mock fee
        );
        
        // Add remote chain as supported on local contract
        localAori.addSupportedChain(remoteEid);
        
        // Mock the quote call for local chain
        vm.mockCall(
            address(remoteAori),
            abi.encodeWithSelector(
                remoteAori.quote.selector,
                localEid,
                uint8(PayloadType.Settlement),
                bytes(""),
                false,
                0,
                address(0)
            ),
            abi.encode(1 ether) // Return a mock fee
        );
        
        // Add local chain as supported on remote contract
        remoteAori.addSupportedChain(localEid);

        // Setup test tokens
        inputToken = new MockERC20("Input", "IN");
        outputToken = new MockERC20("Output", "OUT");
        convertedToken = new MockERC20("Converted", "CONV");
        dstPreferredToken = new MockERC20("DstPreferred", "DST");

        // Mint tokens
        inputToken.mint(userA, 1000e18);
        outputToken.mint(solver, 1000e18);
        dstPreferredToken.mint(solver, 1000e18);

        // Deploy and setup mock hook
        mockHook = new MockHook();
        convertedToken.mint(address(mockHook), 1000e18);
        outputToken.mint(address(mockHook), 1000e18);

        // Whitelist the mockHook in both contracts
        localAori.addAllowedHook(address(mockHook));
        remoteAori.addAllowedHook(address(mockHook));

        // Whitelist the solver in both contracts
        localAori.addAllowedSolver(solver);
        remoteAori.addAllowedSolver(solver);
    }

    /**
     * @notice Creates a valid order for testing with unique parameters
     * @param salt Optional salt value to make orders unique when called multiple times in same block
     */
    function createValidOrder(uint256 salt) public view returns (IAori.Order memory order) {
        // Use current timestamp for startTime to comply with contract requirements
        // Only endTime has an offset for testing
        uint256 endTimeOffset = 1 days;

        // Generate unique random seed based on block properties
        uint256 randomSeed =
            uint256(keccak256(abi.encodePacked(uint32(block.timestamp), block.prevrandao, address(this), salt)));

        // Use randomness to create unique but reasonable input/output amounts
        uint256 inputAmount = 1e18 + (randomSeed % 1e17); // Between 1-1.1 ETH
        uint256 outputAmount = 2e18 + (randomSeed % 2e17); // Between 2-2.2 ETH

        order = IAori.Order({
            offerer: userA,
            recipient: userA,
            inputToken: address(inputToken),
            outputToken: address(outputToken),
            inputAmount: uint128(inputAmount),
            outputAmount: uint128(outputAmount),
            startTime: uint32(block.timestamp), // Set to current timestamp
            endTime: uint32(block.timestamp + endTimeOffset),
            srcEid: localEid,
            dstEid: remoteEid
        });
    }

    /**
     * @notice Creates a valid order for testing with default salt value
     */
    function createValidOrder() public view returns (IAori.Order memory) {
        return createValidOrder(0);
    }

    /**
     * @notice Creates a valid order for testing with custom parameters
     */
    function createCustomOrder(
        address _offerer,
        address _recipient,
        address _inputToken,
        address _outputToken,
        uint256 _inputAmount,
        uint256 _outputAmount,
        uint256 _startTime,
        uint256 _endTime,
        uint32 _srcEid,
        uint32 _dstEid
    ) public pure returns (IAori.Order memory order) {
        order = IAori.Order({
            offerer: _offerer,
            recipient: _recipient,
            inputToken: _inputToken,
            outputToken: _outputToken,
            inputAmount: uint128(_inputAmount),
            outputAmount: uint128(_outputAmount),
            startTime: uint32(_startTime),
            endTime: uint32(_endTime),
            srcEid: _srcEid,
            dstEid: _dstEid
        });
    }

    /**
     * @notice Signs an order using EIP712
     */
    function signOrder(IAori.Order memory order) public view returns (bytes memory) {
        return signOrder(order, userAPrivKey);
    }

    /**
     * @notice Signs an order using EIP712 with a custom private key
     */
    function signOrder(IAori.Order memory order, uint256 privKey) public view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "Order(uint128 inputAmount,uint128 outputAmount,address inputToken,address outputToken,uint32 startTime,uint32 endTime,uint32 srcEid,uint32 dstEid,address offerer,address recipient)"
                ),
                order.inputAmount,
                order.outputAmount,
                order.inputToken,
                order.outputToken,
                order.startTime,
                order.endTime,
                order.srcEid,
                order.dstEid,
                order.offerer,
                order.recipient
            )
        );

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,address verifyingContract)"),
                keccak256(bytes("Aori")),
                keccak256(bytes("0.3.0")),
                address(localAori)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /**
     * @notice Creates default source solver data with hook conversion
     * @param inputAmount The amount of input tokens to use in the hook instructions (defaults to 1e18)
     */
    function defaultSrcSolverData(uint256 inputAmount) public view returns (IAori.SrcHook memory) {
        return IAori.SrcHook({
            hookAddress: address(mockHook),
            preferredToken: address(convertedToken),
            minPreferedTokenAmountOut: 1500,
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(convertedToken), inputAmount)
        });
    }

    /**
     * @notice Creates default source solver data with hook conversion using default input amount
     */
    function defaultSrcSolverData() public view returns (IAori.SrcHook memory) {
        return defaultSrcSolverData(1e18);
    }

    /**
     * @notice Creates default destination solver data with hook conversion
     * @param outputAmount The amount of output tokens for the hook instructions
     */
    function defaultDstSolverData(uint256 outputAmount) public view returns (IAori.DstHook memory) {
        return IAori.DstHook({
            hookAddress: address(mockHook),
            preferredToken: address(dstPreferredToken),
            instructions: abi.encodeWithSelector(MockHook.handleHook.selector, address(outputToken), outputAmount),
            preferedDstInputAmount: outputAmount
        });
    }

    /**
     * @notice Creates default destination solver data with hook conversion using default output amount
     */
    function defaultDstSolverData() public view returns (IAori.DstHook memory) {
        return defaultDstSolverData(2e18);
    }

    /**
     * @notice Creates default LayerZero options
     */
    function defaultOptions() public pure returns (bytes memory) {
        return OptionsBuilder.newOptions().addExecutorLzReceiveOption(200000, 0);
    }

    /**
     * @notice Helper function to directly lock tokens in an offerer's balance for testing
     * @dev This is used only for testing to setup the correct balance state
     * @param offerer The address of the offerer
     * @param token The token address to lock
     * @param amount The amount to lock
     */
    function testLockOffererTokens(address offerer, address token, uint128 amount) external {
        // Cannot directly access private mapping, so this function is removed
        // This would need to be replaced with an appropriate function call to the Aori contract
        // if balance locking functionality is needed for tests
    }
}
