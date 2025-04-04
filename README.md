# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                   | Address                                      |
|----------------------------|----------------------------------------------|
| PoolManager                | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest               | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| AIAgentRegistry            | `0x82013345325952E66a896623c3D3ddDEd202977D` |
| AIOracleServiceManager Impl| `0x6fa8Db81A8afAb6aE3D206E5Dbe18739F72F69D6` |
| AIOracleServiceManager Proxy| `0x36ef836663395c4E84B250274B1dc927F6102962` |
| ProxyAdmin                 | `0xC312320126Be5ba73dcBfAc414999951d70E4729` |
| AIAgent                    | `0x27a3fE3Eb6c77a836dedb958f155C088b548adB4` |
| PoolCreationHelper         | `0xc61304C85223C5d5b0e288962E48CA3380144Da0` |
| PredictionMarketHook       | `0x74D7669e23e5035D8Bea3bDe2ea21C131E984880` |

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