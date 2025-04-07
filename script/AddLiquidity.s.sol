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
 *         loads test market data (collateral address, market IDs) from test_markets.json,
 *         deploys a PoolModifyLiquidityTest router, ensures sufficient token balances,
 *         and adds liquidity to the specified markets.
 * @dev Assumes addresses.json and test_markets.json exist and are populated.
 *      Requires write permission for test_markets.json in foundry.toml (though only read is used here).
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
    bytes32[] private marketIds; // Loaded from file

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
        // Load data specific to the test markets.
        _loadMarketData();

        // Start broadcasting transactions to the network.
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the liquidity router.
        _deployLiquidityRouter();

        // Add liquidity to the loaded markets.
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

    /// @notice Loads test market IDs from test_markets.json.
    function _loadMarketData() internal {
        console.log("\n--- Loading Test Market IDs ---");
        string memory filePath = "script/config/test_markets.json";
        string memory json = vm.readFile(filePath);

        // Removed loading collateral token address from here

        // Read market IDs (serialized as strings)
        string[] memory marketIdStrings = json.readStringArray(".marketIds");
        marketIds = new bytes32[](marketIdStrings.length);
        for (uint256 i = 0; i < marketIdStrings.length; i++) {
            // Convert string back to bytes32 - This requires a helper or assumes format
            // For simplicity, assuming vm.toString format is easily parseable or use a fixed format.
            // Reverting to manual parsing if vm.parseBytes32 doesn't work on stringified bytes32
            bytes memory b = vm.parseBytes(marketIdStrings[i]); // vm.parseBytes32 might also work depending on format
            require(b.length == 32, "Invalid bytes32 string length");
            marketIds[i] = bytesToBytes32(b, 0);
        }
        // Log market IDs by iterating and converting each to string.
        string memory idsLog = "[";
        for (uint256 i = 0; i < marketIds.length; i++) {
            idsLog = string.concat(idsLog, vm.toString(marketIds[i]));
            if (i < marketIds.length - 1) {
                idsLog = string.concat(idsLog, ", ");
            }
        }
        idsLog = string.concat(idsLog, "]");
        console.log("  Loaded Market IDs:", idsLog);
        require(marketIds.length > 0, "No market IDs loaded");
    }

    /// @notice Deploys the Uniswap V4 test router for modifying liquidity.
    function _deployLiquidityRouter() internal {
        console.log("\n--- Deploying Liquidity Router ---");
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        console.log("Deployed PoolModifyLiquidityTest Router at:", address(modifyLiquidityRouter));
    }

    /// @notice Iterates through loaded market IDs and adds liquidity.
    function _addLiquidityToMarkets() internal {
        console.log("\n--- Adding Liquidity to Markets ---");

        uint256 collateralDecimals = collateralToken.decimals();
        uint256 outcomeTokenDecimals = 18;
        uint256 collateralMultiplier = (10 ** (outcomeTokenDecimals - collateralDecimals));
        uint256 collateralForOutcomeTokensPerSide = LIQUIDITY_OUTCOME_TOKENS_PER_SIDE / collateralMultiplier;
        uint256 totalCollateralNeededPerMarket = 2 * (LIQUIDITY_COLLATERAL_PER_SIDE + collateralForOutcomeTokensPerSide);

        // Check and mint collateral if needed for the entire batch.
        uint256 totalOverallCollateralNeeded = marketIds.length * totalCollateralNeededPerMarket;
        console.log("Checking deployer collateral balance for liquidity...");
        uint256 currentBalance = collateralToken.balanceOf(deployer);
        if (currentBalance < totalOverallCollateralNeeded) {
            uint256 amountToMint = (totalOverallCollateralNeeded - currentBalance) * 2; // Mint buffer
            collateralToken.mint(deployer, amountToMint);
            console.log("Minted additional", amountToMint / (10 ** collateralDecimals), "collateral for liquidity.");
        }

        // Approve the hook ONCE for all potential outcome token minting calls.
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved hook for collateral transfer (needed for mintOutcomeTokens)");

        // Loop through each loaded market ID.
        for (uint256 i = 0; i < marketIds.length; i++) {
            bytes32 marketId = marketIds[i];
            console.log("\nProcessing Market ID:", vm.toString(marketId));
            Market memory market = hook.getMarketById(marketId);

            // Basic checks
            if (market.state != MarketState.Active) {
                console.log("  Market is not Active, skipping liquidity addition.");
                continue;
            }
            if (market.collateralAddress != address(collateralToken)) {
                console.log("  Market collateral address mismatch with loaded token! Skipping.");
                continue;
            }

            // Mint outcome tokens for the deployer.
            console.log(
                "  Attempting to mint",
                LIQUIDITY_OUTCOME_TOKENS_PER_SIDE / 1e18,
                "YES/NO tokens each for liquidity provision..."
            );
            uint256 totalCollateralForMinting = collateralForOutcomeTokensPerSide * 2;
            // Transfer collateral to hook *before* calling mint.
            bool sent = collateralToken.transfer(address(hook), totalCollateralForMinting);
            // Add more descriptive require message
            require(sent, string.concat("Collateral transfer to hook failed for market: ", vm.toString(marketId)));
            console.log(
                "  Transferred",
                totalCollateralForMinting / (10 ** collateralDecimals),
                "collateral to hook for minting."
            );

            try hook.mintOutcomeTokens(marketId, LIQUIDITY_OUTCOME_TOKENS_PER_SIDE * 2, address(collateralToken)) {
                console.log("  Successfully minted YES/NO tokens for deployer.");
                OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
                OutcomeToken noToken = OutcomeToken(address(market.noToken));
                console.log("    Deployer YES balance:", yesToken.balanceOf(deployer) / 1e18);
                console.log("    Deployer NO balance:", noToken.balanceOf(deployer) / 1e18);

                // Add liquidity now that tokens are minted.
                _addLiquidityToMarketPools(market, LIQUIDITY_COLLATERAL_PER_SIDE, LIQUIDITY_OUTCOME_TOKENS_PER_SIDE);
            } catch Error(string memory reason) {
                console.log("  Failed to mint outcome tokens:", reason);
                console.log("  Skipping liquidity for this market.");
                continue; // Skip to next market if minting fails
            } catch {
                console.log("  Unknown error minting outcome tokens.");
                console.log("  Skipping liquidity for this market.");
                continue; // Skip to next market
            }
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

        int24 initialTick = 6931; // Approx price = 0.5
        initialTick = (initialTick / tickSpacing) * tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Approve the Liquidity Router to spend the deployer's tokens.
        // Approve the specific amounts needed for one side.
        console.log("    Approving router for YES token (Amount: ", liquidityOutcomeTokens / 1e18, ")");
        yesToken.approve(address(modifyLiquidityRouter), liquidityOutcomeTokens);
        console.log("    Approving router for NO token (Amount: ", liquidityOutcomeTokens / 1e18, ")");
        noToken.approve(address(modifyLiquidityRouter), liquidityOutcomeTokens);
        console.log(
            "    Approving router for Collateral token (Amount: ", liquidityCollateral / (10 ** collateralDecimals), ")"
        );
        // Approve enough collateral for both sides at once.
        collateralToken.approve(address(modifyLiquidityRouter), liquidityCollateral * 2);

        // Calculate the amount of liquidity (L).
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );
        require(liquidityAmount > 0, "Calculated liquidity amount cannot be zero");
        console.log("    Calculated Liquidity Amount (L):", liquidityAmount);

        IPoolManager.ModifyLiquidityParams memory liquidityParams = IPoolManager.ModifyLiquidityParams({
            tickLower: minTick,
            tickUpper: maxTick,
            liquidityDelta: int256(uint256(liquidityAmount)),
            salt: bytes32(0)
        });

        // Add liquidity to YES pool.
        console.log("    Adding liquidity to YES pool...");
        require(collateralToken.balanceOf(deployer) >= liquidityCollateral, "Insufficient collateral for YES pool liq");
        require(yesToken.balanceOf(deployer) >= liquidityOutcomeTokens, "Insufficient YES tokens for liq");
        try modifyLiquidityRouter.modifyLiquidity(market.yesPoolKey, liquidityParams, "") {
            console.log("      YES pool liquidity added successfully.");
        } catch Error(string memory reason) {
            console.log("      Failed to add liquidity to YES pool:", reason);
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("      Unknown low-level error adding liquidity to YES pool.");
        }

        // Add liquidity to NO pool.
        console.log("    Adding liquidity to NO pool...");
        // Re-check balances as YES pool might have consumed some.
        require(collateralToken.balanceOf(deployer) >= liquidityCollateral, "Insufficient collateral for NO pool liq");
        require(noToken.balanceOf(deployer) >= liquidityOutcomeTokens, "Insufficient NO tokens for liq");
        try modifyLiquidityRouter.modifyLiquidity(market.noPoolKey, liquidityParams, "") {
            console.log("      NO pool liquidity added successfully.");
        } catch Error(string memory reason) {
            console.log("      Failed to add liquidity to NO pool:", reason);
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("      Unknown low-level error adding liquidity to NO pool.");
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
