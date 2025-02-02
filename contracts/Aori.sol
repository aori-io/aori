pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "./libs/SafeERC20.sol";
import {IAori} from "./interfaces/IAori.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { OApp, Origin, MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

contract Aori is IAori, ReentrancyGuard, OApp {
    /*//////////////////////////////////////////////////////////////
                               LIBRARIES
    //////////////////////////////////////////////////////////////*/

    using SafeERC20 for IERC20;

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    // @notice 2D mapping of balances. The primary index is by
    // owner and the secondary index is by token.
    // These are locked balances until the order is filled
    mapping(address => mapping(address => uint256)) private balances;
    mapping(address => mapping(address => uint256)) private unlockedBalances;

    // @notice Mapping of settled orders
    mapping(bytes32 => bool) private settledOrders;
    mapping(bytes32 => bool) private cancelledOrders;

    uint256 public chainId;

    constructor(address _endpoint, address _owner) OApp(_endpoint, _owner) Ownable(_owner) {
        chainId = block.chainid;
    }

    /*//////////////////////////////////////////////////////////////
                                ORDERS
    //////////////////////////////////////////////////////////////*/

    /// @notice Order struct
    /// @dev This is the same as the Order struct in IAori.sol
    /// struct Order {
    //     address offerer;
    //     address recipient;
    //     address inputToken;
    //     uint256 inputAmount;
    //     address outputToken;
    //     uint256 outputAmount;
    //     uint256 dstChainId;
    //     uint256 startTime;
    //     uint256 endTime;
    // }

    /*//////////////////////////////////////////////////////////////
                                DEPOSIT
    //////////////////////////////////////////////////////////////*/

    /// @notice Deposits tokens to the contract for filling by a solver on another chain

    function deposit(
        Order calldata orderToCreate
    ) external nonReentrant {
        require(validate(orderToCreate, true), "Invalid deposit");
        // Transfer the amount to the contract
        IERC20(orderToCreate.inputToken).safeTransferFrom(msg.sender, address(this), orderToCreate.inputAmount);
        balances[msg.sender][orderToCreate.inputToken] += orderToCreate.inputAmount;
        emit Deposit(orderToCreate);
    }

    /*//////////////////////////////////////////////////////////////
                                 FILL
    //////////////////////////////////////////////////////////////*/

    function fill(
        Order calldata orderToFill
    ) external {
        require(validate(orderToFill, false), "Invalid fill");
        //Hashes order to fill
        bytes32 orderHash = getOrderHash(orderToFill);
        bool isFilled = settledOrders[orderHash];
        require(!isFilled, "Order already filled");
        require(IERC20(orderToFill.outputToken).balanceOf(msg.sender) >= orderToFill.outputAmount, "Insufficient balance");
        require(block.timestamp >= orderToFill.startTime && block.timestamp <= orderToFill.endTime, "Order has expired");

        //Transfer in the output token from the solver
        IERC20(orderToFill.outputToken).safeTransferFrom(msg.sender, address(this), orderToFill.outputAmount);
        
        //Add to storage the successful fill
        settledOrders[orderHash] = true;
        
        //Transfer tokens to the receipient
        IERC20(orderToFill.outputToken).safeTransfer(orderToFill.recipient, orderToFill.outputAmount);
        
        //TODO Implement lz checking and movement of funds once fill on destination chain is implemented
        emit Fill(orderToFill);
    }


    /*//////////////////////////////////////////////////////////////
                                SETTLEMENT
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice This function checks each order, encodes the valid ones into one payload,
     * then calls _lzSend so the orders can eventually be processed on the destination chain.
     */
    function settle(
        FilledOrder[] calldata orders,
        MessagingFee calldata fee,
        bytes calldata extraOptions
    ) external payable nonReentrant {
        require(msg.value == fee.nativeFee, "Incorrect fee amount");
        require(orders.length > 0, "No orders provided");

        // For this example we assume that all orders in the array share the same destination chain.
        uint32 dstEid = uint32(orders[0].order.dstChainId);
        
        // Check each order for consistency and that it has not been processed.
        for (uint256 i = 0; i < orders.length; i++) {
            bytes32 orderHash = getOrderHash(orders[i].order);
            require(!settledOrders[orderHash], "Order already settled");
            require(!cancelledOrders[orderHash], "Order already cancelled");
            require(uint32(orders[i].order.dstChainId) == dstEid, "Inconsistent destination chain ID");
        }

        // ABI encode the entire array of orders into one payload.
        bytes memory payload = abi.encode(orders);

        // Send the encoded payload via LayerZero.
        _lzSend(
            dstEid,
            payload,
            extraOptions,
            fee,
            payable(msg.sender)
        );

        emit Settle(orders);
    }

    /**
     * @notice Called on the destination chain. Instead of decoding the entire array in one shot,
     * we inspect the total byte length in the payload, then slice and decode each FilledOrder separately.
     */
    function _lzReceive(
        Origin calldata origin,
        bytes32 guid,
        bytes calldata payload,
        address executor,
        bytes calldata extraData
    ) internal override {
        // The encoding for a dynamic array via abi.encode is:
        // [0:32]   -> Offset pointer (normally 32)
        // [32:64]  -> Length (the number of orders)
        // [64:...] -> Each FilledOrder encoded in 320 bytes.

        require(payload.length >= 64, "Payload too short");
        uint256 totalOrders = uint256(bytes32(payload[32:64]));  // read the length

        // Each order occupies 320 bytes.
        uint256 orderSize = 320;
        require(payload.length == 64 + totalOrders * orderSize, "Invalid payload length");

        // Process each encoded order individually.
        for (uint256 i = 0; i < totalOrders; i++) {
            uint256 start = 64 + i * orderSize;
            bytes memory orderBytes = _sliceBytes(payload, start, orderSize);
            
            // Decode the 320-byte slice into a FilledOrder struct.
            FilledOrder memory filledOrder = abi.decode(orderBytes, (FilledOrder));

            bytes32 orderHash = getOrderHash(filledOrder.order);
            require(settledOrders[orderHash], "Order not settled");

            // Update balances on the destination chain.
            balances[filledOrder.order.offerer][filledOrder.order.inputToken] -= filledOrder.order.inputAmount;
            unlockedBalances[filledOrder.filler][filledOrder.order.inputToken] += filledOrder.order.inputAmount;

            emit Repay(filledOrder);
        }
    }

    /**
     * @notice Helper function to extract a slice from a bytes array.
     * @param data The original bytes (in calldata) to slice.
     * @param start The starting byte offset.
     * @param length The length of the slice.
     * @return A new bytes array in memory containing the desired slice.
     */
    function _sliceBytes(
        bytes calldata data,
        uint256 start,
        uint256 length
    ) internal pure returns (bytes memory) {
        require(start + length <= data.length, "Slice out of bounds");
        bytes memory tempBytes = new bytes(length);
        for (uint256 i = 0; i < length; i++) {
            tempBytes[i] = data[start + i];
        }
        return tempBytes;
    }

    /*//////////////////////////////////////////////////////////////
                                VALIDATE
    //////////////////////////////////////////////////////////////*/

    function validate(Order calldata order, bool isDeposit) internal view returns (bool) {
        //Recipient checks
        require(order.recipient != address(0) && order.recipient != address(0), "Invalid recipient");
        //Time checks
        require(order.startTime <= order.endTime, "Invalid time range");
        //Token checks
        require(order.inputAmount > 0, "Invalid input amount");
        require(order.outputAmount > 0, "Invalid output amount");
        require(order.inputToken != address(0) && order.outputToken != address(0), "Invalid token");
        //Balance checks
        if(isDeposit) {
            require(IERC20(order.inputToken).balanceOf(order.offerer) >=  order.inputAmount, "Insufficient balance");
            return true;
        } else {
            require(IERC20(order.outputToken).balanceOf(msg.sender) >=  order.outputAmount, "Insufficient balance");
            return true;
        }
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function hasSettled(
        Order calldata order
    ) public view returns (bool) {
        bytes32 orderHash = getOrderHash(order);
        return settledOrders[orderHash];
    }

    function isCancelled(bytes32 orderHash) public view returns (bool) {
        return cancelledOrders[orderHash];
    }

    function getOrderHash(Order memory order) private view returns (bytes32) {
        return keccak256(abi.encode(order, chainId));
    }
}