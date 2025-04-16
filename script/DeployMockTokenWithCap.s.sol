// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {ERC20MockWithCap} from "../test/utils/ERC20MockWithCap.sol"; // Adjust path to your contract

contract DeployMockTokenWithCap is Script {
    string constant TOKEN_NAME = "Test Token";
    string constant TOKEN_SYMBOL = "TST";
    uint8 constant TOKEN_DECIMALS = 6;
    // MAX_MINT_PER_WALLET is immutable in the contract
    uint256 constant INITIAL_MINT_AMOUNT = 1_000_000 * 10**TOKEN_DECIMALS; // 1 Million tokens

    function run() external returns (ERC20MockWithCap) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY"); // Or use another key source
        address deployerAddress = vm.addr(deployerPrivateKey);

        console.log("Deploying ERC20MockWithCap...");
        console.log("  Name:", TOKEN_NAME);
        console.log("  Symbol:", TOKEN_SYMBOL);
        console.log("  Decimals:", TOKEN_DECIMALS);
        console.log("  Owner (Deployer):", deployerAddress);
        console.log("  Max Mint Per Wallet (Immutable): 100e18"); // Informational
        console.log("  Initial mint to deployer:", INITIAL_MINT_AMOUNT / (10**TOKEN_DECIMALS));

        vm.startBroadcast(deployerPrivateKey);

        ERC20MockWithCap mockToken = new ERC20MockWithCap(
            TOKEN_NAME,
            TOKEN_SYMBOL,
            TOKEN_DECIMALS,
            deployerAddress // Set the deployer as the initial owner
        );

        // --- Mint initial tokens to deployer --- 
        console.log("Minting initial supply to deployer...");
        mockToken.mint(deployerAddress, INITIAL_MINT_AMOUNT);
        // --- End minting ---

        vm.stopBroadcast();

        console.log("ERC20MockWithCap deployed at:", address(mockToken));
        console.log("Deployer balance:", mockToken.balanceOf(deployerAddress) / (10**TOKEN_DECIMALS));
        return mockToken;
    }
}
