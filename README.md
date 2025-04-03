# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                   | Address                                      |
|----------------------------|----------------------------------------------|
| PoolManager                | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| AIAgentRegistry            | `0xb16882f567Aece69E692a82831f754eAdb10A532` |
| AIOracleServiceManager Impl| `0x01e5116e8fDB9f0179dc13c6b0Fc863e80A74ADB` |
| AIOracleServiceManager Proxy| `0x1a1c316af719C72c9835BE2Ff28dD95192Eb59EE` |
| ProxyAdmin                 | `0xC312320126Be5ba73dcBfAc414999951d70E4729` |
| AIAgent                    | `0x5bef72DA2E0CCdEd003D3dA1FfD7F73b872231f5` |
| PoolCreationHelper         | `0x10010FDC0449C83849499A6c6d79F86CCA35589D` |
| PredictionMarketHook       | `0xC19971AcBD52C7EaCd0248767E1D0014837CC880` |

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
forge script script/DeployTestMarketsAndAddLiquidity.s.sol:DeployLiquidity --rpc-url sepolia --broadcast -vvvv
```

## Frontend

The frontend is built with Next.js and can be found in the `frontend` directory.

```bash
cd frontend
npm install
npm run dev
```

Visit `http://localhost:3000` to access the application.