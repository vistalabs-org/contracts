// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

// Oracle Imports
import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAIAgentRegistry} from "../src/interfaces/IAIAgentRegistry.sol";

// Hook Imports
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol"; // Keep if creating test markets
import {ERC20Mock} from "../test/utils/ERC20Mock.sol"; // Keep if creating test markets/collateral

// Uniswap Imports
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";

// Interface for the standard CREATE2 Deployer
interface ICreate2Deployer {
    function deploy(bytes memory code, bytes32 salt) external returns (address);
}

contract DeployAllSepolia is Script {

    // Deployed Contract Instances/Addresses
    PoolManager public manager;
    AIAgentRegistry public registry;
    AIOracleServiceManager public oracleImplementation;
    AIOracleServiceManager public oracleProxy;
    AIAgent public agent;
    PoolCreationHelper public poolCreationHelper;
    PredictionMarketHook public hook;

    // Configuration
    address constant UNISWAP_V4_MANAGER_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    // CREATE2 Deployer used by HookMiner by default (on many chains)
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;


    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Starting deployment on Unichain Sepolia...");
        console.log("Deployer Address:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // --- 1. Connect to existing Manager ---
        manager = PoolManager(UNISWAP_V4_MANAGER_SEPOLIA);
        console.log("Connected to PoolManager at:", address(manager));

        // --- 2. Deploy Oracle Components ---
        // Deploy Registry (no longer needs Oracle address)
        registry = new AIAgentRegistry();
        console.log("Deployed AIAgentRegistry at:", address(registry));

        // Deploy Oracle Implementation (passing the actual registry address)
        oracleImplementation = new AIOracleServiceManager(address(registry));
        console.log("Deployed AIOracleServiceManager Implementation at:", address(oracleImplementation));

        // Deploy PoolCreationHelper (can be done before Oracle/Agent)
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at:", address(poolCreationHelper));

        // --- 3. Predict Hook Address ---
        // Stop broadcast for HookMiner calculation (doesn't deploy)
        vm.stopBroadcast();

        // Renamed hookFlags -> flags to match DeployUnichainSepolia.s.sol
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        ) ^ (0x4444 << 144); // Namespace the hook to avoid collisions

        // **IMPORTANT**: The Oracle Proxy address is *not yet known* because we need the *predicted*
        // Hook address to initialize the Oracle Proxy correctly.
        // We will deploy the proxy *after* predicting the hook address.

        // Predict Hook Address using inline arguments to match DeployUnichainSepolia.s.sol
        // Renamed predictedHookAddress -> hookAddress
        console.log("Predicting Hook address using HookMiner...");
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PredictionMarketHook).creationCode,
            abi.encode(manager, poolCreationHelper, deployer)
        );
        console.log("Predicted Hook address:", hookAddress); // Use new var name
        console.log("Calculated Salt:", vm.toString(salt));

        // --- 4. Deploy Oracle Proxy (initializing with predicted Hook address) ---
        vm.startBroadcast(deployerPrivateKey); // Restart broadcast for deployment

        // Prepare Oracle initialization data (using hookAddress)
        bytes memory oracleInitializeData = abi.encodeWithSelector(
            AIOracleServiceManager.initialize.selector,
            deployer,                   // initialOwner for Oracle
            1,                          // minimumResponses (e.g., 1 for testing)
            10000,                      // consensusThreshold (e.g., 10000 = 100% for testing)
            hookAddress                 // Initialize with the *predicted* hook address (use new var name)
        );

        // Deploy the Oracle Proxy
        TransparentUpgradeableProxy oracleProxyInstance = new TransparentUpgradeableProxy(
            address(oracleImplementation),
            deployer, // Proxy admin
            oracleInitializeData
        );
        address oracleProxyAddress = address(oracleProxyInstance);
        oracleProxy = AIOracleServiceManager(payable(oracleProxyAddress)); // Get usable instance
        console.log("Deployed Oracle Proxy at:", oracleProxyAddress);

        // --- Deploy and Initialize AIAgent NOW ---
        console.log("Deploying AIAgent...");
        agent = new AIAgent(/* constructor args if any */);
        console.log("Deployed AIAgent at:", address(agent));

        console.log("Initializing AIAgent...");
        agent.initialize(
            deployer,                   // _initialOwner (e.g., deployer)
            oracleProxyAddress,         // _serviceManager (the actual Oracle proxy)
            "GPT-4",                    // _modelType (example)
            "v1.0",                     // _modelVersion (example)
            "MyAIAgentNFT",             // _name (example for ERC721)
            "AGENT"                     // _symbol (example for ERC721)
        );
        console.log("AIAgent Initialized.");

        // --- Try Registering Agent (Now only fails if caller != owner or agent SM == 0) ---
        try registry.registerAgent(address(agent)) {
            console.log("Agent registered in Registry successfully.");
        } catch Error(string memory reason) {
            console.log("WARN: Failed to register agent:", reason);
            // Note: Registration might fail if deployer != registry owner
            // or if agent.initialize was not called correctly.
        } catch {
            console.log("WARN: Unknown error registering agent.");
        }

        // --- 5. Deploy PredictionMarketHook using CREATE2 ---
        // Use Forge's native CREATE2 deployment with the calculated salt.
        // Provide deployer as the initialOwner constructor argument.
        console.log("Attempting deployment of PredictionMarketHook via Forge CREATE2...");
        hook = new PredictionMarketHook{salt: salt}(manager, poolCreationHelper, deployer);

        // Verification (using hookAddress)
        require(address(hook) == hookAddress, "Forge CREATE2 Hook Address Mismatch!"); // Use new var name
        require(address(hook) != address(0), "Hook deployment failed!");

        console.log("Deployed PredictionMarketHook via Forge CREATE2 at:", address(hook));

        // --- 6. Set Oracle Address on Hook ---
        console.log("Setting Oracle address on Hook...");
        hook.setOracleServiceManager(oracleProxyAddress);
        console.log("Oracle address set on Hook.");

        // --- 7. Post-Deployment Sanity Checks (Optional) ---
        // Check if Oracle knows the Hook address correctly
        address oracleKnownHook = oracleProxy.predictionMarketHook();
        console.log("Oracle known Hook address:", oracleKnownHook);
        require(oracleKnownHook == address(hook), "Oracle did not initialize with correct Hook address!");

        // Check if Hook knows the Oracle address correctly
        address hookKnownOracle = hook.aiOracleServiceManager();
        console.log("Hook known Oracle address:", hookKnownOracle);
        require(hookKnownOracle == oracleProxyAddress, "Hook did not initialize with correct Oracle address!");


        // --- End Deployment ---
        vm.stopBroadcast();

        console.log("\n Deployment Summary ");
        console.log("---------------------------------");
        console.log("Network: Unichain Sepolia (", block.chainid, ")");
        console.log("Deployer:", deployer);
        console.log("---------------------------------");
        console.log("PoolManager:", address(manager));
        console.log("AIAgentRegistry:", address(registry));
        console.log("AIOracleServiceManager Impl:", address(oracleImplementation));
        console.log("AIOracleServiceManager Proxy:", oracleProxyAddress);
        console.log("AIAgent:", address(agent));
        console.log("PoolCreationHelper:", address(poolCreationHelper));
        console.log("PredictionMarketHook:", address(hook));
        console.log("---------------------------------");
        console.log("\nDeployment Complete!");
    }
}