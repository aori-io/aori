/ SPDX-License-Identifier: MIT                                                                                                                                                  
  pragma solidity 0.8.34;                                                                                                                                                          
                                                                                                                                                                                   
  struct Options {                                                                                                                                                                 
      uint16 feeMbps;                                                                                                                                                              
      uint16 slippageMbps;
      address feeRecipient;
      address srcSolver;
      address dstSolver;
  }

  struct Order {
      uint128 inputAmount;
      uint128 outputAmount;
      address inputToken;
      uint32 startTime;
      uint32 endTime;
      uint32 srcEid;
      address outputToken;
      uint32 dstEid;
      address offerer;
      address recipient;
      Options options;
  }

  contract MockDerivation {
      function deriveAddress(bytes32 solanaPubkey) external pure returns (address) {
          return address(bytes20(keccak256(abi.encodePacked(solanaPubkey))));
      }

      function computeOrderId(Order calldata order) external pure returns (bytes32) {
          return keccak256(abi.encode(order));
      }

      function abiEncodeOrder(Order calldata order) external pure returns (bytes memory) {
          return abi.encode(order);
      }
  }