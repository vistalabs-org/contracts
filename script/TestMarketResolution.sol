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
 * @notice This script loads core contracts from addresses.json, fetches market IDs
 *         directly from the hook contract, and simulates the resolution process
 *         (close -> enter resolution -> resolve via prank) for each fetched market ID.
 * @dev Assumes addresses.json exists and is populated. Does NOT test claiming.
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
    ERC20Mock public collateralToken; // Loaded collateral token

    // --- Loaded Test Config ---
    address private oracleProxyAddress; // Loaded from addresses.json
    address private hookAddress; // Loaded from addresses.json
    address private collateralTokenAddress; // Loaded collateral token address

    // --- Script State ---
    address private deployer;

    /// @notice Main script execution function.
    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        deployer = vm.addr(deployerPrivateKey);
        console.log("Script runner (Deployer):", deployer);

        // Load addresses of already deployed core contracts.
        _loadCoreAddresses();

        // Instantiate necessary contract variables.
        _initializeContracts();

        // Fetch market IDs from the hook
        console.log("\nFetching market IDs from hook...");
        bytes32[] memory fetchedMarketIds = hook.getAllMarketIds();
        require(fetchedMarketIds.length > 0, "No market IDs found on the hook contract to resolve");
        console.log("Found", fetchedMarketIds.length, "market IDs.");

        // Resolve each market found.
        _resolveMarkets(fetchedMarketIds, deployerPrivateKey);

        console.log("\nScript complete! Market resolution simulated."); // Updated log
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

    /// @notice Instantiates remaining contract variables.
    function _initializeContracts() internal {
        hook = PredictionMarketHook(hookAddress);
        oracleProxy = AIOracleServiceManager(payable(oracleProxyAddress));
        collateralToken = ERC20Mock(collateralTokenAddress);
        console.log("\nContracts instantiated.");
    }

    /// @notice Loops through provided market IDs and simulates the resolution process.
    function _resolveMarkets(bytes32[] memory fetchedMarketIds, uint256 deployerPrivateKey) internal {
        // Accept IDs as parameter
        console.log("\n--- Simulating Market Resolution Process (No Claiming) ---"); // Updated log

        for (uint256 i = 0; i < fetchedMarketIds.length; i++) {
            // Use fetchedMarketIds
            bytes32 marketId = fetchedMarketIds[i]; // Get ID from array
            console.log("\nProcessing Market ID:", vm.toString(marketId));
            Market memory market = hook.getMarketById(marketId);

            // 1. Check Initial State (Should be Active)
            if (market.state != MarketState.Active) {
                console.log(
                    "  Market is not Active. Current state:", uint8(market.state), ". Skipping resolution simulation."
                );
                continue; // Skip if market wasn't successfully created/activated earlier
            }
            console.log("  Market state is Active. Proceeding...");

            // 2. Warp Time Past End Date (Outside broadcast)
            if (block.timestamp <= market.endTimestamp) {
                vm.warp(market.endTimestamp + 1 days); // Warp 1 day past end
                console.log("  Warped time past endTimestamp. New timestamp:", block.timestamp);
            } else {
                console.log("  Time is already past endTimestamp.");
            }

            // --- Broadcast Block 1: Close and Enter Resolution ---
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
            // Fetch state *within* broadcast to ensure we see the Closed state
            MarketState stateBeforeEnter = hook.getMarketById(marketId).state;
            console.log("    State read before enterResolution (inside broadcast):", uint8(stateBeforeEnter));
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
            // Stop Broadcast Block 1
            vm.stopBroadcast();
            // --------------------------------------------------------

            // Optional Delay for state propagation if needed on live networks/forks
            // vm.roll(block.number + 1);
            // vm.sleep(1000); // e.g., 1 second

            // --- Pranked Call: Resolve Market (Simulated, NOT broadcast) ---
            // console.log("  Simulating Oracle resolution (Outcome: YES)... (via prank)");
            // vm.prank(oracleProxyAddress); // Oracle Proxy is the expected msg.sender
            // try hook.resolveMarket(marketId, true) {
            //     // true for YES
            //     console.log("    Market resolved successfully by simulated Oracle.");
            // } catch Error(string memory reason) {
            //     console.log("    Failed to resolve market (pranked call):", reason);
            //     // Don't stop broadcast here as we are not in one
            //     continue; // Skip rest if resolution fails
            // } catch {
            //     console.log("    Unknown error resolving market (pranked call).");
            //     continue;
            // }
            // Prank automatically stops after one call
            // -------------------------------------------------------------

            // --- Verification Only --- (No Claiming Broadcast)
            // Verify InResolution State after stopping before resolution
            market = hook.getMarketById(marketId); // Refresh state
            if (market.state == MarketState.InResolution) {
                // Check for InResolution now
                console.log("    Market state verified as InResolution.");
            } else {
                console.log(
                    "    Market state IS NOT InResolution after enterResolution call. State:", uint8(market.state)
                );
                // ", Outcome:", market.outcome // Outcome is not set yet
            }
            // End of loop for this market
        }
    }

    // add this to be excluded from coverage report
    function test() public {}
}
