// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Local Project Imports
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol"; // For context and potential balance checks

// Uniswap Imports
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol"; // For sqrtPriceLimit
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol"; // For swap result
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol"; // For pool key comparison

/**
 * @title TestMarketSwap
 * @notice Loads core contracts and market data, then executes a test swap
 *         (Collateral -> YES Token) in the first available test market pool.
 * @dev Assumes addresses.json and test_markets.json exist and are populated.
 *      Requires the target market to have liquidity added (e.g., by AddLiquidity.s.sol).
 */
contract TestMarketSwap is Script {
    using stdJson for string;
    using CurrencyLibrary for Currency; // Needed for currency comparison

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    PoolManager public manager;
    PoolSwapTest public swapRouter; // Uniswap V4 test swap router

    // --- Loaded Test Config ---
    ERC20Mock public collateralToken;
    bytes32[] private marketIds;
    address private hookAddress; // Loaded from addresses.json
    address private managerAddress; // Loaded from addresses.json
    address private swapRouterAddress; // Loaded from addresses.json
    address private collateralTokenAddress; // Loaded from addresses.json

    // --- Script State ---
    address private deployer;

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Script runner (Deployer):", deployer);

        // Load addresses.
        _loadCoreAddresses();
        _loadMarketData();

        // Instantiate contracts.
        _initializeContracts();

        // Select the first market for the swap test.
        require(marketIds.length > 0, "No market IDs loaded to test swap");
        bytes32 targetMarketId = marketIds[0];
        console.log("\n--- Testing Swap on Market ID:", vm.toString(targetMarketId), "---");

        // Get market details.
        Market memory market = hook.getMarketById(targetMarketId);
        require(market.state == MarketState.Active, "Target market is not Active");

        // Example: Swap Collateral for YES tokens in the YES pool
        PoolKey memory targetPoolKey = market.yesPoolKey;
        // Verify pool key details match expectations (collateral is token0, outcome is token1)
        require(
            Currency.unwrap(targetPoolKey.currency0) == address(collateralToken), "Pool currency0 is not collateral"
        );
        require(Currency.unwrap(targetPoolKey.currency1) == address(market.yesToken), "Pool currency1 is not YES token");
        console.log("Targeting YES Pool (Collateral/YES):");
        console.log("  Currency0:", Currency.unwrap(targetPoolKey.currency0));
        console.log("  Currency1:", Currency.unwrap(targetPoolKey.currency1));
        console.log("  Fee:", targetPoolKey.fee);
        console.log("  Tick Spacing:", targetPoolKey.tickSpacing);
        console.log("  Hook:", address(targetPoolKey.hooks));

        // Start broadcasting transactions.
        vm.startBroadcast(deployerPrivateKey);

        // Prepare for swap (ensure collateral and approve router).
        _prepareForSwap();

        // Execute the swap.
        _executeSwap(targetPoolKey);

        // Stop broadcasting.
        vm.stopBroadcast();
        console.log("\nScript complete! Swap attempted.");
    }

    /// @notice Loads core contract addresses and collateral token address from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory addressesFile = "script/config/addresses.json";
        string memory json = vm.readFile(addressesFile);

        hookAddress = json.readAddress(".predictionMarketHook");
        managerAddress = json.readAddress(".poolManager");
        swapRouterAddress = json.readAddress(".poolSwapTest"); // Load swap router address
        collateralTokenAddress = json.readAddress(".collateralToken"); // Load collateral token

        require(hookAddress != address(0), "Failed to read hook address");
        require(managerAddress != address(0), "Failed to read manager address");
        require(swapRouterAddress != address(0), "Failed to read poolSwapTest address");
        require(collateralTokenAddress != address(0), "Failed to read collateral token address from addresses.json");

        console.log("  Loaded Hook Address:", hookAddress);
        console.log("  Loaded PoolManager Address:", managerAddress);
        console.log("  Loaded PoolSwapTest Address:", swapRouterAddress);
        console.log("  Loaded Collateral Token Address:", collateralTokenAddress);
    }

    /// @notice Loads test market IDs from test_markets.json.
    function _loadMarketData() internal {
        console.log("\n--- Loading Test Market IDs ---");
        string memory filePath = "script/config/test_markets.json";
        string memory json = vm.readFile(filePath);

        // Removed loading collateral token address from here

        string[] memory marketIdStrings = json.readStringArray(".marketIds");
        marketIds = new bytes32[](marketIdStrings.length);
        string memory logIds = "[";
        for (uint256 i = 0; i < marketIdStrings.length; i++) {
            bytes memory b = vm.parseBytes(marketIdStrings[i]);
            require(b.length == 32, "Invalid bytes32 string length");
            marketIds[i] = bytesToBytes32(b, 0);
            logIds = string.concat(logIds, vm.toString(marketIds[i]));
            if (i < marketIdStrings.length - 1) {
                logIds = string.concat(logIds, ", ");
            }
        }
        logIds = string.concat(logIds, "]");
        console.log("  Loaded Market IDs:", logIds);
        require(marketIds.length > 0, "No market IDs loaded");
    }

    /// @notice Instantiates remaining contract variables.
    function _initializeContracts() internal {
        hook = PredictionMarketHook(hookAddress);
        manager = PoolManager(managerAddress);
        swapRouter = PoolSwapTest(swapRouterAddress);
        collateralToken = ERC20Mock(collateralTokenAddress); // Uses address loaded from addresses.json
        console.log("\nContracts instantiated.");
    }

    /// @notice Mints collateral if needed and approves the swap router.
    function _prepareForSwap() internal {
        console.log("\n--- Preparing for Swap ---");
        uint256 swapAmount = 5 * (10 ** collateralToken.decimals()); // Example: Swap 5 collateral tokens

        // Ensure deployer has enough collateral
        if (collateralToken.balanceOf(deployer) < swapAmount) {
            console.log("Minting collateral for swap...");
            collateralToken.mint(deployer, swapAmount * 2); // Mint extra
        }
        console.log(
            "Deployer collateral balance:", collateralToken.balanceOf(deployer) / (10 ** collateralToken.decimals())
        );

        // Approve the swap router to spend the collateral
        uint256 currentAllowance = collateralToken.allowance(deployer, address(swapRouter));
        if (currentAllowance < swapAmount) {
            console.log("Approving swap router to spend collateral...");
            collateralToken.approve(address(swapRouter), type(uint256).max); // Approve max for simplicity
        } else {
            console.log("Swap router already has sufficient collateral allowance.");
        }
    }

    /// @notice Executes the swap transaction.
    function _executeSwap(PoolKey memory poolKey) internal {
        console.log("\n--- Executing Swap ---");

        // Define swap parameters
        bool zeroForOne = true; // true = swap token0 (collateral) for token1 (YES)
        uint256 amountIn = 5 * (10 ** collateralToken.decimals()); // Swap 5 collateral tokens
        int256 amountSpecified = int256(amountIn); // Positive for exact input swap

        // Set sqrtPriceLimitX96: 0 for no limit, or calculate based on desired slippage
        // For swapping token0 for token1, the price *decreases*, so limit is a lower bound.
        uint160 sqrtPriceLimitX96 = TickMath.MIN_SQRT_PRICE + 1; // Minimum possible price + 1

        IPoolManager.SwapParams memory params = IPoolManager.SwapParams({
            zeroForOne: zeroForOne,
            amountSpecified: amountSpecified,
            sqrtPriceLimitX96: sqrtPriceLimitX96
        });

        // Define test settings (optional, use defaults if unsure)
        PoolSwapTest.TestSettings memory testSettings = PoolSwapTest.TestSettings({
            takeClaims: true, // Collect owed tokens during swap
            settleUsingBurn: false // Use transfer instead of burn for settlement
        });

        // Define hook data (empty if hook doesn't require data for beforeSwap)
        bytes memory hookData = "";

        console.log("Calling swapRouter.swap...");
        console.log("  zeroForOne:", params.zeroForOne);
        console.log("  amountSpecified:", params.amountSpecified);
        console.log("  sqrtPriceLimitX96:", params.sqrtPriceLimitX96);

        // Execute swap and handle potential errors
        try swapRouter.swap(poolKey, params, testSettings, hookData) returns (BalanceDelta delta) {
            console.log("Swap successful!");
            console.log("  Amount 0 Delta:", delta.amount0());
            console.log("  Amount 1 Delta:", delta.amount1());
        } catch Error(string memory reason) {
            console.log("Swap failed with reason:", reason);
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("Swap failed with low-level data.");
        }
    }

    // Helper to convert bytes to bytes32
    function bytesToBytes32(bytes memory b, uint256 offset) internal pure returns (bytes32) {
        require(b.length >= offset + 32, "bytesToBytes32: offset out of bounds");
        bytes32 out;
        assembly {
            out := mload(add(add(b, 32), offset))
        }
        return out;
    }
}
