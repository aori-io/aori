import 'dotenv/config'
import 'hardhat-deploy'
import 'hardhat-contract-sizer'
import '@nomiclabs/hardhat-ethers'
import '@layerzerolabs/toolbox-hardhat'
import '@tenderly/hardhat-tenderly'
import { HardhatUserConfig, HttpNetworkAccountsUserConfig } from 'hardhat/types'
import { EndpointId } from '@layerzerolabs/lz-definitions'
// import './tasks/approve-token'


//uncomment this for deployment
import 'hardhat-deploy'

// uncomment this for verification
// import '@nomicfoundation/hardhat-verify'

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

// Check for required environment variables
const requiredEnvVars = [
    'ETHEREUM_RPC_URL',
    'BASE_RPC_URL',
    'ARBITRUM_RPC_URL',
    'OPTIMISM_RPC_URL',
    'MONAD_RPC_URL',
    'TENDERLY_PROJECT',
    'TENDERLY_USERNAME',
    'TENDERLY_ACCESS_TOKEN'
]

requiredEnvVars.forEach(envVar => {
    if (!process.env[envVar]) {
        console.warn(`Warning: ${envVar} environment variable is not set`)
    }
})

const config: HardhatUserConfig & { etherscan?: any } = {
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
                        runs: 100,
                    },
                    viaIR: true,
                },
            },
        ],
    },
    tenderly: {
        project: process.env.TENDERLY_PROJECT || '',
        username: process.env.TENDERLY_USERNAME || '',
        accessKey: process.env.TENDERLY_ACCESS_TOKEN || '',
        privateVerification: true,
    },
    networks: {
        ethereum: {
            eid: 30101,
            chainId: 1, // Ethereum mainnet chainId
            url: process.env.ETHEREUM_RPC_URL || '',
            accounts,
        },
        base: {
            eid: 30184,
            chainId: 8453, // Base mainnet chainId
            url: process.env.BASE_RPC_URL || '',
            accounts,
        },
        'arbitrum-one': {
            eid: 30110,
            chainId: 42161, // Arbitrum One chainId
            url: process.env.ARBITRUM_RPC_URL || '',
            accounts,
        },
        optimism: {
            eid: 30111,
            chainId: 10, // Optimism mainnet chainId
            url: process.env.OPTIMISM_RPC_URL || '',
            accounts,
        },
        bsc: {
            eid: 30102,
            chainId: 56, // BSC mainnet chainId
            url: process.env.BSC_RPC_URL || '',
            accounts,
            // gasPrice: 5000000000, // 3 gwei - BSC minimum
        },
        plasma: {
            eid: EndpointId.PLASMA_V2_MAINNET,
            chainId: 9745,
            url: process.env.PLASMA_RPC_URL || '',
            accounts,
        },
        stable: {
            eid: EndpointId.STABLE_V2_MAINNET,
            chainId: 988,
            url: process.env.STABLE_RPC_URL || '',
            accounts,
            gasPrice: 10000000000, // 10 gwei
            maxPriorityFeePerGas: 0,
        },
        monad: {
            eid: 30390,
            chainId: 143,
            url: process.env.MONAD_RPC_URL || '',
            accounts,
            gasPrice: 102500000000,
        },
        hardhat: {
            // Needed in testing because TestHelperOz5.sol was exceeding the compiled contract size limit.
            allowUnlimitedContractSize: true,
        },
    },
    etherscan: {
        apiKey: process.env.ETHERSCAN_API_KEY || '',
        enabled: true,
    },
    // comment for deployment / uncomment this for verification
    // sourcify: {
    //     enabled: false,
    // },
    namedAccounts: {
        deployer: {
            default: 0,
        },
    },
}

export default config