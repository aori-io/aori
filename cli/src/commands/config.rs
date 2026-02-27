use anyhow::Result;

use crate::commands::send::{parse_chain_public, chain_to_eid, Chain};
use crate::solana;

pub async fn execute(
    action: String,
    chain: String,
    remote_chain: Option<String>,
    peer_address: Option<String>,
    network: String,
) -> Result<()> {
    println!("⚙️  OApp Configuration");
    println!("   Action: {}", action);
    println!("   Chain: {}", chain);
    println!("   Network: {}", network);
    println!();

    match action.as_str() {
        "set-peer" => {
            let remote = remote_chain.ok_or_else(|| anyhow::anyhow!("--remote-chain required for set-peer"))?;
            let address = peer_address.ok_or_else(|| anyhow::anyhow!("--peer-address required for set-peer"))?;

            set_peer(chain, remote, address, network).await?;
        }
        "get-peer" => {
            let remote = remote_chain.ok_or_else(|| anyhow::anyhow!("--remote-chain required for get-peer"))?;

            get_peer(chain, remote, network).await?;
        }
        _ => {
            return Err(anyhow::anyhow!(
                "Unknown action: {}. Use 'set-peer' or 'get-peer'",
                action
            ));
        }
    }

    Ok(())
}

async fn set_peer(
    chain: String,
    remote_chain: String,
    peer_address: String,
    network: String,
) -> Result<()> {
    println!("🔗 Setting peer configuration");
    println!("   Local chain: {}", chain);
    println!("   Remote chain: {}", remote_chain);
    println!("   Peer address: {}", peer_address);
    println!();

    let local = parse_chain_public(&chain)?;
    let remote = parse_chain_public(&remote_chain)?;

    match local {
        Chain::Solana => {
            set_peer_solana(remote, peer_address, network).await?;
        }
        Chain::Arbitrum | Chain::Base | Chain::Optimism | Chain::Ethereum => {
            set_peer_evm(local, remote, peer_address, network).await?;
        }
    }

    Ok(())
}

async fn set_peer_solana(remote_chain: Chain, peer_address: String, network: String) -> Result<()> {
    println!("🔧 Connecting to Solana...");
    let client = solana::client::SolanaClient::new(&network)?;

    let remote_eid = chain_to_eid(&remote_chain, &network)?;

    // Parse peer address (should be hex string)
    let peer_bytes = parse_peer_address(&peer_address)?;

    println!("📤 Setting peer...");
    let signature = client.set_peer_address(remote_eid, peer_bytes).await?;

    println!();
    println!("✅ Peer configured!");
    println!("🧾 Transaction: {}", signature);
    
    let cluster = if network == "testnet" || network == "devnet" { "devnet" } else { "mainnet-beta" };
    println!("🔍 Solscan: https://solscan.io/tx/{}?cluster={}", signature, cluster);

    Ok(())
}

async fn set_peer_evm(
    _local_chain: Chain,
    _remote_chain: Chain,
    _peer_address: String,
    _network: String,
) -> Result<()> {
    println!("🚧 EVM peer configuration coming soon!");
    println!("    Will call setPeer() on your EVM contract");

    Ok(())
}

async fn get_peer(chain: String, remote_chain: String, network: String) -> Result<()> {
    println!("🔍 Getting peer configuration");
    println!("   Local chain: {}", chain);
    println!("   Remote chain: {}", remote_chain);
    println!();

    let local = parse_chain_public(&chain)?;
    let remote = parse_chain_public(&remote_chain)?;

    match local {
        Chain::Solana => {
            get_peer_solana(remote, network).await?;
        }
        Chain::Arbitrum | Chain::Base | Chain::Optimism | Chain::Ethereum => {
            get_peer_evm(local, remote, network).await?;
        }
    }

    Ok(())
}

async fn get_peer_solana(remote_chain: Chain, network: String) -> Result<()> {
    println!("🔧 Connecting to Solana...");
    let client = solana::client::SolanaClient::new(&network)?;

    let remote_eid = chain_to_eid(&remote_chain, &network)?;

    println!("📖 Fetching peer configuration...");
    let peer_address = client.get_peer(remote_eid).await?;

    println!();
    println!("✅ Peer configuration:");
    println!("   Remote chain: {:?} (EID: {})", remote_chain, remote_eid);
    println!("   Peer address: 0x{}", hex::encode(peer_address));

    Ok(())
}

async fn get_peer_evm(
    _local_chain: Chain,
    _remote_chain: Chain,
    _network: String,
) -> Result<()> {
    println!("🚧 EVM peer reading coming soon!");
    println!("    Will call peers() on your EVM contract");

    Ok(())
}

/// Parse peer address from hex string to 32-byte array
fn parse_peer_address(address: &str) -> Result<[u8; 32]> {
    let address = address.strip_prefix("0x").unwrap_or(address);
    
    let bytes = hex::decode(address)
        .map_err(|e| anyhow::anyhow!("Invalid hex address: {}", e))?;
    
    if bytes.len() > 32 {
        return Err(anyhow::anyhow!("Address too long: {} bytes (max 32)", bytes.len()));
    }
    
    // Left-pad with zeros to 32 bytes
    let mut padded = [0u8; 32];
    let offset = 32 - bytes.len();
    padded[offset..].copy_from_slice(&bytes);
    
    Ok(padded)
}
