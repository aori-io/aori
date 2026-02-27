use anchor_client::solana_sdk::{
    commitment_config::CommitmentConfig,
    compute_budget::ComputeBudgetInstruction,
    instruction::{AccountMeta, Instruction},
    pubkey::Pubkey,
    signature::{read_keypair_file, Keypair, Signer},
    system_program,
    transaction::Transaction,
};
use anchor_client::{Client, Cluster};
use anchor_lang::prelude::*;
use anchor_lang::{AnchorDeserialize, AnchorSerialize, InstructionData, ToAccountMetas};
use anyhow::Result;
use std::env;
use std::io::Write;
use std::path::PathBuf;
use std::rc::Rc;
use std::str::FromStr;

// Program seeds (must match your Solana program)
const STORE_SEED: &[u8] = b"Store";
const PEER_SEED: &[u8] = b"Peer";
const LZ_RECEIVE_TYPES_SEED: &[u8] = b"LzReceiveTypes";

// LayerZero Endpoint Program ID (Testnet/Devnet)
const ENDPOINT_PROGRAM_ID: &str = "76y77prsiCMvXMjuoZ5VRrhG5qYBrUMYTE5WgHqgjEn6";

pub struct SolanaClient {
    pub client: Client<Rc<Keypair>>,
    pub keypair: Keypair,
    pub program_id: Pubkey,
    pub store_pda: Pubkey,
}

impl SolanaClient {
    pub fn new(network: &str) -> Result<Self> {
        // Get RPC URL from environment
        let rpc_url = match network {
            "testnet" | "devnet" => env::var("RPC_URL_SOLANA_TESTNET")
                .unwrap_or_else(|_| "https://api.devnet.solana.com".to_string()),
            "mainnet" => env::var("RPC_URL_SOLANA")
                .unwrap_or_else(|_| "https://api.mainnet-beta.solana.com".to_string()),
            _ => return Err(anyhow::anyhow!("Unknown network: {}", network)),
        };

        println!("   RPC: {}", rpc_url);

        // Get keypair from environment
        let keypair = Self::load_keypair()?;
        println!("   Wallet: {}", keypair.pubkey());

        // Create anchor client
        let client = Client::new_with_options(
            Cluster::Custom(rpc_url.clone(), rpc_url),
            Rc::new(keypair.insecure_clone()),
            CommitmentConfig::confirmed(),
        );

        // Get program ID from deployment file or environment
        let program_id = Self::load_program_id(network)?;
        println!("   Program: {}", program_id);

        // Derive Store PDA
        let (store_pda, _bump) = Pubkey::find_program_address(&[STORE_SEED], &program_id);
        println!("   Store PDA: {}", store_pda);
        println!();

        Ok(Self {
            client,
            keypair,
            program_id,
            store_pda,
        })
    }

    fn load_keypair() -> Result<Keypair> {
        // Try SOLANA_PRIVATE_KEY first
        if let Ok(private_key) = env::var("SOLANA_PRIVATE_KEY") {
            // Try base58 format
            if let Ok(bytes) = bs58::decode(&private_key).into_vec() {
                if let Ok(keypair) = Keypair::try_from(&bytes[..]) {
                    return Ok(keypair);
                }
            }

            // Try JSON array format [1,2,3,...]
            if let Ok(bytes) = serde_json::from_str::<Vec<u8>>(&private_key) {
                if let Ok(keypair) = Keypair::try_from(&bytes[..]) {
                    return Ok(keypair);
                }
            }
        }

        // Try SOLANA_KEYPAIR_PATH
        if let Ok(path) = env::var("SOLANA_KEYPAIR_PATH") {
            return read_keypair_file(&path)
                .map_err(|e| anyhow::anyhow!("Failed to read keypair from {}: {}", path, e));
        }

        // Try default path
        let default_path = dirs::home_dir()
            .ok_or_else(|| anyhow::anyhow!("Failed to get home directory"))?
            .join(".config/solana/id.json");

        if default_path.exists() {
            println!(
                "   Using default keypair: {}",
                default_path.display()
            );
            return read_keypair_file(&default_path)
                .map_err(|e| anyhow::anyhow!("Failed to read default keypair: {}", e));
        }

        Err(anyhow::anyhow!(
            "No Solana keypair found. Set SOLANA_PRIVATE_KEY, SOLANA_KEYPAIR_PATH, or place keypair at ~/.config/solana/id.json"
        ))
    }

    fn load_program_id(network: &str) -> Result<Pubkey> {
        // Try to read from deployments/solana-testnet/OApp.json
        let network_name = match network {
            "testnet" | "devnet" => "solana-testnet",
            "mainnet" => "solana-mainnet",
            _ => network,
        };

        let deployment_path = PathBuf::from("deployments")
            .join(network_name)
            .join("OApp.json");

        if deployment_path.exists() {
            let contents = std::fs::read_to_string(&deployment_path)
                .map_err(|e| anyhow::anyhow!("Failed to read deployment file: {}", e))?;
            let deployment: serde_json::Value = serde_json::from_str(&contents)?;

            if let Some(program_id) = deployment.get("programId").and_then(|v| v.as_str()) {
                return Pubkey::from_str(program_id)
                    .map_err(|e| anyhow::anyhow!("Invalid program ID in deployment: {}", e));
            }
        }

        Err(anyhow::anyhow!(
            "Program ID not found. Deploy your program first or set AORI_PROGRAM_ID"
        ))
    }

    /// Derive peer PDA for a given remote endpoint ID
    fn derive_peer_pda(&self, dst_eid: u32) -> Pubkey {
        let (peer_pda, _bump) = Pubkey::find_program_address(
            &[PEER_SEED, self.store_pda.as_ref(), &dst_eid.to_be_bytes()],
            &self.program_id,
        );
        peer_pda
    }

    /// Initialize the OApp Store account
    pub async fn init_store(&self, admin: Option<Pubkey>) -> Result<String> {
        let program = self.client.program(self.program_id)?;
        let admin_pubkey = admin.unwrap_or_else(|| self.keypair.pubkey());
        let endpoint_program = Pubkey::from_str(ENDPOINT_PROGRAM_ID)?;

        println!("   Creating Store PDA: {}", self.store_pda);
        println!("   Admin: {}", admin_pubkey);
        println!("   Endpoint: {}", endpoint_program);

        // Derive LzReceiveTypes PDA
        let (lz_receive_types_pda, _) = Pubkey::find_program_address(
            &[LZ_RECEIVE_TYPES_SEED, self.store_pda.as_ref()],
            &self.program_id,
        );

        // Use raw instruction building since anchor-client's high-level API is complex
        let ix_data = InitStoreParams {
            admin: admin_pubkey,
            endpoint: endpoint_program,
        };

        let mut data = vec![0x9a, 0x28, 0x5c, 0x2f, 0x9a, 0x6c, 0x0c, 0x3f]; // init_store discriminator
        data.extend_from_slice(&ix_data.try_to_vec()?);

        let accounts = vec![
            AccountMeta::new(self.keypair.pubkey(), true),
            AccountMeta::new(self.store_pda, false),
            AccountMeta::new(lz_receive_types_pda, false),
            AccountMeta::new_readonly(system_program::ID, false),
        ];

        let instruction = Instruction {
            program_id: self.program_id,
            accounts,
            data,
        };

        // Send transaction
        let rpc_client = program.rpc();
        let recent_blockhash = rpc_client
            .get_latest_blockhash()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to get blockhash: {}", e))?;

        let transaction = Transaction::new_signed_with_payer(
            &[instruction],
            Some(&self.keypair.pubkey()),
            &[&self.keypair],
            recent_blockhash,
        );

        let signature = rpc_client
            .send_and_confirm_transaction(&transaction)
            .await
            .map_err(|e| anyhow::anyhow!("Transaction failed: {}", e))?;

        println!("   Transaction confirmed!");

        Ok(signature.to_string())
    }

    /// Quote the fee for sending a cross-chain message
    pub async fn quote_send(&self, dst_eid: u32, _message: &str) -> Result<u64> {
        // For quote, we'd need to simulate the quote_send instruction
        // For now, return a reasonable estimate
        
        // Base cross-chain fee estimate
        let base_fee = 5_000_000; // 0.005 SOL

        Ok(base_fee)
    }

    /// Send a cross-chain message
    pub async fn send_message(
        &self,
        dst_eid: u32,
        message: &str,
        native_fee: u64,
    ) -> Result<String> {
        let program = self.client.program(self.program_id)?;
        let peer_pda = self.derive_peer_pda(dst_eid);
        let endpoint_program = Pubkey::from_str(ENDPOINT_PROGRAM_ID)?;

        // Derive endpoint settings PDA
        let (endpoint_settings, _) =
            Pubkey::find_program_address(&[b"EndpointSettings"], &endpoint_program);

        println!("   Building send transaction...");
        println!("   Store: {}", self.store_pda);
        println!("   Peer PDA: {}", peer_pda);
        println!("   Destination EID: {}", dst_eid);

        let ix_data = SendMessageParams {
            dst_eid,
            message: message.to_string(),
            options: vec![],
            native_fee,
            lz_token_fee: 0,
        };

        // send instruction discriminator
        let mut data = vec![0x4c, 0x4b, 0x17, 0x7c, 0x36, 0x2f, 0x5e, 0xfe];
        data.extend_from_slice(&ix_data.try_to_vec()?);

        let accounts = vec![
            AccountMeta::new_readonly(peer_pda, false),
            AccountMeta::new_readonly(self.store_pda, false),
            AccountMeta::new_readonly(endpoint_settings, false),
        ];

        let instruction = Instruction {
            program_id: self.program_id,
            accounts,
            data,
        };

        // Add compute budget
        let compute_limit = ComputeBudgetInstruction::set_compute_unit_limit(250_000);
        let compute_price = ComputeBudgetInstruction::set_compute_unit_price(1_000);

        // Send transaction
        let rpc_client = program.rpc();
        let recent_blockhash = rpc_client
            .get_latest_blockhash()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to get blockhash: {}", e))?;

        let transaction = Transaction::new_signed_with_payer(
            &[compute_limit, compute_price, instruction],
            Some(&self.keypair.pubkey()),
            &[&self.keypair],
            recent_blockhash,
        );

        let signature = rpc_client
            .send_and_confirm_transaction(&transaction)
            .await
            .map_err(|e| anyhow::anyhow!("Transaction failed: {}", e))?;

        println!("   Transaction confirmed!");

        Ok(signature.to_string())
    }

    /// Set peer address for a remote chain
    pub async fn set_peer_address(&self, remote_eid: u32, peer_address: [u8; 32]) -> Result<String> {
        let program = self.client.program(self.program_id)?;
        let peer_pda = self.derive_peer_pda(remote_eid);

        println!("   Setting peer for EID {}", remote_eid);
        println!("   Peer PDA: {}", peer_pda);
        println!("   Peer Address: 0x{}", hex::encode(peer_address));

        let ix_data = SetPeerConfigParams {
            remote_eid,
            config: PeerConfigParam::PeerAddress { peer_address },
        };

        // set_peer_config instruction discriminator
        let mut data = vec![0x8d, 0x38, 0xe4, 0x6f, 0x81, 0x7e, 0x5f, 0x3d];
        data.extend_from_slice(&ix_data.try_to_vec()?);

        let accounts = vec![
            AccountMeta::new(self.keypair.pubkey(), true),
            AccountMeta::new(self.store_pda, false),
            AccountMeta::new(peer_pda, false),
            AccountMeta::new_readonly(system_program::ID, false),
        ];

        let instruction = Instruction {
            program_id: self.program_id,
            accounts,
            data,
        };

        // Send transaction
        let rpc_client = program.rpc();
        let recent_blockhash = rpc_client
            .get_latest_blockhash()
            .await
            .map_err(|e| anyhow::anyhow!("Failed to get blockhash: {}", e))?;

        let transaction = Transaction::new_signed_with_payer(
            &[instruction],
            Some(&self.keypair.pubkey()),
            &[&self.keypair],
            recent_blockhash,
        );

        let signature = rpc_client
            .send_and_confirm_transaction(&transaction)
            .await
            .map_err(|e| anyhow::anyhow!("Transaction failed: {}", e))?;

        println!("   Peer set successfully!");

        Ok(signature.to_string())
    }

    /// Get peer address for a remote chain
    pub async fn get_peer(&self, remote_eid: u32) -> Result<[u8; 32]> {
        let program = self.client.program(self.program_id)?;
        let peer_pda = self.derive_peer_pda(remote_eid);

        // Fetch the PeerConfig account
        let account_data = program
            .rpc()
            .get_account_data(&peer_pda)
            .await
            .map_err(|e| anyhow::anyhow!("Failed to fetch peer account: {}", e))?;

        // Deserialize (skip 8-byte discriminator)
        let peer_config = PeerConfig::try_from_slice(&account_data[8..])?;

        Ok(peer_config.peer_address)
    }

    /// Read Store account data
    pub async fn get_store_data(&self) -> Result<StoreData> {
        let program = self.client.program(self.program_id)?;

        // Fetch the Store account
        let account_data = program
            .rpc()
            .get_account_data(&self.store_pda)
            .await
            .map_err(|e| anyhow::anyhow!("Failed to fetch store account: {}", e))?;

        // Deserialize (skip 8-byte discriminator)
        let store = Store::try_from_slice(&account_data[8..])?;

        Ok(StoreData {
            admin: store.admin,
            endpoint_program: store.endpoint_program,
            string: store.string,
            bump: store.bump,
        })
    }
}

/// Store account data structure
#[derive(Debug)]
pub struct StoreData {
    pub admin: Pubkey,
    pub endpoint_program: Pubkey,
    pub string: String,
    pub bump: u8,
}

// Instruction parameters
#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct InitStoreParams {
    pub admin: Pubkey,
    pub endpoint: Pubkey,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct SendMessageParams {
    pub dst_eid: u32,
    pub message: String,
    pub options: Vec<u8>,
    pub native_fee: u64,
    pub lz_token_fee: u64,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub struct SetPeerConfigParams {
    pub remote_eid: u32,
    pub config: PeerConfigParam,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone)]
pub enum PeerConfigParam {
    PeerAddress { peer_address: [u8; 32] },
    EnforcedOptions { send: Vec<u8>, send_and_call: Vec<u8> },
}

// Account data structures
#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct Store {
    pub admin: Pubkey,
    pub bump: u8,
    pub endpoint_program: Pubkey,
    pub string: String,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug)]
pub struct PeerConfig {
    pub peer_address: [u8; 32],
    pub enforced_options: EnforcedOptions,
    pub bump: u8,
}

#[derive(AnchorSerialize, AnchorDeserialize, Clone, Debug, Default)]
pub struct EnforcedOptions {
    pub send: Vec<u8>,
    pub send_and_call: Vec<u8>,
}
