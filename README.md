# Uniswap v4 Prediction Market

A decentralized prediction market built on Uniswap v4 hooks, allowing users to speculate on binary outcomes using liquidity pools.

## Deployed Contracts (Uniswap Sepolia)

| Contract | Address |
|----------|---------|
| PoolManager | 0x461248D11dad5a36f252A29cE42A6513eAA1dB3e |
| PoolCreationHelper | 0xB1C6fafA7aC5F473C7ceBAfeC9e43EB19FB76891 |
| PredictionMarketHook | 0x3554155e933b167BE0b4eB71CF1008AEbd85ca80 |
| Test USDC | 0x56C99509D99c6ebd90Ba46A277f93611775Bd001 |

### Deployed Markets

| Market Description | Market ID |
|-------------------|-----------|
| Test market: "Market resolves to YES if ETH is above 1000" | 0xb485068b7d9e535fcc34930284e564af6c63a9bb08ef352c2aca4a7bae2175f5 |

## Created Markets

| Market ID | Description |
|-----------|-------------|
| `0xd7ca1d2e31a6879cef41594eeb5a2644738329559765fe9ddae573d00bdf4ac6` | First test market |

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

### Frontend Integration

The contract provides several functions to retrieve market data:

- `getAllMarketIds()`: Returns an array of all market IDs
- `getAllMarkets()`: Returns an array of all markets with their full details
- `getMarkets(offset, limit)`: Returns a paginated subset of markets
- `getMarketCount()`: Returns the total number of markets

Example frontend code to fetch all markets:

```javascript
// Using ethers.js
const predictionMarketContract = new ethers.Contract(
  PREDICTION_MARKET_ADDRESS,
  PREDICTION_MARKET_ABI,
  provider
);

// Get all markets
const markets = await predictionMarketContract.getAllMarkets();

// Display markets
markets.forEach(market => {
  console.log(`Market ID: ${market.id}`);
  console.log(`Title: ${market.title}`);
  console.log(`Description: ${market.description}`);
  console.log(`State: ${['Active', 'Resolved', 'Cancelled'][market.state]}`);
  console.log(`Outcome: ${market.outcome ? 'YES' : 'NO'}`);
  console.log(`Total Collateral: ${ethers.utils.formatUnits(market.totalCollateral, 6)}`);
  console.log('---');
});
```

For applications with many markets, use pagination:

```javascript
// Get markets with pagination
const offset = 0;
const limit = 10;
const marketBatch = await predictionMarketContract.getMarkets(offset, limit);
```

## Interacting with Markets

To interact with an existing market, you'll need:

1. The Market ID (shown in the table above)
2. The PredictionMarketHook contract address
3. Some USDC tokens (you can get test tokens from the contract owner)

Example commands using cast (Foundry's CLI tool):

```bash
# Get market details
cast call 0x351af7D9f5F2BeC762bEb4a5627FF29749458A80 "getMarketById(bytes32)(tuple)" 0xd7ca1d2e31a6879cef41594eeb5a2644738329559765fe9ddae573d00bdf4ac6

# Approve USDC for the hook contract
cast send 0x2ddB197a62723880D182B64cd4f48425A881Ce23 "approve(address,uint256)" 0x351af7D9f5F2BeC762bEb4a5627FF29749458A80 1000000000 --private-key YOUR_PRIVATE_KEY

# Deposit collateral and get outcome tokens
# (Implementation depends on your contract's specific functions)
```

# Known errors

eigenlayer library 
```bash
find lib/eigenlayer-middleware -name "*.sol" -exec sed -i 's/pragma solidity \^0.8.27/pragma solidity ^0.8.26/g' {} \;
```

import adjustments
```solidity
import "lib/solmate/src/utils/FixedPointMathLib.sol";
```