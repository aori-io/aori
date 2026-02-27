mod commands;
mod evm;
mod solana;

use anyhow::Result;
use clap::{Parser, Subcommand};

#[derive(Parser)]
#[command(name = "aori")]
#[command(author, version, about = "Aori cross-chain settlement CLI", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Send a cross-chain message
    Send {
        /// Source chain (solana, arbitrum, base, optimism, ethereum)
        #[arg(long)]
        from: String,

        /// Destination chain (solana, arbitrum, base, optimism, ethereum)
        #[arg(long)]
        to: String,

        /// Message to send
        #[arg(long)]
        message: String,

        /// Network environment (devnet/testnet/mainnet)
        #[arg(long, default_value = "testnet")]
        network: String,
    },

    /// Settle an intent cross-chain
    Settle {
        /// Source chain
        #[arg(long)]
        from: String,

        /// Destination chain
        #[arg(long)]
        to: String,

        /// Intent ID
        #[arg(long)]
        intent_id: String,

        /// Network environment
        #[arg(long, default_value = "testnet")]
        network: String,
    },

    /// Configure peer connections
    Config {
        /// Action: set-peer, get-peer
        #[arg(long)]
        action: String,

        /// Local chain
        #[arg(long)]
        chain: String,

        /// Remote chain (for set-peer)
        #[arg(long)]
        remote_chain: Option<String>,

        /// Peer address (for set-peer)
        #[arg(long)]
        peer_address: Option<String>,

        /// Network environment
        #[arg(long, default_value = "testnet")]
        network: String,
    },

    /// Initialize OApp accounts (Solana only)
    Init {
        /// Program ID of the deployed Solana program
        #[arg(long)]
        program_id: String,

        /// Network environment
        #[arg(long, default_value = "testnet")]
        network: String,
    },

    /// Debug: View stored data
    Debug {
        /// Chain to debug
        #[arg(long)]
        chain: String,

        /// Network environment
        #[arg(long, default_value = "testnet")]
        network: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    // Load environment variables
    dotenv::dotenv().ok();

    let cli = Cli::parse();

    match cli.command {
        Commands::Send {
            from,
            to,
            message,
            network,
        } => {
            commands::send::execute(from, to, message, network).await?;
        }
        Commands::Settle {
            from,
            to,
            intent_id,
            network,
        } => {
            commands::settle::execute(from, to, intent_id, network).await?;
        }
        Commands::Config {
            action,
            chain,
            remote_chain,
            peer_address,
            network,
        } => {
            commands::config::execute(action, chain, remote_chain, peer_address, network).await?;
        }
        Commands::Init {
            program_id,
            network,
        } => {
            commands::init::execute(program_id, network).await?;
        }
        Commands::Debug { chain, network } => {
            commands::debug::execute(chain, network).await?;
        }
    }

    Ok(())
}
