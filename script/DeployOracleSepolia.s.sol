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
        
                
        // Get the deployer address directly
        address deployer = vm.addr(deployerPrivateKey);
        console.log("Deployer address:", deployer);

        // --- Break the circular dependency between Registry and Oracle ---
        
        // 1. Create a temporary placeholder address for Oracle (will be replaced with actual proxy later)
        address tempOracleAddress = address(1); // Placeholder address
        
        // 2. Deploy AIAgentRegistry with the temporary Oracle address
        try new AIAgentRegistry(tempOracleAddress) returns (AIAgentRegistry registryContract) {
            registry = address(registryContract);
            console.log("AIAgentRegistry deployed at:", registry);
            
            // 3. Deploy Oracle Implementation (with actual Registry address)
            try new AIOracleServiceManager(registry) returns (AIOracleServiceManager oracleImpl) {
                console.log("AIOracleServiceManager implementation deployed at:", address(oracleImpl));
                
                // 4. Create a proxy for the Oracle
                TransparentUpgradeableProxy proxy = new TransparentUpgradeableProxy(
                    address(oracleImpl), // Implementation address
                    deployer,           // Admin of the proxy
                    abi.encodeWithSelector(
                        oracleImpl.initialize.selector,
                        deployer,       // initialOwner
                        1,              // minimumResponses (test mode)
                        5100,           // consensusThreshold
                        address(0)      // _predictionMarketHook (set later)
                    )
                );
                
                // 5. Store the actual Oracle proxy address
                oracle = address(proxy);
                console.log("Oracle proxy deployed at:", oracle);
                
                // 6. Update the Registry's Oracle reference
                // We need to get direct access to functions not defined in IAIAgentRegistry
                // If there's a setServiceManager function, call it here
                // Otherwise, this may require a redeployment of the registry - see alternative below
                
                // Commented out example - adjust according to the actual function available in AIAgentRegistry:
                // try registryContract.setServiceManager(oracle) {
                //     console.log("Updated registry's oracle reference");
                // } catch Error(string memory reason) {
                //     console.log("Failed to update registry's oracle reference:", reason);
                // }
                
                // IMPORTANT: If no function exists to update serviceManager, log a notice
                console.log("NOTICE: Registry was deployed with a placeholder oracle address.");
                console.log("Actual oracle proxy is at:", oracle);
                console.log("The registry needs to be updated manually or redeployed.");
                
                // Create a contract instance of the proxy for interactions
                AIOracleServiceManager proxyContract = AIOracleServiceManager(oracle);
                
                // Check test mode
                console.log("Current minimumResponses via proxy:", proxyContract.minimumResponses());
                console.log("Test mode active:", proxyContract.minimumResponses() == 1);
                
                // 7. Deploy AIAgent 
                try new AIAgent() returns (AIAgent agentContract) {
                    agent = address(agentContract);
                    console.log("AIAgent deployed at:", agent);
                    
                    // 8. Try to register the agent in the registry
                    try registryContract.registerAgent(agent) {
                        console.log("Agent registered in registry");
                        
                        // 9. Try to create a test task
                        try proxyContract.createNewTask("Initial Oracle Test Task") {
                            console.log("Created initial test task successfully");
                            uint32 taskNum = proxyContract.latestTaskNum();
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
                console.log("Failed to deploy AIOracleServiceManager implementation:", reason);
            } catch (bytes memory) {
                console.log("Unknown error during Oracle implementation deployment");
            }
        } catch Error(string memory reason) {
            console.log("Failed to deploy AIAgentRegistry:", reason);
        } catch (bytes memory) {
            console.log("Unknown error during Registry deployment");
        }
        
        // --- Alternative approach if needed: Registry Redeployment ---
        // If the registry cannot be updated after initialization, include code 
        // here to redeploy it with the correct Oracle address
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