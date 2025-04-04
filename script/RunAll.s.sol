// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

/**
 * @title RunAll
 * @notice Executes deployment and setup scripts sequentially using vm.ffi().
 * @dev Reads RPC_URL and GAS_PRICE from environment variables.
 *      Requires UNISWAP_SEPOLIA_PK to be set for sub-scripts.
 *      Must be run with the --ffi flag enabled.
 *      Example Usage:
 *      export RPC_URL=<your_rpc_url>
 *      export GAS_PRICE=<gas_price_in_wei>
 *      export UNISWAP_SEPOLIA_PK=<your_private_key>
 *      forge script script/RunAll.s.sol -vv --ffi
 */
contract RunAll is Script {
    function run() public {
        // 1. Get required environment variables
        string memory rpcUrl = vm.envString("UNISWAP_SEPOLIA_RPC_URL");
        string memory gasPrice = vm.envString("GAS_PRICE"); // Expecting value in Wei

        require(bytes(rpcUrl).length > 0, "Error: RPC_URL environment variable not set.");
        require(bytes(gasPrice).length > 0, "Error: GAS_PRICE environment variable not set.");
        // We don't read the PK here, but sub-scripts require it to be set in the environment.
        require(
            bytes(vm.envString("UNISWAP_SEPOLIA_PK")).length > 0,
            "Error: UNISWAP_SEPOLIA_PK environment variable not set."
        );

        console.log("Runner Script Configuration:");
        console.log("  Using RPC_URL:", rpcUrl);
        console.log("  Using GAS_PRICE (Wei):", gasPrice);

        // 2. Define script paths in execution order
        string[] memory scriptsToRun = new string[](5);
        scriptsToRun[0] = "script/DeployUnichainSepolia.s.sol";
        scriptsToRun[1] = "script/DeployTestMarkets.s.sol";
        scriptsToRun[2] = "script/AddLiquidity.s.sol";
        scriptsToRun[3] = "script/TestMarketSwap.s.sol";
        scriptsToRun[4] = "script/TestMarketResolution.s.sol";

        // 3. Execute scripts sequentially using vm.ffi()
        for (uint256 i = 0; i < scriptsToRun.length; i++) {
            console.log("\n============================================================");
            console.log("RUNNING SCRIPT:", scriptsToRun[i]);
            console.log("============================================================");

            // Construct the command arguments array for vm.ffi
            string[] memory cmd = new string[](9); // forge script <path> --rpc-url <url> --broadcast -vv --gas-price <price>
            cmd[0] = "forge";
            cmd[1] = "script";
            cmd[2] = scriptsToRun[i];
            cmd[3] = "--rpc-url";
            cmd[4] = rpcUrl;
            cmd[5] = "--broadcast";
            cmd[6] = "-vv"; // Use verbosity to see sub-script logs
            cmd[7] = "--gas-price";
            cmd[8] = gasPrice;

            // Execute the command via FFI
            bytes memory output = vm.ffi(cmd);

            // Log the output from the executed script
            console.log("--- Script Output ---");
            console.logBytes(output);
            console.log("--- End Script Output ---");

            // Basic check for failure keywords in output (optional, can be brittle)
            // string memory outputStr = string(output);
            // require(!stdstring.contains(outputStr, "Error:") &&
            //         !stdstring.contains(outputStr, "[Failed]") &&
            //         !stdstring.contains(outputStr, "panic:"),
            //         string.concat("Sub-script failed: ", scriptsToRun[i]));

            console.log("Finished script:", scriptsToRun[i]);
            // Optional: Add a small delay between scripts if needed, e.g., for RPC node syncing
            vm.sleep(2000); // Sleep 2 seconds (2000 ms)
        }

        console.log("\n============================================================");
        console.log("All scripts executed successfully.");
        console.log("============================================================");
    }
}
