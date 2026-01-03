import assert from 'assert'
import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'AoriPeriphery'

// Existing Aori contract addresses per chain - fill in with your deployed addresses
const AORI_ADDRESSES: Record<string, string> = {
    // ethereum: '0x8635c874b0fcb361fb9a2f5218852d4b7fc5ace3', // DEV
    // base: '0xf7d57b37065fb14ea6587cb212ef09344579435f', // DEV
    // 'arbitrum-one': '0xe6ce1a5106b72d5471b109097d8db0237628641d', // DEV
    // optimism: '0xfca18df252e0184389ed24e87a1caf75c3009c07', // DEV
    // bsc: '0x634c41a86567b3d54a8f414f40d4dec39ed269e6', // DEV
    // plasma: '0xd95464d11d447eab68df8cff4b0a7751c0efdeb4', // DEV
    // stable: '0xd95464d11d447eab68df8cff4b0a7751c0efdeb4', // DEV
    // monad: '0x17c770e756dda78e5f93f8f34c87fba158dc3755', // DEV
    ethereum: '0x0736bdc975af0675b9a045384efed91360d25479', // PROD
    base: '0xc6868edf1d2a7a8b759856cb8afa333210dfeda6', // PROD
    'arbitrum-one': '0xc6868edf1d2a7a8b759856cb8afa333210dfeda6', // PROD
    optimism: '0xc6868edf1d2a7a8b759856cb8afa333210dfeda6', // PROD
    bsc: '0xffe691a6ddb5d2645321e0a920c2e7bdd00dd3d8', // PROD
    plasma: '0xffe691a6ddb5d2645321e0a920c2e7bdd00dd3d8', // PROD
    stable: '0xffe691a6ddb5d2645321e0a920c2e7bdd00dd3d8', // PROD
    monad: '0xffe691a6ddb5d2645321e0a920c2e7bdd00dd3d8', // PROD
}

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments, network } = hre
    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    const aoriAddress = AORI_ADDRESSES[network.name]
    assert(aoriAddress, `Missing Aori address for network: ${network.name}`)
    assert(aoriAddress !== '0x0000000000000000000000000000000000000000', 
        `Placeholder address detected for ${network.name} - update AORI_ADDRESSES`)

    console.log(`Network: ${network.name}`)
    console.log(`Deployer: ${deployer}`)
    console.log(`Aori Address: ${aoriAddress}`)

    const { address } = await deploy(contractName, {
        from: deployer,
        args: [aoriAddress],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}`)
    console.log(`Network:          ${network.name}`)
    console.log(`Address:          ${address}`)
}

deploy.tags = [contractName]

export default deploy

