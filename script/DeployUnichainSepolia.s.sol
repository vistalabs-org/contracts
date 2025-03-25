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

contract DeployPredictionMarket is Script {
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

        // Deploy Uniswap infrastructure
        manager = new PoolManager(address(this));
        console.log("Deployed PoolManager at", address(manager));

        // Deploy test routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        poolSwapTest = new PoolSwapTest(manager);

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));

        // Deploy hook with proper flags
        vm.stopBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        ) ^ (0x4444 << 144); // Namespace the hook to avoid collisions

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PredictionMarketHook).creationCode,
            abi.encode(manager, modifyLiquidityRouter, poolCreationHelper)
        );

        console.log("Deploying PredictionMarketHook at", hookAddress);

        vm.startBroadcast(deployerPrivateKey);
        hook = new PredictionMarketHook{salt: salt}(manager, modifyLiquidityRouter, poolCreationHelper);
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("Hook deployed at", address(hook));

        // Deploy mock collateral token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        console.log("Collateral token deployed at", address(collateralToken));

        // Mint tokens to deployer
        address deployer = vm.addr(deployerPrivateKey);
        collateralToken.mint(deployer, 1000000 * 10 ** 6);
        console.log("Minted 1,000,000 USDC to deployer");

        // Approve hook to spend tokens
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);

        // Create a market
        CreateMarketParams memory params = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Test market",
            description: "Market resolves to YES if ETH is above 1000",
            duration: 30 days,
            curveId: 0
        });

        bytes32 marketId = hook.createMarketAndDepositCollateral(params);
        console.log("Market created with ID:", vm.toString(marketId));

        vm.stopBroadcast();
        console.log("Deployment complete!");
    }
}
