// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Uniswap V4 Core libraries & interfaces
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol"; // Needed for Market struct access

// Uniswap V4 Test utilities
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

// Local project contracts & types
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/**
 * @title AddLiquidity
 * @notice This script loads core contract addresses (Hook, Manager, Helper) from addresses.json,
 *         loads the collateral token address, fetches existing market IDs directly from the hook,
 *         deploys a PoolModifyLiquidityTest router, ensures sufficient token balances,
 *         and adds liquidity to the fetched markets.
 * @dev Assumes addresses.json exists and is populated.
 */
contract AddLiquidity is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    PoolManager public manager;
    // PoolCreationHelper public poolCreationHelper; // Not directly needed by this script

    // --- Test Contracts (Deployed by this script) ---
    PoolModifyLiquidityTest public modifyLiquidityRouter;

    // --- Loaded Test Config ---
    ERC20Mock public collateralToken; // Instance created from loaded address

    // --- Configuration ---
    uint256 public constant LIQUIDITY_COLLATERAL_PER_SIDE = 50 * 1e6; // 50 USDC collateral to add per side (YES/NO pool).
    uint256 public constant LIQUIDITY_OUTCOME_TOKENS_PER_SIDE = 50 * 1e18; // 50 YES/NO tokens to add per side.

    // --- Script State ---
    address private deployer;

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Script runner (Deployer):", deployer);

        // Load addresses of already deployed core contracts.
        _loadCoreAddresses();

        // Start broadcasting transactions to the network.
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the liquidity router.
        _deployLiquidityRouter();

        // Add liquidity to the markets fetched from the hook.
        _addLiquidityToMarkets();

        // Stop broadcasting transactions.
        vm.stopBroadcast();
        console.log("\nScript complete! Liquidity added to test markets.");
    }

    /// @notice Loads required core contract addresses and collateral token address from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory json = vm.readFile("script/config/addresses.json");

        address hookAddress = json.readAddress(".predictionMarketHook");
        address managerAddress = json.readAddress(".poolManager");
        address collateralAddr = json.readAddress(".collateralToken"); // Load collateral token

        require(hookAddress != address(0), "Failed to read hook address");
        require(managerAddress != address(0), "Failed to read manager address");
        require(collateralAddr != address(0), "Failed to read collateral token address from addresses.json");

        hook = PredictionMarketHook(hookAddress);
        manager = PoolManager(managerAddress);
        collateralToken = ERC20Mock(collateralAddr); // Instantiate collateral token

        console.log("  Loaded Hook:", hookAddress);
        console.log("  Loaded PoolManager:", managerAddress);
        console.log("  Loaded Collateral Token:", collateralAddr);
    }

    /// @notice Deploys the Uniswap V4 test router for modifying liquidity.
    function _deployLiquidityRouter() internal {
        console.log("\n--- Deploying Liquidity Router ---");
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        console.log("Deployed PoolModifyLiquidityTest Router at:", address(modifyLiquidityRouter));
    }

    /// @notice Fetches market IDs from the hook and adds liquidity to them.
    function _addLiquidityToMarkets() internal {
        console.log("\n--- Adding Liquidity to Markets (Fetching from Hook) ---");

        // Fetch Market IDs directly from the hook
        bytes32[] memory fetchedMarketIds = hook.getAllMarketIds();
        uint256 numMarkets = fetchedMarketIds.length;
        console.log("Fetched", numMarkets, "market IDs from the hook.");
        require(numMarkets > 0, "No markets found on the hook contract.");

        uint256 collateralDecimals = collateralToken.decimals();
        uint256 outcomeTokenDecimals = 18;
        uint256 collateralMultiplier = (10 ** (outcomeTokenDecimals - collateralDecimals));

        // Calculate total collateral needed for *minting* outcome tokens across all markets
        uint256 collateralNeededForMintingPerMarket = (LIQUIDITY_OUTCOME_TOKENS_PER_SIDE * 2) / collateralMultiplier;
        uint256 totalCollateralNeededForMinting = numMarkets * collateralNeededForMintingPerMarket;

        // Calculate total collateral needed for *adding liquidity* across all markets
        uint256 collateralNeededForLiquidityPerMarket = LIQUIDITY_COLLATERAL_PER_SIDE * 2; // *2 for YES and NO pools
        uint256 totalCollateralNeededForLiquidity = numMarkets * collateralNeededForLiquidityPerMarket;

        // Calculate overall need and check/mint buffer
        uint256 totalOverallCollateralNeeded = totalCollateralNeededForMinting + totalCollateralNeededForLiquidity;

        console.log("Checking deployer collateral balance for liquidity and minting...");
        uint256 currentBalance = collateralToken.balanceOf(deployer);
        if (currentBalance < totalOverallCollateralNeeded) {
            uint256 amountToMint = (totalOverallCollateralNeeded - currentBalance) * 2; // Mint buffer
            collateralToken.mint(deployer, amountToMint);
            console.log("Minted additional", amountToMint / (10 ** collateralDecimals), "collateral.");
        }

        // Approve the hook ONCE for all potential outcome token minting calls.
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved hook for collateral transfer (needed for mintOutcomeTokens)");
        // Approve the router ONCE for all potential liquidity additions.
        collateralToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        console.log("Approved router for collateral transfer (needed for addLiquidity)");

        // Loop through each fetched market ID.
        for (uint256 i = 0; i < numMarkets; i++) {
            bytes32 marketId = fetchedMarketIds[i];
            console.log("\nProcessing Market ID:", vm.toString(marketId));

            // Fetch the market details using the ID
            Market memory market = hook.getMarketById(marketId);

            console.log("  Read Market State:", uint8(market.state));

            // Check if market is active
            if (market.state != MarketState.Active) {
                console.log("  Market state is not Active! Skipping liquidity for this market.");
                // Add a small delay before checking the next market, maybe state updates are slow
                vm.sleep(500); // Sleep 0.5 seconds (500 ms)
                continue;
            }

            // Verify collateral address matches the one we loaded/approved
            if (market.collateralAddress != address(collateralToken)) {
                console.log("  Market collateral address mismatch with loaded token! Skipping.");
                continue;
            }

            OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
            OutcomeToken noToken = OutcomeToken(address(market.noToken));

            // Ensure deployer has enough Outcome Tokens *before* adding liquidity
            uint256 requiredOutcomeTokens = LIQUIDITY_OUTCOME_TOKENS_PER_SIDE;
            bool needsMinting = yesToken.balanceOf(deployer) < requiredOutcomeTokens
                || noToken.balanceOf(deployer) < requiredOutcomeTokens;

            if (needsMinting) {
                console.log(
                    "  Deployer needs outcome tokens. Attempting to mint",
                    requiredOutcomeTokens / 1e18, // Log amount per token type
                    "YES/NO tokens each..."
                );
                uint256 collateralForThisMint = collateralNeededForMintingPerMarket;

                // Check deployer's collateral balance *before* transfer
                require(
                    collateralToken.balanceOf(deployer) >= collateralForThisMint,
                    "Insufficient collateral in deployer wallet for minting"
                );

                // Transfer collateral to hook *before* calling mint.
                bool sent = collateralToken.transfer(address(hook), collateralForThisMint);
                require(
                    sent,
                    string.concat("Collateral transfer to hook failed for minting for market: ", vm.toString(marketId))
                );
                console.log(
                    "  Transferred",
                    collateralForThisMint / (10 ** collateralDecimals),
                    "collateral to hook for minting."
                );

                try hook.mintOutcomeTokens(marketId, requiredOutcomeTokens * 2, address(collateralToken)) {
                    // Mint * 2 (for YES and NO)
                    console.log("  Successfully minted YES/NO tokens for deployer.");
                    console.log("    Deployer YES balance:", yesToken.balanceOf(deployer) / 1e18);
                    console.log("    Deployer NO balance:", noToken.balanceOf(deployer) / 1e18);
                } catch Error(string memory reason) {
                    console.log("  Failed to mint outcome tokens:", reason);
                    console.log("  Skipping liquidity for this market.");
                    continue; // Skip to next market if minting fails
                } catch {
                    console.log("  Unknown error minting outcome tokens.");
                    console.log("  Skipping liquidity for this market.");
                    continue; // Skip to next market
                }
            } else {
                console.log("  Deployer already has sufficient YES/NO tokens.");
            }

            // Add liquidity now that tokens should be available.
            // Approve the router for the specific outcome tokens needed *just in case* approval was somehow lost/insufficient
            // (though the bulk approval above should handle it)
            yesToken.approve(address(modifyLiquidityRouter), requiredOutcomeTokens);
            noToken.approve(address(modifyLiquidityRouter), requiredOutcomeTokens);

            // Add liquidity now that tokens are minted.
            _addLiquidityToMarketPools(market, LIQUIDITY_COLLATERAL_PER_SIDE, LIQUIDITY_OUTCOME_TOKENS_PER_SIDE);
        }
    }

    /**
     * @notice Adds liquidity to both the YES and NO pools for a given market.
     * @param market The market struct containing pool keys and token addresses.
     * @param liquidityCollateral Desired amount of collateral token to provide per pool.
     * @param liquidityOutcomeTokens Desired amount of outcome token (YES or NO) to provide per pool.
     */
    function _addLiquidityToMarketPools( // Renamed for clarity
    Market memory market, uint256 liquidityCollateral, uint256 liquidityOutcomeTokens)
        internal
    {
        console.log("  Adding liquidity to YES/NO pools...");
        OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
        OutcomeToken noToken = OutcomeToken(address(market.noToken));
        uint256 collateralDecimals = collateralToken.decimals();

        // Define tick range for liquidity provision.
        int24 tickSpacing = market.yesPoolKey.tickSpacing;
        int24 minTick = 0; // Approx 0.135 price
        int24 maxTick = 207000; // Price of 1.0
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        int24 initialTick = 6900; // Approx price = 0.5
        initialTick = (initialTick / tickSpacing) * tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Note: Router approvals for collateral/YES/NO tokens are now handled once in _addLiquidityToMarkets

        // Calculate the amount of liquidity (L).
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral, // This is amount of token0 (collateral) desired
            liquidityOutcomeTokens // This is amount of token1 (YES/NO) desired
        );
        require(liquidityAmount > 0, "Calculated liquidity amount cannot be zero");
        console.log("    Calculated Liquidity Amount (L):", liquidityAmount);

        IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: minTick,
            tickUpper: maxTick,
            liquidityDelta: int256(uint256(liquidityAmount)),
            salt: bytes32(0) // Use zero salt unless specifically needed
        });

        // Add liquidity to YES pool.
        console.log("    Adding liquidity to YES pool...");
        // Check balances before the call for better debugging
        uint256 deployerCollateralBal = collateralToken.balanceOf(deployer);
        uint256 deployerYesBal = yesToken.balanceOf(deployer);
        console.log("      Deployer Collateral Before:", deployerCollateralBal / (10 ** collateralDecimals));
        console.log("      Deployer YES Before:", deployerYesBal / 1e18);
        require(deployerCollateralBal >= liquidityCollateral, "Insufficient collateral for YES pool liq");
        require(deployerYesBal >= liquidityOutcomeTokens, "Insufficient YES tokens for liq");

        try modifyLiquidityRouter.modifyLiquidity(market.yesPoolKey, liquidityParams, "") {
            // data can be empty bytes
            console.log("      YES pool liquidity added successfully.");
        } catch Error(string memory reason) {
            console.log("      Failed to add liquidity to YES pool:", reason);
            // Consider adding vm.sleep() here too if failures seem timing-related
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("      Unknown low-level error adding liquidity to YES pool.");
        }

        // Add liquidity to NO pool.
        console.log("    Adding liquidity to NO pool...");
        // Re-check balances as YES pool might have consumed some.
        deployerCollateralBal = collateralToken.balanceOf(deployer);
        uint256 deployerNoBal = noToken.balanceOf(deployer);
        console.log("      Deployer Collateral Before:", deployerCollateralBal / (10 ** collateralDecimals));
        console.log("      Deployer NO Before:", deployerNoBal / 1e18);
        require(deployerCollateralBal >= liquidityCollateral, "Insufficient collateral for NO pool liq");
        require(deployerNoBal >= liquidityOutcomeTokens, "Insufficient NO tokens for liq");

        try modifyLiquidityRouter.modifyLiquidity(market.noPoolKey, liquidityParams, "") {
            // data can be empty bytes
            console.log("      NO pool liquidity added successfully.");
        } catch Error(string memory reason) {
            console.log("      Failed to add liquidity to NO pool:", reason);
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("      Unknown low-level error adding liquidity to NO pool.");
        }
    }
}
