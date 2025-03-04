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

# User inputs
read -p "Enter your Private Key: " PRIVATE_KEY
read -p "Enter the token name (e.g., Zun Token): " TOKEN_NAME
read -p "Enter the token symbol (e.g., ZUN): " TOKEN_SYMBOL
read -p "Enter the number of transactions to send: " TX_COUNT

# Store in .env
mkdir -p "$SCRIPT_DIR/token_deployment"
cat <<EOL > "$SCRIPT_DIR/token_deployment/.env"
PRIVATE_KEY="$PRIVATE_KEY"
TOKEN_NAME="$TOKEN_NAME"
TOKEN_SYMBOL="$TOKEN_SYMBOL"
TX_COUNT="$TX_COUNT"
EOL

source "$SCRIPT_DIR/token_deployment/.env"

CONTRACT_NAME="ZunXBT"

# Check if Git is initialized
if [ ! -d ".git" ]; then
    show "Initializing Git repository..." "progress"
    git init
fi

# Ensure Foundry is installed
if ! command -v forge &> /dev/null; then
    show "Foundry is not installed. Installing now..." "progress"
    curl -L https://foundry.paradigm.xyz | bash
    foundryup
fi

# Install OpenZeppelin contracts
if [ ! -d "$SCRIPT_DIR/lib/openzeppelin-contracts" ]; then
    show "Installing OpenZeppelin Contracts..." "progress"
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
monad = "https://testnet-rpc.monad.xyz/"
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

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

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

# Deploy contract
show "Deploying the contract to Monad Testnet..." "progress"
DEPLOY_OUTPUT=$(forge create "$SCRIPT_DIR/src/$CONTRACT_NAME.sol:$CONTRACT_NAME" \
    --rpc-url https://testnet-rpc.monad.xyz/ \
    --private-key "$PRIVATE_KEY")

if [[ $? -ne 0 ]]; then
    show "Deployment failed." "error"
    exit 1
fi

# Extract contract address
CONTRACT_ADDRESS=$(echo "$DEPLOY_OUTPUT" | grep -oP 'Deployed to: \K(0x[a-fA-F0-9]{40})')
show "Token deployed successfully at address: https://testnet.monadscan.io/address/$CONTRACT_ADDRESS"

# Send multiple transactions
i=1
while [ "$i" -le "$TX_COUNT" ]; do
    show "Sending transaction #$i..." "progress"
    forge send "$CONTRACT_ADDRESS" "transfer(address,uint256)" "0xReceiverAddress" "1000000000000000000" \
        --rpc-url https://testnet-rpc.monad.xyz/ \
        --private-key "$PRIVATE_KEY"
    if [[ $? -ne 0 ]]; then
        show "Transaction #$i failed." "error"
    else
        show "Transaction #$i sent successfully."
    fi
    ((i++))
done

show "All transactions completed."
