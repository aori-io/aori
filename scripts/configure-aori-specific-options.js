const { ethers } = require("hardhat");
const { Options } = require("@layerzerolabs/lz-v2-utilities");

/**
 * Configure Aori enforced options to match previous Rust backend gas usage
 * Your Rust code was using 1,500,000 gas - let's match that
 */

// Your actual LayerZero Endpoint IDs (update these)
const CHAIN_ENDPOINTS = {
    ethereum: 30101,
    arbitrum: 30110,
    optimism: 30111,
    polygon: 30109,
    base: 30184,
    avalanche: 30106
};

// Gas limits that match your previous Rust implementation
const GAS_LIMITS = {
    // Your Rust code used 1.5M gas for all operations
    settlement: 1500000,    // Match your previous encode_lz_options()
    cancellation: 1500000   // Keep same for consistency
};

async function configureAoriOptions() {
    console.log("🔧 Configuring Aori Enforced Options (matching previous 1.5M gas)\n");

    // Replace with your deployed Aori contract address
    const aoriAddress = "YOUR_DEPLOYED_AORI_ADDRESS";
    const aori = await ethers.getContractAt("Aori", aoriAddress);
    
    const [owner] = await ethers.getSigners();
    console.log(`👤 Configuring as owner: ${owner.address}\n`);

    // Configure for your supported chains
    const supportedChains = [
        { name: "Ethereum", eid: CHAIN_ENDPOINTS.ethereum },
        { name: "Arbitrum", eid: CHAIN_ENDPOINTS.arbitrum },
        { name: "Optimism", eid: CHAIN_ENDPOINTS.optimism },
    ];

    for (const chain of supportedChains) {
        console.log(`⚙️  Configuring ${chain.name} (EID: ${chain.eid})`);
        
        try {
            // Create Type 3 options with 1.5M gas (matching your Rust code)
            const settlementOptions = Options.newOptions()
                .addExecutorLzReceiveOption(GAS_LIMITS.settlement, 0)  // 1.5M gas, 0 msg.value
                .toBytes();

            const cancellationOptions = Options.newOptions()
                .addExecutorLzReceiveOption(GAS_LIMITS.cancellation, 0)  // 1.5M gas, 0 msg.value
                .toBytes();

            // Set enforced options
            console.log(`  ├── Settlement options: ${GAS_LIMITS.settlement.toLocaleString()} gas`);
            const settleTx = await aori.setEnforcedSettlementOptions(chain.eid, settlementOptions);
            await settleTx.wait();
            
            console.log(`  ├── Cancellation options: ${GAS_LIMITS.cancellation.toLocaleString()} gas`);
            const cancelTx = await aori.setEnforcedCancellationOptions(chain.eid, cancellationOptions);
            await cancelTx.wait();
            
            console.log(`  └── ✅ ${chain.name} configured with 1.5M gas\n`);
            
        } catch (error) {
            console.log(`  └── ❌ Failed to configure ${chain.name}: ${error.message}\n`);
        }
    }

    // Verify configuration matches your previous setup
    console.log("🔍 Verifying gas limits match your Rust backend...\n");
    for (const chain of supportedChains) {
        try {
            const settlementOptions = await aori.getEnforcedSettlementOptions(chain.eid);
            const cancellationOptions = await aori.getEnforcedCancellationOptions(chain.eid);
            
            console.log(`${chain.name}:`);
            console.log(`  ├── Settlement: ${settlementOptions.length > 0 ? '✅ 1.5M gas configured' : '❌ Not configured'}`);
            console.log(`  └── Cancellation: ${cancellationOptions.length > 0 ? '✅ 1.5M gas configured' : '❌ Not configured'}`);
        } catch (error) {
            console.log(`${chain.name}: ❌ Error checking options`);
        }
    }
    
    console.log("\n✅ Configuration complete! Your enforced options now match your previous Rust gas usage.");
    console.log("🔄 Next step: Update your Rust backend to use the new function signatures (see rust-fixes.md)");
}

// Run configuration
if (require.main === module) {
    configureAoriOptions()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error("❌ Configuration failed:", error);
            process.exit(1);
        });
}

module.exports = { configureAoriOptions, GAS_LIMITS }; 