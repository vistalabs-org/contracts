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

    error DirectSwapsNotAllowed();
    error DirectLiquidityNotAllowed();
    error NotOracle();
    error MarketAlreadyResolved();
    error NotOracleOrCreator();
    error MarketNotResolved();
    error NoTokensToClaim();
    error AlreadyClaimed();

    event PoolCreated(PoolId poolId);

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
        
        // Enforce full range positions only
        require(
            params.tickLower == TickMath.minUsableTick(TICK_SPACING) &&
            params.tickUpper == TickMath.maxUsableTick(TICK_SPACING),
            "Only full range positions allowed"
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

    function createMarketWithCollateralAndLiquidity(
        address oracle,
        address creator,
        address collateralAddress,
        uint256 collateralAmount,
        string memory title,
        string memory description,
        uint256 duration
    ) public returns (bytes32) {
        bytes32 marketId = createMarketAndDepositCollateral(
            oracle,
            creator,
            collateralAddress,
            collateralAmount,
            title,
            description,
            duration
        );
        _addInitialOutcomeTokensLiquidity(marketId);
        return marketId;
    }

    function createMarketAndDepositCollateral(
        address oracle,
        address creator,
        address collateralAddress,
        uint256 collateralAmount,
        string memory title,
        string memory description,
        uint256 duration
    ) public returns (bytes32) {
        // Create YES and NO tokens
        OutcomeToken yesToken = new OutcomeToken("Market YES", "YES");
        OutcomeToken noToken = new OutcomeToken("Market NO", "NO");

        // Transfer collateral to this contract
        IERC20(collateralAddress).transferFrom(msg.sender, address(this), collateralAmount);
        
        // Create pool keys
        PoolKey memory yesPoolKey = PoolKey({
            currency0: Currency.wrap(collateralAddress),
            currency1: Currency.wrap(address(yesToken)),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });

        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(collateralAddress),
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
            oracle: oracle,
            creator: creator,
            yesToken: yesToken,
            noToken: noToken,
            state: MarketState.Active,
            outcome: false,
            totalCollateral: collateralAmount,
            collateralAddress: collateralAddress,
            title: title,
            description: description,
            endTimestamp: block.timestamp + duration
        });
        
        // Map both pool IDs to this market ID
        _poolToMarketId[yesPoolKey.toId()] = marketId;
        _poolToMarketId[noPoolKey.toId()] = marketId;
        
        return marketId;
    }

    //////////////////////////
    //// Internal functions //
    //////////////////////////

    function _addInitialOutcomeTokensLiquidity(bytes32 marketId) internal {
        // price at tick 0
        uint160 pricePoolQ = TickMath.getSqrtPriceAtTick(0);
        console.log("Pool price SQRTX96: %d", pricePoolQ);

        // mint token yes and no to this contract and approve them
        uint256 initialSupply = 100e18;
        OutcomeToken(_markets[marketId].yesToken).mint(address(this), initialSupply);
        OutcomeToken(_markets[marketId].noToken).mint(address(this), initialSupply);
        console.log("Approving outcome tokens to p");
        console.log("address(posm):", address(posm));
        OutcomeToken(_markets[marketId].yesToken).approve(
            address(posm),
            type(uint256).max
        );
        OutcomeToken(_markets[marketId].noToken).approve(
            address(posm),
            type(uint256).max
        );

        uint128 liquidityDelta = LiquidityAmounts.getLiquidityForAmounts(
            pricePoolQ,
            TickMath.getSqrtPriceAtTick(TickMath.MIN_TICK),
            TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK),
            initialSupply,
            initialSupply // TO DO: this should be precisely equal to what we have minted
        );

        (uint256 amount0Check, uint256 amount1Check) = LiquidityAmounts
            .getAmountsForLiquidity(
                pricePoolQ,
                TickMath.getSqrtPriceAtTick(
                    TickMath.minUsableTick(TICK_SPACING)
                ),
                TickMath.getSqrtPriceAtTick(
                    TickMath.maxUsableTick(TICK_SPACING)
                ),
                liquidityDelta
            );

        console.log("amount0Check: %d", amount0Check);
        console.log("amount1Check: %d", amount1Check);

        posm.modifyLiquidity(
            _markets[marketId].yesPoolKey,
            IPoolManager.ModifyLiquidityParams(
                TickMath.minUsableTick(TICK_SPACING),
                TickMath.maxUsableTick(TICK_SPACING),
                int256(uint256(liquidityDelta)),
                0
            ),
            new bytes(0)
        );
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
        Market memory market = _markets[marketId];
        
        // Check market is resolved
        if (market.state != MarketState.Resolved) {
            revert MarketNotResolved();
        }

        // Check if user has already claimed
        if (_hasClaimed[marketId][msg.sender]) {
            revert AlreadyClaimed();
        }

        // Get user's token balance based on winning outcome
        // Calculate share of collateral based on unclaimed tokens

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