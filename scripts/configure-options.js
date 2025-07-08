const { ethers } = require("hardhat");
const { Options } = require("@layerzerolabs/lz-v2-utilities");

/**
 * Configuration script for Aori enforced options
 * Run this after deploying Aori contracts to configure LayerZero options
 */

// Common LayerZero Endpoint IDs (you'll use the actual ones for your deployment)
const CHAIN_ENDPOINTS = {
    ethereum: 30101,
    arbitrum: 30110,
    optimism: 30111,
    polygon: 30109,
    base: 30184,
    avalanche: 30106
};

// Recommended gas limits based on Aori operations
const GAS_LIMITS = {
    settlement: 200000,    // Higher gas for processing multiple order settlements
    cancellation: 100000   // Lower gas for simple cancellation
};

async function configureEnforcedOptions() {
    console.log("🔧 Configuring Aori Enforced Options\n");

    // Get the deployed Aori contract
    const aoriAddress = "YOUR_DEPLOYED_AORI_ADDRESS"; // Replace with actual address
    const aori = await ethers.getContractAt("Aori", aoriAddress);
    
    // Get the contract owner/signer
    const [owner] = await ethers.getSigners();
    console.log(`👤 Configuring as owner: ${owner.address}\n`);

    // Configure options for each supported chain
    const supportedChains = [
        { name: "Ethereum", eid: CHAIN_ENDPOINTS.ethereum },
        { name: "Arbitrum", eid: CHAIN_ENDPOINTS.arbitrum },
        { name: "Optimism", eid: CHAIN_ENDPOINTS.optimism },
    ];

    for (const chain of supportedChains) {
        console.log(`⚙️  Configuring options for ${chain.name} (EID: ${chain.eid})`);
        
        try {
            // Create settlement options (higher gas limit)
            const settlementOptions = Options.newOptions()
                .addExecutorLzReceiveOption(GAS_LIMITS.settlement, 0)
                .toBytes();

            // Create cancellation options (lower gas limit)  
            const cancellationOptions = Options.newOptions()
                .addExecutorLzReceiveOption(GAS_LIMITS.cancellation, 0)
                .toBytes();

            // Set settlement options
            console.log(`  ├── Setting settlement options (${GAS_LIMITS.settlement} gas)`);
            const settleTx = await aori.setEnforcedSettlementOptions(chain.eid, settlementOptions);
            await settleTx.wait();
            
            // Set cancellation options
            console.log(`  ├── Setting cancellation options (${GAS_LIMITS.cancellation} gas)`);
            const cancelTx = await aori.setEnforcedCancellationOptions(chain.eid, cancellationOptions);
            await cancelTx.wait();
            
            console.log(`  └── ✅ ${chain.name} configured successfully\n`);
            
        } catch (error) {
            console.log(`  └── ❌ Failed to configure ${chain.name}: ${error.message}\n`);
        }
    }

    // Verify configuration
    console.log("🔍 Verifying configuration...\n");
    for (const chain of supportedChains) {
        try {
            const settlementOptions = await aori.getEnforcedSettlementOptions(chain.eid);
            const cancellationOptions = await aori.getEnforcedCancellationOptions(chain.eid);
            
            console.log(`${chain.name}:`);
            console.log(`  ├── Settlement options: ${settlementOptions.length > 0 ? '✅ Set' : '❌ Not set'}`);
            console.log(`  └── Cancellation options: ${cancellationOptions.length > 0 ? '✅ Set' : '❌ Not set'}`);
        } catch (error) {
            console.log(`${chain.name}: ❌ Error checking options`);
        }
    }
}

// Advanced configuration example
async function configureBatchOptions() {
    console.log("\n🚀 Advanced: Batch Configuration Example\n");
    
    const aoriAddress = "YOUR_DEPLOYED_AORI_ADDRESS";
    const aori = await ethers.getContractAt("Aori", aoriAddress);
    
    // Create multiple enforced option configurations at once
    const enforcedOptions = [];
    
    // Configure for multiple chains in one transaction
    const chains = [CHAIN_ENDPOINTS.ethereum, CHAIN_ENDPOINTS.arbitrum];
    
    for (const eid of chains) {
        // Settlement options
        enforcedOptions.push({
            eid: eid,
            msgType: 1, // SETTLEMENT_MSG_TYPE
            options: Options.newOptions().addExecutorLzReceiveOption(200000, 0).toBytes()
        });
        
        // Cancellation options
        enforcedOptions.push({
            eid: eid,
            msgType: 2, // CANCELLATION_MSG_TYPE  
            options: Options.newOptions().addExecutorLzReceiveOption(100000, 0).toBytes()
        });
    }
    
    // Set all at once
    const tx = await aori.setEnforcedOptionsMultiple(enforcedOptions);
    await tx.wait();
    console.log("✅ Batch configuration completed!");
}

// Export for use in other scripts
module.exports = {
    configureEnforcedOptions,
    configureBatchOptions,
    CHAIN_ENDPOINTS,
    GAS_LIMITS
};

// Run if called directly
if (require.main === module) {
    configureEnforcedOptions()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error("❌ Configuration failed:", error);
            process.exit(1);
        });
} 