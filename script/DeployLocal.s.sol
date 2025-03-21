// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/oracle/AIOracleServiceManager.sol";
import "../src/oracle/AIAgentRegistry.sol";
import "../src/oracle/AIAgent.sol";
import "../src/PredictionMarketHook.sol";
import {PoolManager as UniswapPoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
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
    address constant REGISTRY_ADDRESS = 0xCf7Ed3AccA5a467e9e704C703E8D87F634fB0Fc9;
    address constant AGENT_ADDRESS = 0xDc64a140Aa3E981100a9becA4E685f962f0cF6C9;
    address constant ORACLE_ADDRESS = 0x9A9f2CCfdE556A7E9Ff0848998Aa4a0CFD8863AE;
    
    // Add this line to declare the missing variable
    address private oracleAddress;

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
        createPredictionMarketTestTask();
        
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
        // AVS-related addresses for testing
        address avsDirectory = deployer; 
        address stakeRegistry = deployer;
        address rewardsCoordinator = deployer;
        address delegationManager = deployer;
        address allocationManager = deployer;
        
        if (isContract(ORACLE_ADDRESS)) {
            console.log("Using existing AIOracleServiceManager at:", ORACLE_ADDRESS);
            oracle = AIOracleServiceManager(ORACLE_ADDRESS);
        } else {
            // For first deployment, deploy the Oracle the normal way
            oracle = new AIOracleServiceManager(
                avsDirectory,
                stakeRegistry,
                rewardsCoordinator,
                delegationManager,
                allocationManager
            );
            
            // Verify the address isn't what we expected - only on first run
            if (address(oracle) != ORACLE_ADDRESS) {
                console.log("Warning: Oracle deployed at", address(oracle), "instead of expected", ORACLE_ADDRESS);
                console.log("Please update the ORACLE_ADDRESS constant in DeployLocal.s.sol");
            }
        }
        
        oracleAddress = address(oracle);
        console.log("AIOracleServiceManager at:", oracleAddress);
        
        // Note: We're skipping explicit initialization as it's automatically done in the constructor
        // Try to create an initial task to ensure the Oracle is working properly
        try oracle.createNewTask("Initial Oracle Test Task") {
            console.log("Created initial test task in Oracle");
            uint32 taskNum = oracle.latestTaskNum();
            console.log("Latest task number:", taskNum);
        } catch Error(string memory reason) {
            console.log("Failed to create initial task:", reason);
        }
        
        // Deploy or use existing AIAgentRegistry
        if (isContract(REGISTRY_ADDRESS)) {
            console.log("Using existing AIAgentRegistry at:", REGISTRY_ADDRESS);
            registry = AIAgentRegistry(REGISTRY_ADDRESS);
        } else {
            // Deploy AIAgentRegistry with service manager
            registry = new AIAgentRegistry(oracleAddress);
            console.log("AIAgentRegistry deployed at:", address(registry));
        }
        
        // Deploy or use existing AIAgent
        if (isContract(AGENT_ADDRESS)) {
            console.log("Using existing AIAgent at:", AGENT_ADDRESS);
            agent = AIAgent(AGENT_ADDRESS);
        } else {
            // Deploy AIAgent for testing (with 3 parameters)
            agent = new AIAgent(
                oracleAddress,       // Service manager address (use new oracle address)
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
        
        // IMPORTANT: For Uniswap v4, the flags need to be in specific positions
        // The before swap flag is at bit 0, before remove liquidity at bit 10, and before add liquidity at bit 8
        uint160 hookFlags = uint160(
            Hooks.BEFORE_SWAP_FLAG | 
            Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG | 
            Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        );
        
        console.log("Hook flags value:", uint256(hookFlags));
        
        // Prepare hook creation bytecode
        bytes memory creationCode = type(PredictionMarketHook).creationCode;
        bytes memory constructorArgs = abi.encode(
            poolManager, 
            modifyLiquidityRouter,
            poolCreationHelper
        );
        bytes memory bytecode = abi.encodePacked(creationCode, constructorArgs);
        
        // Search for a valid salt
        bytes32 salt;
        address predictedAddress;
        bool found = false;
        
        // Reduce number of attempts from 20000 to 5000
        uint256 maxAttempts = 5000;
        console.log("Searching for valid hook address (up to %d attempts)...", maxAttempts);
        
        for (uint256 i = 0; i < maxAttempts && !found; i++) {
            // Use a more varied salt to increase chances of finding a valid address
            salt = keccak256(abi.encodePacked(i, address(this), block.timestamp, msg.sender));
            
            // Calculate the address that would be created with this salt
            predictedAddress = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff),
                address(this),
                salt,
                keccak256(bytecode)
            )))));
            
            // IMPORTANT: Only check the bits that correspond to the flags we need
            // Each hook permission corresponds to a specific bit in the address
            if (uint160(predictedAddress) & 0xFFFF == hookFlags) {
                found = true;
                console.log("Found valid hook address on attempt", i);
                console.log("Address:", predictedAddress);
                console.log("Lower 16 bits:", uint256(uint160(predictedAddress) & 0xFFFF));
                break;
            }
            
            // Log progress every 1000 attempts
            if (i > 0 && i % 1000 == 0) {
                console.log("Searched %d addresses so far...", i);
            }
        }
        
        if (!found) {
            console.log("Failed to find a valid hook address after %d attempts", maxAttempts);
            console.log("Try running the script again with a different deployer address");
            return;
        }
        
        // Deploy the hook with CREATE2
        address deployedHook;
        assembly {
            deployedHook := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        
        if (deployedHook == address(0)) {
            // Get revert reason if possible
            console.log("Hook deployment failed. This could be due to contract size exceeding the 24KB limit.");
            console.log("Try enabling the optimizer in foundry.toml or splitting the contract into smaller parts.");
            return;
        }
        
        // Verify the deployed address matches what we calculated
        if (deployedHook != predictedAddress) {
            console.log("WARNING: Deployed hook address doesn't match predicted address!");
            console.log("Predicted:", predictedAddress);
            console.log("Actual:", deployedHook);
        }
        
        predictionMarket = PredictionMarketHook(deployedHook);
        console.log("PredictionMarketHook deployed at:", deployedHook);
        
        // Add an extra check for the hook code size
        uint256 codeSize;
        assembly {
            codeSize := extcodesize(deployedHook)
        }
        console.log("PredictionMarketHook code size:", codeSize, "bytes");
    }
    
    // Create a test task for prediction markets
    function createPredictionMarketTestTask() private {
        try oracle.createNewTask("Prediction market question: Will ETH price exceed $4000 by April 1st, 2025? Please respond with YES or NO.") {
            console.log("Created prediction market test task");
            uint32 taskNum = oracle.latestTaskNum();
            console.log("Latest task number after creating prediction market task:", taskNum);
        } catch Error(string memory reason) {
            console.log("Failed to create prediction market task:", reason);
        }
    }
    
    // Log all deployed addresses
    function logDeployedAddresses() private view {
        console.log("\n=== Deployment Summary ===");
        console.log("MockUSDC: ", address(usdc));
        console.log("AIOracleServiceManager: ", oracleAddress);
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
