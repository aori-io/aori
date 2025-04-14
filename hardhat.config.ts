// Get the environment configuration from .env file
//
// To make use of automatic environment setup:
// - Duplicate .env.example file and name it .env
// - Fill in the environment variables
import 'dotenv/config'
import 'hardhat-deploy'
import 'hardhat-contract-sizer'
import '@nomiclabs/hardhat-ethers'
import '@layerzerolabs/toolbox-hardhat'
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types'

// Set your preferred authentication method
//
// If you prefer using a mnemonic, set a MNEMONIC environment variable
// to a valid mnemonic
const MNEMONIC = process.env.MNEMONIC

// If you prefer to be authenticated using a private key, set a PRIVATE_KEY environment variable
const PRIVATE_KEY = process.env.PRIVATE_KEY

const accounts: HttpNetworkAccountsUserConfig | undefined = MNEMONIC
    ? { mnemonic: MNEMONIC }
    : PRIVATE_KEY
      ? [PRIVATE_KEY]
      : undefined

if (accounts == null) {
    console.warn(
        'Could not find MNEMONIC or PRIVATE_KEY environment variables. It will not be possible to execute transactions in your example.'
    )
}

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
    },
    solidity: {
        compilers: [
            {
                version: '0.8.28',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 200,
                    },
                },
            },
        ],
    },
    networks: {
        ethereum: {
            eid: 30101,
            url: 'https://nd-386-647-265.p2pify.com/40723238b029534649bd384dbe410645',
            accounts,
        },
        base: {
            eid: 30184,
            url: 'https://nd-162-609-387.p2pify.com/945ca2cd8ac8ba0bc854378eb6f4c8ea',
            accounts,
        },
        'arbitrum-one': {
            eid: 30110,
            url: 'https://nd-818-527-340.p2pify.com/f1d5b772c018d5ca87dcb6608d43bcf7',
            accounts,
        },
        optimism: {
            eid: 30111,
            url: 'https://nd-292-688-815.p2pify.com/bef6f576c854febba72dedc55dc37dc0',
            accounts,
        },
        hardhat: {
            // Needed in testing because TestHelperOz5.sol was exceeding the compiled contract size limit.
            allowUnlimitedContractSize: true,
        },
    },
    namedAccounts: {
        deployer: {
            default: 0, // Address at index[0] from the mnemonic in .env
        },
    },
}

export default config
