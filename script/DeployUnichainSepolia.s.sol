// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";

import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAIAgentRegistry} from "../src/interfaces/IAIAgentRegistry.sol";

import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";
import "forge-std/console.sol";
// Uniswap libraries
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";

contract DeployUniswapSepolia is Script {

    // Deployed Contract Instances/Addresses
    AIAgentRegistry public registry;
    AIOracleServiceManager public oracleImplementation;
    AIOracleServiceManager public oracleProxy;
    AIAgent public agent;

    PoolManager public manager;
    PredictionMarketHook public hook;
    PoolSwapTest public poolSwapTest;
    PoolCreationHelper public poolCreationHelper;
    ERC20Mock public collateralToken;
    uint256 public COLLATERAL_AMOUNT = 100 * 1e6; // 100 USDC

    // Configuration
    address constant UNISWAP_V4_MANAGER_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Uniswap infrastructure
        manager = PoolManager(UNISWAP_V4_MANAGER_SEPOLIA);
        console.log("PoolManager at", address(manager));

        // Deploy test routers
        poolSwapTest = PoolSwapTest(0x9140a78c1A137c7fF1c151EC8231272aF78a99A4);
        console.log("PoolSwapTest at", address(poolSwapTest));

        // Deploy PoolCreationHelper
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));

        // Deploy Registry
        registry = new AIAgentRegistry();
        console.log("Deployed AIAgentRegistry at:", address(registry));

        // Deploy Oracle Implementation
        oracleImplementation = new AIOracleServiceManager(address(registry));
        console.log("Deployed AIOracleServiceManager Implementation at:", address(oracleImplementation));

        // Stop broadcast for HookMiner
        vm.stopBroadcast();
        
        // Hook mining code
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG
        ) ^ (0x4444 << 144); // Namespace the hook to avoid collisions

        address CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PredictionMarketHook).creationCode,
            abi.encode(manager, poolCreationHelper, deployer)
        );

        console.log("Deploying PredictionMarketHook at", hookAddress);

        vm.startBroadcast(deployerPrivateKey);

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

        // --- Deploy and Initialize AIAgent ---
        agent = new AIAgent();
        console.log("Deployed AIAgent at:", address(agent));
        agent.initialize(
            deployer,                   // _initialOwner (e.g., deployer)
            oracleProxyAddress,         // _serviceManager (the actual Oracle proxy)
            "GPT-4",                    // _modelType (example)
            "v1.0",                     // _modelVersion (example)
            "MyAIAgentNFT",             // _name (example for ERC721)
            "AGENT"                     // _symbol (example for ERC721)
        );
        console.log("AIAgent Initialized.");


        // --- Try Registering Agent ---
        try registry.registerAgent(address(agent)) {
            console.log("Agent registered in Registry successfully.");
        } catch Error(string memory reason) {
            console.log("WARN: Failed to register agent:", reason);
            // Note: Registration might fail if deployer != registry owner
            // or if agent.initialize was not called correctly.
        } catch {
            console.log("WARN: Unknown error registering agent.");
        }

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

        vm.stopBroadcast();

        console.log("\n Deployment Summary ");
        console.log("---------------------------------");
        console.log("Network: Unichain Sepolia (", block.chainid, ")");
        console.log("Deployer:", deployer);
        console.log("---------------------------------");
        console.log("PoolManager:", address(manager));
        console.log("PoolSwapTest:", address(poolSwapTest));
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