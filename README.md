# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                     | Address                                      |
|------------------------------|----------------------------------------------|
| PoolManager                  | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest                 | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Collateral Token (tUSDC)     | `0xa8BEfd0d870df3Cc2C656975de858aae87216B4a` |
| AIAgentRegistry              | `0x744E674901428fc0169C69c5717001e6DA9DA85E` |
| AIOracleServiceManager Impl  | `0x0e8eD93C7e134722d34bC4344B9DCECd144f0197` |
| AIOracleServiceManager Proxy | `0x7fA0A75d79b25E290e0427F5305fE25d578D8c56` |
| AIAgent                      | `0x518295ddBF4A0c7953677BbF3d40c2Bf4FAbC62e` |
| PoolCreationHelper           | `0xDeb20d4a6cF1B3557A9cf1cF63ACc957Cc00010d` |
| PredictionMarketHook         | `0xEc3aA97150992e6a540b707E6C45dd9945AeC880` |

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