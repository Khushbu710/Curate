// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {CuratedLiquidityVault} from "../src/CuratedLiquidityVault.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract CuratedLiquidityVaultTest is Test {
    address internal constant POOL_MANAGER = address(0xBEEF);
    address internal constant HOOK = address(0x9999);
    address internal constant CURATOR = address(0xCAFE);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CHARLIE = address(0xC44A71E);
    address internal constant DONOR = address(0xD0707);

    int24 internal constant INITIAL_TICK_LOWER = -600;
    int24 internal constant INITIAL_TICK_UPPER = 600;

    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    CuratedLiquidityVault internal vault;
    MockERC20 internal tokenA;
    MockERC20 internal tokenB;
    PoolKey internal poolKey;

    function setUp() public {
        MockERC20 t0 = new MockERC20("Token A", "AAA");
        MockERC20 t1 = new MockERC20("Token B", "BBB");
        // Order deterministically the way v4 pools require: currency0 < currency1.
        (tokenA, tokenB) = address(t0) < address(t1) ? (t0, t1) : (t1, t0);

        poolKey = PoolKey({
            currency0: Currency.wrap(address(tokenA)),
            currency1: Currency.wrap(address(tokenB)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(HOOK)
        });

        vault = new CuratedLiquidityVault(
            IPoolManager(POOL_MANAGER), poolKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER
        );

        tokenA.mint(ALICE, 1_000_000 ether);
        tokenB.mint(ALICE, 1_000_000 ether);
        tokenA.mint(BOB, 1_000_000 ether);
        tokenB.mint(BOB, 1_000_000 ether);
        tokenA.mint(CHARLIE, 1_000_000 ether);
        tokenB.mint(CHARLIE, 1_000_000 ether);
        tokenA.mint(DONOR, 1_000_000 ether);
        tokenB.mint(DONOR, 1_000_000 ether);

        vm.prank(ALICE);
        tokenA.approve(address(vault), type(uint256).max);
        vm.prank(ALICE);
        tokenB.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        tokenA.approve(address(vault), type(uint256).max);
        vm.prank(BOB);
        tokenB.approve(address(vault), type(uint256).max);
        vm.prank(CHARLIE);
        tokenA.approve(address(vault), type(uint256).max);
        vm.prank(CHARLIE);
        tokenB.approve(address(vault), type(uint256).max);
    }

    // ── 1/2/3. Deployment / configuration ───────────────────────────────────

    function test_deployment_configuration() public view {
        assertEq(address(vault.poolManager()), POOL_MANAGER);
        assertEq(vault.curator(), CURATOR);
        assertEq(vault.fee(), FEE);
        assertEq(vault.tickSpacing(), TICK_SPACING);
        assertEq(address(vault.hooks()), HOOK);
        assertEq(vault.token0(), address(tokenA));
        assertEq(vault.token1(), address(tokenB));
        assertEq(Currency.unwrap(vault.currency0()), address(tokenA));
        assertEq(Currency.unwrap(vault.currency1()), address(tokenB));
    }

    function test_poolId_matchesPoolKey() public view {
        PoolId expected = poolKey.toId();
        assertEq(PoolId.unwrap(vault.poolId()), PoolId.unwrap(expected));
    }

    // ── 4. approvedRange() ───────────────────────────────────────────────────

    function test_approvedRange_returnsInitialRange() public view {
        (int24 tickLower, int24 tickUpper) = vault.approvedRange();
        assertEq(tickLower, INITIAL_TICK_LOWER);
        assertEq(tickUpper, INITIAL_TICK_UPPER);
    }

    // ── 5/6. Curator range updates ───────────────────────────────────────────

    function test_updateApprovedRange_curator_succeeds() public {
        vm.prank(CURATOR);
        vault.updateApprovedRange(-1200, 1200);
        (int24 tickLower, int24 tickUpper) = vault.approvedRange();
        assertEq(tickLower, -1200);
        assertEq(tickUpper, 1200);
    }

    function test_updateApprovedRange_nonCurator_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, ALICE));
        vault.updateApprovedRange(-1200, 1200);
    }

    function test_updateApprovedRange_invalidRange_reverts() public {
        vm.prank(CURATOR);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.InvalidRange.selector, int24(600), int24(600)));
        vault.updateApprovedRange(600, 600);
    }

    function test_updateApprovedRange_doesNotTransferAssets() public {
        _deposit(ALICE, 10 ether, 10 ether);
        uint256 balBefore0 = tokenA.balanceOf(address(vault));
        uint256 balBefore1 = tokenB.balanceOf(address(vault));

        vm.prank(CURATOR);
        vault.updateApprovedRange(-1200, 1200);

        assertEq(tokenA.balanceOf(address(vault)), balBefore0);
        assertEq(tokenB.balanceOf(address(vault)), balBefore1);
    }

    // ── 7. Zero deposit rejected ─────────────────────────────────────────────

    function test_deposit_zeroAmount0_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(CuratedLiquidityVault.ZeroDeposit.selector);
        vault.deposit(0, 10 ether);
    }

    function test_deposit_zeroAmount1_reverts() public {
        vm.prank(ALICE);
        vm.expectRevert(CuratedLiquidityVault.ZeroDeposit.selector);
        vault.deposit(10 ether, 0);
    }

    // ── 8/9. First deposit succeeds, shares minted correctly ────────────────

    function test_deposit_first_mintsExpectedShares() public {
        uint256 amount0 = 10 ether;
        uint256 amount1 = 40 ether;
        uint256 expectedSqrt = _sqrt(amount0 * amount1);

        vm.prank(ALICE);
        uint256 shares = vault.deposit(amount0, amount1);

        assertEq(shares, expectedSqrt - vault.MINIMUM_LIQUIDITY());
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.balanceOf(address(0)), vault.MINIMUM_LIQUIDITY());
        assertEq(vault.totalSupply(), shares + vault.MINIMUM_LIQUIDITY());
    }

    function test_deposit_emitsDepositEvent() public {
        vm.expectEmit(true, false, false, true, address(vault));
        emit CuratedLiquidityVault.Deposit(ALICE, 10 ether, 10 ether, _sqrt(10 ether * 10 ether) - 1000);
        vm.prank(ALICE);
        vault.deposit(10 ether, 10 ether);
    }

    // ── 10. Second proportional deposit succeeds ─────────────────────────────

    function test_deposit_secondProportionalDeposit_succeeds() public {
        vm.prank(ALICE);
        uint256 firstShares = vault.deposit(10 ether, 40 ether);

        // Exactly double the reserves -> must mint exactly firstShares + MINIMUM_LIQUIDITY more.
        vm.prank(BOB);
        uint256 secondShares = vault.deposit(10 ether, 40 ether);

        assertEq(secondShares, firstShares + vault.MINIMUM_LIQUIDITY());
        assertEq(vault.balanceOf(BOB), secondShares);
        assertEq(vault.reserve0(), 20 ether);
        assertEq(vault.reserve1(), 80 ether);
    }

    // ── 11. Asymmetric / incorrect-ratio deposit rejected ────────────────────

    function test_deposit_incorrectRatio_reverts() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);

        vm.prank(BOB);
        vm.expectRevert(
            abi.encodeWithSelector(
                CuratedLiquidityVault.IncorrectRatio.selector, 10 ether, 10 ether, 10 ether, 40 ether
            )
        );
        vault.deposit(10 ether, 10 ether);
    }

    // ── 12/13. Token and share balances after deposit ───────────────────────

    function test_deposit_tokenBalances_moveFromDepositorToVault() public {
        uint256 aliceBalBefore0 = tokenA.balanceOf(ALICE);
        uint256 aliceBalBefore1 = tokenB.balanceOf(ALICE);

        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);

        assertEq(tokenA.balanceOf(ALICE), aliceBalBefore0 - 10 ether);
        assertEq(tokenB.balanceOf(ALICE), aliceBalBefore1 - 40 ether);
        assertEq(tokenA.balanceOf(address(vault)), 10 ether);
        assertEq(tokenB.balanceOf(address(vault)), 40 ether);
        assertEq(vault.reserve0(), 10 ether);
        assertEq(vault.reserve1(), 40 ether);
    }

    function test_deposit_shareBalance_creditedToDepositor_notCaller() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10 ether, 40 ether);
        assertEq(vault.balanceOf(ALICE), shares);
        assertEq(vault.balanceOf(BOB), 0);
    }

    // ── 14. ERC20 transfer/approve/transferFrom ──────────────────────────────

    function test_erc20_transfer_succeeds() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10 ether, 40 ether);

        vm.prank(ALICE);
        vault.transfer(BOB, shares / 2);

        assertEq(vault.balanceOf(ALICE), shares - shares / 2);
        assertEq(vault.balanceOf(BOB), shares / 2);
    }

    function test_erc20_transfer_insufficientBalance_reverts() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);

        vm.prank(BOB);
        vm.expectRevert(CuratedLiquidityVault.InsufficientBalance.selector);
        vault.transfer(ALICE, 1);
    }

    function test_erc20_transfer_toZeroAddress_reverts() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);

        vm.prank(ALICE);
        vm.expectRevert(CuratedLiquidityVault.TransferToZeroAddress.selector);
        vault.transfer(address(0), 1);
    }

    function test_erc20_approveAndTransferFrom_succeeds() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10 ether, 40 ether);

        vm.prank(ALICE);
        vault.approve(BOB, shares);

        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, shares);

        assertEq(vault.balanceOf(ALICE), 0);
        assertEq(vault.balanceOf(BOB), shares);
        assertEq(vault.allowance(ALICE, BOB), 0);
    }

    function test_erc20_transferFrom_withoutAllowance_reverts() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);

        vm.prank(BOB);
        vm.expectRevert(CuratedLiquidityVault.InsufficientAllowance.selector);
        vault.transferFrom(ALICE, BOB, 1);
    }

    function test_erc20_transferFrom_infiniteAllowance_doesNotDecrement() public {
        vm.prank(ALICE);
        uint256 shares = vault.deposit(10 ether, 40 ether);

        vm.prank(ALICE);
        vault.approve(BOB, type(uint256).max);

        vm.prank(BOB);
        vault.transferFrom(ALICE, BOB, shares);

        assertEq(vault.allowance(ALICE, BOB), type(uint256).max);
    }

    // ── 15. Unauthorized unlockCallback ──────────────────────────────────────
    // (The authorized/real-PoolManager path is now covered in
    // CuratedLiquidityVaultLiquidityTest, which deploys against a real PoolManager — this mock
    // `POOL_MANAGER` address has no code, so it can no longer stand in for a successful call now
    // that `unlockCallback` performs real PoolManager reads.)

    function test_unlockCallback_notPoolManager_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotPoolManager.selector, address(this)));
        vault.unlockCallback("");
    }

    // ── 16. Boundary values ──────────────────────────────────────────────────

    function test_deposit_first_exactlyAtMinimumLiquidity_reverts() public {
        // sqrt(amount0 * amount1) == MINIMUM_LIQUIDITY exactly -> shares would be 0 -> reverts.
        uint256 minLiquidity = vault.MINIMUM_LIQUIDITY();
        vm.prank(ALICE);
        vm.expectRevert(CuratedLiquidityVault.InsufficientInitialLiquidity.selector);
        vault.deposit(minLiquidity, minLiquidity);
    }

    function test_deposit_first_oneAboveMinimumLiquidity_mintsOneShare() public {
        uint256 minLiquidity = vault.MINIMUM_LIQUIDITY();
        // sqrt((minLiquidity+1)^2) == minLiquidity + 1 -> shares == 1.
        vm.prank(ALICE);
        uint256 shares = vault.deposit(minLiquidity + 1, minLiquidity + 1);
        assertEq(shares, 1);
    }

    function test_constructor_tickLowerEqualsTickUpper_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.InvalidRange.selector, int24(0), int24(0)));
        new CuratedLiquidityVault(IPoolManager(POOL_MANAGER), poolKey, CURATOR, 0, 0);
    }

    // ── 17. Zero-address configuration failures ──────────────────────────────

    function test_constructor_zeroPoolManager_reverts() public {
        vm.expectRevert(CuratedLiquidityVault.ZeroPoolManagerAddress.selector);
        new CuratedLiquidityVault(IPoolManager(address(0)), poolKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER);
    }

    function test_constructor_zeroCurator_reverts() public {
        vm.expectRevert(CuratedLiquidityVault.ZeroCuratorAddress.selector);
        new CuratedLiquidityVault(
            IPoolManager(POOL_MANAGER), poolKey, address(0), INITIAL_TICK_LOWER, INITIAL_TICK_UPPER
        );
    }

    function test_constructor_zeroCurrency0_reverts() public {
        PoolKey memory badKey = poolKey;
        badKey.currency0 = Currency.wrap(address(0));
        vm.expectRevert(CuratedLiquidityVault.ZeroCurrencyAddress.selector);
        new CuratedLiquidityVault(IPoolManager(POOL_MANAGER), badKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER);
    }

    function test_constructor_zeroCurrency1_reverts() public {
        PoolKey memory badKey = poolKey;
        badKey.currency1 = Currency.wrap(address(0));
        vm.expectRevert(CuratedLiquidityVault.ZeroCurrencyAddress.selector);
        new CuratedLiquidityVault(IPoolManager(POOL_MANAGER), badKey, CURATOR, INITIAL_TICK_LOWER, INITIAL_TICK_UPPER);
    }

    // ── Invariants ────────────────────────────────────────────────────────────

    function test_invariant_totalSupplyEqualsSumOfBalances() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);
        vm.prank(BOB);
        vault.deposit(20 ether, 80 ether);

        assertEq(vault.totalSupply(), vault.balanceOf(ALICE) + vault.balanceOf(BOB) + vault.balanceOf(address(0)));
    }

    function test_invariant_vaultTokenBalancesEqualReserves() public {
        vm.prank(ALICE);
        vault.deposit(10 ether, 40 ether);
        vm.prank(BOB);
        vault.deposit(5 ether, 20 ether);

        assertEq(tokenA.balanceOf(address(vault)), vault.reserve0());
        assertEq(tokenB.balanceOf(address(vault)), vault.reserve1());
    }

    // ── ZeroSharesMinted guard: tightest reachable boundary + broad invariant ─
    //
    // NOTE ON THIS TEST GROUP: the code review's original repro scenario (a tiny 1:1 deposit
    // against a large pre-existing 1:1 pool) was expected to round down to 0 shares. It does not.
    // For an exactly-equal-amount (1:1) first deposit, `sqrt(amount0 * amount1) == amount0`
    // *exactly* (a perfect square), so `totalSupply == reserve0` exactly rather than
    // `reserve0 - MINIMUM_LIQUIDITY` as originally assumed — meaning `mulDivDown(1, totalSupply,
    // reserve0) == 1`, not 0. A 1:1 pool is provably the tightest possible boundary (any other
    // ratio P:Q leaves strictly more headroom, since `sqrt(P*Q) >= 1` for positive integers with
    // equality only at P=Q=1), and even there the minimum nonzero deposit mints exactly 1 share,
    // never 0. This is verified below both at the exact boundary and via a wide fuzz sweep.
    // `ZeroSharesMinted` therefore cannot currently be reached through any ratio-matching deposit
    // — it is intentionally kept as defense-in-depth (see PR description) in case the ratio check
    // is ever relaxed from exact equality to a tolerance band in a future stage.

    function test_deposit_tightestBoundary_1to1Pool_singleWeiDeposit_mintsOneShare_noLoss() public {
        vm.prank(ALICE);
        vault.deposit(100 ether, 100 ether);

        uint256 reserve0Before = vault.reserve0();
        uint256 totalSupplyBefore = vault.totalSupply();
        assertEq(totalSupplyBefore, reserve0Before, "1:1 equal-amount first deposit is a perfect square");

        uint256 bobBalance0Before = tokenA.balanceOf(BOB);

        vm.prank(BOB);
        uint256 shares = vault.deposit(1, 1);

        // The mathematically tightest possible deposit still mints a full share, with no loss.
        assertEq(shares, 1);
        assertEq(vault.balanceOf(BOB), 1);
        assertEq(vault.reserve0(), reserve0Before + 1);
        assertEq(vault.reserve1(), vault.reserve0()); // still 1:1
        assertEq(tokenA.balanceOf(BOB), bobBalance0Before - 1);
        assertEq(tokenA.balanceOf(address(vault)), vault.reserve0());
    }

    function test_deposit_1to1Pool_scalesLinearly_withNoRoundingLoss() public {
        vm.prank(ALICE);
        vault.deposit(100 ether, 100 ether);

        vm.prank(BOB);
        uint256 shares = vault.deposit(2, 2);
        assertEq(shares, 2);
    }

    /// @dev Property test: for the tightest possible ratio (1:1), every valid deposit amount
    /// mints exactly that many shares — confirming `ZeroSharesMinted` cannot fire for any `m` in
    /// this range, not just the single smallest case checked above.
    function testFuzz_deposit_1to1Pool_neverMintsZeroShares(uint96 amount) public {
        vm.assume(amount > 0 && amount <= 1_000_000 ether);
        vm.prank(ALICE);
        vault.deposit(100 ether, 100 ether);

        vm.prank(BOB);
        uint256 shares = vault.deposit(amount, amount);
        assertEq(shares, amount);
        assertGt(shares, 0);
    }

    // ── Regression: direct donations must not affect reserve/share accounting ─

    function test_directDonation_doesNotAffectReservesOrSharePricing() public {
        vm.prank(ALICE);
        uint256 aliceShares = vault.deposit(50 ether, 50 ether);

        uint256 reserve0Before = vault.reserve0();
        uint256 reserve1Before = vault.reserve1();
        uint256 totalSupplyBefore = vault.totalSupply();

        // Donate directly via a plain ERC-20 transfer, bypassing deposit() entirely. Lopsided
        // (token0 only) and deliberately large, to show it can't skew ratio checks or share math
        // even if it skews the vault's *real* balance ratio.
        uint256 donationAmount0 = 1_000 ether;
        vm.prank(DONOR);
        tokenA.transfer(address(vault), donationAmount0);

        // Reserves (the only thing share math reads) must be completely unaffected.
        assertEq(vault.reserve0(), reserve0Before);
        assertEq(vault.reserve1(), reserve1Before);
        assertEq(vault.totalSupply(), totalSupplyBefore);

        // The donated tokens are NOT accounted as vault assets: real balance now exceeds the
        // accounted reserve by exactly the donation amount, and nothing reconciles that gap.
        assertEq(tokenA.balanceOf(address(vault)), reserve0Before + donationAmount0);
        assertEq(tokenA.balanceOf(address(vault)) - vault.reserve0(), donationAmount0);

        // A subsequent legitimate deposit must be priced off the pre-donation reserve ratio
        // (50:50), NOT the donation-skewed real-balance ratio (1050:50) — proving the donation
        // has zero influence on the ratio check or the share calculation.
        uint256 amount0 = 10 ether;
        uint256 amount1 = 10 ether; // matches the true 50:50 reserve ratio, NOT the skewed balance
        uint256 expectedShares = FixedPointMathLib.mulDivDown(amount0, totalSupplyBefore, reserve0Before);
        assertGt(expectedShares, 0);

        vm.prank(BOB);
        uint256 bobShares = vault.deposit(amount0, amount1);

        assertEq(bobShares, expectedShares);
        assertEq(vault.reserve0(), reserve0Before + amount0);
        assertEq(vault.reserve1(), reserve1Before + amount1);
        // The unaccounted donation gap persists unchanged through the legitimate deposit.
        assertEq(tokenA.balanceOf(address(vault)) - vault.reserve0(), donationAmount0);
        assertEq(vault.balanceOf(ALICE), aliceShares);
    }

    // ── Multi-depositor consistency ──────────────────────────────────────────

    function test_threeSequentialProportionalDepositors_correctSharesAndOwnership() public {
        // 1:4 ratio throughout. Each deposit exactly doubles the then-current reserves.
        vm.prank(ALICE);
        uint256 aliceShares = vault.deposit(10 ether, 40 ether);
        uint256 minimumLiquidity = vault.MINIMUM_LIQUIDITY();
        assertEq(aliceShares, _sqrt(10 ether * 40 ether) - minimumLiquidity);

        vm.prank(BOB);
        uint256 bobShares = vault.deposit(10 ether, 40 ether);

        vm.prank(CHARLIE);
        uint256 charlieShares = vault.deposit(20 ether, 80 ether);

        // Reserves reflect the sum of all three deposits.
        assertEq(vault.reserve0(), 40 ether);
        assertEq(vault.reserve1(), 160 ether);

        // totalSupply is the sum of every minted share, including the locked minimum.
        uint256 totalSupply = vault.totalSupply();
        assertEq(totalSupply, aliceShares + minimumLiquidity + bobShares + charlieShares);
        assertEq(
            totalSupply,
            vault.balanceOf(ALICE) + vault.balanceOf(BOB) + vault.balanceOf(CHARLIE) + vault.balanceOf(address(0))
        );

        // Each later depositor's share of totalSupply exactly matches their share of the final
        // reserves (unaffected by the locked-minimum dust, which only ever dilutes the first
        // depositor). BOB and CHARLIE deposited after the dust was already fixed in place.
        assertEq(bobShares, 20 ether); // 10e18 * 40e18(totalSupply before BOB) / 10e18(reserve0 before BOB)
        assertEq(charlieShares, 40 ether); // 20e18 * 40e18(totalSupply before CHARLIE) / 20e18(reserve0 before CHARLIE)

        // Token balances actually held by the vault match reserves exactly (no donations here).
        assertEq(tokenA.balanceOf(address(vault)), vault.reserve0());
        assertEq(tokenB.balanceOf(address(vault)), vault.reserve1());
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    function _deposit(address who, uint256 amount0, uint256 amount1) internal returns (uint256 shares) {
        vm.prank(who);
        shares = vault.deposit(amount0, amount1);
    }

    function _sqrt(uint256 y) internal pure returns (uint256 z) {
        if (y > 3) {
            z = y;
            uint256 x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }
}
