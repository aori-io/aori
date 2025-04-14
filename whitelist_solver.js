// whitelist_solver.js
const ethers = require('ethers');
require('dotenv').config();

// Contract ABI - only the function we need to call
const contractABI = [
  {
    "inputs": [
      {
        "internalType": "address",
        "name": "solver",
        "type": "address"
      }
    ],
    "name": "addAllowedSolver",
    "outputs": [],
    "stateMutability": "nonpayable",
    "type": "function"
  },
  {
    "inputs": [
      {
        "internalType": "address",
        "name": "",
        "type": "address"
      }
    ],
    "name": "isAllowedSolver",
    "outputs": [
      {
        "internalType": "bool",
        "name": "",
        "type": "bool"
      }
    ],
    "stateMutability": "view",
    "type": "function"
  }
];

// Load whitelist data from the file
const whitelistData = require('./whitelist.json');
const solverAddress = whitelistData.solverWhitelist[0].address;

// Contract addresses by network
const contractAddresses = {
  ethereum: "0xe8820573Bb2d748Dc86C381b2c4bC3cFdFabf30A",
  "arbitrum-one": "0x708a4498dA06b133f73Ee6107F1737015372cb76",
  base: "0x21FC19BE519fB20e9182aDF3Ca0C2Ef625aB1647",
  optimism: "0xa7A636374F22c8fDeA985f84C999dEb3294e78c7"
};

// Network RPC URLs from hardhat.config.ts
const networks = {
  ethereum: {
    rpcUrl: "https://nd-386-647-265.p2pify.com/40723238b029534649bd384dbe410645",
    chainId: 1
  },
  "arbitrum-one": {
    rpcUrl: "https://nd-818-527-340.p2pify.com/f1d5b772c018d5ca87dcb6608d43bcf7",
    chainId: 42161
  },
  base: {
    rpcUrl: "https://nd-162-609-387.p2pify.com/945ca2cd8ac8ba0bc854378eb6f4c8ea",
    chainId: 8453
  },
  optimism: {
    rpcUrl: "https://nd-292-688-815.p2pify.com/bef6f576c854febba72dedc55dc37dc0",
    chainId: 10
  }
};

// Function to create provider based on ethers version
function createProvider(rpcUrl) {
  // Check if we're using ethers v5 or v6
  if (ethers.providers && ethers.providers.JsonRpcProvider) {
    // ethers v5
    return new ethers.providers.JsonRpcProvider(rpcUrl);
  } else if (ethers.JsonRpcProvider) {
    // ethers v6
    return new ethers.JsonRpcProvider(rpcUrl);
  } else {
    throw new Error("Unsupported ethers version");
  }
}

// Function to whitelist the solver on a specific network
async function whitelistSolverOnNetwork(networkName) {
  const network = networks[networkName];
  const contractAddress = contractAddresses[networkName];
  
  console.log(`\nWhitelisting solver on ${networkName.toUpperCase()}...`);
  
  try {
    // Create provider and wallet based on ethers version
    const provider = createProvider(network.rpcUrl);
    
    // Create wallet
    let wallet;
    if (ethers.Wallet) {
      // ethers v6
      wallet = new ethers.Wallet(process.env.PRIVATE_KEY, provider);
    } else {
      // ethers v5
      wallet = new ethers.Wallet(process.env.PRIVATE_KEY).connect(provider);
    }
    
    // Create contract instance
    const contract = new ethers.Contract(contractAddress, contractABI, wallet);
    
    // Check if solver is already whitelisted
    const isWhitelisted = await contract.isAllowedSolver(solverAddress);
    
    if (isWhitelisted) {
      console.log(`Solver ${solverAddress} is already whitelisted on ${networkName.toUpperCase()}`);
      return true;
    }
    
    // Call the addAllowedSolver function
    const tx = await contract.addAllowedSolver(solverAddress);
    console.log(`Transaction submitted: ${tx.hash}`);
    
    // Wait for transaction to be confirmed
    const receipt = await tx.wait();
    console.log(`Transaction confirmed in block ${receipt.blockNumber}`);
    console.log(`Solver ${solverAddress} has been whitelisted on ${networkName.toUpperCase()}`);
    
    return true;
  } catch (error) {
    console.error(`Error whitelisting solver on ${networkName.toUpperCase()}:`, error.message);
    return false;
  }
}

// Main function to whitelist solver on all networks
async function whitelistSolver() {
  console.log(`Whitelisting solver address: ${solverAddress}`);
  
  for (const network of Object.keys(networks)) {
    await whitelistSolverOnNetwork(network);
  }
  
  console.log('\nWhitelisting process completed.');
}

// Execute the whitelist function
whitelistSolver()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error('Fatal error:', error);
    process.exit(1);
  }); 