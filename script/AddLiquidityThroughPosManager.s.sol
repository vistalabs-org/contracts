// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Uniswap V4 Core/Periphery libraries & interfaces
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol"; // Import Actions enum
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol"; // Re-add Currency import

// Use LiquidityAmounts from periphery
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

// Local project contracts & types
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/**
 * @title AddLiquidity
 * @notice This script adds liquidity to prediction markets by calling PositionManager.modifyLiquidities,
 *         encoding MINT_POSITION actions.
 * @dev Assumes addresses.json exists and is populated with hook, collateral, and positionManager addresses.
 *      Requires the deployer to have approved the PositionManager (likely via Permit2) for token transfers.
 */
contract AddLiquidity is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    IPositionManager public positionManager;

    // --- Loaded Test Config ---
    ERC20Mock public collateralToken;

    // --- Configuration ---
    uint256 public constant LIQUIDITY_COLLATERAL_PER_SIDE = 50 * 1e6; // 50 USDC
    uint256 public constant LIQUIDITY_OUTCOME_TOKENS_PER_SIDE = 50 * 1e18; // 50 YES/NO
    uint256 public constant DEADLINE_SECONDS = 600; // 10 minutes from now

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

        // Add liquidity to the markets fetched from the hook.
        _addLiquidityToMarkets();

        // Stop broadcasting transactions.
        vm.stopBroadcast();
        console.log("\nScript complete! Liquidity addition via PositionManager.modifyLiquidities submitted.");
    }

    /// @notice Loads required core contract addresses and collateral token address from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory json = vm.readFile("script/config/addresses.json");

        address hookAddress = json.readAddress(".predictionMarketHook");
        address positionManagerAddress = json.readAddress(".positionManager");
        address collateralAddr = json.readAddress(".collateralToken");

        require(hookAddress != address(0), "Failed to read hook address");
        require(positionManagerAddress != address(0), "Failed to read positionManager address from addresses.json");
        require(collateralAddr != address(0), "Failed to read collateral token address from addresses.json");

        hook = PredictionMarketHook(hookAddress);
        positionManager = IPositionManager(positionManagerAddress);
        collateralToken = ERC20Mock(collateralAddr);

        console.log("  Loaded Hook:", hookAddress);
        console.log("  Loaded PositionManager:", positionManagerAddress);
        console.log("  Loaded Collateral Token:", collateralAddr);
    }

    /// @notice Fetches market IDs from the hook and adds liquidity to them using PositionManager.modifyLiquidities.
    function _addLiquidityToMarkets() internal {
        console.log("\n--- Adding Liquidity to Markets (via PositionManager.modifyLiquidities) --- ");

        // Fetch Market IDs directly from the hook
        bytes32[] memory fetchedMarketIds = hook.getAllMarketIds();
        uint256 numMarkets = fetchedMarketIds.length;
        console.log("Fetched", numMarkets, "market IDs from the hook.");
        require(numMarkets > 0, "No markets found on the hook contract.");

        uint256 collateralDecimals = collateralToken.decimals();
        uint256 outcomeTokenDecimals = 18;
        uint256 collateralMultiplier = (10 ** (outcomeTokenDecimals - collateralDecimals));

        // --- Pre-checks and Approvals (outside the market loop for efficiency) ---

        // Calculate total *collateral* needed for *minting* outcome tokens (estimation)
        uint256 collateralNeededForMintingPerMarket = (LIQUIDITY_OUTCOME_TOKENS_PER_SIDE * 2) / collateralMultiplier;
        uint256 totalCollateralNeededForMinting = numMarkets * collateralNeededForMintingPerMarket;

        // Calculate total *collateral* needed for *adding liquidity*
        uint256 collateralNeededForLiquidityPerMarket = LIQUIDITY_COLLATERAL_PER_SIDE * 2;
        uint256 totalCollateralNeededForLiquidity = numMarkets * collateralNeededForLiquidityPerMarket;

        // Calculate overall collateral need and check/mint buffer
        uint256 totalOverallCollateralNeeded = totalCollateralNeededForMinting + totalCollateralNeededForLiquidity;

        console.log("Checking deployer collateral balance...");
        uint256 currentCollateralBalance = collateralToken.balanceOf(deployer);
        if (currentCollateralBalance < totalOverallCollateralNeeded) {
            uint256 amountToMint = (totalOverallCollateralNeeded - currentCollateralBalance) * 2; // Mint buffer
            collateralToken.mint(deployer, amountToMint);
            console.log("Minted additional", amountToMint / (10 ** collateralDecimals), "collateral.");
        }

        // Approve the hook ONCE for all potential outcome token minting calls.
        collateralToken.approve(address(hook), type(uint256).max);
        console.log("Approved hook for collateral transfer (mintOutcomeTokens)");

        // Approve the PositionManager to spend deployer's collateral.
        collateralToken.approve(address(positionManager), type(uint256).max);
        console.log("Approved PositionManager for collateral transfer (Standard ERC20)");
        // Note: Actual transfer likely relies on Permit2 approval set outside this script.

        // --- Process Each Market --- //
        for (uint256 i = 0; i < numMarkets; i++) {
            bytes32 marketId = fetchedMarketIds[i];
            console.log("\nProcessing Market ID:", vm.toString(marketId));

            Market memory market = hook.getMarketById(marketId);
            console.log("  Read Market State:", uint8(market.state));

            if (market.state != MarketState.Active) {
                console.log("  Market state is not Active! Skipping liquidity.");
                vm.sleep(500);
                continue;
            }

            if (market.collateralAddress != address(collateralToken)) {
                console.log("  Market collateral address mismatch! Skipping.");
                continue;
            }

            OutcomeToken yesToken = OutcomeToken(address(market.yesToken));
            OutcomeToken noToken = OutcomeToken(address(market.noToken));

            // Ensure deployer has enough Outcome Tokens (mint if needed)
            _ensureOutcomeTokens(marketId, yesToken, noToken, collateralNeededForMintingPerMarket);

            // Approve the PositionManager to spend deployer's outcome tokens.
            yesToken.approve(address(positionManager), type(uint256).max);
            noToken.approve(address(positionManager), type(uint256).max);
            console.log("  Approved PositionManager for YES/NO token transfer (Standard ERC20)");

            // Encode and execute the liquidity addition via modifyLiquidities, one pool at a time
            _encodeAndExecuteSingleMint(market.yesPoolKey, address(yesToken), LIQUIDITY_COLLATERAL_PER_SIDE, LIQUIDITY_OUTCOME_TOKENS_PER_SIDE);
            _encodeAndExecuteSingleMint(market.noPoolKey, address(noToken), LIQUIDITY_COLLATERAL_PER_SIDE, LIQUIDITY_OUTCOME_TOKENS_PER_SIDE);
        }
    }

    /// @notice Ensures the deployer has sufficient outcome tokens, minting them if necessary.
    function _ensureOutcomeTokens(
        bytes32 marketId,
        OutcomeToken yesToken,
        OutcomeToken noToken,
        uint256 collateralForMinting
    ) internal {
        uint256 requiredOutcomeTokens = LIQUIDITY_OUTCOME_TOKENS_PER_SIDE;
        bool needsMinting = yesToken.balanceOf(deployer) < requiredOutcomeTokens
            || noToken.balanceOf(deployer) < requiredOutcomeTokens;

        if (needsMinting) {
            console.log(
                "  Deployer needs outcome tokens. Attempting to mint",
                requiredOutcomeTokens / 1e18,
                "YES/NO tokens each..."
            );
            uint256 collateralDecimals = collateralToken.decimals();

            require(
                collateralToken.balanceOf(deployer) >= collateralForMinting,
                "Insufficient collateral for minting"
            );

            // Transfer collateral to hook *before* calling mint.
            try hook.mintOutcomeTokens(marketId, requiredOutcomeTokens * 2, address(collateralToken)) {
                bool sent = collateralToken.transfer(address(hook), collateralForMinting);
                require(sent, string.concat("Collateral transfer failed for minting market: ", vm.toString(marketId)));
                console.log(
                    "    Transferred", collateralForMinting / (10 ** collateralDecimals), "collateral to hook."
                );

                console.log("    Successfully minted YES/NO tokens.");
                console.log("      Deployer YES balance:", yesToken.balanceOf(deployer) / 1e18);
                console.log("      Deployer NO balance:", noToken.balanceOf(deployer) / 1e18);
            } catch Error(string memory reason) {
                console.log("    Failed to mint outcome tokens:", reason);
                revert("Minting failed, cannot add liquidity"); // Revert script if minting fails
            } catch {
                console.log("    Unknown error minting outcome tokens.");
                revert("Minting failed, cannot add liquidity");
            }
        } else {
            console.log("  Deployer already has sufficient YES/NO tokens.");
        }
    }

    /**
     * @notice Encodes a single MINT_POSITION action and calls PositionManager.modifyLiquidities.
     * @param poolKey The specific PoolKey (YES or NO pool) to add liquidity to.
     * @param outcomeTokenAddress The address of the corresponding YES or NO token.
     * @param liquidityCollateral Desired amount of collateral token to provide.
     * @param liquidityOutcomeTokens Desired amount of outcome token to provide.
     */
    function _encodeAndExecuteSingleMint(
        PoolKey memory poolKey,
        address outcomeTokenAddress,
        uint256 liquidityCollateral,
        uint256 liquidityOutcomeTokens
    ) internal {
        console.log("  Encoding single MINT_POSITION action for pool:", Currency.unwrap(poolKey.currency0), Currency.unwrap(poolKey.currency1));

        // Define tick range
        int24 tickSpacing = poolKey.tickSpacing;
        int24 minTick = 0;
        int24 maxTick = 207000;
        minTick = (minTick / tickSpacing) * tickSpacing;
        maxTick = (maxTick / tickSpacing) * tickSpacing;

        int24 initialTick = 6900;
        initialTick = (initialTick / tickSpacing) * tickSpacing;
        uint160 sqrtPriceX96 = TickMath.getSqrtPriceAtTick(initialTick);

        // Calculate liquidity amount (L)
        uint128 liquidityAmount = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtPriceAtTick(minTick),
            TickMath.getSqrtPriceAtTick(maxTick),
            liquidityCollateral,
            liquidityOutcomeTokens
        );
        require(liquidityAmount > 0, "Calculated liquidity L cannot be zero");
        console.log("    Calculated Liquidity Amount (L):", liquidityAmount);

        // Prepare common parameters for encoding
        uint128 amount0Max = uint128(liquidityCollateral);
        uint128 amount1Max = uint128(liquidityOutcomeTokens);
        bytes memory hookData = "";
        uint256 deadline = block.timestamp + DEADLINE_SECONDS;

        // --- Encode Actions and Parameters --- //

        // 1. Actions Bytes (Single Mint)
        bytes memory actionsBytes = abi.encodePacked(uint8(Actions.MINT_POSITION));

        // 2. Parameters Array (Single Mint Params)
        bytes[] memory paramsArray = new bytes[](1);
        paramsArray[0] = abi.encode(
            poolKey,
            minTick,
            maxTick,
            liquidityAmount,
            amount0Max,
            amount1Max,
            deployer,
            hookData
        );

        // 3. Final Unlock Data
        bytes memory unlockData = abi.encode(actionsBytes, paramsArray);

        console.log("    Encoded unlockData for single modifyLiquidities call.");

        // --- Check Balances Before Call --- //
        require(
            collateralToken.balanceOf(deployer) >= liquidityCollateral,
            "Insufficient collateral for this pool"
        );
        require(
            IERC20(outcomeTokenAddress).balanceOf(deployer) >= liquidityOutcomeTokens,
            "Insufficient outcome tokens for this pool"
        );

        // --- Execute modifyLiquidities --- //
        console.log("    Calling PositionManager.modifyLiquidities...");
        try positionManager.modifyLiquidities(unlockData, deadline) {
            console.log("      modifyLiquidities call successful.");
        } catch Error(string memory reason) {
            console.log("      Failed modifyLiquidities call:", reason);
        } catch (bytes memory lowLevelData) {
            console.logBytes(lowLevelData);
            console.log("      Unknown low-level error during modifyLiquidities.");
        }
    }
}
