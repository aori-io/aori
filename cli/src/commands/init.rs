use anyhow::Result;
use std::fs;
use std::path::PathBuf;

use crate::solana;

pub async fn execute(program_id: String, network: String) -> Result<()> {
    println!("🚀 Initializing Solana OApp");
    println!("   Program ID: {}", program_id);
    println!("   Network: {}", network);
    println!();

    println!("🔧 Connecting to Solana...");
    let client = solana::client::SolanaClient::new(&network)?;

    println!("📝 Creating Store PDA...");
    let signature = client.init_store(None).await?;

    println!();
    println!("✅ Store initialized successfully!");
    println!("🧾 Transaction: {}", signature);
    println!("📦 Store PDA: {}", client.store_pda);

    // Save deployment info
    save_deployment(&network, &program_id, &client.store_pda.to_string())?;

    println!();
    println!("💾 Deployment saved to deployments/{}/OApp.json", get_network_name(&network));
    println!();
    println!("🌐 View on Solscan: https://solscan.io/tx/{}?cluster={}", 
        signature, 
        if network == "testnet" || network == "devnet" { "devnet" } else { "mainnet-beta" }
    );

    Ok(())
}

fn get_network_name(network: &str) -> String {
    match network {
        "testnet" | "devnet" => "solana-testnet".to_string(),
        "mainnet" => "solana-mainnet".to_string(),
        _ => format!("solana-{}", network),
    }
}

fn save_deployment(network: &str, program_id: &str, oapp: &str) -> Result<()> {
    let network_name = get_network_name(network);
    let dir = PathBuf::from("deployments").join(&network_name);
    
    fs::create_dir_all(&dir)?;
    
    let deployment = serde_json::json!({
        "programId": program_id,
        "oapp": oapp
    });
    
    let file_path = dir.join("OApp.json");
    fs::write(file_path, serde_json::to_string_pretty(&deployment)?)?;
    
    Ok(())
}
