// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {PredictionMarketHook} from "../src/PredictionMarketHook.sol";
import {PoolCreationHelper} from "../src/PoolCreationHelper.sol";
import "forge-std/console.sol";
import {stdJson} from "forge-std/StdJson.sol";

// Uniswap V4 Core libraries & interfaces
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol"; // Needed for Market struct access
import {Actions} from "v4-periphery/src/libraries/Actions.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";

// Uniswap V4 Test utilities
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
// Local project contracts & types
import {ERC20Mock} from "../test/utils/ERC20Mock.sol";
import {Market, MarketState} from "../src/types/MarketTypes.sol";
import {OutcomeToken} from "../src/OutcomeToken.sol";

/**
 * @title AddLiquidity
 * @notice This script loads core contract addresses (Hook, Manager, Helper) from addresses.json,
 *         loads the collateral token address, fetches existing market IDs directly from the hook,
 *         deploys a PoolModifyLiquidityTest router, ensures sufficient token balances,
 *         and adds liquidity to the fetched markets.
 * @dev Assumes addresses.json exists and is populated.
 */
contract AddLiquidity is Script {
    using stdJson for string;

    // --- Core Contracts (Loaded) ---
    PredictionMarketHook public hook;
    PoolManager public manager;
    IAllowanceTransfer private permit2;
    // PoolCreationHelper public poolCreationHelper; // Not directly needed by this script

    PositionManager public positionManager;

    function run() public {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        vm.startBroadcast(deployerPrivateKey);
        PoolManager manager = PoolManager(0x1F98400000000000000000000000000000000004);
        PredictionMarketHook hook = PredictionMarketHook(0xcB9903081b324B3a743E536D451705f9e1450880);
        PositionManager positionManager = PositionManager(payable(0x4529A01c7A0410167c5740C487A8DE60232617bf));
        ERC20Mock collateralToken = ERC20Mock(0xA5a2250b0170bdb9bd0904C0440717f00A506023);

        PoolKey memory poolKey = PoolKey({
            currency0: Currency.wrap(0xA5a2250b0170bdb9bd0904C0440717f00A506023),
            currency1: Currency.wrap(0xc3B3b75365Fe563454b007950b5B64f4f5096459),
            fee: 10000,
            hooks: IHooks(0xcB9903081b324B3a743E536D451705f9e1450880),
            tickSpacing: 100
        });

        ERC20Mock yesToken = ERC20Mock(0xc3B3b75365Fe563454b007950b5B64f4f5096459);
        /*
        yesToken.approve(address(positionManager), type(uint256).max);
        noToken.approve(address(positionManager), type(uint256).max);
        yesToken.approve(address(manager), type(uint256).max);
        noToken.approve(address(manager), type(uint256).max);
        yesToken.approve(address(hook), type(uint256).max);
        noToken.approve(address(hook), type(uint256).max);*/
        permit2 = IAllowanceTransfer(0x000000000022D473030F116dDEE9F6B43aC78BA3);
        ERC20Mock(yesToken).approve(address(permit2), type(uint256).max);
        permit2.approve(address(yesToken), address(positionManager), type(uint160).max, type(uint48).max);
        ERC20Mock(collateralToken).approve(address(permit2), type(uint256).max);
        permit2.approve(address(collateralToken), address(positionManager), type(uint160).max, type(uint48).max);

        bytes memory actions = abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR));
        bytes[] memory params = new bytes[](2);

        params[0] = abi.encode(poolKey, 0, 207000, 0.000001 ether, 1 ether, 1 ether, deployer, bytes(""));
        params[1] = abi.encode(poolKey.currency0, poolKey.currency1);

        // Increase deadline further if needed (e.g., 30 minutes = 1800 seconds)
        uint256 deadline = block.timestamp + 1800; // Or even longer if necessary

        uint256 valueToPass = 0;

        positionManager.modifyLiquidities{value: valueToPass}(abi.encode(actions, params), deadline);

        vm.stopBroadcast();
    }
}
