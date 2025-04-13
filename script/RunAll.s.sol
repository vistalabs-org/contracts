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
    // Define error patterns as bytes constants
    bytes internal constant ERROR_BYTES = bytes("Error:");
    bytes internal constant FAILED_BYTES = bytes("[Failed]");
    bytes internal constant PANIC_BYTES = bytes("panic:");

    function run() public {
        // 1. Get required environment variables
        string memory rpcUrl = vm.envString("UNISWAP_SEPOLIA_RPC_URL");
        string memory gasPrice = vm.envString("GAS_PRICE"); // Expecting value in Wei

        require(bytes(rpcUrl).length > 0, "Error: RPC_URL environment variable not set.");
        require(bytes(gasPrice).length > 0, "Error: GAS_PRICE environment variable not set.");
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
        scriptsToRun[4] = "script/TestMarketResolution.s.sol:TestMarketResolution";

        // 3. Execute scripts sequentially using vm.ffi()
        for (uint256 i = 0; i < scriptsToRun.length; i++) {
            console.log("\n============================================================");
            console.log("RUNNING SCRIPT:", scriptsToRun[i]);
            console.log("============================================================");

            // Construct the command arguments array for vm.ffi
            string[] memory cmd = new string[](13);
            cmd[0] = "forge";
            cmd[1] = "script";
            cmd[2] = scriptsToRun[i];
            cmd[3] = "--rpc-url";
            cmd[4] = rpcUrl;
            cmd[5] = "--broadcast";
            cmd[6] = "-vvv";
            cmd[7] = "--gas-price";
            cmd[8] = gasPrice;
            cmd[9] = "--retries";
            cmd[10] = "3";
            cmd[11] = "--delay";
            cmd[12] = "5";

            // Execute the command via FFI
            bytes memory outputBytes = vm.ffi(cmd);

            // Log the output from the executed script as a string
            console.log("--- Script Output ---");
            console.log(string(outputBytes));
            console.log("--- End Script Output ---");

            // Basic check for failure keywords in output using bytes comparison
            require(
                !bytesContains(outputBytes, ERROR_BYTES) && !bytesContains(outputBytes, FAILED_BYTES)
                    && !bytesContains(outputBytes, PANIC_BYTES),
                string.concat("Sub-script failed: ", scriptsToRun[i])
            );

            console.log("Finished script:", scriptsToRun[i]);
            vm.sleep(2000); // Sleep 2 seconds (2000 ms)
        }

        console.log("\n============================================================");
        console.log("All scripts executed successfully.");
        console.log("============================================================");
    }

    /**
     * @notice Checks if a byte sequence `sub` is contained within `source`.
     * @param source The bytes to search within.
     * @param sub The bytes to search for.
     * @return true if `sub` is found in `source`, false otherwise.
     */
    function bytesContains(bytes memory source, bytes memory sub) internal pure returns (bool) {
        if (source.length < sub.length || sub.length == 0) {
            return false;
        }
        // OPTIMIZATION: If lengths are equal, just compare directly
        if (source.length == sub.length) {
            return keccak256(source) == keccak256(sub);
        }

        // Iterate through the source bytes
        for (uint256 i = 0; i <= source.length - sub.length; i++) {
            bool foundMatch = true;
            // Check if the substring matches at the current position
            for (uint256 j = 0; j < sub.length; j++) {
                if (source[i + j] != sub[j]) {
                    foundMatch = false;
                    break;
                }
            }
            // If we found a match, return true
            if (foundMatch) {
                return true;
            }
        }
        // No match found
        return false;
    }

    // add this to be excluded from coverage report
    function test() public {}
}
