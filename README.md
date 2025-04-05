# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                   | Address                                      |
|----------------------------|----------------------------------------------|
| PoolManager                | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest               | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Collateral Token (tUSDC)   | `0x820429aFC00F4E5770e4745f338320E7B626b5bc` |
| AIAgentRegistry            | `0x59821c2d121bF882580d6E08B3a257dE8e50782B` |
| AIOracleServiceManager Impl| `0xdfd712572a8B7e1FB3db04B196a315a5098d5d06` |
| AIOracleServiceManager Proxy| `0x5D30682c769d3F302e62b3E7F978752b7FD3b177` |
| AIAgent                    | `0xc0dF7c888B8888A2d78da6c15e53828e65B3B7f4` |
| PoolCreationHelper         | `0xd016a9f6708eF9feeD51fCD542C1d5EAf73e3eEF` |
| PredictionMarketHook       | `0x51abe2CeedC53bCeDf9F1F257f30317A15124880` |

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