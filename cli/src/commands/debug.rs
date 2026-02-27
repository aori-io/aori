use anyhow::Result;

use crate::solana;

pub async fn execute(chain: String, network: String) -> Result<()> {
    println!("🔍 Debugging OApp state");
    println!("   Chain: {}", chain);
    println!("   Network: {}", network);
    println!();

    match chain.to_lowercase().as_str() {
        "solana" | "sol" => {
            debug_solana(network).await?;
        }
        "arbitrum" | "base" | "optimism" | "ethereum" => {
            debug_evm(chain, network).await?;
        }
        _ => {
            return Err(anyhow::anyhow!("Unknown chain: {}", chain));
        }
    }

    Ok(())
}

async fn debug_solana(network: String) -> Result<()> {
    println!("🔧 Connecting to Solana...");
    let client = solana::client::SolanaClient::new(&network)?;

    println!("📊 Fetching OApp state...");
    println!();

    let store_data = client.get_store_data().await?;

    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("📦 STORE ACCOUNT");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("   Address:          {}", client.store_pda);
    println!("   Admin:            {}", store_data.admin);
    println!("   Endpoint Program: {}", store_data.endpoint_program);
    println!("   Bump:             {}", store_data.bump);
    println!();
    println!("📝 STORED DATA");
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");
    println!("   String: \"{}\"", store_data.string);
    println!("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━");

    Ok(())
}

async fn debug_evm(_chain: String, _network: String) -> Result<()> {
    println!("🚧 EVM debugging coming soon!");
    println!("    Will display contract state, owner, and peer configs");
    println!();
    println!("    To implement:");
    println!("    - Add alloy or ethers to Cargo.toml");
    println!("    - Connect to contract");
    println!("    - Read owner, stored data, peers");

    Ok(())
}
