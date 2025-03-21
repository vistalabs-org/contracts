// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ERC20Mock} from "../test/utils/ERC20mock.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";

contract DeployPredictionMarket is Script {
    PredictionMarketHook public hook;
    PoolManager public manager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public poolSwapTest;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    address public oracle;
    address public registry;
    address public agent;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy Uniswap infrastructure
        manager = new PoolManager(address(this));
        console.log("Deployed PoolManager at", address(manager));
        
        // Deploy test routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(manager);
        poolSwapTest = new PoolSwapTest(manager);
        
        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));

        // Deploy hook with proper flags
        vm.stopBroadcast();
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        ) ^ (0x4444 << 144); // Namespace the hook to avoid collisions

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PredictionMarketHook).creationCode,
            abi.encode(manager, modifyLiquidityRouter, poolCreationHelper)
        );

        console.log("Deploying PredictionMarketHook at", hookAddress);

        vm.startBroadcast(deployerPrivateKey);
        hook = new PredictionMarketHook{salt: salt}(
            manager, 
            modifyLiquidityRouter,
            poolCreationHelper
        );
        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("Hook deployed at", address(hook));
        
        // Deploy mock collateral token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        console.log("Collateral token deployed at", address(collateralToken));
        
        // Mint tokens to deployer
        address deployer = vm.addr(deployerPrivateKey);
        collateralToken.mint(deployer, 1000000 * 10**6);
        console.log("Minted 1,000,000 USDC to deployer");
        
        // Approve hook to spend tokens
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
        
        // Create a market
        CreateMarketParams memory params = CreateMarketParams({
            oracle: deployer,
            creator: deployer,
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Test market",
            description: "Market resolves to YES if ETH is above 1000",
            duration: 30 days
        });
        
        bytes32 marketId = hook.createMarketAndDepositCollateral(params);
        console.log("Market created with ID:", vm.toString(marketId));
        
        vm.stopBroadcast();
        console.log("Deployment complete!");

        // Add AI Oracle component deployments
        deployAIOracleComponents();
        
        // Add this to output AI Oracle addresses
        logAIOracleAddresses();
    }

    function deployAIOracleComponents() internal {
        // Deploy Oracle infrastructure
        console.log("Deploying AI Oracle components to Unichain Sepolia...");
        
        // Use this test contract address for all AVS middleware components
        address avsDirectory = address(this);
        address stakeRegistry = address(this);
        address rewardsCoordinator = address(this);
        address delegationManager = address(this);
        address allocationManager = address(this);
        
        // Deploy Oracle
        oracle = address(new AIOracleServiceManager(
            avsDirectory,
            stakeRegistry,
            rewardsCoordinator,
            delegationManager,
            allocationManager
        ));
        console.log("AIOracleServiceManager deployed at:", oracle);
        
        // Deploy Registry with the oracle address
        registry = address(new AIAgentRegistry(oracle));
        console.log("AIAgentRegistry deployed at:", registry);
        
        // Deploy Agent with the oracle address
        agent = address(new AIAgent(
            oracle,
            "OpenAI",
            "gpt-4-turbo"
        ));
        console.log("AIAgent deployed at:", agent);
        
        // Register the agent in the registry
        AIAgentRegistry(registry).registerAgent(agent);
        console.log("Agent registered in registry");
        
        // Create an initial test task to verify Oracle is working
        try AIOracleServiceManager(oracle).createNewTask("Initial Oracle Test Task") {
            console.log("Created initial test task successfully");
            uint32 taskNum = AIOracleServiceManager(oracle).latestTaskNum();
            console.log("Latest task number:", taskNum);
        } catch Error(string memory reason) {
            console.log("Failed to create initial task:", reason);
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
        console.log("}");
        console.log("==============================================\n");
    }
}