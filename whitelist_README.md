# Aori Contract Whitelist Scripts

These scripts help you whitelist solvers and hooks across multiple Aori contract deployments.

## Setup

1. Install dependencies:
```bash
npm install ethers dotenv
```

2. Configure your private key:
   - Create a `.env` file with your private key:
   ```
   PRIVATE_KEY=your_private_key_here
   ```
   - Make sure the private key corresponds to the owner address of the Aori contracts

## About the Scripts

The scripts use the RPC URLs directly from your `hardhat.config.ts` file, so there's no need to configure additional RPC URLs.

## Available Scripts

### 1. Whitelist Solver

This script whitelists the solver address from `whitelist.json` across all Aori contract deployments.

```bash
node whitelist_solver.js
```

### 2. Whitelist Hooks

This script whitelists hook addresses from `whitelist.json` for each chain according to the configuration.

```bash
node whitelist_hooks.js
```

## Whitelist Configuration

The `whitelist.json` file contains:

1. Solver addresses to whitelist (`solverWhitelist`)
2. Hook addresses to whitelist per chain (`hookWhitelist`)

Example structure:
```json
{
  "solverWhitelist": [
    {
      "address": "0x2002d368c670f5dB65f732152F8887677933D830"
    }
  ],
  "hookWhitelist": {
    "Ethereum": {
      "chainId": 1,
      "hookAddresses": ["0x34482660b6c78747bc3cf86ba4cc81992976d49a"]
    },
    "Arbitrum": {
      "chainId": 42161,
      "hookAddresses": ["0x04ffe14f0293d4ef534078bf407b9c2af2a06bfa"]
    }
  }
}
```

## Notes

- All scripts use the owner wallet to make the contract calls
- The scripts check if addresses are already whitelisted before attempting to whitelist them
- Error handling is included to prevent script crashes and provide useful output
- All transactions are logged along with their confirmation status 