// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Local Project Imports
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {IPredictionMarketHook} from "../src/interfaces/IPredictionMarketHook.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol"; // Removed CreateMarketParams
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {IAIAgentRegistry} from "../src/interfaces/IAIAgentRegistry.sol";
import {IAIOracleServiceManager} from "../src/interfaces/IAIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

// Uniswap Imports
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";

/**
 * @title TestMarketResolution
 * @notice This script loads core contracts from addresses.json, loads market data
 *         (collateral address, market IDs) from test_markets.json,
 *         and simulates the resolution process (close -> enter resolution -> resolve -> claim)
 *         for each loaded market ID.
 * @dev Assumes addresses.json and test_markets.json exist and are populated.
 */
contract TestMarketResolution is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    AIAgentRegistry public registry;
    AIOracleServiceManager public oracleProxy;
    AIAgent public agent;
    PoolManager public manager;
    PoolCreationHelper public poolCreationHelper;
    PredictionMarketHook public hook;

    // --- Test Contracts (Loaded/Instantiated) ---
    ERC20Mock public collateralToken; // Loaded from test_markets.json

    // --- Loaded Test Config ---
    bytes32[] private marketIds; // Loaded from file
    address private oracleProxyAddress; // Loaded from addresses.json
    address private hookAddress; // Loaded from addresses.json
    address private collateralTokenAddress; // Loaded from test_markets.json

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
        // Instantiate necessary contract variables.
        _initializeContracts();

        // Resolve each market found in the file.
        _resolveMarkets(deployerPrivateKey);

        console.log("\nScript complete! Market resolution tested.");
    }

    /// @notice Loads required core contract addresses and collateral token address from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory addressesFile = "script/config/addresses.json";
        string memory json = vm.readFile(addressesFile);

        registry = AIAgentRegistry(json.readAddress(".aiAgentRegistry"));
        oracleProxyAddress = json.readAddress(".aiOracleServiceManagerProxy");
        agent = AIAgent(json.readAddress(".aiAgent"));
        manager = PoolManager(json.readAddress(".poolManager"));
        poolCreationHelper = PoolCreationHelper(json.readAddress(".poolCreationHelper"));
        hookAddress = json.readAddress(".predictionMarketHook");
        collateralTokenAddress = json.readAddress(".collateralToken"); // Load collateral token address

        require(address(registry) != address(0), "Failed to read registry address");
        require(oracleProxyAddress != address(0), "Failed to read oracle proxy address");
        require(address(agent) != address(0), "Failed to read agent address");
        require(address(manager) != address(0), "Failed to read manager address");
        require(address(poolCreationHelper) != address(0), "Failed to read helper address");
        require(hookAddress != address(0), "Failed to read hook address");
        require(collateralTokenAddress != address(0), "Failed to read collateral token address from addresses.json");

        console.log("  Loaded Registry:", address(registry));
        console.log("  Loaded Oracle Proxy Address:", oracleProxyAddress);
        console.log("  Loaded Agent:", address(agent));
        console.log("  Loaded PoolManager:", address(manager));
        console.log("  Loaded PoolCreationHelper:", address(poolCreationHelper));
        console.log("  Loaded Hook Address:", hookAddress);
        console.log("  Loaded Collateral Token Address:", collateralTokenAddress);
    }

    /// @notice Loads test market IDs from test_markets.json.
    function _loadMarketData() internal {
        console.log("\n--- Loading Test Market IDs ---");
        string memory filePath = "script/config/test_markets.json";
        string memory json = vm.readFile(filePath);

        string[] memory marketIdStrings = json.readStringArray(".marketIds");
        marketIds = new bytes32[](marketIdStrings.length);
        string memory logIds = "[";
        for (uint256 i = 0; i < marketIdStrings.length; i++) {
            bytes memory b = vm.parseBytes(marketIdStrings[i]);
            require(b.length == 32, "Invalid bytes32 string length");
            marketIds[i] = bytesToBytes32(b, 0);
            logIds = string.concat(logIds, vm.toString(marketIds[i]));
            if (i < marketIds.length - 1) {
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
        oracleProxy = AIOracleServiceManager(payable(oracleProxyAddress));
        collateralToken = ERC20Mock(collateralTokenAddress);
        console.log("\nContracts instantiated.");
    }

    /// @notice Loops through loaded market IDs and simulates the resolution process.
    function _resolveMarkets(uint256 deployerPrivateKey) internal {
        console.log("\n--- Testing Market Resolution Process ---");

        for (uint256 i = 0; i < marketIds.length; i++) {
            bytes32 marketId = marketIds[i];
            console.log("\nProcessing Market ID:", vm.toString(marketId));
            Market memory market = hook.getMarketById(marketId);

            // 1. Check Initial State (Should be Active)
            if (market.state != MarketState.Active) {
                console.log(
                    "  Market is not Active. Current state:", uint8(market.state), ". Skipping resolution test."
                );
                continue; // Skip if market wasn't successfully created/activated earlier
            }
            console.log("  Market state is Active. Proceeding...");

            // 2. Warp Time Past End Date
            if (block.timestamp <= market.endTimestamp) {
                vm.warp(market.endTimestamp + 1 days); // Warp 1 day past end
                console.log("  Warped time past endTimestamp. New timestamp:", block.timestamp);
            } else {
                console.log("  Time is already past endTimestamp.");
            }

            // Need broadcast for state changes
            vm.startBroadcast(deployerPrivateKey);

            // 3. Close Market
            console.log("  Closing market...");
            try hook.closeMarket(marketId) {
                console.log("    Market closed successfully.");
            } catch Error(string memory reason) {
                console.log("    Failed to close market:", reason);
                vm.stopBroadcast(); // Stop broadcast if this step fails
                continue; // Skip rest for this market
            } catch {
                console.log("    Unknown error closing market.");
                vm.stopBroadcast();
                continue;
            }

            // 4. Enter Resolution Phase
            console.log("  Entering resolution phase...");
            MarketState stateBeforeEnter = hook.getMarketById(marketId).state;
            console.log("    State before enterResolution:", uint8(stateBeforeEnter));
            require(stateBeforeEnter == MarketState.Closed, "Market must be Closed to enter resolution");

            try hook.enterResolution(marketId) {
                console.log("    Entered resolution phase successfully.");
            } catch Error(string memory reason) {
                console.log("    Failed to enter resolution:", reason);
                vm.stopBroadcast();
                continue;
            } catch {
                console.log("    Unknown error entering resolution.");
                vm.stopBroadcast();
                continue;
            }

            vm.stopBroadcast(); // Stop broadcast before prank

            // 5. Simulate Oracle Resolving (e.g., YES)
            console.log("  Simulating Oracle resolution (Outcome: YES)...");
            vm.prank(oracleProxyAddress); // Oracle Proxy is the expected msg.sender
            try hook.resolveMarket(marketId, true) {
                // true for YES
                console.log("    Market resolved successfully by simulated Oracle.");
            } catch Error(string memory reason) {
                console.log("    Failed to resolve market:", reason);
                continue; // Skip claim test if resolution fails
            } catch {
                console.log("    Unknown error resolving market.");
                continue;
            }

            // 6. Verify Resolved State
            market = hook.getMarketById(marketId); // Refresh state
            require(market.state == MarketState.Resolved, "Market state should be Resolved");
            require(market.outcome == true, "Market outcome should be YES (true)");
            console.log("    Market state verified as Resolved (Outcome: YES).");

            // 7. (Optional) Attempt to Claim Winnings
            _attemptClaimWinnings(marketId, deployerPrivateKey);
        }
    }

    /// @notice Attempts to claim winnings for a resolved market.
    function _attemptClaimWinnings(bytes32 marketId, uint256 deployerPrivateKey) internal {
        console.log("  Attempting to claim winnings...");
        Market memory market = hook.getMarketById(marketId); // Get latest state
        require(market.state == MarketState.Resolved, "Market must be resolved to claim");

        OutcomeToken winningToken;
        if (market.outcome) {
            // true = YES wins
            winningToken = market.yesToken;
            console.log("    Winning token: YES");
        } else {
            // false = NO wins
            winningToken = market.noToken;
            console.log("    Winning token: NO");
        }

        uint256 balance = winningToken.balanceOf(deployer);
        console.log("    Deployer winning token balance:", balance / 1e18);

        if (balance == 0) {
            console.log("    Deployer has no winning tokens. Skipping claim.");
            return;
        }

        // Start broadcast for claim transaction
        vm.startBroadcast(deployerPrivateKey);

        // Approve hook to burn the winning tokens
        console.log("    Approving hook to burn winning tokens...");
        try winningToken.approve(address(hook), balance) {
            console.log("      Approval successful.");
        } catch Error(string memory reason) {
            console.log("      Approval failed:", reason);
            vm.stopBroadcast();
            return; // Cannot claim without approval
        } catch {
            console.log("      Unknown error during approval.");
            vm.stopBroadcast();
            return;
        }

        // Call claimWinnings
        console.log("    Calling claimWinnings...");
        try hook.claimWinnings(marketId) {
            console.log("      Claim winnings successful!");
            // Optional: Add balance checks after claim
        } catch Error(string memory reason) {
            console.log("      Claim winnings failed:", reason);
        } catch {
            console.log("      Unknown error during claim winnings.");
        }

        vm.stopBroadcast();
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
