// SPDX-License-Identifier: MIT
pragma solidity 0.8.33;

import { ERC1967Proxy } from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

/**                            @@@@@@@@@@@@
                             @@         @@@@@@                     @@@@@
                             @@           @@@@@                    @@@@@
                             @@@
                               @@@@
                                 @@@@@
                                     @@@@@
       @@@@@@@@@    @@@@          @@@@@@@@@@    @@@@@@    @@@@@@@  @@@@@
     @@@@      @@   @@@@      @@@@       @@@@@@@   @@@@ @@    @@@   @@@@
    @@@@         @ @@@@     @@@@          @@@@@@   @@@@        @@   @@@@
   @@@@@         @@@@@@   @@@@@            @@@@@@  @@@@         @   @@@@
   @@@@@          @@@@    @@@@@   @    @    @@@@@  @@@@             @@@@
   @@@@@          @@@@   @@@@@@   @@@@@@    @@@@@  @@@@             @@@@
   @@@@@         @@@@@   @@@@@@   @    @    @@@@@  @@@@             @@@@
   @@@@@         @@@@     @@@@@             @@@@   @@@@             @@@@
    @@@@        @@@@@@    @@@@@@           @@@@    @@@@             @@@@
     @@@@      @@@@  @@@@@@ @@@@@         @@@      @@@@             @@@@   @@
       @@@@@@@@@     @@@@@     @@@@@@@@@@@         @@@@               @@@@@
 */
/**
 * @title AoriProxy
 * @notice ERC1967 proxy for the Aori protocol
 * @dev This proxy delegates all calls to the Aori implementation contract.
 *      The implementation address is stored in the ERC1967 implementation slot.
 *      Upgrades are handled by the UUPS pattern in the implementation contract.
 */
contract AoriProxy is ERC1967Proxy {
    /**
     * @notice Deploys the proxy and initializes the implementation
     * @param implementation The address of the Aori implementation contract
     * @param _data The initialization calldata (typically Aori.initialize encoded)
     */
    constructor(
        address implementation,
        bytes memory _data
    ) ERC1967Proxy(implementation, _data) {}
}
