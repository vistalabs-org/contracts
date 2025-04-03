pragma solidity ^0.8.24;

import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {Market, MarketState} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPredictionMarketHook} from "./interfaces/IPredictionMarketHook.sol";
import {PoolCreationHelper} from "./PoolCreationHelper.sol";
import {CreateMarketParams} from "./types/MarketTypes.sol";
import {IAIOracleServiceManager} from "./interfaces/IAIOracleServiceManager.sol";
/// @title PredictionMarketHook - Hook for prediction market management

contract PredictionMarketHook is BaseHook, IPredictionMarketHook {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint160;

    IPoolManager public poolm;
    PoolCreationHelper public poolCreationHelper;
    int24 public TICK_SPACING = 100;
    // Market ID counter
    uint256 private _marketCount;
    // mapping(uint256 => PoolId) private _marketPoolIds; // Removed as unused and conflicting with interface getter
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

    // Add a nonce counter as a state variable
    uint256 private _tokenDeploymentNonce;

    // Store Oracle Service Manager as address
    address public immutable aiOracleServiceManager;

    error MarketAlreadyResolved();
    error MarketNotResolved();
    error AlreadyClaimed();

    // --- Events Removed (duplicates from interface) ---
    // event PoolCreated(PoolId poolId);
    // event WinningsClaimed(bytes32 indexed marketId, address indexed user, uint256 amount);

    constructor(IPoolManager _poolManager, PoolCreationHelper _poolCreationHelper, address _aiOracleServiceManager)
        BaseHook(_poolManager)
    {
        require(_aiOracleServiceManager != address(0), "Invalid Oracle Service Manager");
        poolm = IPoolManager(_poolManager);
        poolCreationHelper = PoolCreationHelper(_poolCreationHelper);
        aiOracleServiceManager = _aiOracleServiceManager; // Store address
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

    function _beforeSwap(address sender, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata data)
        internal view override returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId poolId = key.toId();
        Market storage market = _getMarketFromPoolId(poolId);
        require(market.state == MarketState.Active, "Market not open for trading");
        // Call BaseHook's implementation? Or is logic fully custom?
        // Assuming custom logic here based on original code.
        // If BaseHook logic is needed: return BaseHook._beforeSwap(sender, key, params, data);
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        Market storage market = _getMarketFromPoolId(poolId);
        require(market.state == MarketState.Active, "Market not active for adding liquidity");

        int24 minValidTick = -9200;
        int24 maxValidTick = -100;
        minValidTick = (minValidTick / TICK_SPACING) * TICK_SPACING;
        maxValidTick = (maxValidTick / TICK_SPACING) * TICK_SPACING;

        require(
            params.tickLower >= minValidTick && params.tickUpper <= maxValidTick,
            "Position must be within 0.01-0.99 price range"
        );
        // Call BaseHook's implementation? Or is logic fully custom?
        // Assuming custom logic here based on original code.
        // If BaseHook logic is needed: return BaseHook._beforeAddLiquidity(sender, key, params, data);
        return BaseHook.beforeAddLiquidity.selector;
    }

    //////////////////////////
    function createMarketAndDepositCollateral(CreateMarketParams calldata params) public override returns (bytes32) {
        // Generate a unique market ID first
        bytes32 marketId = keccak256(abi.encodePacked(
            params.creator,
            params.title,
            params.description,
            block.timestamp
        ));
        
        // Use the marketId in the salt to ensure uniqueness
        bytes32 yesSalt = keccak256(abi.encodePacked(
            "YES_TOKEN", 
            marketId, 
            params.collateralAddress, 
            _tokenDeploymentNonce++
        ));
        bytes32 noSalt = keccak256(abi.encodePacked(
            "NO_TOKEN", 
            marketId, 
            params.collateralAddress, 
            _tokenDeploymentNonce++));
        
        // Create tokens with CREATE2 to get deterministic addresses
        OutcomeToken yesToken = new OutcomeToken{salt: yesSalt}("Market YES", "YES");
        OutcomeToken noToken = new OutcomeToken{salt: noSalt}("Market NO", "NO");
        
        // Force correct ordering if needed
        address collateral = params.collateralAddress;
        if (collateral > address(yesToken)) {
            // Deploy again with modified salt to get higher address
            yesSalt = keccak256(abi.encodePacked("YES_TOKEN_HIGHER", marketId, params.collateralAddress, _tokenDeploymentNonce++));
            yesToken = new OutcomeToken{salt: yesSalt}("Market YES", "YES");
        }
        
        if (collateral > address(noToken)) {
            // Deploy again with modified salt to get higher address
            noSalt = keccak256(abi.encodePacked("NO_TOKEN_HIGHER", marketId, params.collateralAddress, _tokenDeploymentNonce++));
            noToken = new OutcomeToken{salt: noSalt}("Market NO", "NO");
        }
        
        // Verify correct ordering
        assert(collateral < address(yesToken));
        assert(collateral < address(noToken));
        
        // Create pool keys with guaranteed ordering
        PoolKey memory yesPoolKey = PoolKey({
            currency0: Currency.wrap(collateral),
            currency1: Currency.wrap(address(yesToken)),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });
        
        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(collateral),
            currency1: Currency.wrap(address(noToken)),
            fee: 10000,
            tickSpacing: 100,
            hooks: IHooks(address(this))
        });
        
        // Create both pools
        console.log("Creating both pools");
        // The PoolCreationHelper currently sets its own initial price internally.
        // Passing 'true' because collateral is token0 in both pool keys.
        poolCreationHelper.createUniswapPoolWithCollateral(yesPoolKey, true);
        poolCreationHelper.createUniswapPoolWithCollateral(noPoolKey, true);

        // Emit PoolCreated Events (moved from constructor of helper?)
        emit PoolCreated(yesPoolKey.toId());
        emit PoolCreated(noPoolKey.toId());

        console.log("Storing market info");
        _markets[marketId] = Market({
            yesPoolKey: yesPoolKey,
            noPoolKey: noPoolKey,
            oracle: address(aiOracleServiceManager), // Oracle is the manager address
            creator: params.creator,
            yesToken: yesToken,
            noToken: noToken,
            state: MarketState.Created, // Use Created state
            outcome: false,
            totalCollateral: 0, // Initialize collateral to 0 before transfer
            collateralAddress: params.collateralAddress,
            title: params.title,
            description: params.description,
            endTimestamp: block.timestamp + params.duration,
            curveId: params.curveId        
        });

        IERC20(params.collateralAddress).transferFrom(msg.sender, address(this), params.collateralAmount);
        _markets[marketId].totalCollateral = params.collateralAmount;

        mintOutcomeTokensForCreator(marketId, params.collateralAmount);

        // Add market ID to the array of all markets
        _allMarketIds.push(marketId);

        // Map both pool IDs to this market ID
        _poolToMarketId[yesPoolKey.toId()] = marketId;
        _poolToMarketId[noPoolKey.toId()] = marketId;

        return marketId;
    }

    // mint YES / NO tokens based on collateral amount
    // Users can mint based on current price to provide liquidity to the market
    function mintOutcomeTokens(bytes32 marketId, uint256 collateralAmount) public {
        Market memory market = _markets[marketId];

        // Calculate collateral to return (accounting for decimal differences)
        // YES/NO tokens have 18 decimals, collateral might have different decimals
        uint256 collateralDecimals = ERC20(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);

        // Take collateral from the user
        IERC20(market.collateralAddress).transferFrom(msg.sender, address(this), collateralAmount);

        // update total collateral in the market
        market.totalCollateral += collateralAmount;

        // Calculate token amount to mint (adjusting for decimal differences)
        uint256 tokenAmount = collateralAmount * decimalAdjustment;

        // Mint YES and NO tokens to the user
        market.yesToken.mint(msg.sender, tokenAmount);
        market.noToken.mint(msg.sender, tokenAmount);
    }

    // Function to get all market IDs
    function getAllMarketIds() external view override returns (bytes32[] memory) {
        return _allMarketIds;
    }

    // Function to get all markets with details
    function getAllMarkets() external view override returns (Market[] memory) {
        uint256 count = _allMarketIds.length;
        Market[] memory _marketList = new Market[](count); // Rename local variable

        for (uint256 i = 0; i < count; i++) {
            _marketList[i] = _markets[_allMarketIds[i]];
        }

        return _marketList;
    }

    // Function to get markets with pagination
    function getMarkets(uint256 offset, uint256 limit) external view override returns (Market[] memory) {
        uint256 count = _allMarketIds.length;

        // Ensure offset is valid
        if (offset >= count) {
            return new Market[](0);
        }

        // Calculate actual limit
        uint256 actualLimit = (offset + limit > count) ? count - offset : limit;

        Market[] memory _marketList = new Market[](actualLimit); // Rename local variable

        for (uint256 i = 0; i < actualLimit; i++) {
            _marketList[i] = _markets[_allMarketIds[offset + i]];
        }

        return _marketList;
    }

    // Function to get market count - RENAME back to match interface
    function getMarketCount() external view override returns (uint256) {
        return _allMarketIds.length;
    }

    //////////////////////////
    //////// State Transitions //////
    //////////////////////////

    /// @notice Activates a market, allowing trading and liquidity provision.
    /// @dev Can only be called when the market is in the Created state.
    /// @param marketId The ID of the market to activate.
    function activateMarket(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        require(market.state == MarketState.Created, "Market not in created state");
        // Add permission checks if needed (e.g., only creator or admin)
        // require(msg.sender == market.creator, "Only creator can activate");
        market.state = MarketState.Active;
        emit MarketActivated(marketId);
    }

    /// @notice Moves the market from Active to Closed (e.g., based on end time)
    /// @dev Needs logic to determine when this transition should happen (e.g., time-based)
    /// @param marketId The ID of the market
    function closeMarket(bytes32 marketId) external override { // Renamed from closeTrading
        Market storage market = _markets[marketId];
        require(market.state == MarketState.Active, "Market not active");
        // Add permission checks (e.g., only callable by specific role or after endTimestamp)
        // require(block.timestamp >= market.endTimestamp, "Trading period not ended");
        market.state = MarketState.Closed; // Updated state name
        emit MarketClosed(marketId);
    }

    /// @notice Moves the market from Closed to InResolution (e.g., oracle starts process)
    /// @dev Needs logic for initiation (e.g., oracle call)
    /// @param marketId The ID of the market
    function enterResolution(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        require(market.state == MarketState.Closed, "Market not closed"); // Check for Closed state
        // Add permission checks (e.g., only callable by oracle)
        // require(msg.sender == market.oracle, "Only oracle can initiate resolution");
        market.state = MarketState.InResolution;
        // Emit ResolutionStarted event

        // Create task in AI Oracle Service Manager (cast address to interface)
        string memory taskName = string.concat("Resolve Market: ", market.title);
        uint32 taskIndex = IAIOracleServiceManager(aiOracleServiceManager).createMarketResolutionTask(
            taskName,
            marketId,
            address(this)
        );

        // Optional: Store the task index for reference
        // marketIdToOracleTaskIndex[marketId] = taskIndex; // Need to define this mapping if needed

        emit ResolutionStarted(marketId, taskIndex);
    }

    /// @notice Allows oracle to resolve the market with the outcome
    /// @param marketId The ID of the market
    /// @param outcome true for YES, false for NO
    function resolveMarket(bytes32 marketId, bool outcome) external override {
        Market storage market = _markets[marketId];
        // Check if caller is oracle
        if (msg.sender != aiOracleServiceManager) {
            revert MarketNotResolved();
        }

        // Check if market is in a resolvable state (InResolution or Disputed)
        require(
            market.state == MarketState.InResolution || market.state == MarketState.Disputed,
            "Market not in resolution or dispute phase"
        );

        // Update market state and outcome
        market.state = MarketState.Resolved;
        market.outcome = outcome;
        // Emit MarketResolved event
        emit MarketResolved(marketId, outcome, msg.sender);
    }

    /// @notice Allows oracle or creator to cancel the market
    /// @param marketId The ID of the market
    function cancelMarket(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        // Check if caller is oracle or creator
        if (msg.sender != aiOracleServiceManager && msg.sender != market.creator) {
            revert("Not authorized to cancel");
        }

        // Check if market can be cancelled (Created, Active, or Closed)
        require(
            market.state == MarketState.Created || market.state == MarketState.Active || market.state == MarketState.Closed,
            "Market cannot be cancelled in current state"
        );

        // Update market state
        market.state = MarketState.Cancelled;
        // Emit MarketCancelled event
        emit MarketCancelled(marketId);
    }

    /// @notice Allows a dispute process to be initiated
    /// @dev Needs logic for who can dispute and under what conditions
    /// @param marketId The ID of the market
    function disputeResolution(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        // Can only dispute a market that is currently Resolved
        require(market.state == MarketState.Resolved, "Market not resolved");
        // Add permission checks and dispute mechanism logic (e.g., staking collateral)
        market.state = MarketState.Disputed; // Use Disputed state
        // Emit MarketDisputed event
        emit MarketDisputed(marketId);
    }

    //////////////////////////
    //////// Core Logic ///////
    //////////////////////////

    /// @notice Allows users to claim collateral based on their winning token holdings
    /// @param marketId The ID of the market
    function claimWinnings(bytes32 marketId) external override {
        Market storage market = _markets[marketId];

        // Check market is *Resolved*
        require(market.state == MarketState.Resolved, "Market not resolved");

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
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);

        // Calculate claim amount
        uint256 claimAmount = tokenBalance / decimalAdjustment;
        console.log("claim amount: %s", claimAmount);

        // Ensure there's enough collateral left to claim

        uint256 remainingCollateral = market.totalCollateral - _claimedTokens[marketId];
        console.log("remaining collateral: %s", remainingCollateral);
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

    /// @notice Allows users to redeem their collateral if the market is cancelled
    /// @param marketId The ID of the market
    function redeemCollateral(bytes32 marketId) external override {
        Market storage market = _markets[marketId];

        // Check market is *Cancelled*
        require(market.state == MarketState.Cancelled, "Market not cancelled");

        // Get user's balance of YES and NO tokens
        uint256 yesBalance = market.yesToken.balanceOf(msg.sender);
        uint256 noBalance = market.noToken.balanceOf(msg.sender);

        // Total tokens represent the user's share of the original collateral
        uint256 totalTokens = yesBalance + noBalance;
        require(totalTokens > 0, "No tokens to redeem");

        // Calculate collateral to return (accounting for decimal differences)
        uint256 collateralDecimals = ERC20(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 redeemAmount = totalTokens / decimalAdjustment;

        // Burn YES and NO tokens
        if (yesBalance > 0) {
            market.yesToken.burnFrom(msg.sender, yesBalance);
        }
        if (noBalance > 0) {
            market.noToken.burnFrom(msg.sender, noBalance);
        }

        // Transfer collateral back to user
        IERC20(market.collateralAddress).transfer(msg.sender, redeemAmount);

        // Mark user as redeemed (optional, depending on if multiple redemptions are possible)
        // _hasRedeemed[marketId][msg.sender] = true;

        // Emit event
        // emit CollateralRedeemed(marketId, msg.sender, redeemAmount);
    }

    // Implement getters manually
    function markets(PoolId poolId) external view override returns (Market memory) {
        return _getMarketFromPoolId(poolId);
    }

    function claimedTokens(bytes32 marketId) external view override returns (uint256) {
        return _claimedTokens[marketId];
    }

    function hasClaimed(bytes32 marketId, address user) external view override returns (bool) {
        return _hasClaimed[marketId][user];
    }

    // Helper function to get market from pool ID
    function _getMarketFromPoolId(PoolId poolId) internal view returns (Market storage) {
        bytes32 marketId = _poolToMarketId[poolId];
        require(marketId != bytes32(0), "Market not found");
        return _markets[marketId];
    }

    function getMarketById(bytes32 marketId) external view override returns (Market memory) {
        require(marketId != bytes32(0), "Market ID cannot be zero"); // Add basic check
        // Add check if market actually exists? Optional, depends on desired behavior for invalid IDs
        // require(_markets[marketId].creator != address(0), "Market not found");
        return _markets[marketId];
    }

    function mintOutcomeTokensForCreator(bytes32 marketId, uint256 collateralAmount) internal {
        Market storage market = _markets[marketId];

        uint256 collateralDecimals = ERC20(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 tokenAmount = collateralAmount * decimalAdjustment;

        market.yesToken.mint(market.creator, tokenAmount);
        market.noToken.mint(market.creator, tokenAmount);
    }
}
