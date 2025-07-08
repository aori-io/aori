# Required Rust Backend Fixes

## 1. Update settle function (remove options parameter)

```rust
// OLD - with options parameter
pub fn build_settle_calldata(&self, src_eid: u32, filler: Address) -> Result<Vec<u8>> {
    let settle_function = self
        .contract
        .functions
        .get("settle")
        .ok_or_else(|| eyre::eyre!("Settle function not found in contract"))?
        .first()
        .ok_or_else(|| eyre::eyre!("No settle function found"))?;

    let filler_addr = EthAddress::from_slice(filler.as_slice());
    let options = self.encode_lz_options()?;  // ← Remove this

    let tokens = vec![
        Token::Uint(EthU256::from(src_eid)),
        Token::Address(filler_addr),
        Token::Bytes(options),  // ← Remove this parameter
    ];

    settle_function
        .encode_input(&tokens)
        .map_err(|e| eyre::eyre!("Failed to encode settle function call: {}", e))
}

// NEW - without options parameter
pub fn build_settle_calldata(&self, src_eid: u32, filler: Address) -> Result<Vec<u8>> {
    let settle_function = self
        .contract
        .functions
        .get("settle")
        .ok_or_else(|| eyre::eyre!("Settle function not found in contract"))?
        .first()
        .ok_or_else(|| eyre::eyre!("No settle function found"))?;

    let filler_addr = EthAddress::from_slice(filler.as_slice());

    let tokens = vec![
        Token::Uint(EthU256::from(src_eid)),
        Token::Address(filler_addr),
        // No options parameter anymore!
    ];

    settle_function
        .encode_input(&tokens)
        .map_err(|e| eyre::eyre!("Failed to encode settle function call: {}", e))
}
```

## 2. Update quote function (remove options parameter)

```rust
// OLD - with options parameter
pub fn build_quote_calldata(
    &self,
    dst_eid: u32,
    msg_type: u8,
    pay_in_lz_token: bool,
    src_eid: u32,
    filler: Address,
) -> Result<Vec<u8>> {
    let quote_function = self
        .contract
        .functions
        .get("quote")
        .ok_or_else(|| eyre::eyre!("Quote function not found in contract"))?
        .first()
        .ok_or_else(|| eyre::eyre!("No quote function found"))?;

    let filler_addr = EthAddress::from_slice(filler.as_slice());
    let encoded_options = self.encode_lz_options()?;  // ← Remove this

    let tokens = vec![
        Token::Uint(EthU256::from(dst_eid)),
        Token::Uint(EthU256::from(msg_type)),
        Token::Bytes(encoded_options),  // ← Remove this parameter
        Token::Bool(pay_in_lz_token),
        Token::Uint(EthU256::from(src_eid)),
        Token::Address(filler_addr),
    ];

    quote_function
        .encode_input(&tokens)
        .map_err(|e| eyre::eyre!("Failed to encode quote function call: {}", e))
}

// NEW - without options parameter
pub fn build_quote_calldata(
    &self,
    dst_eid: u32,
    msg_type: u8,
    pay_in_lz_token: bool,
    src_eid: u32,
    filler: Address,
) -> Result<Vec<u8>> {
    let quote_function = self
        .contract
        .functions
        .get("quote")
        .ok_or_else(|| eyre::eyre!("Quote function not found in contract"))?
        .first()
        .ok_or_else(|| eyre::eyre!("No quote function found"))?;

    let filler_addr = EthAddress::from_slice(filler.as_slice());

    let tokens = vec![
        Token::Uint(EthU256::from(dst_eid)),
        Token::Uint(EthU256::from(msg_type)),
        // No options parameter anymore!
        Token::Bool(pay_in_lz_token),
        Token::Uint(EthU256::from(src_eid)),
        Token::Address(filler_addr),
    ];

    quote_function
        .encode_input(&tokens)
        .map_err(|e| eyre::eyre!("Failed to encode quote function call: {}", e))
}
```

## 3. Remove the encode_lz_options function

```rust
// DELETE THIS FUNCTION - it's no longer needed
fn encode_lz_options(&self) -> Result<Vec<u8>> {
    // This function is no longer needed since options are now enforced on-chain
}
```

## 4. Add cancel function with updated signature

```rust
// Update cancel function to handle cross-chain cancellations
pub fn build_cancel_cross_chain_calldata(
    &self, 
    order_hash: &str, 
    order: &Order
) -> Result<Vec<u8>> {
    // Find the cancel function with 2 inputs: (bytes32, Order)
    let cancel_function = self
        .contract
        .functions
        .get("cancel")
        .and_then(|funcs| {
            funcs.iter().find(|f| f.inputs.len() == 2)
        })
        .context("No cancel(bytes32, Order) function found in contract")?;

    // Convert order_hash (hex string) to [u8; 32]
    let hash_bytes = hex::decode(order_hash.strip_prefix("0x").unwrap_or(order_hash))
        .map_err(|e| eyre::eyre!("Invalid order hash hex: {}", e))?;
    if hash_bytes.len() != 32 {
        return Err(eyre::eyre!("Order hash must be 32 bytes"));
    }

    let order_token = self.order_to_token(order);

    let tokens = vec![
        Token::FixedBytes(hash_bytes),
        order_token,
        // No options parameter anymore!
    ];
    
    cancel_function
        .encode_input(&tokens)
        .map_err(|e| eyre::eyre!("Failed to encode cancel function call: {}", e))
}
``` 