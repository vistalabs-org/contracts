// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/oracle/AIOracleServiceManager.sol";
import "../src/oracle/AIAgentRegistry.sol";
import "../src/oracle/AIAgent.sol";
import "../src/PredictionMarketHook.sol";
import {PoolManager as UniswapPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import "../src/PoolCreationHelper.sol";

// Mock USDC token for testing
contract MockUSDC {
    string public name = "Mock USDC";
    string public symbol = "mUSDC";
    uint8 public decimals = 6;
    uint256 public totalSupply = 1000000 * 10**6; // 1 million USDC
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    
    constructor() {
        balanceOf[msg.sender] = totalSupply;
    }
    
    function transfer(address to, uint256 value) public returns (bool) {
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }
    
    function approve(address spender, uint256 value) public returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }
    
    function transferFrom(address from, address to, uint256 value) public returns (bool) {
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }
    
    // Mint function for testing
    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
        emit Transfer(address(0), to, amount);
    }
}

contract DeployLocal is Script {
    // Storage variables to share between functions
    address private deployer;
    MockUSDC private usdc;
    AIOracleServiceManager private oracle;
    AIAgentRegistry private registry;
    AIAgent private agent;
    UniswapPoolManager private poolManager;
    PoolModifyLiquidityTest private modifyLiquidityRouter;
    PoolCreationHelper private poolCreationHelper;
    PredictionMarketHook private predictionMarket;
    
    // Addresses of existing contracts
    address constant USDC_ADDRESS = 0x5FbDB2315678afecb367f032d93F642f64180aa3;
    address constant ORACLE_ADDRESS = 0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512;
    address constant REGISTRY_ADDRESS = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    address constant AGENT_ADDRESS = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;

    function run() external {
        // Get the deployer's private key
        uint256 privateKey = vm.envUint("PRIVATE_KEY");
        deployer = vm.addr(privateKey);
        
        console.log("Deploying contracts with address:", deployer);
        
        vm.startBroadcast(privateKey);
        
        // Deploy in steps to avoid stack too deep errors
        deployMockUSDC();
        deployOracleAndRegistryAgent();
        deployUniswapAndPredictionMarket();
        
        // Mint tokens after all deployments
        usdc.mint(deployer, 10000 * 10**6); // 10,000 USDC
        
        vm.stopBroadcast();
        
        logDeployedAddresses();
        
        console.log("Local deployment completed!");
    }
    
    // Deploy MockUSDC
    function deployMockUSDC() private {
        // Check if already deployed
        if (isContract(USDC_ADDRESS)) {
            console.log("Using existing MockUSDC at:", USDC_ADDRESS);
            usdc = MockUSDC(USDC_ADDRESS);
        } else {
            usdc = new MockUSDC();
            console.log("MockUSDC deployed at:", address(usdc));
        }
    }
    
    // Deploy Oracle, Registry, and Agent
    function deployOracleAndRegistryAgent() private {
        // Deploy service manager or use existing one
        if (isContract(ORACLE_ADDRESS)) {
            console.log("Using existing AIOracleServiceManager at:", ORACLE_ADDRESS);
            oracle = AIOracleServiceManager(ORACLE_ADDRESS);
            // Skip initialization for existing contract - it's already initialized
        } else {
            // AVS-related addresses for testing
            address avsDirectory = deployer; 
            address stakeRegistry = deployer;
            address rewardsCoordinator = deployer;
            address delegationManager = deployer;
            address allocationManager = deployer;
            
            // Deploy AIOracleServiceManager with required parameters
            oracle = new AIOracleServiceManager(
                avsDirectory,
                stakeRegistry,
                rewardsCoordinator,
                delegationManager,
                allocationManager
            );
            console.log("AIOracleServiceManager deployed at:", address(oracle));
            
            // Initialize only newly deployed contract
            try oracle.initialize(
                deployer,            // initial owner
                deployer,            // rewards initiator
                2,                   // minimum responses for consensus
                7000                 // consensus threshold of 70%
            ) {
                console.log("Oracle initialized successfully");
            } catch Error(string memory reason) {
                console.log("Oracle initialization failed:", reason);
            }
        }
        
        // Deploy or use existing AIAgentRegistry
        if (isContract(REGISTRY_ADDRESS)) {
            console.log("Using existing AIAgentRegistry at:", REGISTRY_ADDRESS);
            registry = AIAgentRegistry(REGISTRY_ADDRESS);
        } else {
            // Deploy AIAgentRegistry with service manager
            registry = new AIAgentRegistry(address(oracle));
            console.log("AIAgentRegistry deployed at:", address(registry));
        }
        
        // Deploy or use existing AIAgent
        if (isContract(AGENT_ADDRESS)) {
            console.log("Using existing AIAgent at:", AGENT_ADDRESS);
            agent = AIAgent(AGENT_ADDRESS);
        } else {
            // Deploy AIAgent for testing (with 3 parameters)
            agent = new AIAgent(
                address(oracle),     // Service manager address
                "OpenAI",            // Model type
                "gpt-4-turbo"        // Model version
            );
            console.log("AIAgent deployed at:", address(agent));
            
            // Try to register the agent in the registry if it's not already registered
            try registry.registerAgent(address(agent)) {
                console.log("Agent registered successfully");
            } catch {
                console.log("Agent already registered or registration failed");
            }
        }
    }
    
    // Deploy Uniswap and PredictionMarket
    function deployUniswapAndPredictionMarket() private {
        // Deploy Uniswap infrastructure needed for PredictionMarketHook
        poolManager = new UniswapPoolManager(deployer);
        console.log("UniswapPoolManager deployed at:", address(poolManager));
        
        modifyLiquidityRouter = new PoolModifyLiquidityTest(poolManager);
        console.log("PoolModifyLiquidityTest deployed at:", address(modifyLiquidityRouter));
        
        poolCreationHelper = new PoolCreationHelper(address(poolManager));
        console.log("PoolCreationHelper deployed at:", address(poolCreationHelper));
        
        // For Uniswap v4 hooks, we need to deploy at a special address with the correct hook bits set
        // Check for errors and use try-catch
        try new PredictionMarketHook(
            poolManager,
            modifyLiquidityRouter,
            poolCreationHelper
        ) returns (PredictionMarketHook hook) {
            predictionMarket = hook;
            console.log("PredictionMarketHook deployed at:", address(predictionMarket));
        } catch Error(string memory reason) {
            console.log("PredictionMarketHook deployment failed:", reason);
            console.log("Note: For production, use a factory with CREATE2 to deploy at a valid hook address");
        } catch {
            console.log("PredictionMarketHook deployment failed with unknown error");
            console.log("Note: For production, use a factory with CREATE2 to deploy at a valid hook address");
        }
    }
    
    // Log all deployed addresses
    function logDeployedAddresses() private view {
        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDC: ", address(usdc));
        console.log("AIOracleServiceManager: ", address(oracle));
        console.log("AIAgentRegistry: ", address(registry));
        console.log("AIAgent: ", address(agent));
        console.log("UniswapPoolManager: ", address(poolManager));
        console.log("PoolModifyLiquidityTest: ", address(modifyLiquidityRouter));
        console.log("PoolCreationHelper: ", address(poolCreationHelper));
        console.log("PredictionMarketHook: ", address(predictionMarket));
    }
    
    // Helper function to check if an address is a contract
    function isContract(address addr) private view returns (bool) {
        uint32 size;
        assembly {
            size := extcodesize(addr)
        }
        return size > 0;
    }
}
