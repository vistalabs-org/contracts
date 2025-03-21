// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {ERC20Mock} from "./utils/ERC20mock.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

/**
 * @title TestUnichainPredictionMarketAI
 * @dev Test contract for end-to-end testing of prediction markets with AI resolution on Unichain Sepolia
 * 
 * This test covers:
 * 1. Deployment to Unichain Sepolia
 * 2. Market creation
 * 3. AI task submission
 * 4. Waiting for agent responses
 * 5. Market resolution
 * 
 * To run:
 * - First run: `forge test --match-test test_deployToUnichain -vvv --rpc-url <URL>`
 * - After config: `forge test --match-test test_marketWithAI -vvv --rpc-url <URL>`
 */
contract TestUnichainPredictionMarketAI is Test {
    // Contracts
    PredictionMarketHook public hook;
    PoolManager public poolManager;
    PoolModifyLiquidityTest public modifyLiquidityRouter;
    PoolSwapTest public poolSwapTest;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    
    // AI Oracle components
    AIOracleServiceManager public oracle;
    AIAgentRegistry public registry;
    AIAgent public agent;
    
    // Test variables
    bytes32 public marketId;
    uint32 public taskNum;
    bool public aiDecision;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    
    // Configuration options
    bool public useExistingDeployment;
    address public existingHook;
    address public existingOracle;
    address public existingRegistry;
    address public existingAgent;
    address public existingCollateral;
    
    /**
     * @notice Set up test with configuration
     * If useExistingDeployment is true, it will use previously deployed contracts
     */
    function setUp() public {
        // Check if we should use existing contracts from config
        string memory configPath = "test/unichain_config.json";
        if (vm.exists(configPath)) {
            string memory configJson = vm.readFile(configPath);
            useExistingDeployment = vm.parseJsonBool(configJson, ".use_existing_deployment");
            
            if (useExistingDeployment) {
                existingHook = vm.parseJsonAddress(configJson, ".hook_address");
                existingOracle = vm.parseJsonAddress(configJson, ".oracle_address");
                existingRegistry = vm.parseJsonAddress(configJson, ".registry_address");
                existingAgent = vm.parseJsonAddress(configJson, ".agent_address");
                existingCollateral = vm.parseJsonAddress(configJson, ".collateral_address");
                
                console.log("Using existing deployment from config");
                console.log("Hook:", existingHook);
                console.log("Oracle:", existingOracle);
                console.log("Agent:", existingAgent);
            }
        }
    }
    
    /**
     * @notice Helper to get runtime bytecode from initialization bytecode
     * @param initBytecode The initialization bytecode (creationCode + constructor args)
     * @return runtimeBytecode The runtime bytecode to be placed at the address
     */
    function runtime(bytes memory initBytecode) internal returns (bytes memory runtimeBytecode) {
        // Create a temporary contract to get its runtime bytecode
        address deployed;
        assembly {
            deployed := create(0, add(initBytecode, 0x20), mload(initBytecode))
        }
        
        // Get the size of the runtime bytecode
        uint256 size;
        assembly {
            size := extcodesize(deployed)
        }
        
        // Copy the runtime bytecode
        runtimeBytecode = new bytes(size);
        assembly {
            extcodecopy(deployed, add(runtimeBytecode, 0x20), 0, size)
        }
    }
    
    /**
     * @notice Deploy all contracts to Unichain Sepolia
     * This test should be run first to deploy everything
     */
    function test_deployToUnichain() public {
        // Skip if using existing deployment
        if (useExistingDeployment) {
            console.log("Skipping deployment - using existing contracts");
            return;
        }
        
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);
        
        console.log("Deploying contracts to Unichain Sepolia as:", deployer);
        
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy Uniswap infrastructure
        poolManager = new PoolManager(deployer);
        console.log("Deployed PoolManager at", address(poolManager));
        
        // Deploy test routers
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        poolSwapTest = new PoolSwapTest(poolManager);
        
        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(poolManager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));
        
        // Define the hook flags
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        
        // Prepare constructor arguments
        bytes memory constructorArgs = abi.encode(
            address(poolManager),
            address(modifyLiquidityRouter),
            address(poolCreationHelper)
        );
        
        // Get creation code
        bytes memory creationCode = type(PredictionMarketHook).creationCode;
        
        // Get combined bytecode
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
        // Find a valid salt for hook address
        (address hookAddress, bytes32 salt) = HookMiner.find(
            deployer,
            flags,
            bytecode,
            bytes("")
        );
        
        console.log("Found valid hook address:", hookAddress);
        
        // Stop broadcasting to use VM cheatcodes
        vm.stopBroadcast();
        
        // Deploy the hook with create, then get its runtime code
        address deployedTemp;
        assembly {
            deployedTemp := create(0, add(bytecode, 0x20), mload(bytecode))
        }
        
        // Convert address to string for vm.getCode (this is what's causing the error)
        string memory deployedTempString = vm.toString(deployedTemp);
        bytes memory runtimeCode = vm.getCode(deployedTempString);
        
        // Use etch to place the runtime code at the correct address
        vm.etch(hookAddress, runtimeCode);
        hook = PredictionMarketHook(hookAddress);
        
        console.log("Hook deployed at:", address(hook));
        
        // Resume broadcasting for remaining contracts
        vm.startBroadcast(deployerPrivateKey);
        
        // Deploy mock collateral token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        console.log("Collateral token deployed at", address(collateralToken));
        
        // Mint tokens to deployer
        collateralToken.mint(deployer, 1000000 * 10**6);
        console.log("Minted 1,000,000 USDC to deployer");
        
        // Deploy Oracle infrastructure
        address avsDirectory = deployer;
        address stakeRegistry = deployer;
        address rewardsCoordinator = deployer;
        address delegationManager = deployer;
        address allocationManager = deployer;
        
        // Deploy Oracle
        oracle = new AIOracleServiceManager(
            avsDirectory,
            stakeRegistry,
            rewardsCoordinator,
            delegationManager,
            allocationManager
        );
        console.log("AIOracleServiceManager deployed at:", address(oracle));
        
        // Deploy Registry with the oracle address
        registry = new AIAgentRegistry(address(oracle));
        console.log("AIAgentRegistry deployed at:", address(registry));
        
        // Deploy Agent
        agent = new AIAgent(
            address(oracle),
            "OpenAI",
            "gpt-4-turbo"
        );
        console.log("AIAgent deployed at:", address(agent));
        
        // Register the agent in the registry
        registry.registerAgent(address(agent));
        console.log("Agent registered in registry");
        
        // Create an initial test task to verify Oracle is working
        try oracle.createNewTask("Initial Oracle Test Task") {
            console.log("Created initial test task successfully");
            taskNum = oracle.latestTaskNum();
            console.log("Latest task number:", taskNum);
        } catch Error(string memory reason) {
            console.log("Failed to create initial task:", reason);
        }
        
        vm.stopBroadcast();
        
        // Save deployment info to config file
        string memory configJson = string(abi.encodePacked(
            '{"use_existing_deployment": true,',
            '"hook_address": "', vm.toString(address(hook)), '",',
            '"oracle_address": "', vm.toString(address(oracle)), '",',
            '"registry_address": "', vm.toString(address(registry)), '",',
            '"agent_address": "', vm.toString(address(agent)), '",',
            '"collateral_address": "', vm.toString(address(collateralToken)), '"',
            '}'
        ));
        
        vm.writeFile("test/unichain_config.json", configJson);
        
        // Output agent config
        outputAgentConfig();
    }
    
    /**
     * @notice Full market lifecycle test with AI resolution
     * This test creates a market, submits AI task, waits for response, and resolves
     */
    function test_marketWithAI() public {
        // Initialize with existing deployment if specified
        initializeFromExistingDeployment();
        
        // Get private key for transactions
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(privateKey);
        console.log("Running test as:", deployer);
        
        // Step 1: Create a prediction market
        vm.startBroadcast(privateKey);
        marketId = createPredictionMarket(deployer);
        console.log("Market created with ID:", vm.toString(marketId));
        
        // Step 2: Create an AI task for resolution
        taskNum = createAITask("Will ETH price exceed $5000 by the end of 2024?");
        console.log("AI task created, number:", taskNum);
        
        // Note: At this point, the Python agent should detect the task and respond
        logAgentInstructions();
        
        // Step 3: Wait for response (optional - can be manual)
        bool hasResponse = waitForAIResponse(taskNum, 30); // 30 seconds timeout
        if (!hasResponse) {
            console.log("No AI response yet. You may need to configure and run the Python agent.");
            console.log("Run this test again after the agent has responded.");
            vm.stopBroadcast();
            return;
        }
        
        // Step 4: Get decision from AI response
        aiDecision = getAIDecision(taskNum);
        console.log("AI Decision:", aiDecision ? "YES" : "NO");
        
        // Step 5: Resolve market with AI decision
        resolveMarket(marketId, aiDecision);
        console.log("Market resolved with decision:", aiDecision ? "YES" : "NO");
        
        // Verify final market state
        Market memory market = hook.getMarketById(marketId);
        assertEq(uint8(market.state), uint8(MarketState.Resolved), "Market should be resolved");
        assertEq(market.outcome, aiDecision, "Market outcome should match AI decision");
        
        vm.stopBroadcast();
        console.log("Market lifecycle test completed successfully!");
    }
    
    /**
     * @notice Helper to initialize contract instances from existing deployment
     */
    function initializeFromExistingDeployment() internal {
        if (!useExistingDeployment) {
            console.log("No existing deployment specified. Run test_deployToUnichain first.");
            return;
        }
        
        hook = PredictionMarketHook(existingHook);
        oracle = AIOracleServiceManager(existingOracle);
        registry = AIAgentRegistry(existingRegistry);
        agent = AIAgent(existingAgent);
        collateralToken = ERC20Mock(existingCollateral);
        
        console.log("Initialized with existing deployment:");
        console.log("Hook:", address(hook));
        console.log("Oracle:", address(oracle));
        console.log("Agent:", address(agent));
    }
    
    /**
     * @notice Create a prediction market
     * @param creator Address of the market creator
     * @return marketId The ID of the created market
     */
    function createPredictionMarket(address creator) internal returns (bytes32) {
        // Approve collateral spending
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
        
        // Create market parameters
        CreateMarketParams memory params = CreateMarketParams({
            oracle: creator,  // Using the creator as oracle for now
            creator: creator,
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH exceed $5000 in 2024?",
            description: "Market resolves to YES if the price of ETH exceeds $5000 at any point before December 31, 2024",
            duration: 180 days
        });
        
        // Create the market
        return hook.createMarketAndDepositCollateral(params);
    }
    
    /**
     * @notice Create a task for AI agent to respond to
     * @param question The question for the AI agent
     * @return taskNum The task number
     */
    function createAITask(string memory question) internal returns (uint32) {
        AIOracleServiceManager.Task memory task = oracle.createNewTask(question);
        return oracle.latestTaskNum() - 1;
    }
    
    /**
     * @notice Wait for AI agent to respond to a task
     * @param _taskNum The task number to check
     * @param timeoutSeconds Maximum time to wait in seconds
     * @return hasResponse Whether a response was received
     */
    function waitForAIResponse(uint32 _taskNum, uint256 timeoutSeconds) internal returns (bool) {
        uint256 startTime = block.timestamp;
        uint256 endTime = startTime + timeoutSeconds;
        
        while (block.timestamp < endTime) {
            // Check for responses
            address[] memory respondents = oracle.taskRespondents(_taskNum);
            if (respondents.length > 0) {
                console.log("Received response from AI agent!");
                return true;
            }
            
            // Wait and check again
            vm.warp(block.timestamp + 5); // Move forward 5 seconds
            console.log("Waiting for AI response...");
        }
        
        return false;
    }
    
    /**
     * @notice Extract decision from AI response
     * @param _taskNum The task number to check
     * @return decision The YES/NO decision
     */
    function getAIDecision(uint32 _taskNum) internal view returns (bool) {
        // Get consensus result
        (bytes memory result, bool isResolved) = oracle.getConsensusResult(_taskNum);
        
        // If not resolved, default to false
        if (!isResolved) {
            console.log("Warning: No consensus reached, defaulting to NO");
            return false;
        }
        
        // Extract YES/NO decision
        string memory resultStr = string(result);
        console.log("Raw AI response:", resultStr);
        
        // Simple comparison - any response containing "yes" is treated as YES
        bytes memory resultBytes = bytes(resultStr);
        bytes memory yesBytes = bytes("YES");
        
        // Check if response contains "YES" (case sensitive)
        bool containsYes = false;
        if (resultBytes.length >= yesBytes.length) {
            for (uint i = 0; i <= resultBytes.length - yesBytes.length; i++) {
                bool isMatch = true;
                for (uint j = 0; j < yesBytes.length; j++) {
                    if (resultBytes[i + j] != yesBytes[j]) {
                        isMatch = false;
                        break;
                    }
                }
                if (isMatch) {
                    containsYes = true;
                    break;
                }
            }
        }
        
        return containsYes;
    }
    
    /**
     * @notice Resolve a market with the given outcome
     * @param _marketId The market to resolve
     * @param outcome The YES/NO outcome
     */
    function resolveMarket(bytes32 _marketId, bool outcome) internal {
        hook.resolveMarket(_marketId, outcome);
    }
    
    /**
     * @notice Log instructions for configuring the Python agent
     */
    function logAgentInstructions() internal view {
        console.log("\n======== AI AGENT INSTRUCTIONS ========");
        console.log("To get real AI responses:");
        console.log("1. Update eigenlayer-ai-agent/config.json with:");
        console.log("   - RPC URL: https://unichain-sepolia.drpc.org");
        console.log("   - Oracle address:", address(oracle));
        console.log("   - Agent address:", address(agent));
        console.log("   - Chain ID:", block.chainid);
        console.log("   - Your private key and OpenAI API key");
        console.log("2. Run the agent with: cd eigenlayer-ai-agent && poetry run python -m agent.main");
        console.log("3. Wait for the agent to detect and respond to the task");
        console.log("4. Run this test again to check for responses and resolve the market");
        console.log("========================================\n");
    }
    
    /**
     * @notice Output configuration for the AI agent
     */
    function outputAgentConfig() internal view {
        console.log("\nConfig for eigenlayer-ai-agent/config.json:");
        console.log("{");
        console.log("  \"rpc_url\": \"https://unichain-sepolia.drpc.org\",");
        console.log("  \"oracle_address\": \"", address(oracle), "\",");
        console.log("  \"agent_address\": \"", address(agent), "\",");
        console.log("  \"chain_id\": ", block.chainid, ",");
        console.log("  \"agent_private_key\": \"YOUR_PRIVATE_KEY_HERE\",");
        console.log("  \"poll_interval_seconds\": 5,");
        console.log("  \"openai_api_key\": \"YOUR_OPENAI_API_KEY_HERE\"");
        console.log("}");
    }
    
    /**
     * @notice Helper to compute CREATE2 address
     */
    function getCreate2Address(bytes32 salt, bytes32 codeHash) internal view returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            address(this),
            salt,
            codeHash
        )))));
    }
} 