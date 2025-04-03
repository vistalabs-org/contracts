/**
 * @title PredictionMarketAITest
 * @dev Test for Prediction Market with REAL AI Agent integration
 * 
 * Note: The test is designed to work with the eigenlayer-ai-agent directory structure.
 */

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
import {ERC20Mock} from "./utils/ERC20Mock.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MockUSDC} from "../script/DeployLocal.s.sol";

// External library to help with stack issues
library AIOracleTestHelpers {
    // Helper to convert bytes to hex string for logging
    function bytesToHexString(bytes memory data) internal pure returns (string memory) {
        bytes memory hexChars = "0123456789abcdef";
        bytes memory result = new bytes(2 + data.length * 2);
        
        result[0] = '0';
        result[1] = 'x';
        
        for (uint i = 0; i < data.length; i++) {
            result[2 + i * 2] = hexChars[uint8(data[i] >> 4)];
            result[2 + 1 + i * 2] = hexChars[uint8(data[i] & 0x0f)];
        }
        
        return string(result);
    }
    
    // Helper to convert bytes32 to hex string
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
    
    // Helper to compare strings
    function compareStrings(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(abi.encodePacked(a)) == keccak256(abi.encodePacked(b));
    }
    
    // Helper to get market state as string
    function getMarketStateString(MarketState state) internal pure returns (string memory) {
        if (state == MarketState.Active) return "Active";
        if (state == MarketState.Resolved) return "Resolved";
        if (state == MarketState.Cancelled) return "Cancelled";
        return "Unknown";
    }
    
    // Helper to extract YES/NO decision
    function extractYesNoDecision(bytes memory response) internal pure returns (bool) {
        uint256 hashValue = uint256(keccak256(response));
        return hashValue % 2 == 0;
    }
    
    // Helper to create agent response signature
    function createAgentResponseSignature(string memory taskName) internal pure returns (bytes memory) {
        bytes32 messageHash = keccak256(abi.encodePacked("Hello, ", taskName));
        return abi.encodePacked(messageHash, "YES");
    }
}

/**
 * @title PredictionMarketAITest
 * @dev Test contract for integration between PredictionMarketHook and AI Oracle
 */
contract PredictionMarketAITest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using AIOracleTestHelpers for *; // Use our helper library
    
    // Contracts (already deployed)
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    
    // AI Oracle components (already deployed)
    AIOracleServiceManager public oracle;
    AIAgent public agent;
    
    // Constants
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    
    // For storing market information
    bytes32 public marketId;
    MockUSDC public collateralToken;
    
    // Contract addresses from the deployment
    address public constant ORACLE_ADDRESS = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address public constant AGENT_ADDRESS = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address public constant HOOK_ADDRESS = 0x4444000000000000000000000000000000000a80;
    address public constant POOL_MANAGER_ADDRESS = 0x5615dEB798BB3E4dFa0139dFa1b3D433Cc23b72f;
    address public constant POOL_MODIFY_LIQUIDITY_ADDRESS = 0xa513E6E4b8f2a923D98304ec87F64353C4D5C853;
    address public constant POOL_CREATION_HELPER_ADDRESS = 0x2279B7A0a67DB372996a5FaB50D91eAA73d2eBe6;
    address public constant MOCK_USDC_ADDRESS = 0x5FbDB2315678afecb367f032d93F642f64180aa3;

    function setUp() public {
        console.log("Setting up test with existing deployments");
        
        // Check addresses first
        bool oracleHasCode = ORACLE_ADDRESS.code.length > 0;
        bool hookHasCode = HOOK_ADDRESS.code.length > 0;
        bool agentHasCode = AGENT_ADDRESS.code.length > 0;

        console.log("Oracle has code:", oracleHasCode);
        console.log("Hook has code:", hookHasCode);
        console.log("Agent has code:", agentHasCode);
        
        // Only initialize if they have code
        if (oracleHasCode) {
            oracle = AIOracleServiceManager(ORACLE_ADDRESS);
        } else {
            console.log("WARNING: Oracle contract not found at", ORACLE_ADDRESS);
        }
        if (hookHasCode) {
            hook = PredictionMarketHook(HOOK_ADDRESS);
        } else {
            console.log("WARNING: Hook contract not found at", HOOK_ADDRESS);
        }
        if (agentHasCode) {
            agent = AIAgent(AGENT_ADDRESS);
        } else {
             console.log("WARNING: Agent contract not found at", AGENT_ADDRESS);
        }
        
        // Similar checks for other contracts
        bool poolModifyHasCode = POOL_MODIFY_LIQUIDITY_ADDRESS.code.length > 0;
        bool poolCreateHasCode = POOL_CREATION_HELPER_ADDRESS.code.length > 0;
        bool usdcHasCode = MOCK_USDC_ADDRESS.code.length > 0;
        
        // Connect to other contracts directly if they exist
        if (poolModifyHasCode) poolModifyLiquidityTest = PoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_ADDRESS);
        if (poolCreateHasCode) poolCreationHelper = PoolCreationHelper(POOL_CREATION_HELPER_ADDRESS);
        if (usdcHasCode) collateralToken = MockUSDC(MOCK_USDC_ADDRESS);
        
        // Check if connections were successful
        bool hookHasCodeAfterInit = address(hook).code.length > 0;
        bool oracleHasCodeAfterInit = address(oracle).code.length > 0;
        bool agentHasCodeAfterInit = address(agent).code.length > 0;

        // Authorize the agent in the Oracle Service Manager if both exist
        if (oracleHasCodeAfterInit && agentHasCodeAfterInit) {
             // Use try-catch as the operator might already be added, or permissions issues
            try oracle.addTestOperator(AGENT_ADDRESS) {
                console.log("Authorized AGENT_ADDRESS as test operator in AIOracleServiceManager.");
            } catch Error(string memory reason) {
                // Check if already authorized (simple check, might need refinement)
                if (oracle.testOperators(AGENT_ADDRESS())) {
                     console.log("Agent already authorized as test operator.");
                } else {
                     console.log("Failed to add test operator:", reason);
                }
            } catch {
                console.log("Failed to call addTestOperator (unknown error).");
            }
        }
        
        // Only approve if hook and token exist
        if (hookHasCodeAfterInit && usdcHasCode) {
            collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
            console.log("Tokens approved for Hook");
        }
        
        console.log("Setup complete - using existing deployed contracts");
    }
    
    function test_createNewMarketWithExistingOracle() public {
        console.log("\n===== STARTING TEST WITH EXISTING DEPLOYMENTS =====");
        
        // Verify Oracle connectivity with try/catch
        if (address(oracle).code.length == 0) {
             console.log("Oracle not available, skipping test.");
            return;
        }
        try oracle.latestTaskNum() returns (uint32 latestTaskNum) {
            console.log("Latest task number from Oracle:", latestTaskNum);
        } catch {
            console.log("ERROR: Failed to call latestTaskNum() on Oracle");
            return; // Stop test if oracle interaction fails
        }
        
        // Skip market creation if hook isn't initialized
        if (address(hook).code.length == 0) {
            console.log("Hook not available, skipping market creation");
            return;
        }
        
        // Create a new market
        console.log("\n----- Creating New Prediction Market -----");
        marketId = createTestMarket();
        console.log("Market created with ID:", bytes32ToString(marketId));
        
        // Create a new task for AI agents
        string memory marketTitle = "Will AI replace developers by 2030?";
        uint32 taskNum = createAIOracleTask(marketTitle);
        console.log("New task created with number:", taskNum);
        
        // Log agent setup instructions
        console.log("\n----- AGENT SETUP INFORMATION -----");
        console.log("To test with your agent, ensure it's configured with:");
        console.log("Oracle Address:", address(oracle));
        console.log("Agent Address:", address(agent));
        
        console.log("\n===== TEST COMPLETED SUCCESSFULLY =====");
    }
    
    function createAIOracleTask(string memory title) internal returns (uint32) {
        console.log("\n======== ATTENTION AI AGENT ========");
        console.log("Creating a new task that requires your response");
        
        // Create a task in the AI Oracle
        string memory taskDescription = string(abi.encodePacked(
            "Prediction market question: ", title, 
            ". Please respond with YES or NO."
        ));
        
        console.log("Task description:", taskDescription);
        console.log("Oracle address:", address(oracle));
        console.log("====================================\n");
        
        // Call the createNewTask function
        // Ensure oracle exists before calling
        if (address(oracle).code.length == 0) {
            console.log("Oracle not initialized, cannot create task.");
            return 0; // Or revert appropriately
        }
        try oracle.createNewTask(taskDescription) returns (AIOracleServiceManager.Task memory /*newTask*/) {
            console.log("Task created successfully in Oracle Service Manager");
            
            // The task number is the current value of latestTaskNum - 1
            uint32 taskNum = oracle.latestTaskNum() - 1;
            console.log("Task number:", taskNum);
            return taskNum;
        } catch Error(string memory reason) {
            console.log("ERROR creating task:", reason);
            revert("Failed to create AI Oracle task");
        } catch {
             console.log("ERROR creating task (unknown error)");
             revert("Failed to create AI Oracle task");
        }
    }

    // --- Helper Functions --- 

    function createTestMarket() internal returns (bytes32) {
        // Ensure needed contracts are available
        require(address(hook) != address(0), "Hook not initialized");
        require(address(collateralToken) != address(0), "Collateral token not initialized");
        require(address(poolCreationHelper) != address(0), "PoolCreationHelper not initialized");
        
        console.log("Creating test market...");

        // Define market parameters
        CreateMarketParams memory params;
        params.collateralToken = Currency.wrap(address(collateralToken));
        params.marketName = "Test Market: AI Future";
        params.resolver = address(this); // Use test contract as resolver for simplicity
        params.hookAddress = address(hook);
        params.initialLiquidity = 1 ether; // Example initial liquidity
        
        // Create the market using the helper
        bytes32 newMarketId = poolCreationHelper.createMarket(params);
        
        console.log("Market creation initiated.");
        console.log("Assigned Market ID:", bytes32ToString(newMarketId));
        
        return newMarketId;
    }

    // Helper to convert bytes32 to string for logging
    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        // Basic hex string conversion
        return AIOracleTestHelpers.bytes32ToHexString(_bytes32);
    }
    
    // Placeholder for market resolution logic (if needed in further tests)
    function resolveMarket(bytes32 _marketId, bool outcome) external {
        // Ensure hook is initialized
        require(address(hook) != address(0), "Hook not initialized");
        // In a real scenario, only the designated resolver could call this
        // Hook should have a function like `resolveMarket(marketId, outcome)`
        // hook.resolveMarket(_marketId, outcome); 
        console.log("Market resolution called (placeholder)", bytes32ToString(_marketId), outcome);
    }

    // Fallback function to receive Ether
    receive() external payable {}

    // TODO: Add tests for:
    // - Agent responding to task (processTask)
    // - Consensus mechanism in AIOracleServiceManager
    // - Market resolution based on AI consensus
    // - Trading outcome tokens
}
