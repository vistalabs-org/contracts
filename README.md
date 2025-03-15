## Foundry

**Foundry is a blazing fast, portable and modular toolkit for Ethereum application development written in Rust.**

Foundry consists of:

-   **Forge**: Ethereum testing framework (like Truffle, Hardhat and DappTools).
-   **Cast**: Swiss army knife for interacting with EVM smart contracts, sending transactions and getting chain data.
-   **Anvil**: Local Ethereum node, akin to Ganache, Hardhat Network.
-   **Chisel**: Fast, utilitarian, and verbose solidity REPL.

## Documentation

https://book.getfoundry.sh/

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```

### Gas Snapshots

```shell
$ forge snapshot
```

### Anvil

```shell
$ anvil
```

### Deploy

```shell
$ forge script script/Counter.s.sol:CounterScript --rpc-url <your_rpc_url> --private-key <your_private_key>
```

### Cast

```shell
$ cast <subcommand>
```

### Help

```shell
$ forge --help
$ anvil --help
$ cast --help
```

# Uniswap v4 Prediction Market

A decentralized prediction market built on Uniswap v4 hooks, allowing users to speculate on binary outcomes using liquidity pools.

## Deployed Contracts (Uniswap Sepolia)

| Contract | Address |
|----------|---------|
| PoolManager | 0x461248D11dad5a36f252A29cE42A6513eAA1dB3e |
| PoolCreationHelper | 0xB1C6fafA7aC5F473C7ceBAfeC9e43EB19FB76891 |
| PredictionMarketHook | 0x3554155e933b167BE0b4eB71CF1008AEbd85ca80 |
| Test USDC | 0x56C99509D99c6ebd90Ba46A277f93611775Bd001 |

## How the Prediction Market Works

### Overview

This prediction market allows users to speculate on binary outcomes (YES/NO) of future events. The market uses Uniswap v4 hooks to create specialized liquidity pools for each outcome token, enabling price discovery through trading activity.

### Key Components

1. **PredictionMarketHook**: The core contract that manages markets, handles token minting/burning, and enforces trading rules.
2. **OutcomeTokens**: ERC20 tokens representing YES and NO positions for each market.
3. **Uniswap v4 Pools**: Liquidity pools that enable trading between collateral (e.g., USDC) and outcome tokens.

### Market Lifecycle

#### 1. Market Creation
- An oracle (trusted entity) creates a market with a specific question and expiration date
- The creator deposits collateral (e.g., USDC)
- The hook mints equal amounts of YES and NO tokens backed by the collateral
- Two Uniswap v4 pools are created: collateral/YES and collateral/NO

#### 2. Trading Phase
- Users can buy YES tokens if they believe the outcome will be true
- Users can buy NO tokens if they believe the outcome will be false
- Prices of YES and NO tokens fluctuate based on market sentiment
- The price of YES tokens represents the market's estimated probability of the event occurring

#### 3. Market Resolution
- After the event occurs, the oracle resolves the market as either YES or NO
- Holders of the winning outcome token can claim collateral at a 1:1 ratio
- Holders of the losing outcome token receive nothing

### Trading Mechanics

- **Buying YES/NO Tokens**: Users swap collateral for outcome tokens through the Uniswap pools
- **Selling YES/NO Tokens**: Users swap outcome tokens back to collateral
- **Price Range**: Prices are constrained between 0.01 and 0.99 collateral units to prevent extreme pricing
- **Initial Liquidity**: Market creators typically provide initial liquidity to enable trading

### Claiming Winnings

After market resolution:
1. Holders of the winning outcome token approve the hook to burn their tokens
2. They call the `claimWinnings` function
3. The hook burns their tokens and transfers the equivalent amount of collateral

## Development

### Prerequisites

- Foundry
- Node.js
- Uniswap v4 dependencies

### Deployment

To deploy the contracts to Uniswap Sepolia:

```bash
forge script script/DeployUnichainSepolia.s.sol:DeployPredictionMarket --rpc-url $UNISWAP_SEPOLIA_RPC_URL --broadcast --verify
```

Make sure to set the following environment variables:
- `UNISWAP_SEPOLIA_RPC_URL`: Your Uniswap Sepolia RPC endpoint
- `UNISWAP_SEPOLIA_PK`: Your private key for the Uniswap Sepolia testnet
- `ETHERSCAN_API_KEY`: For contract verification
