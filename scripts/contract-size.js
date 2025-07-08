const { ethers } = require("hardhat");

async function measureContractSize() {
    console.log("📏 Measuring Contract Sizes\n");

    try {
        // Compile contracts
        await hre.run("compile");
        
        // Get contract artifacts
        const AoriArtifact = await hre.artifacts.readArtifact("Aori");
        
        // Calculate sizes
        const bytecodeSize = AoriArtifact.bytecode.length / 2 - 1; // Remove 0x prefix and convert to bytes
        const deployedBytecodeSize = AoriArtifact.deployedBytecode.length / 2 - 1;
        
        console.log(`Contract: Aori`);
        console.log(`├── Bytecode size: ${bytecodeSize.toLocaleString()} bytes`);
        console.log(`├── Deployed size: ${deployedBytecodeSize.toLocaleString()} bytes`);
        console.log(`├── Size limit: 24,576 bytes (EIP-170)`);
        console.log(`└── Remaining: ${(24576 - deployedBytecodeSize).toLocaleString()} bytes`);
        
        // Check if approaching limit
        const sizePercentage = (deployedBytecodeSize / 24576) * 100;
        if (sizePercentage > 90) {
            console.log(`⚠️  WARNING: Contract is ${sizePercentage.toFixed(1)}% of size limit!`);
        } else {
            console.log(`✅ Contract size is ${sizePercentage.toFixed(1)}% of limit`);
        }
        
    } catch (error) {
        console.error("Error measuring contract size:", error.message);
    }
}

// Run if called directly
if (require.main === module) {
    measureContractSize()
        .then(() => process.exit(0))
        .catch((error) => {
            console.error(error);
            process.exit(1);
        });
}

module.exports = { measureContractSize }; 