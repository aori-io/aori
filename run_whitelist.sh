#!/bin/bash

echo "Running whitelist scripts..."

# Check if .env file exists, if not create it
if [ ! -f .env ]; then
  echo "Creating .env file. Please update it with your private key."
  echo "PRIVATE_KEY=YOUR_PRIVATE_KEY_HERE" > .env
  echo ".env file created. Please edit it to add your private key and run this script again."
  exit 1
fi

# Check if either script has been run successfully before
if [ ! -f .whitelist_success ]; then
  echo "First time running whitelist scripts. Checking environment..."
  
  # Make sure we have the right packages
  echo "Setting up dependencies..."
  which npm >/dev/null 2>&1 && npm install ethers@5.7.2 dotenv >/dev/null 2>&1
  which pnpm >/dev/null 2>&1 && pnpm install ethers@5.7.2 dotenv >/dev/null 2>&1
  which yarn >/dev/null 2>&1 && yarn add ethers@5.7.2 dotenv >/dev/null 2>&1
fi

# Run the whitelist scripts
echo "1. Whitelisting solvers..."
node whitelist_solver.js

if [ $? -eq 0 ]; then
  echo "Solver whitelisting completed successfully."
  
  echo "2. Whitelisting hooks..."
  node whitelist_hooks.js
  
  if [ $? -eq 0 ]; then
    echo "Hook whitelisting completed successfully."
    touch .whitelist_success
    echo "Whitelist process completed successfully!"
  else
    echo "Error during hook whitelisting. Check logs above."
  fi
else
  echo "Error during solver whitelisting. Check logs above."
fi 