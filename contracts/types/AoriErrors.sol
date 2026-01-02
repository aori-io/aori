// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {OrderStatus} from "./AoriTypes.sol";

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
error InvalidEndTime();

/// @notice Thrown when order has not started yet
error OrderNotStarted();

/// @notice Thrown when order has expired
error OrderExpired();

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
error DestinationChainNotSupported();

/// @notice Thrown when chain ID doesn't match expected
error ChainMismatch();

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

/// @notice Thrown when trying to unlock more than locked balance
error InsufficientLockedBalance();

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

/// @notice Thrown when contract doesn't have enough native balance
error InsufficientContractNativeBalance();

/// @notice Thrown when contract doesn't have enough token balance
error InsufficientContractBalance();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                       HOOK ERRORS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when hook address is missing
error MissingHook();

/// @notice Thrown when hook address is not whitelisted
error InvalidHookAddress();

/// @notice Thrown when solver is not specified in hook
error SolverRequiredInHook();

/// @notice Thrown when solver in hook is not whitelisted
error InvalidSolverInHook();

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

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      TOKEN ERRORS                          */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when native token should be used but ERC20 was specified
error UseDepositNativeForNativeTokens();

/// @notice Thrown when order must specify native token
error OrderMustSpecifyNativeToken();

/// @notice Thrown when incorrect native amount is sent
error IncorrectNativeAmount();

/// @notice Thrown when only offerer can deposit native tokens
error OnlyOffererCanDepositNativeTokens();

/// @notice Thrown when no native tokens should be sent for ERC20 fills
error NoNativeTokensForERC20Fills();

/// @notice Thrown when no native tokens should be sent for ERC20 preferred token
error NoNativeTokensForERC20PreferredToken();

/// @notice Thrown when no native tokens are expected
error NoNativeTokensExpected();

/// @notice Thrown when native transfer fails
error NativeTransferFailed();

/// @notice Thrown when native transfer to hook fails
error NativeTransferToHookFailed();

/// @notice Thrown when ether withdrawal fails
error EtherWithdrawalFailed();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                      PERMIT2 ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when Permit2 signature has expired
error Permit2SignatureExpired();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                     PAYLOAD ERRORS                         */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when cancellation payload has invalid length
error InvalidCancellationPayloadLength();

/// @notice Thrown when settlement payload is too short
error PayloadTooShortForSettlement();

/// @notice Thrown when payload has invalid length
error InvalidPayloadLength();

/// @notice Thrown when payload index is out of bounds
error PayloadIndexOutOfBounds();

/// @notice Thrown when message type is invalid
error InvalidMessageType();

/// @notice Thrown when payload type is not supported
error UnsupportedPayloadType();

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

/// @notice Thrown when recipient address is invalid
error InvalidRecipientAddress();

/// @notice Thrown when user address is invalid
error InvalidUserAddress();

/// @notice Thrown when amount must be greater than zero
error AmountMustBeGreaterThanZero();

/*´:°•.°+.*•´.*:˚.°*.˚•´.°:°•.°•.*•´.*:˚.°*.˚•´.°:°•.°+.*•´.*:*/
/*                    PERIPHERY ERRORS                        */
/*.•°:°.´+˚.*°.˚:*.´•*.+°.•°:´*.´•*.•°.•°:°.´:•˚°.*°.˚:*.´+°.•*/

/// @notice Thrown when Aori address is invalid
error InvalidAoriAddress();
