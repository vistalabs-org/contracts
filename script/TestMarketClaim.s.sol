// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Local Project Imports
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/**
 * @title TestMarketClaim
 * @notice This script loads core contracts, fetches all market IDs from the hook,
 *         checks if each market is RESOLVED on-chain, and if so, attempts to
 *         claim winnings for the deployer.
 * @dev Assumes addresses.json exists and is populated.
 *      Requires the target market to have already been resolved on-chain by the oracle.
 */
contract TestMarketClaim is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;

    // --- Test Contracts (Loaded/Instantiated) ---
    ERC20Mock public collateralToken; // Loaded collateral token

    // --- Loaded Config ---
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
        require(fetchedMarketIds.length > 0, "No market IDs found on the hook contract");
        console.log("Found", fetchedMarketIds.length, "market IDs.");

        // Attempt to claim winnings for each market ID found.
        for (uint256 i = 0; i < fetchedMarketIds.length; i++) {
            _attemptClaimOnMarket(fetchedMarketIds[i], deployerPrivateKey);
        }

        console.log("\nScript complete! Claim attempts finished.");
    }

    /// @notice Loads required core contract addresses and collateral token address from the `script/config/addresses.json` file.
    function _loadCoreAddresses() internal {
        console.log("\n--- Loading Core & Collateral Contract Addresses ---");
        string memory addressesFile = "script/config/addresses.json";
        string memory json = vm.readFile(addressesFile);

        hookAddress = json.readAddress(".predictionMarketHook");
        collateralTokenAddress = json.readAddress(".collateralToken"); // Load collateral token address

        require(hookAddress != address(0), "Failed to read hook address");
        require(collateralTokenAddress != address(0), "Failed to read collateral token address from addresses.json");

        console.log("  Loaded Hook Address:", hookAddress);
        console.log("  Loaded Collateral Token Address:", collateralTokenAddress);
    }

    /// @notice Instantiates remaining contract variables.
    function _initializeContracts() internal {
        hook = PredictionMarketHook(hookAddress);
        collateralToken = ERC20Mock(collateralTokenAddress);
        console.log("\nContracts instantiated.");
    }

    /// @notice Attempts to claim winnings for a specific market if it's resolved.
    function _attemptClaimOnMarket(bytes32 marketId, uint256 deployerPrivateKey) internal {
        console.log("\nProcessing Market ID for Claim:", vm.toString(marketId));

        // 1. Fetch Market State
        Market memory market;
        try hook.getMarketById(marketId) returns (Market memory m) {
            market = m;
        } catch {
            console.log("  Failed to fetch market details. Skipping claim.");
            return;
        }

        // 2. Check if Resolved
        if (market.state != MarketState.Resolved) {
            console.log("  Market is not resolved on-chain. Current state:", uint8(market.state), ". Skipping claim.");
            return;
        }
        console.log("  Market is Resolved (Outcome:", market.outcome, "). Proceeding to claim...");

        // 3. Determine Winning Token & Check Balance
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

        // 4. Check if Already Claimed
        bool alreadyClaimed;
        try hook.hasClaimed(marketId, deployer) returns (bool claimed) {
            alreadyClaimed = claimed;
        } catch {
            console.log("  Failed to check claim status. Skipping claim.");
            return;
        }
        if (alreadyClaimed) {
            console.log("  Deployer has already claimed winnings for this market. Skipping.");
            return;
        }

        // 5. Broadcast Claim Transaction
        console.log("    Attempting to broadcast claim transaction...");
        vm.startBroadcast(deployerPrivateKey);

        // Approve hook to burn the winning tokens
        console.log("      Approving hook to burn winning tokens (Amount:", balance, ")...");
        try winningToken.approve(address(hook), balance) {
            console.log("        Approval successful.");
        } catch Error(string memory reason) {
            console.log("        Approval failed:", reason);
            vm.stopBroadcast(); // Stop broadcast if approval fails
            return; // Cannot claim without approval
        } catch {
            console.log("        Unknown error during approval.");
            vm.stopBroadcast();
            return;
        }

        // Call claimWinnings
        console.log("      Calling claimWinnings...");
        uint256 collateralBalanceBefore = collateralToken.balanceOf(deployer);
        try hook.claimWinnings(marketId) {
            uint256 collateralBalanceAfter = collateralToken.balanceOf(deployer);
            console.log("        Claim winnings successful!");
            console.log(
                "        Collateral Received:",
                (collateralBalanceAfter - collateralBalanceBefore) / (10 ** collateralToken.decimals())
            );
        } catch Error(string memory reason) {
            console.log("        Claim winnings failed:", reason);
        } catch {
            console.log("        Unknown error during claim winnings.");
        }

        vm.stopBroadcast();
    }
}
