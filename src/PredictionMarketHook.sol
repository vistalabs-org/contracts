// SPDX-License-Identifier: MIT
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
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "@uniswap/v4-core/lib/solmate/src/utils/FixedPointMathLib.sol";
import {Market, MarketState, MarketSetting, CreateMarketParams} from "./types/MarketTypes.sol";
import {OutcomeToken} from "./OutcomeToken.sol";
import {console} from "forge-std/console.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPredictionMarketHook} from "./interfaces/IPredictionMarketHook.sol";
import {PoolCreationHelper} from "./PoolCreationHelper.sol";
import {IAIOracleServiceManager} from "./interfaces/IAIOracleServiceManager.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
/// @title PredictionMarketHook - Hook for prediction market management

contract PredictionMarketHook is BaseHook, IPredictionMarketHook, Ownable, ReentrancyGuard {
    using PoolIdLibrary for PoolKey;
    using FixedPointMathLib for uint160;
    using SafeERC20 for IERC20;

    IPoolManager public poolm;
    PoolCreationHelper public poolCreationHelper;

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

    // Add a nonce counter as a state variable
    uint256 private _tokenDeploymentNonce;

    // Add a dedicated market nonce
    uint256 private _marketNonce;

    // Store Oracle address, set post-deployment
    address private _aiOracleServiceManagerAddress;

    // Custom errors
    error MarketAlreadyResolved();
    error MarketNotResolved();
    error AlreadyClaimed();
    error InvalidOracleAddress();
    error InvalidTickRange();
    error MarketNotFound();
    error MarketNotActive();
    error MarketNotClosed();
    error MarketNotInCreatedState();
    error MarketNotInResolutionOrDisputePhase();
    error NotAuthorizedToCancelMarket();
    error MarketCannotBeCancelledInCurrentState();
    error NoTokensToClaim();
    error NoTokensToRedeem();
    error InsufficientCollateralRemaining();
    error InvalidTokenAddressOrdering();
    error TickBelowMinimumValidTick();
    error TickAboveMaximumValidTick();
    error MarketIdCannotBeZero();
    error OnlyConfiguredOracleAllowed();
    error MarketNotCancelled();

    /// @notice Constructor to initialize the hook
    /// @param _poolManager The address of the Uniswap V4 PoolManager
    /// @param _poolCreationHelper The address of the PoolCreationHelper contract
    /// @param initialOwner The address to receive initial ownership
    constructor(IPoolManager _poolManager, PoolCreationHelper _poolCreationHelper, address initialOwner)
        BaseHook(_poolManager)
        Ownable(msg.sender) // Owner is deployer initially
    {
        poolm = IPoolManager(_poolManager);
        poolCreationHelper = PoolCreationHelper(_poolCreationHelper);
        _transferOwnership(initialOwner); // Transfer ownership to the intended owner
    }

    /// @notice Defines the hook permissions required by this contract
    /// @return Permissions struct indicating which hook points are implemented
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

    /// @notice Hook called before a swap occurs
    /// @dev Ensures the market associated with the pool is active before allowing the swap.
    /// @param sender The address initiating the swap
    /// @param key The PoolKey identifying the pool
    /// @param params Parameters for the swap operation
    /// @param data Arbitrary data passed by the caller
    /// @return selector The selector of this function (beforeSwap)
    /// @return deltaBefore The swap delta to apply before the swap (always zero here)
    /// @return hookData Data to be passed to the afterSwap hook (always zero here)
    function _beforeSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        bytes calldata data
    ) internal view override returns (bytes4, BeforeSwapDelta, uint24) {
        PoolId poolId = key.toId();
        Market storage market = _getMarketFromPoolId(poolId);
        if (market.state != MarketState.Active) {
            revert MarketNotActive();
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @notice Hook called before liquidity is added
    /// @dev Ensures the market is active and the provided liquidity tick range is valid for the market settings.
    /// @param sender The address adding liquidity
    /// @param key The PoolKey identifying the pool
    /// @param params Parameters for modifying liquidity
    /// @param data Arbitrary data passed by the caller
    /// @return selector The selector of this function (beforeAddLiquidity)
    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata params,
        bytes calldata data
    ) internal view override returns (bytes4) {
        PoolId poolId = key.toId();
        Market storage market = _getMarketFromPoolId(poolId);
        if (market.state != MarketState.Active) {
            revert MarketNotActive();
        }

        // Use min/max ticks from market settings
        // Note: Need to ensure min/max ticks are adjusted for tickSpacing during setting creation or here
        int24 minValidTick = (market.settings.minTick / market.settings.tickSpacing) * market.settings.tickSpacing;
        int24 maxValidTick = (market.settings.maxTick / market.settings.tickSpacing) * market.settings.tickSpacing;

        // Check that the liquidity position is entirely within the valid range defined by market settings
        if (params.tickLower < minValidTick) {
             revert TickBelowMinimumValidTick(); // Potentially rename error or add context
        }
        if (params.tickUpper > maxValidTick) {
             revert TickAboveMaximumValidTick(); // Potentially rename error or add context
        }

        return BaseHook.beforeAddLiquidity.selector;
    }

    //////////////////////////
    /// @notice Creates a new prediction market, associated Uniswap pools, and deposits initial collateral.
    /// @dev Deploys YES/NO outcome tokens using CREATE2, creates YES/collateral and NO/collateral pools,
    /// @dev transfers collateral from the creator, stores market details, and mints initial outcome tokens to the creator.
    /// @param params Struct containing all necessary parameters for market creation.
    /// @return marketId The unique identifier (keccak256 hash) for the newly created market.
    function createMarketAndDepositCollateral(CreateMarketParams calldata params) public override nonReentrant returns (bytes32) {
        // Generate a truly unique market ID
        bytes32 marketId = keccak256(
            abi.encodePacked(
                params.creator,
                params.title,
                params.description,
                _marketNonce++,
                msg.sender
            )
        );

        address collateral = params.collateralAddress;
        OutcomeToken yesToken;
        OutcomeToken noToken;
        _marketCount += 1;

        // Keep trying different salts until we get tokens with higher addresses than collateral
        uint256 attempts = 0;
        bool validTokens = false;

        while (!validTokens && attempts < 100) {
            // Generate unique salts for each attempt
            bytes32 yesSalt =
                keccak256(abi.encodePacked("YES_TOKEN", marketId, attempts, block.timestamp, _tokenDeploymentNonce++));

            bytes32 noSalt =
                keccak256(abi.encodePacked("NO_TOKEN", marketId, attempts, block.timestamp, _tokenDeploymentNonce++));

            // Deploy tokens with CREATE2
            yesToken = new OutcomeToken{salt: yesSalt}(
                string(abi.encodePacked("Market YES ", params.title)),
                string(abi.encodePacked("YES", _tokenDeploymentNonce))
            );

            noToken = new OutcomeToken{salt: noSalt}(
                string(abi.encodePacked("Market NO ", params.title)),
                string(abi.encodePacked("NO", _tokenDeploymentNonce))
            );

            // Check if both tokens have higher addresses than collateral
            if (collateral < address(yesToken) && collateral < address(noToken)) {
                validTokens = true;
            } else {
                // If not valid, increment attempts and try again
                attempts++;
            }
        }

        // If we couldn't get valid tokens after multiple attempts, revert
        if (!validTokens) {
            revert InvalidTokenAddressOrdering();
        }

        // Use settings from params
        MarketSetting memory settings = params.settings;

        // Create pool keys with guaranteed ordering using settings from params
        PoolKey memory yesPoolKey = PoolKey({
            currency0: Currency.wrap(collateral),
            currency1: Currency.wrap(address(yesToken)),
            fee: settings.fee, // Use fee from settings
            tickSpacing: settings.tickSpacing, // Use tickSpacing from settings
            hooks: IHooks(address(this))
        });

        PoolKey memory noPoolKey = PoolKey({
            currency0: Currency.wrap(collateral),
            currency1: Currency.wrap(address(noToken)),
            fee: settings.fee, // Use fee from settings
            tickSpacing: settings.tickSpacing, // Use tickSpacing from settings
            hooks: IHooks(address(this))
        });

        // Create both pools
        // Consider passing startingTick from settings if createUniswapPoolWithCollateral supports it
        poolCreationHelper.createUniswapPoolWithCollateral(yesPoolKey, settings.startingTick);
        poolCreationHelper.createUniswapPoolWithCollateral(noPoolKey, settings.startingTick);

        // Use safeTransferFrom correctly
        IERC20(collateral).safeTransferFrom(params.creator, address(this), params.collateralAmount);

        // Store market info
        console.log("Storing market info");
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
            endTimestamp: block.timestamp + params.duration,
            settings: settings // Store the settings struct
        });

        // Map both pool IDs to this market ID
        _poolToMarketId[yesPoolKey.toId()] = marketId;
        _poolToMarketId[noPoolKey.toId()] = marketId;

        // Mint initial YES and NO tokens directly to the creator based on the deposited collateral
        mintOutcomeTokensForCreator(marketId, params.collateralAmount);

        // Add market ID to the array of all markets
        _allMarketIds.push(marketId);

        return marketId;
    }

    /// @notice Allows users to mint equal amounts of YES and NO tokens by providing collateral.
    /// @dev This increases the total collateral backing the market and provides the user with outcome tokens.
    /// @param marketId The ID of the market for which to mint tokens.
    /// @param collateralAmount The amount of collateral the user is providing.
    /// @param collateralAddress The address of the collateral token being provided.
    function mintOutcomeTokens(bytes32 marketId, uint256 collateralAmount, address collateralAddress) public override {
        // Check if market exists
        if (_markets[marketId].creator == address(0)) {
            revert MarketNotFound();
        }

        // Calculate collateral to return (accounting for decimal differences)
        uint256 collateralDecimals = IERC20Metadata(collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);

        // update total collateral in the market
        _markets[marketId].totalCollateral += collateralAmount;

        // Calculate token amount to mint (adjusting for decimal differences)
        uint256 tokenAmount = collateralAmount * decimalAdjustment;

        // Mint YES and NO tokens to the user
        _markets[marketId].yesToken.mint(msg.sender, tokenAmount);
        _markets[marketId].noToken.mint(msg.sender, tokenAmount);
    }

    /// @notice Retrieves all market IDs managed by this hook contract.
    /// @return An array containing the unique IDs of all created markets.
    function getAllMarketIds() external view override returns (bytes32[] memory) {
        return _allMarketIds;
    }

    /// @notice Retrieves the full details for all markets managed by this hook.
    /// @dev Be cautious calling this on-chain for a large number of markets due to gas costs.
    /// @return An array of Market structs containing details for every market.
    function getAllMarkets() external view override returns (Market[] memory) {
        uint256 count = _allMarketIds.length;
        Market[] memory _marketList = new Market[](count); // Rename local variable

        for (uint256 i = 0; i < count; i++) {
            _marketList[i] = _markets[_allMarketIds[i]];
        }

        return _marketList;
    }

    /// @notice Retrieves a paginated list of market details.
    /// @param offset The starting index (0-based) of the markets to retrieve.
    /// @param limit The maximum number of markets to return.
    /// @return An array of Market structs for the requested page.
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

    /// @notice Returns the total number of markets created by this hook.
    /// @return The count of all markets.
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
        if (market.state != MarketState.Created) {
            revert MarketNotInCreatedState();
        }
        market.state = MarketState.Active;
        emit MarketActivated(marketId);
    }

    /// @notice Moves the market from Active to Closed (e.g., based on end time)
    /// @dev Needs logic to determine when this transition should happen (e.g., time-based)
    /// @param marketId The ID of the market
    function closeMarket(bytes32 marketId) external override {
        // Renamed from closeTrading
        Market storage market = _markets[marketId];
        if (market.state != MarketState.Active) {
            revert MarketNotActive();
        }
        market.state = MarketState.Closed; // Updated state name
        emit MarketClosed(marketId);
    }

    /// @notice Moves the market from Closed to InResolution (e.g., oracle starts process)
    /// @dev Needs logic for initiation (e.g., oracle call)
    /// @param marketId The ID of the market
    function enterResolution(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        if (market.state != MarketState.Closed) {
            revert MarketNotClosed();
        }
        market.state = MarketState.InResolution;
        // Emit ResolutionStarted event

        // Create task in AI Oracle Service Manager
        if (_aiOracleServiceManagerAddress == address(0)) revert InvalidOracleAddress();
        string memory taskName = string.concat("Resolve Market: ", market.title);
        // We need the IAIOracleServiceManager interface to call the function
        uint32 taskIndex = IAIOracleServiceManager(_aiOracleServiceManagerAddress).createMarketResolutionTask(
            taskName, marketId, address(this)
        );

        // Optional: Store the task index for reference
        // marketIdToOracleTaskIndex[marketId] = taskIndex; // Need to define this mapping if needed

        emit ResolutionStarted(marketId, taskIndex); // Emit with actual task index
    }

    /// @notice Allows oracle to resolve the market with the outcome
    /// @param marketId The ID of the market
    /// @param outcome true for YES, false for NO
    function resolveMarket(bytes32 marketId, bool outcome) external override {
        // Ensure only the configured oracle can call this
        if (msg.sender != _aiOracleServiceManagerAddress) {
            revert OnlyConfiguredOracleAllowed();
        }

        Market storage market = _markets[marketId];
        if (market.state != MarketState.InResolution && market.state != MarketState.Disputed) {
            revert MarketNotInResolutionOrDisputePhase();
        }
        market.state = MarketState.Resolved;
        market.outcome = outcome;
        emit MarketResolved(marketId, outcome, msg.sender);
    }

    /// @notice Allows oracle or creator to cancel the market
    /// @param marketId The ID of the market
    function cancelMarket(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        // Check if caller is oracle or creator
        if (msg.sender != _aiOracleServiceManagerAddress && msg.sender != market.creator) {
            revert NotAuthorizedToCancelMarket();
        }

        // Check if market can be cancelled (Created, Active, or Closed)
        if (market.state != MarketState.Created && market.state != MarketState.Active && market.state != MarketState.Closed) {
            revert MarketCannotBeCancelledInCurrentState();
        }
        market.state = MarketState.Cancelled;
        emit MarketCancelled(marketId);
    }

    /// @notice Allows a dispute process to be initiated
    /// @dev Needs logic for who can dispute and under what conditions
    /// @param marketId The ID of the market
    function disputeResolution(bytes32 marketId) external override {
        Market storage market = _markets[marketId];
        if (market.state != MarketState.Resolved) {
            revert MarketNotResolved();
        }
        market.state = MarketState.Disputed;
        emit MarketDisputed(marketId);
    }

    //////////////////////////
    //////// Core Logic ///////
    //////////////////////////

    /// @notice Allows users to claim collateral based on their winning token holdings following the Checks-Effects-Interactions pattern.
    /// @param marketId The ID of the market
    function claimWinnings(bytes32 marketId) external override nonReentrant {
        // --- Setup ---
        Market storage market = _markets[marketId];
        address sender = msg.sender; // Cache msg.sender

        // --- Checks ---
        // 1. Check market state
        if (market.state != MarketState.Resolved) {
            revert MarketNotResolved();
        }

        // 2. Check if already claimed by this user
        if (_hasClaimed[marketId][sender]) {
            revert AlreadyClaimed();
        }

        // 3. Determine winning token and get user's balance (Interaction - external read, necessary for checks)
        address winningTokenAddress;
        if (market.outcome) {
            winningTokenAddress = address(market.yesToken);
        } else {
            winningTokenAddress = address(market.noToken);
        }
        OutcomeToken winningToken = OutcomeToken(winningTokenAddress);
        uint256 tokenBalance = winningToken.balanceOf(sender);

        // 4. Check if user has winning tokens
        if (tokenBalance == 0) {
            revert NoTokensToClaim();
        }

        // 5. Calculate claim amount based on collateral decimals (Interaction - external read, necessary for checks)
        IERC20Metadata collateralTokenMeta = IERC20Metadata(market.collateralAddress);
        uint256 collateralDecimals = collateralTokenMeta.decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals); // Assumes outcome token decimals are 18
        uint256 claimAmount = tokenBalance / decimalAdjustment; // Calculate the equivalent collateral amount

        // 6. Check if sufficient collateral remains in the contract's pool
        uint256 currentlyClaimed = _claimedTokens[marketId];
        if (claimAmount > market.totalCollateral - currentlyClaimed) {
             revert InsufficientCollateralRemaining();
        }

        // --- Effects ---
        // Update state variables *before* external interactions
        _claimedTokens[marketId] = currentlyClaimed + claimAmount; // Increment total claimed amount for the market
        _hasClaimed[marketId][sender] = true; // Mark this user as having claimed

        // --- Interactions ---
        // 1. Burn the user's winning outcome tokens
        winningToken.burnFrom(sender, tokenBalance);

        // 2. Transfer the calculated collateral amount to the user
        IERC20(market.collateralAddress).safeTransfer(sender, claimAmount);

        // Emit event after successful completion of effects and interactions
        emit WinningsClaimed(marketId, sender, claimAmount);
    }

    /// @notice Allows users to redeem their collateral if the market is cancelled.
    /// @dev Each YES and NO token held is redeemed for 1/2 of the corresponding collateral unit's value.
    /// @param marketId The ID of the market
    function redeemCollateral(bytes32 marketId) external override nonReentrant {
        Market storage market = _markets[marketId];
        // --- Checks ---
        if (market.state != MarketState.Cancelled) {
            revert MarketNotCancelled();
        }

        address sender = msg.sender; // Cache msg.sender
        uint256 yesBalance = market.yesToken.balanceOf(sender);
        uint256 noBalance = market.noToken.balanceOf(sender);

        // Calculate total tokens held by the user
        uint256 totalTokens = yesBalance + noBalance;

        if (totalTokens == 0) {
            revert NoTokensToRedeem(); // User has no tokens to redeem
        }

        // Calculate the redemption amount
        // 1 Collateral Unit initially minted `decimalAdjustment` YES and `decimalAdjustment` NO tokens.
        // So, 1 Collateral Unit corresponds to `2 * decimalAdjustment` total tokens.
        // The value of 1 token (YES or NO) upon cancellation is (1 / (2 * decimalAdjustment)) Collateral Units.
        // Total Redeem Amount = totalTokens * (Value of 1 token)
        // Total Redeem Amount = totalTokens / (2 * decimalAdjustment)
        uint256 collateralDecimals = IERC20Metadata(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals); // Outcome tokens are always 18 decimals
        uint256 redeemAmount = totalTokens / (2 * decimalAdjustment); // Each token is worth half the collateral value

        // --- Effects ---
        // State changes (burning tokens) happen before external call (transfer)

        // --- Interactions ---
        // Burn ALL YES and NO tokens held by the user.
        // User must have approved the hook beforehand for both tokens.
        if (yesBalance > 0) {
            market.yesToken.burnFrom(sender, yesBalance);
        }
        if (noBalance > 0) {
            market.noToken.burnFrom(sender, noBalance);
        }

        // Transfer the calculated collateral amount to the user
        // Only transfer if there's an amount to transfer (should always be > 0 if totalTokens > 0)
        if (redeemAmount > 0) {
             IERC20(market.collateralAddress).safeTransfer(sender, redeemAmount);
        }

        // Emit an event if desired, e.g., CollateralRedeemed(marketId, sender, redeemAmount);
    }

    /// @notice Gets market details for a given pool ID.
    /// @dev A market consists of two pools (YES/collateral, NO/collateral). This resolves either pool ID to the market struct.
    /// @param poolId The PoolId of either the YES or NO token pool associated with the market.
    /// @return The Market struct containing details about the associated market.
    function markets(PoolId poolId) external view override returns (Market memory) {
        return _getMarketFromPoolId(poolId);
    }

    /// @notice Returns the total number of markets created (duplicate of getMarketCount, potentially removable if interface adjusted).
    /// @return The count of created markets.
    function marketCount() external view returns (uint256) {
        return _marketCount;
    }

    /// @notice Returns the PoolId of a market pool based on an internal index.
    /// @dev This likely corresponds to the creation order but depends on internal storage (`_marketPoolIds`). Use with caution.
    /// @param index The index in the internal mapping.
    /// @return The PoolId stored at that index.
    function marketPoolIds(uint256 index) external view override returns (PoolId) {
        return _marketPoolIds[index];
    }

    /// @notice Returns the total amount of collateral claimed for a specific market.
    /// @param marketId The ID of the market.
    /// @return The total collateral claimed so far.
    function claimedTokens(bytes32 marketId) external view override returns (uint256) {
        return _claimedTokens[marketId];
    }

    /// @notice Checks if a specific user has already claimed their winnings for a given market.
    /// @param marketId The ID of the market.
    /// @param user The address of the user to check.
    /// @return true if the user has claimed, false otherwise.
    function hasClaimed(bytes32 marketId, address user) external view override returns (bool) {
        return _hasClaimed[marketId][user];
    }

    // Helper function to get market from pool ID
    function _getMarketFromPoolId(PoolId poolId) internal view returns (Market storage) {
        bytes32 marketId = _poolToMarketId[poolId];
        if (marketId == bytes32(0)) {
            revert MarketNotFound();
        }
        return _markets[marketId];
    }

    /// @notice Retrieves market details using the market's unique ID.
    /// @param marketId The unique ID of the market.
    /// @return The Market struct containing details for the specified market.
    function getMarketById(bytes32 marketId) external view override returns (Market memory) {
        if (marketId == bytes32(0)) {
            revert MarketIdCannotBeZero();
        }
        return _markets[marketId];
    }

    /// @notice Mints initial YES and NO outcome tokens to the market creator.
    /// @dev Internal function called during market creation. Assumes collateral has already been transferred to the hook.
    /// @param marketId The ID of the market being created.
    /// @param collateralAmount The amount of collateral deposited by the creator.
    function mintOutcomeTokensForCreator(bytes32 marketId, uint256 collateralAmount) internal {
        Market storage market = _markets[marketId];
        uint256 collateralDecimals = IERC20Metadata(market.collateralAddress).decimals();
        uint256 decimalAdjustment = 10 ** (18 - collateralDecimals);
        uint256 tokenAmount = collateralAmount * decimalAdjustment;
        market.yesToken.mint(market.creator, tokenAmount);
        market.noToken.mint(market.creator, tokenAmount);
    }

    /// @notice Sets or updates the address of the AI Oracle Service Manager contract.
    /// @dev Can only be called by the owner. Emits OracleServiceManagerSet event.
    /// @param newOracleAddress The address of the new oracle service manager.
    function setOracleServiceManager(address newOracleAddress) external onlyOwner {
        if (newOracleAddress == address(0)) revert InvalidOracleAddress();
        _aiOracleServiceManagerAddress = newOracleAddress;
        emit OracleServiceManagerSet(newOracleAddress); // Emit event
    }

    /// @notice Returns the stored address of the AI Oracle Service Manager.
    /// @dev Required by the IPredictionMarketHook interface.
    /// @return The address of the configured IAIOracleServiceManager.
    function aiOracleServiceManager() public view override returns (address) {
        return _aiOracleServiceManagerAddress;
    }
}
