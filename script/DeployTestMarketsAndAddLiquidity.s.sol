// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Create2} from "lib/openzeppelin-contracts/contracts/utils/Create2.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

// Create a deployer contract that uses the Create2 library

contract SwapTest is Script {
    PredictionMarketHook public hook;
    PoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public poolSwapTest;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC


    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        vm.startBroadcast(deployerPrivateKey);
        // using already deployed hook and manager
        hook = PredictionMarketHook(0xABF6985E92fC0d4A8F7b8ceC535aD0215DbD0a80);
        // from uni v4 docs
        manager = PoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        modifyLiquidityRouter = PoolModifyLiquidityTest(0x5fa728C0A5cfd51BEe4B060773f50554c0C8A7AB);
        
        // create markets
        createMarkets();

        // Get all market IDs instead of markets
        bytes32[] memory marketIds = hook.getAllMarketIds();

        // for every market, add liquidity
        for (uint256 i = 0; i < marketIds.length; i++) {
            addLiquidityToMarket(marketIds[i]);
        }

        vm.stopBroadcast();
        console.log("Deployment complete!");
    }

    function addLiquidityToMarket(bytes32 marketId) public {
        // Get market details
        Market memory market = hook.getMarketById(marketId);

        // Get token references
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));

        //collateralToken.mint(address(this), 100e6 * 1e6);

        // Transfer tokens instead of minting
        // Request tokens from the hook contract which should have minting rights
        //hook.mintOutcomeTokens(marketId, address(this), 100e2 * 1e18);


        // Set up price range for prediction market (0.01-0.99)
        int24 tickSpacing = 100;
        int24 minTick = -9200; // ~0.01 USDC
        int24 maxTick = -100; // ~0.99 USDC
        int24 initialTick = -6900; // ~0.5 USDC

        // Ensure ticks are valid with the tick spacing
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        // Get the sqrtPriceX96 for the initial tick (0.5 USDC)
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Prepare liquidity amounts
        uint256 liquidityCollateral = 50 * 1e6; // 50 USDC
        uint256 liquidityOutcomeTokens = 100 * 1e18; // 100 outcome tokens

        // Approve tokens for liquidity provision
        //console.log("Approving collateral token");
        //collateralToken.approve(address(modifyLiquidityRouter), liquidityCollateral);
        console.log("Approving yes token");
        yesToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        console.log("Approving no token");
        noToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        console.log("Approving collateral token");
        collateralToken.approve(address(modifyLiquidityRouter), type(uint256).max);

        // Calculate liquidity amount
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );

        console.log("Liquidity amount", liquidityAmount);

        // Add liquidity to YES pool
        modifyLiquidityRouter.modifyLiquidity(
            market.yesPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        // Add liquidity to NO pool
        modifyLiquidityRouter.modifyLiquidity(
            market.noPoolKey,
            IPoolManager.ModifyLiquidityParams({
                tickLower: minTick,
                tickUpper: maxTick,
                liquidityDelta: int256(uint256(liquidityAmount)),
                salt: 0
            }),
            new bytes(0)
        );

        
    }

    function createMarkets() public {



        // Deploy mock collateral token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        console.log("Collateral token deployed at", address(collateralToken));

        // Mint tokens to deployer
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");

        address deployer = vm.addr(deployerPrivateKey);
        collateralToken.mint(deployer, 1e6 * 10 ** 6);
        console.log("Minted 1,000,000 USDC to deployer");

        // Approve hook to spend tokens
        collateralToken.approve(address(hook), type(uint256).max);

        // Create a market
        console.log("Creating market params");
        CreateMarketParams memory params = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will the U.S. Department of Education be dismantled by December 31, 2025?",
            description: "This market resolves to YES if the U.S. Department of Education will be dismantled by December 31, 2025.",
            duration: 30 days,
            curveId: 0
        });

        console.log("calling createMarketAndDepositCollateral");
        bytes32 marketId = hook.createMarketAndDepositCollateral(params);

        console.log("Market created with ID:", vm.toString(marketId));

        // Create a market
        CreateMarketParams memory params2 = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will the U.S. acquire greenland by December 31, 2025?",
            description: "Market resolves to YES if the U.S. acquires Greenland by December 31, 2025.",
            duration: 30 days,
            curveId: 0
        });

        bytes32 marketId2 = hook.createMarketAndDepositCollateral(params2);

        console.log("Market created with ID:", vm.toString(marketId2));

    }

}
