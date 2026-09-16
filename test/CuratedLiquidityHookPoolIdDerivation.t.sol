// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {CuratedLiquidityHook} from "../src/CuratedLiquidityHook.sol";
import {MockVault} from "./mocks/MockVault.sol";

/// @notice Stage 6A.1 regression coverage: the hook must derive its own `poolId` from
/// `address(this)` rather than receive a precomputed one, so that real CREATE2/HookMiner
/// address mining is not circular (see CuratedLiquidityHook's constructor doc comment).
contract CuratedLiquidityHookPoolIdDerivationTest is Test {
    address internal constant POOL_MANAGER = address(0xBEEF);
    uint160 internal constant FLAGS = uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG);

    Currency internal constant CURRENCY0 = Currency.wrap(address(0x1111));
    Currency internal constant CURRENCY1 = Currency.wrap(address(0x2222));
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    MockVault internal vault;

    function setUp() public {
        vault = new MockVault(-600, 600);
    }

    function _deployHookAt(address hookAddress) internal returns (CuratedLiquidityHook) {
        bytes memory constructorArgs =
            abi.encode(IPoolManager(POOL_MANAGER), address(vault), CURRENCY0, CURRENCY1, FEE, TICK_SPACING);
        deployCodeTo("CuratedLiquidityHook.sol:CuratedLiquidityHook", constructorArgs, hookAddress);
        return CuratedLiquidityHook(hookAddress);
    }

    /// A. The hook's stored poolId equals PoolKey{..., hooks: address(hook)}.toId().
    function test_poolId_derivedFromOwnAddress() public {
        address hookAddress = address(FLAGS);
        CuratedLiquidityHook hook = _deployHookAt(hookAddress);

        PoolId expected = PoolKey({
            currency0: CURRENCY0, currency1: CURRENCY1, fee: FEE, tickSpacing: TICK_SPACING, hooks: IHooks(hookAddress)
        }).toId();

        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(expected), "poolId must match self-derived PoolKey.toId()");
    }

    /// B. The stored poolId changes if the hook address changes, with every other input fixed —
    /// proving poolId is a genuine function of address(this), not a value baked in independently
    /// of where the hook actually lands.
    function test_poolId_changesWithHookAddress() public {
        address hookAddressA = address(FLAGS);
        // Bits above the 14-bit permission mask are free to vary without breaking
        // BaseHook's permission validation, so this is still a deployable hook address.
        address hookAddressB = address(FLAGS | (uint160(1) << 20));
        assertTrue(hookAddressA != hookAddressB, "test addresses must actually differ");

        CuratedLiquidityHook hookA = _deployHookAt(hookAddressA);
        CuratedLiquidityHook hookB = _deployHookAt(hookAddressB);

        assertTrue(
            PoolId.unwrap(hookA.poolId()) != PoolId.unwrap(hookB.poolId()),
            "different hook addresses must produce different poolIds"
        );
    }
}
