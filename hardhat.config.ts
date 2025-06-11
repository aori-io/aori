import 'dotenv/config'
import 'hardhat-deploy'
import 'hardhat-contract-sizer'
import '@nomiclabs/hardhat-ethers'
import '@layerzerolabs/toolbox-hardhat'
import '@tenderly/hardhat-tenderly'
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

// For v1.x we don't need to call setup

const config: HardhatUserConfig = {
    paths: {
        cache: 'cache/hardhat',
        sources: "./contracts",
    },
    solidity: {
        compilers: [
            {
                version: '0.8.28',
                settings: {
                    optimizer: {
                        enabled: true,
                        runs: 2000,
                    },
                    viaIR: true,
                },
            },
        ],
    },
    tenderly: {
        project: 'project', // Should match your project name in Tenderly dashboard
        username: 'aori', // Your Tenderly username
        privateVerification: true, // Set to true for private verification
    },
    networks: {
        ethereum: {
            eid: 30101,
            chainId: 1, // Ethereum mainnet chainId
            url: 'https://nd-386-647-265.p2pify.com/40723238b029534649bd384dbe410645',
            accounts,
        },
        base: {
            eid: 30184,
            chainId: 8453, // Base mainnet chainId
            url: 'https://nd-162-609-387.p2pify.com/945ca2cd8ac8ba0bc854378eb6f4c8ea',
            accounts,
        },
        'arbitrum-one': {
            eid: 30110,
            chainId: 42161, // Arbitrum One chainId
            url: 'https://nd-818-527-340.p2pify.com/f1d5b772c018d5ca87dcb6608d43bcf7',
            accounts,
        },
        optimism: {
            eid: 30111,
            chainId: 10, // Optimism mainnet chainId
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
            default: 0, 
        },
    },
}

export default config