// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { OrderStatus } from "./AoriTypes.sol";

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      INITIALIZATION                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when owner address is zero during initialization
error InvalidOwner();

/// @notice Thrown when max fills per settle is set to zero
error InvalidMaxFillsPerSettle();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     ORDER VALIDATION                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when offerer address is zero
error InvalidOfferer();

/// @notice Thrown when recipient address is zero
error InvalidRecipient();

/// @notice Thrown when end time is not greater than start time
/// @param startTime The order start time
/// @param endTime The order end time
error InvalidEndTime(uint32 startTime, uint32 endTime);

/// @notice Thrown when order has not started yet
/// @param startTime The order start time
/// @param currentTime The current block timestamp
error OrderNotStarted(uint32 startTime, uint256 currentTime);

/// @notice Thrown when order has expired
/// @param endTime The order end time
/// @param currentTime The current block timestamp
error OrderExpired(uint32 endTime, uint256 currentTime);

/// @notice Thrown when input amount is zero
error InvalidInputAmount();

/// @notice Thrown when output amount is zero
error InvalidOutputAmount();

/// @notice Thrown when token address is zero
error InvalidToken();

/// @notice Thrown when order already exists
error OrderAlreadyExists();

/// @notice Thrown when order was already processed on destination chain (status != Unknown)
/// @param currentStatus The current status of the order
error OrderAlreadyProcessed(OrderStatus currentStatus);

/// @notice Thrown when order is not in Active state on source chain
/// @param currentStatus The current status of the order
error OrderNotInActiveState(OrderStatus currentStatus);

/// @notice Thrown when order status is not Active (for emergency/internal cancel)
error CanOnlyCancelActiveOrders();

/// @notice Thrown when caller is not authorized to cancel the order
error UnauthorizedCancel();

/// @notice Thrown when signature verification fails
error InvalidSignature();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       CHAIN ERRORS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when destination chain is not supported
/// @param dstEid The unsupported destination endpoint ID
error DestinationChainNotSupported(uint32 dstEid);

/// @notice Thrown when chain ID doesn't match expected
/// @param expected The expected chain endpoint ID
/// @param actual The actual chain endpoint ID
error ChainMismatch(uint32 expected, uint32 actual);

/// @notice Thrown when operation is attempted on wrong chain
error NotOnDestinationChain();

/// @notice Thrown when operation is attempted on wrong chain
error NotOnSourceChain();

/// @notice Thrown when cross-chain order cancel is attempted from source chain
error CrossChainOrdersMustBeCancelledFromDestinationChain();

/// @notice Thrown when emergency cancel is attempted from non-source chain
error EmergencyCancelOnlyAllowedOnSourceChain();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      BALANCE ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when trying to withdraw more than unlocked balance
error InsufficientUnlockedBalance();

/// @notice Thrown when trying to withdraw with zero balance
error NonZeroBalanceRequired();

/// @notice Thrown when decreasing locked balance fails
/// @param attempted The amount attempted to decrease
/// @param available The available locked balance
error LockedBalanceDecreaseFailed(uint128 attempted, uint128 available);

/// @notice Thrown when balance consistency check fails
/// @param expected The expected balance
/// @param actual The actual balance
error BalanceInconsistency(uint256 expected, uint256 actual);

/// @notice Thrown when contract doesn't have enough balance
/// @param token The token address (NATIVE_TOKEN for native)
error InsufficientContractBalance(address token);

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       HOOK ERRORS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when hook address is missing
error MissingHook();

/// @notice Thrown when hook address is not whitelisted
error InvalidHookAddress();

/// @notice Thrown when hook call fails
error HookCallFailed();

/// @notice Thrown when hook decreases contract balance
error HookDecreasedContractBalance();

/// @notice Thrown when source hook doesn't provide enough output tokens
/// @param expected The expected output amount
/// @param received The actual amount received
error InsufficientSrcHookOutput(uint256 expected, uint256 received);

/// @notice Thrown when destination hook doesn't provide enough output tokens
/// @param expected The expected output amount
/// @param received The actual amount received
error InsufficientDstHookOutput(uint256 expected, uint256 received);

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      SOLVER ERRORS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when caller is not a whitelisted solver
error InvalidSolver();

/// @notice Thrown when caller is not the authorized solver for the order
error UnauthorizedSolver();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      TOKEN ERRORS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when native token should be used but ERC20 was specified
error UseDepositNativeForNativeTokens();

/// @notice Thrown when order must specify native token
error OrderMustSpecifyNativeToken();

/// @notice Thrown when incorrect native amount is sent
/// @param expected The expected native amount
/// @param actual The actual native amount sent
error IncorrectNativeAmount(uint256 expected, uint256 actual);

/// @notice Thrown when only offerer can deposit native tokens
error OnlyOffererCanDepositNativeTokens();

/// @notice Thrown when native tokens are sent but not expected
error UnexpectedNativeTokens();

/// @notice Thrown when native transfer fails
error NativeTransferFailed();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      PERMIT2 ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when Permit2 signature has expired
error Permit2SignatureExpired();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     PAYLOAD ERRORS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when payload has invalid length
/// @param expected The expected payload length
/// @param actual The actual payload length
error InvalidPayloadLength(uint256 expected, uint256 actual);

/// @notice Thrown when payload index is out of bounds
error PayloadIndexOutOfBounds();

/// @notice Thrown when message type is invalid
error InvalidMessageType();

/// @notice Thrown when payload is empty
error EmptyPayload();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    SETTLEMENT ERRORS                       */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when no orders are provided for settlement
error NoOrdersProvided();

/// @notice Thrown when submitted order data doesn't match orderId
error OrderDataMismatch();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    EMERGENCY ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when user address is invalid
error InvalidUserAddress();

/// @notice Thrown when amount must be greater than zero
error AmountMustBeGreaterThanZero();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       SWAP ERRORS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when swap() is called for a cross-chain order
error NotSingleChainOrder();

/// @notice Thrown when swapNative() should be used instead of swapWithPermit2
error UseSwapNativeForNativeTokens();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    PERIPHERY ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when Aori address is invalid
error InvalidAoriAddress();
