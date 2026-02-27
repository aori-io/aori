use crate::commands::send::Chain;
use anyhow::{Context, Result};
use std::env;

// TODO: Add alloy or ethers dependency to Cargo.toml
// For alloy: alloy = { version = "0.10", features = ["full"] }
// For ethers: ethers = "2.0"

pub struct EvmClient {
    chain: Chain,
    network: String,
}

impl EvmClient {
    pub fn new(chain: Chain, network: &str) -> Result<Self> {
        // Get RPC URL from environment
        let rpc_url = Self::get_rpc_url(&chain, network)?;
        println!("   RPC: {}", rpc_url);

        // Get private key from environment
        let _private_key = env::var("PRIVATE_KEY")
            .context("PRIVATE_KEY not set. Add it to your .env file")?;

        println!("   Network: {}", network);
        println!();

        Ok(Self {
            chain,
            network: network.to_string(),
        })
    }

    fn get_rpc_url(chain: &Chain, network: &str) -> Result<String> {
        let env_key = match (chain, network) {
            (Chain::Arbitrum, "testnet") => "ARBITRUM_SEPOLIA_RPC_URL",
            (Chain::Arbitrum, "mainnet") => "ARBITRUM_RPC_URL",
            (Chain::Base, "testnet") => "BASE_SEPOLIA_RPC_URL",
            (Chain::Base, "mainnet") => "BASE_RPC_URL",
            (Chain::Optimism, "testnet") => "OPTIMISM_SEPOLIA_RPC_URL",
            (Chain::Optimism, "mainnet") => "OPTIMISM_RPC_URL",
            (Chain::Ethereum, "testnet") => "SEPOLIA_RPC_URL",
            (Chain::Ethereum, "mainnet") => "ETHEREUM_RPC_URL",
            _ => return Err(anyhow::anyhow!("Unsupported chain/network combination")),
        };

        env::var(env_key).context(format!("{} not set in .env file", env_key))
    }

    pub async fn quote_send(&self, dst_eid: u32, message: &str) -> Result<u128> {
        // TODO: Implement quote call to EVM contract
        // This will:
        // 1. Connect to the contract using alloy
        // 2. Call quote(dstEid, message, options, false)
        // 3. Return the native fee in wei

        println!("   Destination EID: {}", dst_eid);
        println!("   Message length: {} bytes", message.len());

        // Placeholder: return estimate
        Ok(10_000_000_000_000_000) // ~0.01 ETH
    }

    pub async fn send_message(
        &self,
        dst_eid: u32,
        message: &str,
        native_fee: u128,
    ) -> Result<String> {
        // TODO: Implement send call to EVM contract
        // This will:
        // 1. Build the transaction
        // 2. Sign it
        // 3. Send it
        // 4. Return tx hash

        println!("   Building transaction...");
        println!("   Destination EID: {}", dst_eid);
        println!("   Fee: {} wei", native_fee);

        // Placeholder
        Ok("0x1234...".to_string())
    }
}
