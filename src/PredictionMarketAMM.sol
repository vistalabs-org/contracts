pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";
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
import "./utils/Quoter.sol";
import {toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";

/// @title PredictionMarketHook - Hook for prediction market management

contract PredictionMarketHook is BaseHook, IPredictionMarketHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint160;
    using CurrencyLibrary for Currency;
    using CurrencySettler for Currency;
    IPoolManager public poolm;
    PoolModifyLiquidityTest public posm;
    PoolCreationHelper public poolCreationHelper;
    NormalQuoter public quoter;
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

    struct CallbackData {
        uint256 amountEach; // Amount of each token to add as liquidity
        Currency currency0;
        Currency currency1;
        address sender;
        PoolKey key;
    }

    error DirectSwapsNotAllowed();
    error DirectLiquidityNotAllowed();
    error NotOracle();
    error MarketAlreadyResolved();
    error NotOracleOrCreator();
    error MarketNotResolved();
    error NoTokensToClaim();
    error AlreadyClaimed();
    error AddLiquidityThroughHook();
    event PoolCreated(PoolId poolId);
    event WinningsClaimed(bytes32 indexed marketId, address indexed user, uint256 amount);

    constructor(
        IPoolManager _poolManager,
        PoolModifyLiquidityTest _posm,
        PoolCreationHelper _poolCreationHelper,
        NormalQuoter _quoter
    ) BaseHook(_poolManager) {
        poolm = IPoolManager(_poolManager);
        posm = PoolModifyLiquidityTest(_posm);
        poolCreationHelper = PoolCreationHelper(_poolCreationHelper);
        quoter = _quoter;
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
                beforeSwapReturnDelta: true,
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        // Get market from pool key
        PoolId poolId = key.toId();
        Market memory market = _getMarketFromPoolId(poolId);
        
        // Check market exists and is active
        require(market.state == MarketState.Active, "Market not active");
        
        // Get current reserves
        (uint256 reserve0, uint256 reserve1) = _getReserves(key);
        
        // Determine if we're swapping in token0 or token1
        bool zeroForOne = params.zeroForOne;
        uint256 amountIn = params.amountSpecified > 0 ? uint256(params.amountSpecified) : 0;
        
        // Calculate output amount using our custom invariant
        uint256 amountOut;
        if (zeroForOne) {
            // Swapping token0 for token1
            // We need to calculate how much token1 to give out
            amountOut = quoter.computeOutputAmount(amountIn, reserve1);
        } else {
            // Swapping token1 for token0
            // We need to calculate how much token0 to give out
            amountOut = quoter.computeOutputAmount(amountIn, reserve0);
        }
        
        // Create the BeforeSwapDelta
        BeforeSwapDelta delta;
        if (zeroForOne) {
            // User gives token0, gets token1
            delta = toBeforeSwapDelta(
                int128(int256(amountIn)),
                -int128(int256(amountOut))
            );
        } else {
            // User gives token1, gets token0
            delta = toBeforeSwapDelta(
                -int128(int256(amountOut)),
                int128(int256(amountIn))
            );
        }
        
        return (BaseHook.beforeSwap.selector, delta, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        revert AddLiquidityThroughHook();
    }

    function addLiquidity(PoolKey calldata key, uint256 amountEach) external {
        poolManager.unlock(
        abi.encode(
            CallbackData(
                amountEach, 
                key.currency0,
                key.currency1,
                msg.sender,
                key
            )
        )
       );
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        CallbackData memory callbackData = abi.decode(data, (CallbackData));
	    console.log("callbackData: ",callbackData.amountEach);
        
	    callbackData.currency0.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false 
        );
        callbackData.currency1.settle(
            poolManager,
            callbackData.sender,
            callbackData.amountEach,
            false
        );

        callbackData.currency0.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true 
        );
        callbackData.currency1.take(
            poolManager,
            address(this),
            callbackData.amountEach,
            true
        );
	    return "";
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
            currency0: Currency.wrap(params.collateralAddress),
            currency1: Currency.wrap(address(yesToken)),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });

        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(params.collateralAddress),
            currency1: Currency.wrap(address(noToken)),
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

    // mint YES / NO tokens based on collateral amount
    // Users can mint based on current price to provide liquidity to the market
    function mintOutcomeTokens(bytes32 marketId, uint256 collateralAmount) external {
        Market memory market = _markets[marketId];
        // Calculate collateral to return (accounting for decimal differences)
        // YES/NO tokens have 18 decimals, collateral might have different decimals
        uint256 collateralDecimals = ERC20(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10**(18 - collateralDecimals);

        // 1 unit of collateral = 1 unit of YES and one of NO token (100 USDC mints 100 YES and 100 NO)
        // take collateral from the user
        IERC20(market.collateralAddress).transferFrom(msg.sender, address(this), collateralAmount);

        // mint YES and NO tokens to the user
        market.yesToken.mint(msg.sender, collateralAmount / decimalAdjustment);
        market.noToken.mint(msg.sender, collateralAmount / decimalAdjustment);
    }

    // Helper function to get current reserves
    function _getReserves(PoolKey calldata key) internal view returns (uint256 reserve0, uint256 reserve1) {
        // Get balances using CurrencyLibrary's balanceOf function
        reserve0 = CurrencyLibrary.balanceOf(key.currency0, address(poolManager));
        reserve1 = CurrencyLibrary.balanceOf(key.currency1, address(poolManager));
    }

}