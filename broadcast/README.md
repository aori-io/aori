# Deployment Records

This folder contains Foundry broadcast logs for contract deployments.

## Aori v0.3.2 Deployment

**Proxy Address (all chains):** `0x7417dE230d7635C7906fEb6aE73d0C551e2aF339`
**Implementation Address:** `0x5511935DB22290E892DF51aD572fDe02E9EAa000`
**Deploy Salt:** `aori-1769116853`

| Chain | Chain ID | Status |
|-------|----------|--------|
| Ethereum | 1 | Deployed |
| Base | 8453 | Deployed |
| Optimism | 10 | Deployed |
| BSC | 56 | Deployed |
| Arbitrum | 42161 | Deployed |
| Plasma | 9745 | Deployed |
| Monad | 143 | Deployed |
| Stable | 988 | Deployed |

## File Structure

```
broadcast/
└── DeployMultichain.s.sol/
    └── <chain_id>/
        ├── run-latest.json     # Most recent broadcast (tracked)
        └── dry-run/            # Simulations (gitignored)
```
