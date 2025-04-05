// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "forge-std/console.sol";

import {AIOracleServiceManager} from "../src/oracle/AIOracleServiceManager.sol";
import {AIAgentRegistry} from "../src/oracle/AIAgentRegistry.sol";
import {AIAgent} from "../src/oracle/AIAgent.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IAIAgentRegistry} from "../src/interfaces/IAIAgentRegistry.sol";

import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import {CreateMarketParams} from "../src/types/MarketTypes.sol";

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

    // Configuration
    address constant UNISWAP_V4_MANAGER_SEPOLIA = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    address constant POOL_SWAP_TEST_SEPOLIA = 0x9140a78c1A137c7fF1c151EC8231272aF78a99A4;
    address constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // State variables for hook deployment
    address private hookAddress;
    bytes32 private hookSalt;
    address private deployer;
    address private oracleProxyAddress;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("UNISWAP_SEPOLIA_PK");
        deployer = vm.addr(deployerPrivateKey);

        // Deploy Collateral Token
        _deployCollateralToken(deployerPrivateKey);

        // Initialize other contracts (like PoolManager)
        _initializeContracts();
        _deployCoreInfrastructure(deployerPrivateKey);
        _mineHookAddress();

        vm.startBroadcast(deployerPrivateKey);
        _deployOracleProxy();
        _deployAndInitializeAgent();
        _registerAgent();
        _deployHook();
        _linkContracts();
        _verifyDeployment();
        vm.stopBroadcast();

        _saveAddresses();
        _printSummary();
    }

    // --- Helper Functions ---

    /// @notice Deploys the mock ERC20 collateral token.
    function _deployCollateralToken(uint256 deployerPrivateKey) internal {
        vm.startBroadcast(deployerPrivateKey);
        collateralToken = new ERC20Mock("Test USDC", "tUSDC", 6);
        console.log("Deployed Mock Collateral Token (tUSDC) at:", address(collateralToken));
        vm.stopBroadcast();
    }

    function _initializeContracts() internal {
        manager = PoolManager(UNISWAP_V4_MANAGER_SEPOLIA);
        poolSwapTest = PoolSwapTest(POOL_SWAP_TEST_SEPOLIA);
        console.log("PoolManager at", address(manager));
        console.log("PoolSwapTest at", address(poolSwapTest));
    }

    function _deployCoreInfrastructure(uint256 deployerPrivateKey) internal {
        vm.startBroadcast(deployerPrivateKey);
        poolCreationHelper = new PoolCreationHelper(address(manager));
        console.log("Deployed PoolCreationHelper at", address(poolCreationHelper));

        registry = new AIAgentRegistry();
        console.log("Deployed AIAgentRegistry at:", address(registry));

        oracleImplementation = new AIOracleServiceManager(address(registry));
        console.log("Deployed AIOracleServiceManager Implementation at:", address(oracleImplementation));
        vm.stopBroadcast();
    }

    function _mineHookAddress() internal {
        uint160 flags = uint160(Hooks.BEFORE_SWAP_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG) ^ (0x4444 << 144);

        (hookAddress, hookSalt) = HookMiner.find(
            CREATE2_DEPLOYER,
            flags,
            type(PredictionMarketHook).creationCode,
            abi.encode(manager, poolCreationHelper, deployer)
        );
        console.log("Predicted PredictionMarketHook address:", hookAddress);
    }

    function _deployOracleProxy() internal {
        bytes memory oracleInitializeData = abi.encodeWithSelector(
            AIOracleServiceManager.initialize.selector,
            deployer, // initialOwner for Oracle
            1, // minimumResponses
            10000, // consensusThreshold
            hookAddress // Initialize with the *predicted* hook address
        );

        TransparentUpgradeableProxy oracleProxyInstance = new TransparentUpgradeableProxy(
            address(oracleImplementation),
            deployer, // Proxy admin
            oracleInitializeData
        );

        oracleProxyAddress = address(oracleProxyInstance);
        oracleProxy = AIOracleServiceManager(payable(oracleProxyAddress));
        console.log("Deployed Oracle Proxy at:", oracleProxyAddress);
    }

    function _deployAndInitializeAgent() internal {
        agent = new AIAgent();
        console.log("Deployed AIAgent at:", address(agent));
        agent.initialize(
            oracleProxyAddress, // _serviceManager (the actual Oracle proxy)
            "GPT-4", // _modelType
            "v1.0", // _modelVersion
            "MyAIAgentNFT", // _name
            "AGENT" // _symbol
        );
        console.log("AIAgent Initialized.");
    }

    function _registerAgent() internal {
        try registry.registerAgent(address(agent)) {
            console.log("Agent registered in Registry successfully.");
        } catch Error(string memory reason) {
            console.log("WARN: Failed to register agent:", reason);
        } catch {
            console.log("WARN: Unknown error registering agent.");
        }
    }

    function _deployHook() internal {
        hook = new PredictionMarketHook{salt: hookSalt}(manager, poolCreationHelper, deployer);
        require(address(hook) == hookAddress, "Hook address mismatch after CREATE2 deploy");
        require(address(hook) != address(0), "Hook deployment failed");
        console.log("Deployed PredictionMarketHook via Forge CREATE2 at:", address(hook));
    }

    function _linkContracts() internal {
        console.log("Setting Oracle address on Hook...");
        hook.setOracleServiceManager(oracleProxyAddress);
        console.log("Oracle address set on Hook.");
    }

    function _verifyDeployment() internal view {
        console.log("Verifying deployment links...");
        address oracleKnownHook = oracleProxy.predictionMarketHook();
        console.log("  Oracle known Hook address:", oracleKnownHook);
        require(oracleKnownHook == address(hook), "Oracle did not initialize with correct Hook address!");

        address hookKnownOracle = hook.aiOracleServiceManager();
        console.log("  Hook known Oracle address:", hookKnownOracle);
        require(hookKnownOracle == oracleProxyAddress, "Hook did not initialize with correct Oracle address!");
        console.log("Deployment links verified.");
    }

    function _saveAddresses() internal {
        string memory addressesJson = string.concat(
            "{\n",
            "  \"chainId\": ",
            vm.toString(block.chainid),
            ",\n",
            "  \"deployer\": \"",
            vm.toString(deployer),
            "\",\n",
            "  \"collateralToken\": \"",
            vm.toString(address(collateralToken)),
            "\",\n",
            "  \"poolManager\": \"",
            vm.toString(address(manager)),
            "\",\n",
            "  \"poolSwapTest\": \"",
            vm.toString(address(poolSwapTest)),
            "\",\n",
            "  \"aiAgentRegistry\": \"",
            vm.toString(address(registry)),
            "\",\n",
            "  \"aiOracleServiceManagerImpl\": \"",
            vm.toString(address(oracleImplementation)),
            "\",\n",
            "  \"aiOracleServiceManagerProxy\": \"",
            vm.toString(oracleProxyAddress),
            "\",\n",
            "  \"aiAgent\": \"",
            vm.toString(address(agent)),
            "\",\n",
            "  \"poolCreationHelper\": \"",
            vm.toString(address(poolCreationHelper)),
            "\",\n",
            "  \"predictionMarketHook\": \"",
            vm.toString(address(hook)),
            "\"\n",
            "}"
        );
        vm.writeFile("script/config/addresses.json", addressesJson);
        console.log("\nAddresses saved to script/config/addresses.json");
    }

    function _printSummary() internal view {
        console.log("\n Deployment Summary ");
        console.log("---------------------------------");
        console.log("Network: Unichain Sepolia (", block.chainid, ")");
        console.log("Deployer:", deployer);
        console.log("---------------------------------");
        console.log("Collateral Token (tUSDC):", address(collateralToken));
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
