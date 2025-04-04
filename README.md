# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Sepolia)

| Contract                   | Address                                      |
|----------------------------|----------------------------------------------|
| PoolManager                | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest               | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Collateral Token (tUSDC)   | `0x85a0086903EDf0a2eA3A1De6441f1bc98a0ddb2e` |
| AIAgentRegistry            | `0xB70C86f1Ee2Ff1Fd3C2a7c001a431C202E1C2ED7` |
| AIOracleServiceManager Impl| `0xd033DA368b741FFcd65D678EACdBec0ba90e7250` |
| AIOracleServiceManager Proxy| `0xe0f96383C4266B55457B70Fe4A00236288b9dA2b` |
| ProxyAdmin                 | `0xC312320126Be5ba73dcBfAc414999951d70E4729` |
| AIAgent                    | `0xE0632905E4C0B4181ee01AeB26AFe253B96d410f` |
| PoolCreationHelper         | `0x83aBB30aCEf747AAE863278008DebFB8dBab0D8A` |
| PredictionMarketHook       | `0xB774A6C1D493F57fEe18FdAf60F164aB5A2b4880` |

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