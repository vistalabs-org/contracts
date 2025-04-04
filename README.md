# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                   | Address                                      |
|----------------------------|----------------------------------------------|
| PoolManager                | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest               | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Collateral Token (tUSDC)   | `0x125C45450a65a6FE4748F782F9B6ab9f5Fbcf049` |
| AIAgentRegistry            | `0xFaa36947DE7AEd3026227AEa7D131A230EC0E64B` |
| AIOracleServiceManager Impl| `0xe27457B3949b5cf0eE13bce2375E9beE74A0C44c` |
| AIOracleServiceManager Proxy| `0x5A802dea13147CD9A39a18543D9ef83B6A10d1a5` |
| ProxyAdmin                 | `0xC312320126Be5ba73dcBfAc414999951d70E4729` |
| AIAgent                    | `0x8069eB807ABEF565c962D1B627A8f72D0fe1EF09` |
| PoolCreationHelper         | `0x97937cEe5c6C30756e80db66Dd9bf3d911f78149` |
| PredictionMarketHook       | `0xdb02d9340BfC85196FaAe9f05Bf0F3963dd38880` |

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