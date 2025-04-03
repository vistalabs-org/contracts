// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

contract DeployOracleSepolia is Script {
    address public oracle;
    address public registry;
    address public agent;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        
        // Start broadcasting with higher gas limit
        vm.startBroadcast(deployerPrivateKey);
        
        deployAIOracleComponents(deployerPrivateKey);
        
        // End broadcasting
        vm.stopBroadcast();
        
        // Log addresses (no broadcasting needed)
        logAIOracleAddresses();
    }

    function deployAIOracleComponents(uint256 deployerPrivateKey) internal {
        console.log("Deploying AI Oracle components to Unichain Sepolia...");
        
        // Use this test contract address for all AVS middleware components
        address avsDirectory = 0x055733000064333CaDDbC92763c58BF0192fFeBf;
        address stakeRegistry = 0xdfB5f6CE42aAA7830E94ECFCcAd411beF4d4D5b6;
        address rewardsCoordinator = 0xAcc1fb458a1317E886dB376Fc8141540537E68fE;
        address delegationManager = 0xA44151489861Fe9e3055d95adC98FbD462B948e7;
        address allocationManager = 0x78469728304326CBc65f8f95FA756B0B73164462;
        
        // Get the deployer address directly
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);
        
        // Deploy Oracle with a try/catch to detect errors
        try new AIOracleServiceManager() returns (AIOracleServiceManager oracleContract) {
            // Add this right after deploying the oracle
            // Create a proxy for proper initialization
            TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
                address(oracleContract),
                deployer,  // admin of the proxy
                abi.encodeWithSelector(
                    oracleContract.initialize.selector,
                    deployer,  // initialOwner
                    deployer,  // rewardsInitiator
                    1,         // minimumResponses (test mode)
                    5100       // consensusThreshold
                )
            );

            // Now use the proxy address instead
            oracle = address(proxy);
            console.log("Oracle proxy deployed at:", oracle);
            
            // CREATE A NEW CONTRACT INSTANCE THAT POINTS TO THE PROXY
            AIOracleServiceManager proxyContract = AIOracleServiceManager(oracle);

            // Now call through the proxy contract
            try proxyContract.updateConsensusParameters(1, 5100) {
                console.log("Updated consensus parameters successfully");
            } catch Error(string memory reason) {
                console.log("Failed to update consensus parameters:", reason);
            }
            
            // Add test operator through the proxy
            try proxyContract.addTestOperator(0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266) {
                console.log("Added test operator successfully");
            } catch Error(string memory reason) {
                console.log("Failed to add test operator:", reason);
            }
            
            // Check current values
            console.log("Current minimumResponses:", oracleContract.minimumResponses());
            console.log("Test mode active:", oracleContract.minimumResponses() == 1);
            
            // Continue with other deployments only if Oracle deployment succeeds
            try new AIAgentRegistry(oracle) returns (AIAgentRegistry registryContract) {
                registry = address(registryContract);
                console.log("AIAgentRegistry deployed at:", registry);
                
                try new AIAgent() returns (AIAgent agentContract) {
                    agent = address(agentContract);
                    console.log("AIAgent deployed at:", agent);
                    
                    // Register the agent in the registry
                    try AIAgentRegistry(registry).registerAgent(agent) {
                        console.log("Agent registered in registry");
                        
                        // Create an initial test task
                        try AIOracleServiceManager(oracle).createNewTask("Initial Oracle Test Task") {
                            console.log("Created initial test task successfully");
                            uint32 taskNum = AIOracleServiceManager(oracle).latestTaskNum();
                            console.log("Latest task number:", taskNum);
                        } catch Error(string memory reason) {
                            console.log("Failed to create initial task:", reason);
                        }
                    } catch Error(string memory reason) {
                        console.log("Failed to register agent:", reason);
                    }
                } catch Error(string memory reason) {
                    console.log("Failed to deploy AIAgent:", reason);
                }
            } catch Error(string memory reason) {
                console.log("Failed to deploy AIAgentRegistry:", reason);
            }
        } catch Error(string memory reason) {
            console.log("Failed to deploy AIOracleServiceManager:", reason);
        } catch (bytes memory) {
            console.log("Unknown error during Oracle deployment");
        }
    }
    
    function logAIOracleAddresses() internal view {
        console.log("\n========== AI ORACLE DEPLOYMENT INFO ==========");
        console.log("Network: Unichain Sepolia (", block.chainid, ")");
        console.log("Oracle Address: ", oracle);
        console.log("Agent Address: ", agent);
        console.log("Registry Address: ", registry);
        
        // Create a formatted string for easy copying to config.json
        console.log("\nConfig for eigenlayer-ai-agent/config.json:");
        console.log("{");
        console.log("  \"rpc_url\": \"https://sepolia-unichain.infura.io/v3/YOUR_INFURA_KEY\",");
        console.log("  \"oracle_address\": \"", oracle, "\",");
        console.log("  \"agent_address\": \"", agent, "\",");
        console.log("  \"chain_id\": ", block.chainid, ",");
        console.log("  \"agent_private_key\": \"YOUR_PRIVATE_KEY_HERE\",");
        console.log("  \"poll_interval_seconds\": 5,");
        console.log("  \"openai_api_key\": \"YOUR_OPENAI_API_KEY\"");
        console.log("}");
        console.log("==============================================\n");
    }
} 