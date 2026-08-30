// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {CuratedLiquidityVault} from "../src/CuratedLiquidityVault.sol";
import {CuratedLiquidityHook} from "../src/CuratedLiquidityHook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice A third party that is NOT the vault, attempting to add liquidity to the vault's pool
/// directly against PoolManager. Used to prove the hook stays live and enforcing after a
/// rebalance, not just at initial deployment.
contract RogueCaller is IUnlockCallback {
    IPoolManager internal immutable manager;
    PoolKey internal key;
    int24 internal tickLower;
    int24 internal tickUpper;

    constructor(IPoolManager _manager, PoolKey memory _key, int24 _tickLower, int24 _tickUpper) {
        manager = _manager;
        key = _key;
        tickLower = _tickLower;
        tickUpper = _tickUpper;
    }

    function attempt() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        manager.modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 1000, salt: bytes32(0)}),
            ""
        );
        return "";
    }
}

contract CuratedLiquidityVaultRebalanceTest is Test {
    address internal constant CURATOR = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);

    int24 internal constant INITIAL_TICK_LOWER = -600;
    int24 internal constant INITIAL_TICK_UPPER = 600;
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    PoolManager internal poolManager;
    CuratedLiquidityVault internal vault;
    CuratedLiquidityHook internal hook;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    PoolKey internal poolKey;
    PoolId internal poolId;

    function setUp() public {
        poolManager = new PoolManager(address(this));

        MockERC20 t0 = new MockERC20("Token A", "AAA");
        MockERC20 t1 = new MockERC20("Token B", "BBB");
        (tokenA, tokenB) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);

        address hookAddress = address(uint160(Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));

        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(hookAddress)
        });
        poolId = poolKey.toId();

        bytes32 vaultSalt = bytes32(uint256(1));
        bytes memory vaultCreationCode = abi.encodePacked(
            type(CuratedLiquidityVault).creationCode,
            abi.encode(IPoolManager(address(poolManager)), poolKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER)
        );
        address predictedVault = vm.computeCreate2Address(vaultSalt, keccak256(vaultCreationCode), address(this));

        bytes memory hookArgs = abi.encode(poolManager, predictedVault, poolId);
        deployCodeTo("CuratedLiquidityHook.sol:CuratedLiquidityHook", hookArgs, hookAddress);
        hook = CuratedLiquidityHook(hookAddress);

        vault = new CuratedLiquidityVault{salt: vaultSalt}(
            IPoolManager(address(poolManager)), poolKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER
        );
        assertEq(address(vault), predictedVault, "vault address prediction must match actual deployment");

        poolManager.initialize(poolKey, TickMath.getSqrtPriceAtTick(0));

        tokenA.mint(ALICE, 1_000_000 ether);
        tokenB.mint(ALICE, 1_000_000 ether);
        vm.prank(ALICE);
        tokenA.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        tokenB.approve(address(vault), type(uint256).max);
    }

    function _deposit(uint256 amount0, uint256 amount1) internal {
        vm.prank(ALICE);
        vault.deposit(amount0, amount1);
    }

    function _openInitialPosition() internal {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();
    }

    function _positionKey(int24 tickLower, int24 tickUpper) internal view returns (bytes32) {
        return keccak256(abi.encodePacked(address(vault), tickLower, tickUpper, bytes32(0)));
    }

    // ── 1/5/6/7/8/9/10/11/12/13/14. Successful rebalance, full invariant check ─

    function test_rebalance_rangeAtoB_succeeds() public {
        _openInitialPosition();

        uint256 vaultBalance0Before = tokenA.balanceOf(address(vault));
        uint256 vaultBalance1Before = tokenB.balanceOf(address(vault));

        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);

        // 5/11/12. Old position liquidity is exactly zero; old range cannot remain active.
        (uint128 oldLiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-600, 600));
        assertEq(oldLiquidity, 0);

        // 6/7/8/9. New position exists, owned by the vault, at the requested range, salt 0.
        (uint128 newLiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-1200, 1200));
        assertGt(newLiquidity, 0);
        assertEq(newLiquidity, vault.positionLiquidity());

        // 10. approved range == active range == new range.
        assertEq(vault.activeTickLower(), -1200);
        assertEq(vault.activeTickUpper(), 1200);
        (int24 approvedLower, int24 approvedUpper) = vault.approvedRange();
        assertEq(approvedLower, -1200);
        assertEq(approvedUpper, 1200);
        assertTrue(vault.positionActive());

        // 13. Token accounting remains internally consistent: idle reserves always match the
        // vault's real, undeployed token balances.
        assertEq(tokenA.balanceOf(address(vault)), vault.reserve0());
        assertEq(tokenB.balanceOf(address(vault)), vault.reserve1());

        // No tokens vanished or appeared: the vault's real balance only ever moved by what
        // actually left/entered via PoolManager during this one atomic operation.
        assertLe(tokenA.balanceOf(address(vault)), vaultBalance0Before);
        assertLe(tokenB.balanceOf(address(vault)), vaultBalance1Before);

        // 14. No unresolved PoolManager delta: reaching here at all already proves it (PoolManager
        // reverts with CurrencyNotSettled otherwise). Confirm no stray ERC-6909 claim either.
        assertEq(poolManager.balanceOf(address(vault), uint256(uint160(address(tokenA)))), 0);
        assertEq(poolManager.balanceOf(address(vault), uint256(uint160(address(tokenB)))), 0);
    }

    // ── 2/3. Curator-only ────────────────────────────────────────────────────

    function test_rebalance_nonCurator_reverts() public {
        _openInitialPosition();

        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, ALICE));
        vault.rebalance(-1200, 1200);
    }

    // ── 4. No active position ────────────────────────────────────────────────

    function test_rebalance_noActivePosition_reverts() public {
        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.NoActivePosition.selector);
        vault.rebalance(-1200, 1200);
    }

    // ── 17. Invalid range ────────────────────────────────────────────────────

    function test_rebalance_invalidRange_reverts() public {
        _openInitialPosition();

        vm.prank(CURATOR);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.InvalidRange.selector, int24(600), int24(600)));
        vault.rebalance(600, 600);
    }

    // ── 15/16. Hook stays live and enforcing after a rebalance ──────────────

    function _expectWrappedHookRevert(address rogue, bytes4 hookSelector) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                hookSelector,
                abi.encodeWithSelector(CuratedLiquidityHook.NotVault.selector, rogue),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_rebalance_hookRejectsRogue_atNewApprovedRange() public {
        _openInitialPosition();
        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);

        // A rogue directly targeting the pool at the NEW approved range must still be rejected —
        // proving the hook genuinely executed (and re-executes) against live state, not a stale
        // snapshot from before the rebalance.
        RogueCaller rogue = new RogueCaller(IPoolManager(address(poolManager)), poolKey, -1200, 1200);
        _expectWrappedHookRevert(address(rogue), IHooks.beforeAddLiquidity.selector);
        rogue.attempt();
    }

    function test_rebalance_hookRejectsRogue_atStaleOldRange() public {
        _openInitialPosition();
        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);

        // A rogue targeting the OLD range post-rebalance is rejected too (wrong sender, checked
        // before range) — the old range is not some lingering backdoor.
        RogueCaller rogue = new RogueCaller(IPoolManager(address(poolManager)), poolKey, -600, 600);
        _expectWrappedHookRevert(address(rogue), IHooks.beforeAddLiquidity.selector);
        rogue.attempt();
    }

    // ── 18. Price inside/above/below the new range ──────────────────────────

    function test_rebalance_toRangeAboveCurrentPrice_usesToken0Only() public {
        _openInitialPosition();

        vm.prank(CURATOR);
        vault.rebalance(6000, 12000);

        assertEq(vault.activeTickLower(), 6000);
        assertEq(vault.activeTickUpper(), 12000);
        assertGt(vault.positionLiquidity(), 0);
        // Entirely above current price -> 100% token0; whatever token1 was recovered from the old
        // (in-range) position stays fully idle.
        assertGt(vault.reserve1(), 0);
    }

    function test_rebalance_toRangeBelowCurrentPrice_usesToken1Only() public {
        _openInitialPosition();

        vm.prank(CURATOR);
        vault.rebalance(-12000, -6000);

        assertEq(vault.activeTickLower(), -12000);
        assertEq(vault.activeTickUpper(), -6000);
        assertGt(vault.positionLiquidity(), 0);
        assertGt(vault.reserve0(), 0);
    }

    function test_rebalance_toRangeStillContainingPrice_usesBothTokens() public {
        _openInitialPosition();

        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);

        assertGt(vault.positionLiquidity(), 0);
    }

    // ── 19. Atomicity: a failure mid-rebalance leaves everything untouched ──

    function test_rebalance_failureMidCallback_isFullyAtomic() public {
        _openInitialPosition();

        uint256 reserve0Before = vault.reserve0();
        uint256 reserve1Before = vault.reserve1();
        (int24 approvedLowerBefore, int24 approvedUpperBefore) = vault.approvedRange();
        int24 activeLowerBefore = vault.activeTickLower();
        int24 activeUpperBefore = vault.activeTickUpper();
        (uint128 oldLiquidityBefore,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-600, 600));

        // -601 is not a multiple of tickSpacing (60): this passes the vault's own
        // tickLower < tickUpper check, so the removal step runs first and genuinely succeeds
        // in-flight, but PoolManager itself then reverts deep inside the new-position add
        // (tick-spacing is PoolManager's job, not re-validated by us). The whole unlock() call —
        // and therefore the whole rebalance() transaction — must revert as one unit.
        vm.prank(CURATOR);
        vm.expectRevert();
        vault.rebalance(-601, 1200);

        // Old position fully intact.
        (uint128 oldLiquidityAfter,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-600, 600));
        assertEq(oldLiquidityAfter, oldLiquidityBefore);
        assertGt(oldLiquidityAfter, 0);

        // No partial state transition anywhere.
        assertTrue(vault.positionActive());
        assertEq(vault.activeTickLower(), activeLowerBefore);
        assertEq(vault.activeTickUpper(), activeUpperBefore);
        (int24 approvedLowerAfter, int24 approvedUpperAfter) = vault.approvedRange();
        assertEq(approvedLowerAfter, approvedLowerBefore);
        assertEq(approvedUpperAfter, approvedUpperBefore);
        assertEq(vault.reserve0(), reserve0Before);
        assertEq(vault.reserve1(), reserve1Before);
    }

    // ── 20. Still impossible to create a second position through any function ─

    function test_afterRebalance_openPosition_stillReverts() public {
        _openInitialPosition();
        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionAlreadyActive.selector);
        vault.openPosition();
    }

    function test_rebalance_calledTwiceInSequence_bothSucceed_singleActivePosition() public {
        _openInitialPosition();

        vm.prank(CURATOR);
        vault.rebalance(-1200, 1200);
        vm.prank(CURATOR);
        vault.rebalance(60, 1800);

        (uint128 rangeALiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-600, 600));
        (uint128 rangeBLiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(-1200, 1200));
        (uint128 rangeCLiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, _positionKey(60, 1800));

        assertEq(rangeALiquidity, 0);
        assertEq(rangeBLiquidity, 0);
        assertGt(rangeCLiquidity, 0);
        assertEq(vault.activeTickLower(), 60);
        assertEq(vault.activeTickUpper(), 1800);
    }
}
