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
/// directly against PoolManager. Used to prove the hook genuinely protects the live pool, not
/// just in isolated unit tests against the hook contract alone.
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

contract CuratedLiquidityVaultLiquidityTest is Test {
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

        // The vault's constructor needs the hook's address up front (as part of `poolKey`), and
        // the hook's constructor needs the vault's address up front (as its immutable `vault`).
        // Predict the vault's address via CREATE2 (deterministic from deployer+salt+initcode,
        // unlike CREATE's nonce-dependent prediction) so both can be deployed pointing at each
        // other, exactly like a real deployment would.
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

    // ── 1/5/9/10/11/12/13/15. Successful deployment, full invariant check ────

    function test_openPosition_priceInRange_succeeds() public {
        _deposit(10 ether, 10 ether);

        uint256 vaultBalance0Before = tokenA.balanceOf(address(vault));
        uint256 vaultBalance1Before = tokenB.balanceOf(address(vault));
        uint256 reserve0Before = vault.reserve0();
        uint256 reserve1Before = vault.reserve1();

        vm.prank(CURATOR);
        vault.openPosition();

        // 9. Vault is the actual PoolManager position owner, at the approved range, salt 0.
        bytes32 positionKey =
            keccak256(abi.encodePacked(address(vault), INITIAL_TICK_LOWER, INITIAL_TICK_UPPER, bytes32(0)));
        (uint128 posLiquidity,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionKey);

        // 11. Position liquidity is > 0.
        assertGt(posLiquidity, 0);
        assertEq(posLiquidity, vault.positionLiquidity());

        // 5/15. Position identity matches poolId + vault + approved range + salt(0).
        assertEq(vault.activeTickLower(), INITIAL_TICK_LOWER);
        assertEq(vault.activeTickUpper(), INITIAL_TICK_UPPER);
        assertTrue(vault.positionActive());

        // approvedRange() must be untouched by opening the position.
        (int24 approvedLower, int24 approvedUpper) = vault.approvedRange();
        assertEq(approvedLower, INITIAL_TICK_LOWER);
        assertEq(approvedUpper, INITIAL_TICK_UPPER);

        // 12. Vault token balances decreased by exactly what was actually consumed.
        uint256 amount0Paid = vaultBalance0Before - tokenA.balanceOf(address(vault));
        uint256 amount1Paid = vaultBalance1Before - tokenB.balanceOf(address(vault));
        assertGt(amount0Paid, 0);
        assertGt(amount1Paid, 0);

        // Reserve accounting matches actual token movement exactly (no silent over/under decrement).
        assertEq(vault.reserve0(), reserve0Before - amount0Paid);
        assertEq(vault.reserve1(), reserve1Before - amount1Paid);
        assertEq(tokenA.balanceOf(address(vault)), vault.reserve0());
        assertEq(tokenB.balanceOf(address(vault)), vault.reserve1());

        // 13. No unresolved delta: PoolManager itself would have reverted with
        // `CurrencyNotSettled` if any delta were left open at the end of `unlock` — reaching this
        // point at all is already proof settlement completed cleanly. Confirm no stray ERC-6909
        // claim balance was left in the vault's name either (it never called `mint`/expects one).
        assertEq(poolManager.balanceOf(address(vault), uint256(uint160(address(tokenA)))), 0);
        assertEq(poolManager.balanceOf(address(vault), uint256(uint160(address(tokenB)))), 0);
    }

    // ── 2/3. Curator-only ────────────────────────────────────────────────────

    function test_openPosition_onlyCurator() public {
        _deposit(10 ether, 10 ether);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, ALICE));
        vault.openPosition();
    }

    // ── 4. Zero idle assets reverts cleanly ─────────────────────────────────

    function test_openPosition_noIdleAssets_reverts() public {
        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.ZeroLiquidity.selector);
        vault.openPosition();
    }

    // ── 14. Second deployment cannot create a second position ──────────────

    function test_openPosition_secondCall_reverts() public {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionAlreadyActive.selector);
        vault.openPosition();
    }

    // ── approvedRange must not drift from the active position once one exists ─

    function test_updateApprovedRange_beforePosition_curatorSucceeds() public {
        vm.prank(CURATOR);
        vault.updateApprovedRange(-1200, 1200);

        (int24 tickLower, int24 tickUpper) = vault.approvedRange();
        assertEq(tickLower, -1200);
        assertEq(tickUpper, 1200);
    }

    function test_updateApprovedRange_beforePosition_nonCuratorReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, ALICE));
        vault.updateApprovedRange(-1200, 1200);
    }

    function test_updateApprovedRange_afterPositionOpened_reverts() public {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionActive.selector);
        vault.updateApprovedRange(-1200, 1200);
    }

    function test_updateApprovedRange_afterPositionOpened_activeRangeUnchanged() public {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();

        int24 activeLowerBefore = vault.activeTickLower();
        int24 activeUpperBefore = vault.activeTickUpper();

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionActive.selector);
        vault.updateApprovedRange(-1200, 1200);

        assertEq(vault.activeTickLower(), activeLowerBefore);
        assertEq(vault.activeTickUpper(), activeUpperBefore);
    }

    function test_updateApprovedRange_afterPositionOpened_approvedRangeUnchanged() public {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();

        (int24 approvedLowerBefore, int24 approvedUpperBefore) = vault.approvedRange();

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionActive.selector);
        vault.updateApprovedRange(-1200, 1200);

        (int24 approvedLowerAfter, int24 approvedUpperAfter) = vault.approvedRange();
        assertEq(approvedLowerAfter, approvedLowerBefore);
        assertEq(approvedUpperAfter, approvedUpperBefore);
    }

    function test_updateApprovedRange_afterPositionOpened_livePositionUnchanged() public {
        _deposit(10 ether, 10 ether);
        vm.prank(CURATOR);
        vault.openPosition();

        bytes32 positionKey =
            keccak256(abi.encodePacked(address(vault), INITIAL_TICK_LOWER, INITIAL_TICK_UPPER, bytes32(0)));
        (uint128 liquidityBefore,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionKey);
        assertGt(liquidityBefore, 0);

        vm.prank(CURATOR);
        vm.expectRevert(CuratedLiquidityVault.PositionActive.selector);
        vault.updateApprovedRange(-1200, 1200);

        (uint128 liquidityAfter,,) = StateLibrary.getPositionInfo(poolManager, poolId, positionKey);
        assertEq(liquidityAfter, liquidityBefore);
    }

    // ── 7/8. Hook actually executes and protects the live pool ─────────────

    /// @dev PoolManager routes hook calls through `Hooks.callHook`, which wraps any hook revert in
    /// `CustomRevert.WrappedError(target, selector, reason, details)` (verified in
    /// `CustomRevert.sol`/`Hooks.sol`) rather than letting it bubble up raw — so the expectation
    /// here must match that wrapper, not the hook's bare error.
    function _expectWrappedHookRevert(address rogue) internal {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(CuratedLiquidityHook.NotVault.selector, rogue),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
    }

    function test_hook_rejectsRogueDirectModifyLiquidity_evenAtApprovedRange() public {
        // A third party, not the vault, tries to add liquidity to the SAME pool at the SAME
        // (currently approved) range. If the hook weren't genuinely wired in and enforcing on the
        // real, deployed pool, this would succeed.
        RogueCaller rogue =
            new RogueCaller(IPoolManager(address(poolManager)), poolKey, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER);
        _expectWrappedHookRevert(address(rogue));
        rogue.attempt();
    }

    function test_hook_rejectsRogue_offApprovedRange() public {
        RogueCaller rogue = new RogueCaller(IPoolManager(address(poolManager)), poolKey, -1200, 1200);
        // Wrong sender is checked before range, so NotVault fires first — this still proves the
        // hook is live on the real pool and that no arbitrary range/caller combination is exempt.
        _expectWrappedHookRevert(address(rogue));
        rogue.attempt();
    }

    // ── 16. Boundary conditions ──────────────────────────────────────────────

    function test_openPosition_priceBelowRange_usesToken0Only() public {
        // Approve a range entirely ABOVE the current price (tick 0) so the position is 100%
        // token0 per LiquidityAmounts' out-of-range branch.
        vm.prank(CURATOR);
        vault.updateApprovedRange(6000, 12000);

        _deposit(10 ether, 10 ether);

        vm.prank(CURATOR);
        vault.openPosition();

        // token1 must be entirely untouched — the position needed none of it.
        assertEq(vault.reserve1(), 10 ether);
        assertEq(vault.reserve0(), 0);
        assertGt(vault.positionLiquidity(), 0);
    }

    function test_openPosition_priceAboveRange_usesToken1Only() public {
        // Range entirely BELOW the current price -> 100% token1.
        vm.prank(CURATOR);
        vault.updateApprovedRange(-12000, -6000);

        _deposit(10 ether, 10 ether);

        vm.prank(CURATOR);
        vault.openPosition();

        assertEq(vault.reserve0(), 10 ether);
        assertEq(vault.reserve1(), 0);
        assertGt(vault.positionLiquidity(), 0);
    }

    function test_openPosition_priceExactlyAtLowerBoundary_usesToken0Only() public {
        // tickLower == current tick (0): LiquidityAmounts treats price <= lower as "at/below",
        // i.e. entirely token0.
        vm.prank(CURATOR);
        vault.updateApprovedRange(0, 600);

        _deposit(10 ether, 10 ether);

        vm.prank(CURATOR);
        vault.openPosition();

        assertEq(vault.reserve1(), 10 ether);
        assertGt(vault.positionLiquidity(), 0);
    }
}
