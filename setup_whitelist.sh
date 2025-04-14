#!/bin/bash

echo "Setting up whitelist scripts..."

# Make sure the scripts use the project's installed packages
echo "Installing dependencies if not already installed..."
pnpm install ethers@5.7.2 dotenv

echo "Creating symlinks to use ethers from main project..."
ln -sf ../node_modules/ethers whitelist_node_modules_ethers || true
ln -sf ../node_modules/dotenv whitelist_node_modules_dotenv || true

# Run the whitelist scripts
echo "Running the whitelist scripts..."
echo "1. Whitelisting solvers..."
NODE_PATH=. node whitelist_solver.js

echo "2. Whitelisting hooks..."
NODE_PATH=. node whitelist_hooks.js

echo "Whitelist setup complete!" 