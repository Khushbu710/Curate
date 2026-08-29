// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CuratedLiquidityHook} from "../src/CuratedLiquidityHook.sol";
import {MockVault} from "./mocks/MockVault.sol";

contract CuratedLiquidityHookTest is Test {
    address internal constant POOL_MANAGER = address(0xBEEF);

    int24 internal constant APPROVED_TICK_LOWER = -600;
    int24 internal constant APPROVED_TICK_UPPER = 600;

    CuratedLiquidityHook internal hook;
    MockVault internal vault;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        vault = new MockVault(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(0x1111)),
            currency1: Currency.wrap(address(0x2222)),
            fee: 3000,
            tickSpacing: 60,
            hooks: IHooks(_hookAddress())
        });
        poolId = poolKey.toId();

        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(vault), poolId);
        deployCodeTo("CuratedLiquidityHook.sol:CuratedLiquidityHook", constructorArgs, _hookAddress());
        hook = CuratedLiquidityHook(_hookAddress());
    }

    /// @dev An address whose low bits carry exactly BEFORE_ADD_LIQUIDITY_FLAG | BEFORE_REMOVE_LIQUIDITY_FLAG
    /// and nothing else, so BaseHook's constructor-time `validateHookPermissions` accepts it.
    function _hookAddress() internal pure returns (address) {
        return address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
    }

    function _params(int24 tickLower, int24 tickUpper, int256 liquidityDelta)
        internal
        pure
        returns (ModifyLiquidityParams memory)
    {
        return ModifyLiquidityParams({
            tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
        });
    }

    // ── 1. Correct hook permissions ─────────────────────────────────────────

    function test_permissions_onlyAddAndRemoveLiquidityEnabled() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeAddLiquidity, "beforeAddLiquidity should be enabled");
        assertTrue(p.beforeRemoveLiquidity, "beforeRemoveLiquidity should be enabled");
        assertFalse(p.beforeInitialize);
        assertFalse(p.afterInitialize);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeSwap);
        assertFalse(p.afterSwap);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.beforeSwapReturnDelta);
        assertFalse(p.afterSwapReturnDelta);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
    }

    // ── 2/3. beforeAddLiquidity range enforcement ───────────────────────────

    function test_beforeAddLiquidity_approvedRange_succeeds() public {
        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.beforeAddLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, 1000), ""
        );
        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_wrongRange_reverts() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CuratedLiquidityHook.RangeNotApproved.selector, APPROVED_TICK_LOWER + 60, APPROVED_TICK_UPPER
            )
        );
        hook.beforeAddLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER + 60, APPROVED_TICK_UPPER, 1000), ""
        );
    }

    // ── 4/5. beforeRemoveLiquidity range enforcement for genuine removals ──

    function test_beforeRemoveLiquidity_approvedRange_genuineRemoval_succeeds() public {
        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.beforeRemoveLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, -1000), ""
        );
        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }

    function test_beforeRemoveLiquidity_wrongRange_genuineRemoval_reverts() public {
        vm.prank(POOL_MANAGER);
        vm.expectRevert(
            abi.encodeWithSelector(
                CuratedLiquidityHook.RangeNotApproved.selector, APPROVED_TICK_LOWER, APPROVED_TICK_UPPER + 60
            )
        );
        hook.beforeRemoveLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER + 60, -1000), ""
        );
    }

    // ── 6. liquidityDelta == 0 fee poke stays permissionless w.r.t. range ──

    function test_beforeRemoveLiquidity_zeroDelta_feePoke_allowed_evenOffRange() public {
        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.beforeRemoveLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER + 60, APPROVED_TICK_UPPER + 60, 0), ""
        );
        assertEq(selector, IHooks.beforeRemoveLiquidity.selector);
    }

    // ── 7. Only PoolManager may invoke the external callback wrappers ──────

    function test_beforeAddLiquidity_directCall_notPoolManager_reverts() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(vault), poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, 1000), "");
    }

    function test_beforeRemoveLiquidity_directCall_notPoolManager_reverts() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(
            address(vault), poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, -1000), ""
        );
    }

    // ── 8. Wrong sender/vault identity rejected ─────────────────────────────

    function test_beforeAddLiquidity_wrongSender_reverts() public {
        address notVault = address(0xDEAD);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityHook.NotVault.selector, notVault));
        hook.beforeAddLiquidity(notVault, poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, 1000), "");
    }

    function test_beforeRemoveLiquidity_wrongSender_reverts_evenForFeePoke() public {
        address notVault = address(0xDEAD);
        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityHook.NotVault.selector, notVault));
        hook.beforeRemoveLiquidity(notVault, poolKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, 0), "");
    }

    // ── 9. PoolKey validation ────────────────────────────────────────────────

    function test_beforeAddLiquidity_wrongPool_reverts() public {
        PoolKey memory otherKey = poolKey;
        otherKey.fee = 500; // same hook address, different key => different poolId
        PoolId otherPoolId = otherKey.toId();

        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityHook.WrongPool.selector, otherPoolId));
        hook.beforeAddLiquidity(address(vault), otherKey, _params(APPROVED_TICK_LOWER, APPROVED_TICK_UPPER, 1000), "");
    }

    // ── 10. Boundary tick ranges: exact match succeeds, off-by-one reverts ──

    function test_beforeAddLiquidity_boundaryTicks_exactMatch_succeeds() public {
        int24 lower = -887220; // divisible by tickSpacing (60), near MIN_TICK
        int24 upper = 887220; // near MAX_TICK
        vault.setApprovedRange(lower, upper);

        vm.prank(POOL_MANAGER);
        bytes4 selector = hook.beforeAddLiquidity(address(vault), poolKey, _params(lower, upper, 1000), "");
        assertEq(selector, IHooks.beforeAddLiquidity.selector);
    }

    function test_beforeAddLiquidity_boundaryTicks_offByOneTickSpacing_reverts() public {
        int24 lower = -887220;
        int24 upper = 887220;
        vault.setApprovedRange(lower, upper);

        vm.prank(POOL_MANAGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityHook.RangeNotApproved.selector, lower, upper - 60));
        hook.beforeAddLiquidity(address(vault), poolKey, _params(lower, upper - 60, 1000), "");
    }
}
