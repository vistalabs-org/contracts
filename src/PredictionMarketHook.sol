pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Market, MarketState} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {console} from "forge-std/console.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {V4Quoter} from "@uniswap/v4-periphery/src/lens/V4Quoter.sol";
import {IV4Quoter} from "@uniswap/v4-periphery/src/interfaces/IV4Quoter.sol";
import {QuoterRevert} from "@uniswap/v4-periphery/src/libraries/QuoterRevert.sol";
import {IPredictionMarketHook} from "./interfaces/IPredictionMarketHook.sol";
import {Market} from "./types/MarketTypes.sol";
import {PoolCreationHelper} from "./PoolCreationHelper.sol";
import {CreateMarketParams} from "./types/MarketTypes.sol";
/// @title PredictionMarketHook - Hook for prediction market management

contract PredictionMarketHook is BaseHook, IPredictionMarketHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint160;
    IPoolManager public poolm;
    PoolModifyLiquidityTest public posm;
    PoolCreationHelper public poolCreationHelper;
    int24 public TICK_SPACING = 100;
    // Market ID counter
    uint256 private _marketCount;
    mapping(uint256 => PoolId) private _marketPoolIds;
    // Map market pools to market info
    mapping(bytes32 => Market) private _markets;
    /// @notice Mapping to track which addresses have claimed their winnings
    mapping(bytes32 => mapping(address => bool)) private _hasClaimed;

    /// @notice Mapping to track claimed tokens (separate from liquidity tokens)
    mapping(bytes32 => uint256) private _claimedTokens;
    
    // Map pool IDs to market IDs
    mapping(PoolId => bytes32) private _poolToMarketId;

    // Array to store all market IDs
    bytes32[] private _allMarketIds;

    error DirectSwapsNotAllowed();
    error DirectLiquidityNotAllowed();
    error NotOracle();
    error MarketAlreadyResolved();
    error NotOracleOrCreator();
    error MarketNotResolved();
    error NoTokensToClaim();
    error AlreadyClaimed();

    event PoolCreated(PoolId poolId);
    event WinningsClaimed(bytes32 indexed marketId, address indexed user, uint256 amount);

    constructor(
        IPoolManager _poolManager,
        PoolModifyLiquidityTest _posm,
        PoolCreationHelper _poolCreationHelper
    ) BaseHook(_poolManager) {
        poolm = IPoolManager(_poolManager);
        posm = PoolModifyLiquidityTest(_posm);
        poolCreationHelper = PoolCreationHelper(_poolCreationHelper);
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true,
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true,
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: false,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata,
        bytes calldata
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _getMarketFromPoolId(poolId);
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _getMarketFromPoolId(poolId);
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        // For prediction markets, we want to constrain the price between 0.01 and 0.99 USDC
        // These ticks correspond to those prices (rounded to valid tick spacing)
        int24 minValidTick = -9200; // Slightly above 0.01 USDC
        int24 maxValidTick = -100;  // Slightly below 0.99 USDC
        
        // Ensure ticks are valid with the tick spacing
        minValidTick = (minValidTick / TICK_SPACING) * TICK_SPACING;
        maxValidTick = (maxValidTick / TICK_SPACING) * TICK_SPACING;
        
        // Enforce position is within the valid price range for prediction markets
        require(
            params.tickLower >= minValidTick && 
            params.tickUpper <= maxValidTick,
            "Position must be within 0.01-0.99 price range"
        );
        
        return BaseHook.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        bytes calldata
    ) internal view override returns (bytes4) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _getMarketFromPoolId(poolId);
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        // Only allow removals after market is resolved
        if (market.state != MarketState.Resolved) {
            revert DirectLiquidityNotAllowed();
        }
        
        return BaseHook.beforeRemoveLiquidity.selector;
    }

    //////////////////////////
    function createMarketAndDepositCollateral(
        CreateMarketParams calldata params
    ) public returns (bytes32) {
        // Create YES and NO tokens
        OutcomeToken yesToken = new OutcomeToken("Market YES", "YES");
        OutcomeToken noToken = new OutcomeToken("Market NO", "NO");

        // Each unit of collateral backs 1 yes token and 1 no token
        uint256 yesTokens = params.collateralAmount;
        uint256 noTokens = params.collateralAmount;

        // Mint YES and NO tokens to the creator instead of this contract
        OutcomeToken(address(yesToken)).mint(params.creator, yesTokens);
        OutcomeToken(address(noToken)).mint(params.creator, noTokens);

        // Transfer collateral to this contract
        IERC20(params.collateralAddress).transferFrom(msg.sender, address(this), params.collateralAmount);
        
        // Create pool keys
        PoolKey memory yesPoolKey = PoolKey({
            currency0: Currency.wrap(address(yesToken)),
            currency1: Currency.wrap(params.collateralAddress),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });

        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(address(noToken)),
            currency1: Currency.wrap(params.collateralAddress),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });

        // Create both pools
        poolCreationHelper.createUniswapPool(yesPoolKey);
        poolCreationHelper.createUniswapPool(noPoolKey);

        // Create market ID from both pool keys
        bytes32 marketId = keccak256(abi.encodePacked(yesPoolKey.toId(), noPoolKey.toId()));

        // Store market info
        _markets[marketId] = Market({
            yesPoolKey: yesPoolKey,
            noPoolKey: noPoolKey,
            oracle: params.oracle,
            creator: params.creator,
            yesToken: yesToken,
            noToken: noToken,
            state: MarketState.Active,
            outcome: false,
            totalCollateral: params.collateralAmount,
            collateralAddress: params.collateralAddress,
            title: params.title,
            description: params.description,
            endTimestamp: block.timestamp + params.duration
        });
        
        // Add market ID to the array of all markets
        _allMarketIds.push(marketId);
        
        // Map both pool IDs to this market ID
        _poolToMarketId[yesPoolKey.toId()] = marketId;
        _poolToMarketId[noPoolKey.toId()] = marketId;
        
        return marketId;
    }

    // Function to get all market IDs
    function getAllMarketIds() external view returns (bytes32[] memory) {
        return _allMarketIds;
    }

    // Function to get all markets with details
    function getAllMarkets() external view returns (Market[] memory) {
        uint256 count = _allMarketIds.length;
        Market[] memory markets = new Market[](count);
        
        for (uint256 i = 0; i < count; i++) {
            markets[i] = _markets[_allMarketIds[i]];
        }
        
        return markets;
    }

    // Function to get markets with pagination
    function getMarkets(uint256 offset, uint256 limit) external view returns (Market[] memory) {
        uint256 count = _allMarketIds.length;
        
        // Ensure offset is valid
        if (offset >= count) {
            return new Market[](0);
        }
        
        // Calculate actual limit
        uint256 actualLimit = (offset + limit > count) ? count - offset : limit;
        
        Market[] memory markets = new Market[](actualLimit);
        
        for (uint256 i = 0; i < actualLimit; i++) {
            markets[i] = _markets[_allMarketIds[offset + i]];
        }
        
        return markets;
    }

    // Function to get market count
    function getMarketCount() external view returns (uint256) {
        return _allMarketIds.length;
    }

    //////////////////////////
    //////// Modifiers ////////
    //////////////////////////

    /// @notice Allows oracle to resolve the market with the outcome
    /// @param marketId The ID of the market
    /// @param outcome true for YES, false for NO
    function resolveMarket(bytes32 marketId, bool outcome) external {
        // Check if caller is oracle
        if (msg.sender != _markets[marketId].oracle) {
            revert NotOracle();
        }

        // Check if market is still active
        if (_markets[marketId].state != MarketState.Active) {
            revert MarketAlreadyResolved();
        }

        // Update market state and outcome
        _markets[marketId].state = MarketState.Resolved;
        _markets[marketId].outcome = outcome;
    }

    /// @notice Allows oracle or creator to cancel the market
    /// @param marketId The ID of the market
    function cancelMarket(bytes32 marketId) external {
        // Check if caller is oracle or creator
        if (msg.sender != _markets[marketId].oracle) {
            revert NotOracle();
        }

        // Check if market is still active
        if (_markets[marketId].state != MarketState.Active) {
            revert MarketAlreadyResolved();
        }

        // Update market state
        _markets[marketId].state = MarketState.Cancelled;
    }

    /// @notice Allows users to claim collateral based on their winning token holdings
    /// @param marketId The ID of the market
    function claimWinnings(bytes32 marketId) external {
        Market storage market = _markets[marketId];
        
        // Check market is resolved
        if (market.state != MarketState.Resolved) {
            revert MarketNotResolved();
        }
        
        // Check user hasn't already claimed
        if (_hasClaimed[marketId][msg.sender]) {
            revert AlreadyClaimed();
        }
        
        // Determine which token is the winning token
        address winningToken;
        if (market.outcome) {
            // YES outcome
            winningToken = address(market.yesToken);
        } else {
            // NO outcome
            winningToken = address(market.noToken);
        }
        
        // Get user's token balance
        uint256 tokenBalance = OutcomeToken(winningToken).balanceOf(msg.sender);
        
        // Ensure user has tokens to claim
        require(tokenBalance > 0, "No tokens to claim");
        
        // Calculate collateral to return (accounting for decimal differences)
        // YES/NO tokens have 18 decimals, collateral might have different decimals
        uint256 collateralDecimals = ERC20(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10**(18 - collateralDecimals);
        
        // Calculate claim amount
        uint256 claimAmount = tokenBalance / decimalAdjustment;
        
        // Ensure there's enough collateral left to claim
        uint256 remainingCollateral = market.totalCollateral - _claimedTokens[marketId];
        require(claimAmount <= remainingCollateral, "Insufficient collateral remaining");
        
        // Burn the winning tokens
        OutcomeToken(winningToken).burnFrom(msg.sender, tokenBalance);
        
        // Transfer collateral to user
        IERC20(market.collateralAddress).transfer(msg.sender, claimAmount);
        
        // Update claimed tokens amount
        _claimedTokens[marketId] += claimAmount;
        
        // Mark user as claimed
        _hasClaimed[marketId][msg.sender] = true;
        
        // Emit event
        emit WinningsClaimed(marketId, msg.sender, claimAmount);
    }

    // Implement getters manually
    function markets(PoolId poolId) external view returns (Market memory) {
        return _getMarketFromPoolId(poolId);
    }

    function marketCount() external view returns (uint256) {
        return _marketCount;
    }

    function marketPoolIds(uint256 index) external view returns (PoolId) {
        return _marketPoolIds[index];
    }

    function claimedTokens(bytes32 marketId) external view returns (uint256) {
        return _claimedTokens[marketId];
    }

    function hasClaimed(bytes32 marketId, address user) external view returns (bool) {
        return _hasClaimed[marketId][user];
    }

    // Helper function to get market from pool ID
    function _getMarketFromPoolId(PoolId poolId) internal view returns (Market storage) {
        bytes32 marketId = _poolToMarketId[poolId];
        require(marketId != bytes32(0), "Market not found");
        return _markets[marketId];
    }

    function getMarketById(bytes32 marketId) external view returns (Market memory) {
        return _markets[marketId];
    }

}