import assert from 'assert'

import { type DeployFunction } from 'hardhat-deploy/types'

const contractName = 'Aori'

const deploy: DeployFunction = async (hre) => {
    const { getNamedAccounts, deployments, network } = hre

    const { deploy } = deployments
    const { deployer } = await getNamedAccounts()

    assert(deployer, 'Missing named deployer account')

    console.log(`Network: ${network.name}`)
    console.log(`Deployer: ${deployer}`)

    const maxFills = 100
    const initialSolvers: string[] = [] 
    const initialHooks: string[] = []
    const initialSupportedChains: number[] = [] 
    // Retrieve the external EndpointV2 deployment.
    const endpointV2Deployment = await deployments.get('EndpointV2')

    // For example, retrieve the "eid" from your hardhat.config, default to 1 if absent.
    const eid = network.config.eid || 1

    // Deploy Aori.
    const { address } = await deploy(contractName, {
        from: deployer,
        args: [
            endpointV2Deployment.address,
            deployer,
            eid,
            maxFills,
            initialSolvers,
            initialHooks,
            initialSupportedChains,
        ],
        log: true,
        skipIfAlreadyDeployed: false,
    })

    console.log(`Deployed contract: ${contractName}`)
    console.log(`Network:          ${network.name}`)
    console.log(`Address:          ${address}`)
}

deploy.tags = [contractName]

export default deploy
