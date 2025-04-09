# Vista Market - Prediction Markets on Uniswap v4

## Deployed Contracts (Mainnet)

| Contract                     | Address                                      |
|------------------------------|----------------------------------------------|
| Collateral Token             | `0xA5a2250b0170bdb9bd0904C0440717f00A506023` |
| PoolManager                  | `0x1F98400000000000000000000000000000000004` |
| PoolSwapTest                 | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| AIAgentRegistry              | `0xB5fF28b7E3eB8D70f456D5afcaeBc40210d25284` |
| AIOracleServiceManager Impl  | `0x871F75C1cE8776768E92A81604eDec5716137c81` |
| AIOracleServiceManager Proxy | `0xf2F14993D8744d3b7bf2ea0ECe03665e9a7f9298` |
| AIAgent                      | `0xe87B112662F877B2C947B309233D025F7EAD3c4D` |
| PoolCreationHelper           | `0x43B7819F4A66532Ad028B34D1Fe28eCC1dEAD820` |
| PredictionMarketHook         | `0xcB9903081b324B3a743E536D451705f9e1450880` |

## Deployed Contracts (Sepolia)

| Contract                     | Address                                      |
|------------------------------|----------------------------------------------|
| PoolManager                  | `0x00B036B58a818B1BC34d502D3fE730Db729e62AC` |
| PoolSwapTest                 | `0x9140a78c1A137c7fF1c151EC8231272aF78a99A4` |
| Collateral Token (tUSDC)     | `0xd17aA6A05F3C32009801C8cf79716650A2793907` |
| AIAgentRegistry              | `0xe8622FA7282f8824c1CE37B27c2f844828b5D60e` |
| AIOracleServiceManager Impl  | `0xa3b35B35bd6F320044C49dA48340BB3ED0241e49` |
| AIOracleServiceManager Proxy | `0x392080073a7De157b9A3EA2de1E2a00016273cBA` |
| AIAgent                      | `0x02B78E1c7e61afa62613f3c9d8De2C81ab551637` |
| PoolCreationHelper           | `0x80a72ADA9d27Ea178833D3dDCA34989B8A55435b` |
| PredictionMarketHook         | `0x70FC0B47F1773F072dECd26497531D6511a98880` |

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