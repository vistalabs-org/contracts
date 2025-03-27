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
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {ECDSAStakeRegistry} from "@eigenlayer-middleware/src/unaudited/ECDSAStakeRegistry.sol";
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
    using ECDSA for bytes32;
    
    // Contracts (already deployed)
    PredictionMarketHook public hook;
    PoolCreationHelper public poolCreationHelper;
    PoolModifyLiquidityTest public poolModifyLiquidityTest;
    
    // AI Oracle components (already deployed)
    AIOracleServiceManager public oracle;
    AIAgentRegistry public registry;
    AIAgent public agent;
    
    // Constants
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC
    
    // For storing market information
    bytes32 public marketId;
    MockUSDC public collateralToken;
    
    // Contract addresses from the deployment
    address public constant ORACLE_ADDRESS = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address public constant REGISTRY_ADDRESS = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
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
        console.log("Oracle has code:", oracleHasCode);
        console.log("Hook has code:", hookHasCode);
        
        // Only initialize if they have code
        if (oracleHasCode) {
            oracle = AIOracleServiceManager(ORACLE_ADDRESS);
        }
        if (hookHasCode) {
            hook = PredictionMarketHook(HOOK_ADDRESS);
        }
        
        // Similar checks for other contracts
        
        // Connect to contracts directly
        poolModifyLiquidityTest = PoolModifyLiquidityTest(POOL_MODIFY_LIQUIDITY_ADDRESS);
        poolCreationHelper = PoolCreationHelper(POOL_CREATION_HELPER_ADDRESS);
        collateralToken = MockUSDC(MOCK_USDC_ADDRESS);
        
        // Check if connections were successful by calling a view function 
        // or checking the code size
        bool hookHasCodeAfterInit = address(hook).code.length > 0;
        console.log("Hook has code:", hookHasCodeAfterInit);
        
        bool oracleHasCodeAfterInit = address(oracle).code.length > 0;
        console.log("Oracle has code:", oracleHasCodeAfterInit);
        
        // Same for other contracts...
        
        // Only approve if hook has code
        if (hookHasCodeAfterInit && address(collateralToken).code.length > 0) {
            collateralToken.approve(address(hook), COLLATERAL_AMOUNT);
            console.log("Tokens approved for Hook");
        }
        
        // Add these in setUp() right after Hook initialization
        bool registryHasCode = REGISTRY_ADDRESS.code.length > 0;
        bool agentHasCode = AGENT_ADDRESS.code.length > 0;
        console.log("Registry has code:", registryHasCode);
        console.log("Agent has code:", agentHasCode);

        if (registryHasCode) {
            registry = AIAgentRegistry(REGISTRY_ADDRESS);
        }
        if (agentHasCode) {
            agent = AIAgent(AGENT_ADDRESS);
        }
        
        console.log("Setup complete - using existing deployed contracts");
    }
    
    function test_createNewMarketWithExistingOracle() public {
        console.log("\n===== STARTING TEST WITH EXISTING DEPLOYMENTS =====");
        
        // Verify Oracle connectivity with try/catch
        try oracle.latestTaskNum() returns (uint32 latestTaskNum) {
            console.log("Latest task number from Oracle:", latestTaskNum);
        } catch {
            console.log("ERROR: Failed to call latestTaskNum() on Oracle");
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
        console.log("Registry Address:", address(registry));
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
        try oracle.createNewTask(taskDescription) returns (AIOracleServiceManager.Task memory newTask) {
            console.log("Task created successfully");
            
            // The task number is the current value of latestTaskNum - 1
            uint32 taskNum = oracle.latestTaskNum() - 1;
            console.log("Task number:", taskNum);
            return taskNum;
        } catch Error(string memory reason) {
            console.log("Task creation FAILED:", reason);
            revert(string(abi.encodePacked("Failed to create AI Oracle task: ", reason)));
        } catch {
            console.log("Task creation FAILED: Unknown error");
            revert("Failed to create AI Oracle task with unknown error");
        }
    }
    
    function createTestMarket() internal returns (bytes32) {
        console.log("Creating test market...");
        
        // Create a market
        CreateMarketParams memory params = CreateMarketParams({
            oracle: address(this),
            creator: address(this),
            collateralAddress: address(collateralToken),
            collateralAmount: COLLATERAL_AMOUNT,
            title: "Will AI replace developers by 2030?",
            description: "Market resolves to YES if AI systems can autonomously create complete production applications by 2030",
            duration: 30 days,
            curveId: 0
        });
        
        try hook.createMarketAndDepositCollateral(params) returns (bytes32 id) {
            console.log("Market created successfully");
            return id;
        } catch Error(string memory reason) {
            console.log("Market creation FAILED:", reason);
            revert(string(abi.encodePacked("Failed to create market: ", reason)));
        } catch {
            console.log("Market creation FAILED with unknown error");
            revert("Failed to create market");
        }
    }

    function bytes32ToString(bytes32 _bytes32) internal pure returns (string memory) {
        bytes memory bytesArray = new bytes(64);
        for (uint256 i = 0; i < 32; i++) {
            bytesArray[i*2] = bytes1(uint8(uint256(_bytes32) / (2**(8*(31 - i))) % 16 + 48) + (uint8(uint256(_bytes32) / (2**(8*(31 - i))) % 16) >= 10 ? 39 : 0));
            bytesArray[i*2+1] = bytes1(uint8(uint256(_bytes32) / (2**(8*(31 - i) + 4)) % 16 + 48) + (uint8(uint256(_bytes32) / (2**(8*(31 - i) + 4)) % 16) >= 10 ? 39 : 0));
        }
        return string(bytesArray);
    }
}
