pragma solidity 0.8.24;

import { MessagingFee } from "@layerzerolabs/oapp-evm/contracts/oapp/OApp.sol";

interface IAori {

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    //20 bytes per address
    //32 bytes per uint256
    struct Order {
        address offerer;
        address recipient;
        address inputToken;
        uint256 inputAmount;
        address outputToken;
        uint256 outputAmount;
        uint256 dstChainId;
        uint256 startTime;
        uint256 endTime;
    }

    struct FilledOrder {
        Order order;
        address filler;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Deposit(
        Order order
    );

    event Fill(
        Order order
    );

    event Settle(
        FilledOrder[] orders
    );

    event Repay(
        FilledOrder order
    );

    /*//////////////////////////////////////////////////////////////
                                 FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function deposit(Order calldata orderToCreate) external;

    function fill(Order calldata orderToFill) external;

    function settle(FilledOrder[] calldata orders, MessagingFee calldata fee, bytes calldata extraOptions) external payable;

}