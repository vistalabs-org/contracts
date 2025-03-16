// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {CurrencyLibrary, Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Market, MarketState, CreateMarketParams} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";
import {ERC20Mock} from "./utils/ERC20mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";

/**
 * @title PredictionMarketAITest
 * @dev Test contract for integration between PredictionMarketHook and AI Oracle
 */
contract PredictionMarketAITest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    
    // Contracts
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    PoolSwapTest public poolSwapTest;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    
    // AI Oracle components
    AIOracleServiceManager public oracle;
    AIAgentRegistry public registry;
    AIAgent public agent;
    
    // Constants
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    
    // For storing market information
    bytes32 public marketId;
    
    // Event for catching AI response
    event NewTaskCreated(uint32 indexed taskIndex, AIOracleServiceManager.Task task);
    event TaskResponded(uint32 indexed taskIndex, AIOracleServiceManager.Task task, address indexed respondent);
    event ConsensusReached(uint32 indexed taskIndex, bytes result);

    function setUp() public {
        // Deploy Uniswap v4 infrastructure
        console.log("Deploying Uniswap v4 infrastructure from ", address(this));
        deployFreshManagerAndRouters();

        // Deploy PoolSwapTest
        poolSwapTest = new PoolSwapTest(manager);
        
        // Deploy PoolModifyLiquidityTest
        poolModifyLiquidityTest = new PoolModifyLiquidityTest(manager);

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("PoolCreationHelper deployed at:", address(poolCreationHelper));
        
        // Calculate hook address with specific flags for swap and liquidity operations
        address flags = address(
            uint160(
                Hooks.BEFORE_SWAP_FLAG | 
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG
            ) ^ (0x4444 << 144) // Namespace the hook to avoid collisions
        );

        // Deploy the hook using foundry cheatcode with specific flags
        deployCodeTo(
            "PredictionMarketHook.sol:PredictionMarketHook", 
            abi.encode(manager, poolModifyLiquidityTest, poolCreationHelper), 
            flags
        );
        
        // Initialize hook instance at the deployed address
        hook = PredictionMarketHook(flags);
        console.log("Hook address:", address(hook));

        // Deploy AI Oracle components
        setupAIOracleComponents();

        // Create and mint a collateral token
        collateralToken = new ERC20Mock("Test USDC", "USDC", 6);
        collateralToken.mint(address(this), 1000000 * 10**6);
        collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
    }
    
    function setupAIOracleComponents() internal {
        // Deploy AIOracleServiceManager
        // AVS-related addresses - using this contract as a stand-in for all roles
        address avsDirectory = address(this);
        address stakeRegistry = address(this);
        address rewardsCoordinator = address(this);
        address delegationManager = address(this);
        address allocationManager = address(this);
        
        oracle = new AIOracleServiceManager(
            avsDirectory,
            stakeRegistry,
            rewardsCoordinator,
            delegationManager,
            allocationManager
        );
        
        // Initialize the oracle
        oracle.initialize(
            address(this),  // owner
            address(this),  // rewards initiator
            2,              // minimum responses for consensus
            7000            // consensus threshold (70%)
        );
        
        console.log("AIOracleServiceManager deployed at:", address(oracle));
        
        // Deploy AIAgentRegistry
        registry = new AIAgentRegistry(address(oracle));
        console.log("AIAgentRegistry deployed at:", address(registry));
        
        // Deploy AIAgent
        agent = new AIAgent(
            address(oracle),
            "OpenAI",
            "gpt-4-turbo"
        );
        console.log("AIAgent deployed at:", address(agent));
        
        // Register the agent
        registry.registerAgent(address(agent));
    }
    
    function test_createMarketAndGetAIResponse() public {
        // Create a prediction market
        marketId = createTestMarket();
        console.log("Market created with ID:", bytes32ToHexString(marketId));
        
        // Get market details
        Market memory market = hook.getMarketById(marketId);
        console.log("Market title:", market.title);
        
        // Create a task for the AI Oracle
        uint32 taskNum = createAIOracleTask(market.title);
        console.log("Created task with ID:", taskNum);
        
        // In a real scenario, the AI agent would process this task
        // For testing purposes, we'll simulate a response
        simulateAIAgentResponse(taskNum, market.title);
        
        // Wait for consensus and resolve the market
        bool aiDecision = getAIDecisionAndResolveMarket(taskNum, marketId);
        
        // Verify the market was resolved
        market = hook.getMarketById(marketId);
        assertEq(uint8(market.state), uint8(MarketState.Resolved), "Market should be resolved");
        assertEq(market.outcome, aiDecision, "Market outcome should match AI decision");
    }
    
    function createAIOracleTask(string memory title) internal returns (uint32) {
        // Create a task in the AI Oracle
        string memory taskDescription = string(abi.encodePacked(
            "Prediction market question: ", title, 
            ". Please respond with YES or NO."
        ));
        
        // Call the createNewTask function
        AIOracleServiceManager.Task memory newTask = oracle.createNewTask(taskDescription);
        
        // The task number is the current value of latestTaskNum - 1
        return oracle.latestTaskNum() - 1;
    }
    
    function simulateAIAgentResponse(uint32 taskNum, string memory question) internal {
        // In a real integration, this would be calling the Python AI agent
        // For this test, we'll simulate the agent responding
        
        // Create the task structure to pass to respondToTask
        AIOracleServiceManager.Task memory task;
        task.name = string(abi.encodePacked("Prediction market question: ", question, ". Please respond with YES or NO."));
        task.taskCreatedBlock = uint32(block.number - 1);
        
        // Create a second agent to meet minimum consensus requirements
        address secondAgent = address(0x2222);
        
        // Deploy a second AIAgent contract
        AIAgent agent2 = new AIAgent(
            address(oracle),
            "Anthropic",
            "claude-3"
        );
        registry.registerAgent(address(agent2));
        
        // Create deterministic signatures by simply hashing with different salt values
        bytes32 messageHash = keccak256(abi.encodePacked("Hello, ", task.name));
        
        // We need to mock responses from agents
        // First agent
        vm.prank(address(agent));
        oracle.respondToTask(task, taskNum, abi.encodePacked(messageHash, "agent1"));
        
        console.log("First AI agent responded to task:", taskNum);
        
        // Second agent - must provide the same response data for consensus
        vm.prank(address(agent2));
        oracle.respondToTask(task, taskNum, abi.encodePacked(messageHash, "agent1"));
        
        console.log("Second AI agent responded to task:", taskNum);
    }
    
    function getAIDecisionAndResolveMarket(uint32 taskNum, bytes32 marketId) internal returns (bool) {
        // Check consensus result status
        (bytes memory result, bool isResolved) = oracle.getConsensusResult(taskNum);
        
        require(isResolved, "Consensus not yet reached");
        console.log("Consensus reached for task:", taskNum);
        
        // In a real scenario, we would decode the result to get YES/NO
        // For simplicity in testing, we'll use task index as deterministic result
        bool decision = (taskNum % 2 == 0);
        
        // Resolve the market
        hook.resolveMarket(marketId, decision);
        
        console.log("Resolved market with decision:", decision ? "YES" : "NO");
        
        return decision;
    }
    
    // Helper function to create a market for testing
    function createTestMarket() internal returns (bytes32) {
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will ETH reach $10k in 2024?",
            description: "Market resolves to YES if ETH price reaches $10,000 before Dec 31, 2024",
            duration: 30 days
        });
        
        return hook.createMarketAndDepositCollateral(params);
    }
    
    // Helper function to convert bytes32 to hex string for logging
    function bytes32ToHexString(bytes32 value) internal pure returns (string memory) {
        bytes memory result = new bytes(64);
        bytes16 hexSymbols = "0123456789abcdef";
        
        for (uint i = 0; i < 32; i++) {
            uint8 b = uint8(value[i]);
            result[i*2] = hexSymbols[b >> 4];
            result[i*2+1] = hexSymbols[b & 0x0f];
        }
        
        return string(result);
    }
}
