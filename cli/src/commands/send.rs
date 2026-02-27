use anyhow::Result;

use crate::evm;
use crate::solana;

pub async fn execute(from: String, to: String, message: String, network: String) -> Result<()> {
    println!("📨 Sending cross-chain message");
    println!("   From: {}", from);
    println!("   To: {}", to);
    println!("   Message: \"{}\"", message);
    println!("   Network: {}", network);
    println!();

    let from_chain = parse_chain(&from)?;
    let to_chain = parse_chain(&to)?;

    match from_chain {
        Chain::Solana => {
            send_from_solana(to_chain, message, network).await?;
        }
        Chain::Arbitrum | Chain::Base | Chain::Optimism | Chain::Ethereum => {
            send_from_evm(from_chain, to_chain, message, network).await?;
        }
    }

    Ok(())
}

async fn send_from_solana(to_chain: Chain, message: String, network: String) -> Result<()> {
    let dst_eid = chain_to_eid(&to_chain, &network)?;

    println!("🔧 Connecting to Solana...");
    let client = solana::client::SolanaClient::new(&network)?;

    println!("📋 Quoting message fee...");
    let fee = client.quote_send(dst_eid, &message).await?;
    println!("💰 Fee: {} lamports (~{:.4} SOL)", fee, fee as f64 / 1e9);

    println!("📤 Sending transaction...");
    let signature = client.send_message(dst_eid, &message, fee).await?;

    println!();
    println!("✅ Message sent!");
    println!("   Message: \"{}\"", message);
    println!("   From: Solana");
    println!("   To: {} (EID: {})", chain_name(&to_chain), dst_eid);
    println!();
    println!("🧾 Transaction: {}", signature);
    
    let cluster = if network == "testnet" || network == "devnet" {
        "devnet"
    } else {
        "mainnet-beta"
    };
    
    println!("🔍 Solscan: https://solscan.io/tx/{}?cluster={}", signature, cluster);
    println!("🌐 LayerZero Scan: https://{}layerzeroscan.com/tx/{}", 
        if network == "testnet" || network == "devnet" { "testnet." } else { "" },
        signature
    );

    Ok(())
}

async fn send_from_evm(
    from_chain: Chain,
    to_chain: Chain,
    message: String,
    network: String,
) -> Result<()> {
    let dst_eid = chain_to_eid(&to_chain, &network)?;

    println!("🔧 Connecting to {}...", chain_name(&from_chain));
    let client = evm::client::EvmClient::new(from_chain, &network)?;

    println!("📋 Quoting message fee...");
    let fee = client.quote_send(dst_eid, &message).await?;
    println!("💰 Fee: {} wei ({} ETH)", fee, fee as f64 / 1e18);

    println!("📤 Sending transaction...");
    let tx_hash = client.send_message(dst_eid, &message, fee).await?;

    println!();
    println!("✅ Message sent!");
    println!("🧾 Transaction: {}", tx_hash);
    println!(
        "🌐 LayerZero Scan: https://testnet.layerzeroscan.com/tx/{}",
        tx_hash
    );

    Ok(())
}

#[derive(Debug, Clone, Copy)]
pub enum Chain {
    Solana,
    Arbitrum,
    Base,
    Optimism,
    Ethereum,
}

pub fn parse_chain_public(chain: &str) -> Result<Chain> {
    parse_chain(chain)
}

fn parse_chain(chain: &str) -> Result<Chain> {
    match chain.to_lowercase().as_str() {
        "solana" | "sol" => Ok(Chain::Solana),
        "arbitrum" | "arb" => Ok(Chain::Arbitrum),
        "base" => Ok(Chain::Base),
        "optimism" | "op" => Ok(Chain::Optimism),
        "ethereum" | "eth" => Ok(Chain::Ethereum),
        _ => Err(anyhow::anyhow!("Unknown chain: {}", chain)),
    }
}

fn chain_name(chain: &Chain) -> &'static str {
    match chain {
        Chain::Solana => "Solana",
        Chain::Arbitrum => "Arbitrum",
        Chain::Base => "Base",
        Chain::Optimism => "Optimism",
        Chain::Ethereum => "Ethereum",
    }
}

pub fn chain_to_eid(chain: &Chain, network: &str) -> Result<u32> {
    match (chain, network) {
        // Testnet EIDs
        (Chain::Solana, "testnet" | "devnet") => Ok(40168),
        (Chain::Arbitrum, "testnet") => Ok(40231),
        (Chain::Base, "testnet") => Ok(40245),
        (Chain::Optimism, "testnet") => Ok(40232),
        (Chain::Ethereum, "testnet") => Ok(40161),

        // Mainnet EIDs
        (Chain::Solana, "mainnet") => Ok(30168),
        (Chain::Arbitrum, "mainnet") => Ok(30110),
        (Chain::Base, "mainnet") => Ok(30184),
        (Chain::Optimism, "mainnet") => Ok(30111),
        (Chain::Ethereum, "mainnet") => Ok(30101),

        _ => Err(anyhow::anyhow!(
            "Unknown network '{}' for chain {:?}",
            network,
            chain
        )),
    }
}
