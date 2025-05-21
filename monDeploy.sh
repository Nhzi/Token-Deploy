#!/bin/bash

# Display a logo
curl -s https://raw.githubusercontent.com/zunxbt/logo/main/logo.sh | bash
sleep 5

# Styling
BOLD=$(tput bold)
NORMAL=$(tput sgr0)
PINK='\033[1;35m'

show() {
    case $2 in
        "error")
            echo -e "${PINK}${BOLD}❌ $1${NORMAL}"
            ;;
        "progress")
            echo -e "${PINK}${BOLD}⏳ $1${NORMAL}"
            ;;
        *)
            echo -e "${PINK}${BOLD}✅ $1${NORMAL}"
            ;;
    esac
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR" || exit

# Validate user inputs
read -p "Enter your Private Key: " PRIVATE_KEY
if [[ ! $PRIVATE_KEY =~ ^0x[0-9a-fA-F]{64}$ ]]; then
    show "Invalid private key format. Must be 64 hex characters starting with 0x." "error"
    exit 1
fi

read -p "Enter the token name (e.g., Zun Token): " TOKEN_NAME
if [[ -z "$TOKEN_NAME" ]]; then
    show "Token name cannot be empty." "error"
    exit 1
fi

read -p "Enter the token symbol (e.g., ZUN): " TOKEN_SYMBOL
if [[ -z "$TOKEN_SYMBOL" ]]; then
    show "Token symbol cannot be empty." "error"
    exit 1
fi

read -p "Enter the receiver address (e.g., 0x123...): " RECEIVER_ADDRESS
if [[ ! $RECEIVER_ADDRESS =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    show "Invalid receiver address. Must be a valid Ethereum address starting with 0x." "error"
    exit 1
fi

read -p "Enter the number of transactions to send: " TX_COUNT
if ! [[ "$TX_COUNT" =~ ^[0-9]+$ ]] || [ "$TX_COUNT" -lt 1 ]; then
    show "Transaction count must be a positive integer." "error"
    exit 1
fi

# Store in .env
mkdir -p "$SCRIPT_DIR/token_deployment"
cat <<EOL > "$SCRIPT_DIR/token_deployment/.env"
PRIVATE_KEY="$PRIVATE_KEY"
TOKEN_NAME="$TOKEN_NAME"
TOKEN_SYMBOL="$TOKEN_SYMBOL"
RECEIVER_ADDRESS="$RECEIVER_ADDRESS"
TX_COUNT="$TX_COUNT"
EOL

source "$SCRIPT_DIR/token_deployment/.env"

CONTRACT_NAME="ZunXBT"
RPC_URL="https://testnet-rpc.monad.xyz/"

# Check network connectivity
show "Checking Monad Testnet RPC connectivity..." "progress"
if ! cast block-number --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    show "Failed to connect to Monad Testnet RPC. Please check the RPC URL or network status." "error"
    exit 1
fi
show "RPC connectivity confirmed."

# Check if Git is initialized
if [ ! -d ".git" ]; then
    show "Initializing Git repository..." "progress"
    git init
fi

# Ensure Foundry is installed and up-to-date
if ! command -v forge &> /dev/null || ! command -v cast &> /dev/null; then
    show "Foundry is not installed or outdated. Installing/Updating now..." "progress"
    curl -L https://foundry.paradigm.xyz | bash
    foundryup
    if ! command -v cast &> /dev/null; then
        show "Failed to install Foundry with cast command." "error"
        exit 1
    fi
fi

# Check Foundry version
FOUNDRY_VERSION=$(cast --version 2>/dev/null)
if [[ $? -ne 0 ]]; then
    show "Failed to verify Foundry version." "error"
    exit 1
fi
show "Foundry version: $FOUNDRY_VERSION"

# Install OpenZeppelin contracts
if [ ! -d "$SCRIPT_DIR/lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin Contracts..." "progress"
    mkdir -p "$SCRIPT_DIR/lib"
    git clone https://github.com/OpenZeppelin/openzeppelin-contracts.git "$SCRIPT_DIR/lib/openzeppelin-contracts"
else
    show "OpenZeppelin Contracts already installed."
fi

# Configure foundry.toml
if [ ! -f "$SCRIPT_DIR/foundry.toml" ]; then
    show "Creating foundry.toml and adding Monad Testnet RPC..." "progress"
    cat <<EOL > "$SCRIPT_DIR/foundry.toml"
[profile.default]
src = "src"
out = "out"
libs = ["lib"]

[rpc_endpoints]
monad = "$RPC_URL"
EOL
else
    show "foundry.toml already exists."
fi

# Create ERC-20 contract
show "Creating ERC-20 token contract using OpenZeppelin..." "progress"
mkdir -p "$SCRIPT_DIR/src"
cat <<EOL > "$SCRIPT_DIR/src/$CONTRACT_NAME.sol"
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract $CONTRACT_NAME is ERC20 {
    constructor() ERC20("$TOKEN_NAME", "$TOKEN_SYMBOL") {
        _mint(msg.sender, 100000 * (10 ** decimals()));
    }
}
EOL

# Compile contract
show "Compiling the contract..." "progress"
forge build
if [[ $? -ne 0 ]]; then
    show "Contract compilation failed." "error"
    exit 1
fi

# Check account balance
show "Checking account balance..." "progress"
SENDER_ADDRESS=$(cast wallet address --private-key "$PRIVATE_KEY" 2>/dev/null)
if [[ $? -ne 0 ]]; then
    show "Invalid private key." "error"
    exit 1
fi
BALANCE=$(cast balance --rpc-url "$RPC_URL" "$SENDER_ADDRESS" 2>/dev/null)
if [[ $? -ne 0 || "$BALANCE" -eq 0 ]]; then
    show "Insufficient funds or invalid private key." "error"
    exit 1
fi
show "Account balance: $BALANCE wei"

# Deploy contract
show "Deploying the contract to Monad Testnet..." "progress"
DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/$CONTRACT_NAME.sol:$CONTRACT_NAME" \
    --rpc-url "$RPC_URL" \
    --private-key "$PRIVATE_KEY" \
    --gas-limit 3000000 \
    --broadcast 2>&1)

if [[ $? -ne 0 || "$DEPLOY_OUTPUT" =~ "Dry run enabled" ]]; then
    show "Deployment failed or dry run detected: $DEPLOY_OUTPUT" "error"
    exit 1
fi

# Extract contract address
CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oE 'Deployed to: (0x[a-fA-F0-9]{40})' | cut -d' ' -f3)
if [[ -z "$CONTRACT_ADDRESS" ]]; then
    show "Failed to extract contract address. Deployment output: $DEPLOY_OUTPUT" "error"
    exit 1
fi
show "Token deployed successfully at address: https://testnet.monadscan.io/address/$CONTRACT_ADDRESS"

# Send multiple transactions
i=1
while [ "$i" -le "$TX_COUNT" ]; do
    show "Sending transaction #$i..." "progress"
    NONCE=$(cast nonce --rpc-url "$RPC_URL" "$SENDER_ADDRESS" 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        show "Failed to fetch nonce for transaction #$i." "error"
        ((i++))
        continue
    fi
    TX_OUTPUT=$(cast send "$CONTRACT_ADDRESS" "transfer(address,uint256)" "$RECEIVER_ADDRESS" "1000000000000000000" \
        --rpc-url "$RPC_URL" \
        --private-key "$PRIVATE_KEY" \
        --gas-limit 200000 \
        --nonce "$NONCE" 2>&1)
    if [[ $? -ne 0 ]]; then
        show "Transaction #$i failed: $TX_OUTPUT" "error"
    else
        show "Transaction #$i sent successfully."
    fi
    sleep 3 # Delay to prevent nonce issues
    ((i++))
done

show "All transactions completed."
