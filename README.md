# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract | Address |
|----------|---------|
| PoolManager | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolModifyLiquidityTest | `0x64D6ee06A8Ece25F5588ffbB066B5C64c878AedE` |
| PoolSwapTest | `0xf7E9C016a23b05700FDF36caB39F64065F20Cdfd` |
| PoolCreationHelper | `0xC07BEE42ea57Afd89ca5eF7307bd6a630391d3A0` |
| PredictionMarketHook | `0x312D3B8A8aa25186F53ECb939Bdce6F5B403c880` |

## Overview

Vista Market is a prediction market platform built on Uniswap v4. It allows users to create and trade on markets for future events, with prices representing the probability of those events occurring.

## Features

- Create prediction markets for any future event
- Trade YES/NO outcome tokens
- Automated market making via Uniswap v4
- Oracle-based resolution system
- Initial price set at 0.5 USDC per outcome token

## Development

### Prerequisites

- [Foundry](https://book.getfoundry.sh/getting-started/installation)
- [Node.js](https://nodejs.org/en/download/)

### Setup

```bash
# Clone the repository
git clone https://github.com/your-username/vista-market.git
cd vista-market

# Install dependencies
forge install
npm install

# Compile contracts
forge build

# Run tests
forge test
```

### Deployment

```bash
# Deploy to Sepolia
forge script script/DeployUnichainSepolia.s.sol:DeployPredictionMarket --rpc-url sepolia --broadcast -vvvv

# Create test markets and add liquidity
forge script script/DeployTestMarketsAndAddLiquidity.s.sol:SwapTest --rpc-url sepolia --broadcast -vvvv
```

## Frontend

The frontend is built with Next.js and can be found in the `frontend` directory.

```bash
cd frontend
npm install
npm run dev
```

Visit `http://localhost:3000` to access the application.

# Known errors

## EigenLayer Library Version Fix
The EigenLayer middleware library uses a Solidity version that might not be available. Fix with:
```bash
find lib/eigenlayer-middleware -name "*.sol" -exec sed -i 's/pragma solidity \^0.8.27/pragma solidity ^0.8.26/g' {} \;
```
