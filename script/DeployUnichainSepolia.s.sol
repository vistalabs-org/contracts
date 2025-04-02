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
        manager = PoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
        console.log("PoolManager at", address(manager));

        // Deploy test routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        console.log("Deployed PoolModifyLiquidityTest at", address(modifyLiquidityRouter));
        poolSwapTest = new PoolSwapTest(manager);
        console.log("Deployed PoolSwapTest at", address(poolSwapTest));

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));

        // Deploy hook with proper flags
        vm.stopBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
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
        vm.stopBroadcast();

    }
}