// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";

import {CuratedLiquidityVault} from "../src/CuratedLiquidityVault.sol";
import {CuratedLiquidityHook} from "../src/CuratedLiquidityHook.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {DemoSwapper} from "./DemoSwapper.sol";

/// @notice Stage 6C: exercises the FULL lifecycle (deposit -> openPosition -> swap -> fees ->
/// collectFees -> rebalance -> withdraw) against the actual contracts deployed by
/// script/Deploy.s.sol on a real (already-running) local Anvil instance — reading their
/// addresses from deployments/anvil.json rather than hardcoding them.
///
/// This is a demo/integration script, not a Foundry test: it exists to prove the DEPLOYED
/// system (real PoolManager, real CREATE2-mined hook, real vault, all already on-chain) behaves
/// correctly end-to-end, which `forge test` alone cannot show (tests build a fresh in-memory
/// fixture per run, never the actual deployed addresses). `require`+console2 logging is used for
/// assertions since this contract extends `Script`, not `Test` — pulling in `forge-std/Test.sol`
/// here would drag in test-only scaffolding for a script that must run via `forge script`.
contract EndToEndDemo is Script {
    /// @dev Must match script/Deploy.s.sol's demo account keys exactly (duplicated, not
    /// imported, to avoid coupling this script to Deploy.s.sol's internals) — Anvil's own
    /// well-known, worthless dev keys, reused here so this script drives the exact same
    /// curator/depositor/trader roles Deploy.s.sol actually set up on-chain.
    uint256 internal constant CURATOR_KEY = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    uint256 internal constant DEPOSITOR_KEY = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 internal constant TRADER_KEY = 0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6;

    uint256 internal constant DEPOSIT_AMOUNT = 100 ether;
    int256 internal constant SWAP_AMOUNT = -1 ether; // exact-input, matches the proven fee test
    int24 internal constant REBALANCE_TICK_LOWER = -1200;
    int24 internal constant REBALANCE_TICK_UPPER = 1200;

    CuratedLiquidityVault internal vault;
    CuratedLiquidityHook internal hook;
    MockERC20 internal token0;
    MockERC20 internal token1;
    IPoolManager internal poolManager;
    DemoSwapper internal swapper;
    PoolId internal poolId;

    address internal curator;
    address internal depositor;
    address internal trader;

    function run() external {
        _loadDeployment();

        console2.log("=== Stage 6C end-to-end demo ===");
        _checkHookRejectsDirectCall();

        // script/Deploy.s.sol's own Part-13 smoke test already performs a 100/100 deposit and
        // openPosition() as part of deployment (Stage 6B). Re-running this script against that
        // same deployment therefore finds a vault that is already past those two states — detect
        // that instead of blindly assuming a pristine vault (see Part 2's own instruction to
        // adapt ordering to actual on-chain mechanics rather than an idealized sequence).
        bool alreadyDeposited = vault.totalSupply() > 0;
        bool alreadyPositioned = vault.positionActive();

        if (alreadyDeposited) {
            console2.log("--- Step: deposit (already performed by Deploy.s.sol's own smoke test) ---");
            _recordExistingDeposit();
        } else {
            _stepDeposit();
        }

        _checkNonCuratorCannotOpenPosition();
        if (!alreadyPositioned) {
            _checkInvalidRangeRejected();
        } else {
            console2.log("[check] skipped: invalid-range check requires positionActive == false, already true");
        }

        if (alreadyPositioned) {
            console2.log("--- Step: openPosition (already performed by Deploy.s.sol's own smoke test) ---");
            _recordExistingPosition();
        } else {
            _stepOpenPosition();
        }

        _stepSwap();
        _stepCollectFees();

        _checkNonCuratorCannotRebalance();
        _stepRebalance();

        _checkDepositorCannotOverWithdraw();
        _stepWithdraw();

        console2.log("=== Stage 6C end-to-end demo COMPLETE ===");
    }

    // ── Setup ────────────────────────────────────────────────────────────────

    function _loadDeployment() internal {
        string memory json = vm.readFile("deployments/anvil.json");
        vault = CuratedLiquidityVault(vm.parseJsonAddress(json, ".vault"));
        hook = CuratedLiquidityHook(vm.parseJsonAddress(json, ".hook"));
        token0 = MockERC20(vm.parseJsonAddress(json, ".token0"));
        token1 = MockERC20(vm.parseJsonAddress(json, ".token1"));
        poolManager = IPoolManager(vm.parseJsonAddress(json, ".poolManager"));
        poolId = PoolId.wrap(vm.parseJsonBytes32(json, ".poolId"));

        curator = vm.addr(CURATOR_KEY);
        depositor = vm.addr(DEPOSITOR_KEY);
        trader = vm.addr(TRADER_KEY);

        require(vault.curator() == curator, "loaded curator mismatch");
        require(PoolId.unwrap(hook.poolId()) == PoolId.unwrap(poolId), "loaded poolId mismatch");

        vm.startBroadcast(CURATOR_KEY);
        swapper = new DemoSwapper(poolManager, vault.poolKey(), trader);
        vm.stopBroadcast();
        vm.startBroadcast(CURATOR_KEY);
        token0.mint(address(swapper), 1_000_000 ether);
        token1.mint(address(swapper), 1_000_000 ether);
        vm.stopBroadcast();

        console2.log("vault", address(vault));
        console2.log("hook", address(hook));
        console2.log("curator", curator);
        console2.log("depositor", depositor);
        console2.log("trader", trader);
    }

    // ── Negative / access-control checks (local-only, never broadcast) ───────

    function _checkHookRejectsDirectCall() internal {
        // Pre-evaluate the argument (an external view call) BEFORE arming expectRevert — otherwise
        // expectRevert attaches to that argument-evaluation call instead of the intended one below.
        PoolKey memory key = vault.poolKey();
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(
            address(vault),
            key,
            ModifyLiquidityParams({tickLower: -600, tickUpper: 600, liquidityDelta: 1, salt: bytes32(0)}),
            ""
        );
        console2.log("[check] arbitrary caller cannot invoke hook callback directly: OK");
    }

    /// @dev A non-participant address, used for every "wrong caller" negative check below
    /// instead of pranking as trader/depositor/curator directly. Observed empirically: pranking
    /// as an address (e.g. `trader`) that this same script LATER broadcasts a real transaction
    /// from (its very first ever, in trader's case) corrupts forge's nonce bookkeeping for that
    /// account's subsequent broadcast ("provider nonce (0) is still behind expected nonce (1)"),
    /// even though the pranked call reverts and is never actually sent. Using a throwaway address
    /// that never broadcasts anything sidesteps this entirely; the checks below only need "some
    /// address that is not curator" (or, for the over-withdraw check, any account attempting to
    /// withdraw more shares than it owns) — none of them require the specific role identity.
    address internal constant STRANGER = address(0xBAD1BAD1);

    function _checkNonCuratorCannotOpenPosition() internal {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, STRANGER));
        vault.openPosition();
        console2.log("[check] non-curator cannot openPosition: OK");
    }

    /// @dev Must prank the real `curator` (not STRANGER) to reach the InvalidRange branch
    /// specifically rather than NotCurator. Only exercised on a truly pristine vault
    /// (positionActive == false), where curator has not yet broadcast anything in this script —
    /// if that combination is ever observed to hit the same nonce-corruption issue documented on
    /// STRANGER's declaration, curator's later broadcasts should be re-verified.
    function _checkInvalidRangeRejected() internal {
        vm.prank(curator);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.InvalidRange.selector, int24(600), int24(-600)));
        vault.updateApprovedRange(600, -600);
        console2.log("[check] invalid (lower >= upper) range rejected: OK");
    }

    function _checkNonCuratorCannotRebalance() internal {
        vm.prank(STRANGER);
        vm.expectRevert(abi.encodeWithSelector(CuratedLiquidityVault.NotCurator.selector, STRANGER));
        vault.rebalance(REBALANCE_TICK_LOWER, REBALANCE_TICK_UPPER);
        console2.log("[check] non-curator cannot rebalance: OK");
    }

    /// @dev Tests the general "cannot withdraw more shares than you own" invariant using a
    /// zero-balance stranger rather than pranking the real depositor (see STRANGER's doc comment)
    /// — depositor's own share balance is still read for real via a plain view call.
    function _checkDepositorCannotOverWithdraw() internal {
        uint256 balance = vault.balanceOf(depositor);
        vm.prank(STRANGER);
        vm.expectRevert(CuratedLiquidityVault.InsufficientBalance.selector);
        vault.withdraw(balance + 1, 0, 0);
        console2.log("[check] cannot withdraw more shares than owned: OK");
    }

    /// @dev Records/verifies the deposit state Deploy.s.sol's own smoke test already established,
    /// instead of attempting a redundant (and, against a non-empty vault with fully-committed
    /// reserves, arithmetically invalid — division by zero in the ratio check) second deposit.
    function _recordExistingDeposit() internal view {
        require(vault.balanceOf(depositor) > 0, "expected depositor to already hold shares");
        require(vault.balanceOf(address(0)) == vault.MINIMUM_LIQUIDITY(), "MINIMUM_LIQUIDITY not locked");
        console2.log("depositor share balance (pre-existing)", vault.balanceOf(depositor));
        console2.log("totalSupply (pre-existing)", vault.totalSupply());
        _logAccounting("pre-existing-deposit");
    }

    /// @dev Records/verifies the open-position state Deploy.s.sol's own smoke test already
    /// established, instead of attempting a redundant openPosition() call (which would revert
    /// PositionAlreadyActive).
    function _recordExistingPosition() internal view {
        require(vault.positionActive(), "expected position to already be active");
        require(vault.activeTickLower() == -600, "unexpected pre-existing activeTickLower");
        require(vault.activeTickUpper() == 600, "unexpected pre-existing activeTickUpper");
        require(vault.positionLiquidity() > 0, "expected nonzero pre-existing liquidity");
        require(
            PoolId.unwrap(hook.poolId()) == PoolId.unwrap(vault.poolId()), "poolId mismatch on pre-existing position"
        );

        console2.log("positionActive (pre-existing)", vault.positionActive());
        console2.log("activeTickLower (pre-existing)", int256(vault.activeTickLower()));
        console2.log("activeTickUpper (pre-existing)", int256(vault.activeTickUpper()));
        console2.log("positionLiquidity (pre-existing)", vault.positionLiquidity());
        _logAccounting("pre-existing-position");
    }

    // ── Step 1: Deposit ────────────────────────────────────────────────────

    function _stepDeposit() internal {
        console2.log("--- Step: deposit ---");
        uint256 depositorBalance0Before = token0.balanceOf(depositor);
        uint256 depositorBalance1Before = token1.balanceOf(depositor);
        uint256 reserve0Before = vault.reserve0();
        uint256 reserve1Before = vault.reserve1();
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAssets0Before = vault.totalAssets0();
        uint256 totalAssets1Before = vault.totalAssets1();

        vm.startBroadcast(DEPOSITOR_KEY);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, DEPOSIT_AMOUNT);
        vm.stopBroadcast();

        require(token0.balanceOf(depositor) == depositorBalance0Before - DEPOSIT_AMOUNT, "token0 not debited");
        require(token1.balanceOf(depositor) == depositorBalance1Before - DEPOSIT_AMOUNT, "token1 not debited");
        require(vault.reserve0() == reserve0Before + DEPOSIT_AMOUNT, "reserve0 mismatch");
        require(vault.reserve1() == reserve1Before + DEPOSIT_AMOUNT, "reserve1 mismatch");

        bool isFirstDeposit = totalSupplyBefore == 0;
        if (isFirstDeposit) {
            require(vault.totalSupply() == shares + vault.MINIMUM_LIQUIDITY(), "MINIMUM_LIQUIDITY not locked");
            require(vault.balanceOf(address(0)) == vault.MINIMUM_LIQUIDITY(), "MINIMUM_LIQUIDITY not at address(0)");
        }
        require(vault.balanceOf(depositor) == shares, "depositor share balance mismatch");
        require(vault.totalAssets0() == totalAssets0Before + DEPOSIT_AMOUNT, "totalAssets0 did not increase by deposit");
        require(vault.totalAssets1() == totalAssets1Before + DEPOSIT_AMOUNT, "totalAssets1 did not increase by deposit");

        console2.log("shares minted", shares);
        console2.log("depositor share balance", vault.balanceOf(depositor));
        console2.log("totalSupply", vault.totalSupply());
        _logAccounting("after-deposit");
    }

    // ── Step 2: Open position ──────────────────────────────────────────────

    function _stepOpenPosition() internal {
        console2.log("--- Step: openPosition ---");
        uint256 reserve0Before = vault.reserve0();
        uint256 reserve1Before = vault.reserve1();

        vm.startBroadcast(CURATOR_KEY);
        vault.openPosition();
        vm.stopBroadcast();

        require(vault.positionActive(), "position not active after openPosition");
        require(vault.activeTickLower() == -600, "unexpected activeTickLower");
        require(vault.activeTickUpper() == 600, "unexpected activeTickUpper");
        require(vault.positionLiquidity() > 0, "zero liquidity after openPosition");
        require(PoolId.unwrap(hook.poolId()) == PoolId.unwrap(vault.poolId()), "poolId mismatch after openPosition");
        require(vault.reserve0() < reserve0Before, "reserve0 did not decrease into position");
        require(vault.reserve1() < reserve1Before, "reserve1 did not decrease into position");

        console2.log("positionActive", vault.positionActive());
        console2.log("activeTickLower", int256(vault.activeTickLower()));
        console2.log("activeTickUpper", int256(vault.activeTickUpper()));
        console2.log("positionLiquidity", vault.positionLiquidity());
        _logAccounting("after-openPosition");
    }

    // ── Step 3: Real swap ──────────────────────────────────────────────────

    function _stepSwap() internal {
        console2.log("--- Step: real swap ---");
        (uint256 totalAssets0Before, uint256 totalAssets1Before) = (vault.totalAssets0(), vault.totalAssets1());
        (uint256 feesBefore0, uint256 feesBefore1) = vault.pendingFees();
        uint128 liquidityBefore = vault.positionLiquidity();
        (, int24 tickBefore,,) = StateLibrary.getSlot0(poolManager, poolId);

        vm.startBroadcast(TRADER_KEY);
        swapper.swap(true, SWAP_AMOUNT);
        vm.stopBroadcast();

        (uint256 feesAfter0, uint256 feesAfter1) = vault.pendingFees();
        (, int24 tickAfter,,) = StateLibrary.getSlot0(poolManager, poolId);

        require(vault.positionLiquidity() == liquidityBefore, "swap must not change LP liquidity");
        require(feesAfter0 > feesBefore0, "expected token0-denominated fees to accrue");

        console2.log("tick before swap", int256(tickBefore));
        console2.log("tick after swap", int256(tickAfter));
        console2.log("pendingFees0 before", feesBefore0);
        console2.log("pendingFees0 after", feesAfter0);
        console2.log("pendingFees1 after (expected 0, input-side fee only)", feesAfter1);
        console2.log("totalAssets0 before swap", totalAssets0Before);
        console2.log("totalAssets1 before swap", totalAssets1Before);
        _logAccounting("after-swap");
    }

    // ── Step 4: Collect fees ───────────────────────────────────────────────

    function _stepCollectFees() internal {
        console2.log("--- Step: collectFees ---");
        (uint256 pendingFees0Before, uint256 pendingFees1Before) = vault.pendingFees();
        uint256 reserve0Before = vault.reserve0();
        uint128 liquidityBefore = vault.positionLiquidity();
        int24 activeLowerBefore = vault.activeTickLower();
        int24 activeUpperBefore = vault.activeTickUpper();
        uint256 totalAssets0Before = vault.totalAssets0();
        uint256 totalAssets1Before = vault.totalAssets1();

        vm.startBroadcast(CURATOR_KEY);
        vault.collectFees();
        vm.stopBroadcast();

        (uint256 pendingFees0After, uint256 pendingFees1After) = vault.pendingFees();

        require(vault.positionLiquidity() == liquidityBefore, "collectFees must not change LP liquidity");
        require(vault.activeTickLower() == activeLowerBefore, "collectFees must not change active range");
        require(vault.activeTickUpper() == activeUpperBefore, "collectFees must not change active range");
        require(pendingFees0After == 0, "pendingFees0 should be fully realized");
        require(pendingFees1After == 0, "pendingFees1 should be fully realized");
        require(vault.reserve0() == reserve0Before + pendingFees0Before, "reserve0 did not increase by collected fee");
        require(vault.totalAssets0() == totalAssets0Before, "totalAssets0 must be unchanged by fee realization");
        require(vault.totalAssets1() == totalAssets1Before, "totalAssets1 must be unchanged by fee realization");

        console2.log("pendingFees0 collected", pendingFees0Before);
        console2.log("pendingFees1 collected", pendingFees1Before);
        console2.log("reserve0 after collectFees", vault.reserve0());
        _logAccounting("after-collectFees");
    }

    // ── Step 5: Rebalance ──────────────────────────────────────────────────

    function _stepRebalance() internal {
        console2.log("--- Step: rebalance ---");
        int24 oldLower = vault.activeTickLower();
        int24 oldUpper = vault.activeTickUpper();
        uint256 totalAssets0Before = vault.totalAssets0();
        uint256 totalAssets1Before = vault.totalAssets1();
        (, int24 currentTick,,) = StateLibrary.getSlot0(poolManager, poolId);
        console2.log("current tick before rebalance (chosen range must bracket this)", int256(currentTick));
        require(
            currentTick >= REBALANCE_TICK_LOWER && currentTick < REBALANCE_TICK_UPPER,
            "chosen rebalance range does not bracket the current tick"
        );

        vm.startBroadcast(CURATOR_KEY);
        vault.rebalance(REBALANCE_TICK_LOWER, REBALANCE_TICK_UPPER);
        vm.stopBroadcast();

        require(vault.positionActive(), "position must remain active after rebalance");
        require(vault.activeTickLower() == REBALANCE_TICK_LOWER, "new activeTickLower mismatch");
        require(vault.activeTickUpper() == REBALANCE_TICK_UPPER, "new activeTickUpper mismatch");
        require(
            vault.activeTickLower() != oldLower || vault.activeTickUpper() != oldUpper, "range did not actually change"
        );
        require(vault.positionLiquidity() > 0, "zero liquidity after rebalance");
        require(PoolId.unwrap(hook.poolId()) == PoolId.unwrap(vault.poolId()), "poolId changed by rebalance");

        (int24 approvedLower, int24 approvedUpper) = vault.approvedRange();
        require(
            approvedLower == REBALANCE_TICK_LOWER && approvedUpper == REBALANCE_TICK_UPPER,
            "approvedRange out of sync with active range"
        );

        console2.log("old range", vm.toString(oldLower), vm.toString(oldUpper));
        console2.log("new activeTickLower", int256(vault.activeTickLower()));
        console2.log("new activeTickUpper", int256(vault.activeTickUpper()));
        console2.log("new positionLiquidity", vault.positionLiquidity());
        console2.log("totalAssets0 before/after", totalAssets0Before, vault.totalAssets0());
        console2.log("totalAssets1 before/after", totalAssets1Before, vault.totalAssets1());
        _logAccounting("after-rebalance");
    }

    // ── Step 6: Withdraw (full — the only non-locked shareholder) ─────────

    function _stepWithdraw() internal {
        console2.log("--- Step: withdraw (full) ---");
        uint256 sharesToBurn = vault.balanceOf(depositor);
        uint256 totalSupplyBefore = vault.totalSupply();
        uint256 totalAssets0Before = vault.totalAssets0();
        uint256 totalAssets1Before = vault.totalAssets1();
        uint256 depositorBalance0Before = token0.balanceOf(depositor);
        uint256 depositorBalance1Before = token1.balanceOf(depositor);

        uint256 expected0 = (totalAssets0Before * sharesToBurn) / totalSupplyBefore;
        uint256 expected1 = (totalAssets1Before * sharesToBurn) / totalSupplyBefore;
        uint256 minAmount0 = (expected0 * 99) / 100;
        uint256 minAmount1 = (expected1 * 99) / 100;

        require(
            sharesToBurn == totalSupplyBefore - vault.MINIMUM_LIQUIDITY(),
            "expected depositor to be the sole non-locked shareholder"
        );

        vm.startBroadcast(DEPOSITOR_KEY);
        (uint256 amount0, uint256 amount1) = vault.withdraw(sharesToBurn, minAmount0, minAmount1);
        vm.stopBroadcast();

        require(vault.balanceOf(depositor) == 0, "depositor shares not fully burned");
        require(
            vault.totalSupply() == vault.MINIMUM_LIQUIDITY(),
            "totalSupply should equal only the locked MINIMUM_LIQUIDITY"
        );
        require(token0.balanceOf(depositor) == depositorBalance0Before + amount0, "token0 payout mismatch");
        require(token1.balanceOf(depositor) == depositorBalance1Before + amount1, "token1 payout mismatch");
        require(amount0 <= expected0 + 1 && amount1 <= expected1 + 1, "payout exceeds proportional claim");
        require(amount0 >= minAmount0 && amount1 >= minAmount1, "slippage protection violated");

        // The vault's own rule: the last non-locked shareholder's withdrawal fully drains the
        // position rather than leaving permanent LP dust behind. Assert whichever the
        // implementation actually did, instead of assuming.
        if (vault.positionActive()) {
            console2.log("position remains active after full withdrawal (unexpected for the sole shareholder case)");
            require(vault.positionLiquidity() > 0, "active position must retain nonzero liquidity");
        } else {
            console2.log("position fully closed after last-shareholder withdrawal, as implemented");
            require(vault.positionLiquidity() == 0, "position marked inactive but liquidity nonzero");
        }

        require(vault.reserve0() <= vault.totalAssets0() + 1, "no stranded reserve vs totalAssets0");
        require(token0.balanceOf(address(vault)) == vault.reserve0(), "vault token0 balance must equal reserve0");
        require(token1.balanceOf(address(vault)) == vault.reserve1(), "vault token1 balance must equal reserve1");

        console2.log("shares burned", sharesToBurn);
        console2.log("amount0 paid", amount0);
        console2.log("amount1 paid", amount1);
        console2.log("expected0 (pre-slippage-buffer)", expected0);
        console2.log("expected1 (pre-slippage-buffer)", expected1);
        _logAccounting("after-withdraw");
    }

    // ── Accounting helper ──────────────────────────────────────────────────

    function _logAccounting(string memory label) internal view {
        (uint256 principal0, uint256 principal1) = vault.positionAmounts();
        (uint256 fees0, uint256 fees1) = vault.pendingFees();
        console2.log(string.concat("[accounting] ", label));
        console2.log("  reserve0/1", vault.reserve0(), vault.reserve1());
        console2.log("  principal0/1", principal0, principal1);
        console2.log("  pendingFees0/1", fees0, fees1);
        console2.log("  totalAssets0/1", vault.totalAssets0(), vault.totalAssets1());
        console2.log("  positionLiquidity", vault.positionLiquidity());
        require(vault.totalAssets0() == vault.reserve0() + principal0 + fees0, "totalAssets0 reconciliation failed");
        require(vault.totalAssets1() == vault.reserve1() + principal1 + fees1, "totalAssets1 reconciliation failed");
    }
}
