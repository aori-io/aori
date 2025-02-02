// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../../contracts/Aori.sol";
import "../../contracts/interfaces/IAori.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { OApp } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

// Import the LayerZero test helper so we can deploy dummy endpoints.
import { TestHelperOz5 } from "@layerzerolabs/test-devtools-evm-foundry/contracts/TestHelperOz5.sol";
// LibraryType is used by TestHelperOz5; see MyOApp.t.sol for reference.
import { OptionsBuilder } from "@layerzerolabs/oapp-evm/contracts/oapp/libs/OptionsBuilder.sol";

/**
 * @notice A minimal Mock ERC20 for testing deposit and fill functions.
 */
contract MockERC20 is IERC20 {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
    uint256 public override totalSupply;

    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address recipient, uint256 amount) external override returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(msg.sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external override returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address sender, address recipient, uint256 amount) external override returns (bool) {
        require(balanceOf[sender] >= amount, "Insufficient balance");
        require(allowance[sender][msg.sender] >= amount, "Allowance exceeded");
        balanceOf[sender] -= amount;
        allowance[sender][msg.sender] -= amount;
        balanceOf[recipient] += amount;
        emit Transfer(sender, recipient, amount);
        return true;
    }
}

/**
 * @notice TestAori is a small extension of Aori with an override for _lzSend.
 * In production the _lzSend method would send the payload cross-chain via LayerZero.
 * For testing purposes (as per LayerZero's OApp testing methodology) we simply override it.
 */
contract TestAori is Aori {
    constructor(address _endpoint, address _owner) Aori(_endpoint, _owner) {}

    function _lzSend(
        uint32 _dstEid,
        bytes memory payload,
        bytes memory extraOptions,
        MessagingFee memory fee,
        address payable refundAddress
    ) internal {
        emit LzSendCalled(_dstEid, payload, extraOptions, fee, refundAddress);
    }
    event LzSendCalled(uint32 dstEid, bytes payload, bytes extraOptions, MessagingFee fee, address refundAddress);
}

/**
 * @notice AoriTest demonstrates basic deposit, fill and settle tests of the Aori contract.
 * It now uses a dummy endpoint deployed by TestHelperOz5.
 */
contract AoriTest is TestHelperOz5 {
    TestAori public aori;
    MockERC20 public inputToken;
    MockERC20 public outputToken;

    // Define test users:
    address public userA = address(0x100);   // The order offerer
    address public solver = address(0x200);    // The order filler/solver
    address public recipient = address(0x300); // The recipient of the output token

    // Setting the endpoint id to use from the dummy endpoints.
    uint32 private constant aEid = 1;

    function setUp() public override {
        // Deploy dummy endpoints (the first parameter is the number of endpoints to create).
        setUpEndpoints(1, LibraryType.UltraLightNode);

        // Deploy our mock ERC20 tokens.
        inputToken = new MockERC20("InputToken", "INP");
        outputToken = new MockERC20("OutputToken", "OUT");

        // Mint tokens so that userA can deposit and solver can fill.
        inputToken.mint(userA, 1000 ether);
        outputToken.mint(solver, 1000 ether);

        // Deploy our TestAori contract using the dummy endpoint.
        aori = new TestAori(address(endpoints[aEid]), address(this));
    }

    function testDeposit() public {
        // Create a valid order.
        Aori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            inputAmount: 10 ether,
            outputToken: address(outputToken),
            outputAmount: 20 ether,
            dstChainId: 100, // Arbitrary destination chain id for testing.
            startTime: block.timestamp,
            endTime: block.timestamp + 3600
        });

        // Simulate userA approving the deposit amount.
        vm.prank(userA);
        inputToken.approve(address(aori), 10 ether);

        // userA deposits the order.
        vm.prank(userA);
        aori.deposit(order);

        // Verify that the contract now holds the deposited input tokens.
        uint256 contractBalance = inputToken.balanceOf(address(aori));
        assertEq(contractBalance, 10 ether, "Deposit failed: Incorrect contract balance");
    }

    function testFill() public {
        // Create a valid order.
        Aori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            inputAmount: 10 ether,
            outputToken: address(outputToken),
            outputAmount: 20 ether,
            dstChainId: 100,
            startTime: block.timestamp,
            endTime: block.timestamp + 3600
        });

        // Deposit funds from userA.
        vm.prank(userA);
        inputToken.approve(address(aori), 10 ether);
        vm.prank(userA);
        aori.deposit(order);

        // Simulate the solver approving and filling the order.
        vm.prank(solver);
        outputToken.approve(address(aori), 20 ether);
        vm.prank(solver);
        aori.fill(order);

        // Verify that recipient received the output tokens.
        uint256 recipientBalance = outputToken.balanceOf(recipient);
        assertEq(recipientBalance, 20 ether, "Fill failed: Incorrect recipient balance");
    }

    function testSettle() public {
        // Create an order with a different destination chain id.
        Aori.Order memory order = IAori.Order({
            offerer: userA,
            recipient: recipient,
            inputToken: address(inputToken),
            inputAmount: 10 ether,
            outputToken: address(outputToken),
            outputAmount: 20 ether,
            dstChainId: 200,
            startTime: block.timestamp,
            endTime: block.timestamp + 3600
        });

        // userA deposits the order.
        vm.prank(userA);
        inputToken.approve(address(aori), 10 ether);
        vm.prank(userA);
        aori.deposit(order);

        // A solver fills the order.
        vm.prank(solver);
        outputToken.approve(address(aori), 20 ether);
        vm.prank(solver);
        aori.fill(order);

        // Prepare the FilledOrder array for settlement.
        Aori.FilledOrder[] memory orders = new Aori.FilledOrder[](1);
        orders[0] = IAori.FilledOrder({
            order: order,
            filler: solver
        });

        // Create a MessagingFee structure with a native fee of 0.
        MessagingFee memory fee = MessagingFee({
            nativeFee: 0,
            lzTokenFee: 0
        });

        // Call settle from userA (or any address) with the proper fee.
        vm.prank(userA);
        aori.settle{value: 0}(orders, fee, "");

        // In the current design, the input tokens remain locked until _lzReceive is called.
        // We simply verify that the contract's input token balance is unchanged.
        uint256 contractBalance = inputToken.balanceOf(address(aori));
        assertEq(contractBalance, 10 ether, "Settle: Contract balance should still hold deposited tokens");
    }
}