// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "@uniswap/v4-core/src/libraries/FixedPoint128.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {ICuratedLiquidityVault} from "./interfaces/ICuratedLiquidityVault.sol";

/// @notice Pools token0/token1 deposits behind a single curator-managed Uniswap v4 position.
/// @dev STAGE 4B.2: adds user withdrawals (`withdraw`) — proportional redemption against total
/// economic assets (idle + live position principal + pending fees), with partial LP removal,
/// slippage protection, and correct last-shareholder/MINIMUM_LIQUIDITY handling. The vault's own
/// shares double as the ERC-20 share token (no separate contract), matching "no unnecessary
/// abstractions".
contract CuratedLiquidityVault is ICuratedLiquidityVault, IUnlockCallback {
    /// @dev Discriminates the single `unlockCallback` between the two operations that can trigger
    /// it. `data` is always constructed by the vault itself (never accepted raw from a caller), so
    /// this is not an externally-influenceable dispatch surface.
    enum Action {
        OpenPosition,
        Rebalance,
        CollectFees,
        Withdraw
    }

    /// @dev Shares permanently locked on the first deposit, mirroring Uniswap V2's `Pair.mint()`.
    /// Forces a minimum real stake before shares are usable, closing the classic
    /// mint-1-wei-then-donate first-depositor manipulation.
    uint256 public constant MINIMUM_LIQUIDITY = 1000;

    string public constant name = "Curated Liquidity Vault Share";
    string public constant symbol = "CLVS";
    uint8 public constant decimals = 18;

    /// @notice The v4 PoolManager this vault's (future) position will live in.
    IPoolManager public immutable poolManager;

    /// @notice The pool's currencies, fee tier, tick spacing and hook — the immutable components
    /// of this vault's single `PoolKey`. Stored as individual immutables (a struct cannot be
    /// `immutable`) and reassembled into a `PoolKey` wherever one is needed.
    Currency public immutable currency0;
    Currency public immutable currency1;
    uint24 public immutable fee;
    int24 public immutable tickSpacing;
    IHooks public immutable hooks;

    /// @notice Cached `keccak256`-derived id of this vault's single pool.
    PoolId public immutable poolId;

    /// @notice The only address permitted to update the approved range.
    address public immutable curator;

    /// @notice The curator's currently configured range. This is curation *intent* only — at
    /// this stage no Uniswap position exists at all, so it cannot yet describe where any real
    /// liquidity sits. A later stage that introduces an actual position must not conflate this
    /// with the position's real on-chain range.
    int24 public approvedTickLower;
    int24 public approvedTickUpper;

    /// @notice Whether the vault's single Uniswap v4 position currently exists.
    /// @dev `approvedTickLower/Upper` is configuration/intent; this — together with
    /// `activeTickLower/Upper` below — is the actual PoolManager position's state. They are not
    /// the same thing and must never be conflated: `approvedRange()` can change at any time (see
    /// `updateApprovedRange`), but that alone never moves the real position.
    bool public positionActive;

    /// @notice The range the vault's single position actually occupies on PoolManager, snapshotted
    /// at the moment it was opened. Only meaningful when `positionActive` is true.
    int24 public activeTickLower;
    int24 public activeTickUpper;

    /// @dev Every position this vault ever opens uses the same salt — there is only ever one.
    bytes32 private constant POSITION_SALT = bytes32(0);

    /// @notice Internally tracked idle (undeployed) balances used for share pricing. Deliberately
    /// NOT live `token.balanceOf(this)`: a bare ERC-20 `transfer()` straight to this contract must
    /// not be able to move share pricing, since nothing minted shares for it. Decremented only by
    /// the exact amount actually paid into the position (from the settled `BalanceDelta`), never
    /// by whatever amount the liquidity math was merely offered.
    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed depositor, uint256 amount0, uint256 amount1, uint256 shares);
    event ApprovedRangeUpdated(int24 tickLower, int24 tickUpper);
    event PositionOpened(int24 tickLower, int24 tickUpper, uint128 liquidity, uint256 amount0Paid, uint256 amount1Paid);
    event PositionRemoved(
        int24 tickLower, int24 tickUpper, uint128 liquidityRemoved, uint256 amount0Received, uint256 amount1Received
    );
    event FeesCollected(uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, uint256 sharesBurned, uint256 amount0, uint256 amount1);
    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    error ZeroPoolManagerAddress();
    error ZeroCuratorAddress();
    error ZeroCurrencyAddress();
    error InvalidRange(int24 tickLower, int24 tickUpper);
    error NotCurator(address caller);
    error ZeroDeposit();
    error IncorrectRatio(uint256 amount0, uint256 amount1, uint256 reserve0, uint256 reserve1);
    error InsufficientInitialLiquidity();
    error ZeroSharesMinted();
    error NotPoolManager(address caller);
    error PositionAlreadyActive();
    error PositionActive();
    error NoActivePosition();
    error ZeroLiquidity();
    error PositionNotFullyRemoved(uint128 remainingLiquidity);
    error TransferToZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ZeroWithdrawal();
    error ZeroPayout();
    error SlippageExceeded(uint256 amount0, uint256 minAmount0, uint256 amount1, uint256 minAmount1);
    error InsufficientVaultAssets(uint256 requested0, uint256 available0, uint256 requested1, uint256 available1);

    constructor(
        IPoolManager _poolManager,
        PoolKey memory initialPoolKey,
        address _curator,
        int24 _initialTickLower,
        int24 _initialTickUpper
    ) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManagerAddress();
        if (_curator == address(0)) revert ZeroCuratorAddress();
        if (Currency.unwrap(initialPoolKey.currency0) == address(0)) revert ZeroCurrencyAddress();
        if (Currency.unwrap(initialPoolKey.currency1) == address(0)) revert ZeroCurrencyAddress();
        if (_initialTickLower >= _initialTickUpper) revert InvalidRange(_initialTickLower, _initialTickUpper);

        poolManager = _poolManager;
        currency0 = initialPoolKey.currency0;
        currency1 = initialPoolKey.currency1;
        fee = initialPoolKey.fee;
        tickSpacing = initialPoolKey.tickSpacing;
        hooks = initialPoolKey.hooks;
        poolId = initialPoolKey.toId();
        curator = _curator;

        approvedTickLower = _initialTickLower;
        approvedTickUpper = _initialTickUpper;
    }

    /// @inheritdoc ICuratedLiquidityVault
    function approvedRange() external view returns (int24 tickLower, int24 tickUpper) {
        return (approvedTickLower, approvedTickUpper);
    }

    /// @notice Updates the curator-approved range. Does NOT move any liquidity.
    /// @dev Only callable while no position exists (`positionActive == false`). Once a position
    /// is open, `approvedTickLower/Upper` and `activeTickLower/Upper` must stay identical — a
    /// live position can only ever be moved by an explicit rebalance action (a later stage), never
    /// by silently letting configuration drift out from under it.
    function updateApprovedRange(int24 newTickLower, int24 newTickUpper) external {
        if (msg.sender != curator) revert NotCurator(msg.sender);
        if (positionActive) revert PositionActive();
        if (newTickLower >= newTickUpper) revert InvalidRange(newTickLower, newTickUpper);
        approvedTickLower = newTickLower;
        approvedTickUpper = newTickUpper;
        emit ApprovedRangeUpdated(newTickLower, newTickUpper);
    }

    /// @notice Deposits token0/token1 in the vault's current reserve ratio and mints shares.
    /// @dev Reverts on any deposit that isn't an exact integer scaling of the current reserves
    /// (see contract-level design notes) — no partial fills, no swaps.
    function deposit(uint256 amount0, uint256 amount1) external returns (uint256 shares) {
        if (amount0 == 0 || amount1 == 0) revert ZeroDeposit();

        uint256 _reserve0 = reserve0;
        uint256 _reserve1 = reserve1;
        uint256 _totalSupply = totalSupply;

        if (_totalSupply == 0) {
            uint256 sqrtProduct = _sqrt(amount0 * amount1);
            if (sqrtProduct <= MINIMUM_LIQUIDITY) revert InsufficientInitialLiquidity();
            shares = sqrtProduct - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            if (amount0 * _reserve1 != amount1 * _reserve0) {
                revert IncorrectRatio(amount0, amount1, _reserve0, _reserve1);
            }
            shares = FixedPointMathLib.mulDivDown(amount0, _totalSupply, _reserve0);
            uint256 shares1 = FixedPointMathLib.mulDivDown(amount1, _totalSupply, _reserve1);
            if (shares1 < shares) shares = shares1;
            if (shares == 0) revert ZeroSharesMinted();
        }

        reserve0 = _reserve0 + amount0;
        reserve1 = _reserve1 + amount1;
        _mint(msg.sender, shares);

        emit Deposit(msg.sender, amount0, amount1, shares);

        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency0)), msg.sender, address(this), amount0);
        SafeTransferLib.safeTransferFrom(ERC20(Currency.unwrap(currency1)), msg.sender, address(this), amount1);
    }

    /// @notice The ERC-20 address backing `currency0`.
    function token0() external view returns (address) {
        return Currency.unwrap(currency0);
    }

    /// @notice The ERC-20 address backing `currency1`.
    function token1() external view returns (address) {
        return Currency.unwrap(currency1);
    }

    /// @notice Deploys the vault's idle reserves into its single Uniswap v4 position, at the
    /// currently approved range. Curator-only; can only ever create the position once.
    /// @dev Takes no range parameters — it always uses `approvedTickLower/Upper` at the moment of
    /// the call, never an arbitrary caller-supplied range.
    function openPosition() external {
        if (msg.sender != curator) revert NotCurator(msg.sender);
        if (positionActive) revert PositionAlreadyActive();

        poolManager.unlock(abi.encode(Action.OpenPosition, bytes("")));
    }

    /// @notice Atomically moves the vault's single position to a new curator-chosen range:
    /// removes all liquidity from the current position, updates the approved range, then
    /// redeploys the recovered (plus any already-idle) assets into the new range.
    /// @dev The curator must explicitly choose the destination range every time — there is no
    /// path that updates `approvedRange()` without also moving the real position in the same
    /// transaction, and no path that moves the position without the caller having chosen where.
    function rebalance(int24 newTickLower, int24 newTickUpper) external {
        if (msg.sender != curator) revert NotCurator(msg.sender);
        if (!positionActive) revert NoActivePosition();
        if (newTickLower >= newTickUpper) revert InvalidRange(newTickLower, newTickUpper);

        poolManager.unlock(abi.encode(Action.Rebalance, abi.encode(newTickLower, newTickUpper)));
    }

    /// @notice Realizes accrued fees from the vault's active position into idle reserves.
    /// @dev Permissionless: this can only ever move the vault's own already-earned fees into the
    /// vault's own idle reserves (see `_collectFees`) — it cannot touch principal, share balances,
    /// or the active/approved range, so there is no one it could disadvantage. A zero-liquidity
    /// (`liquidityDelta == 0`) `modifyLiquidity` call is the current v4 mechanism for this: per
    /// `Position.update`, the principal-delta computation is skipped entirely for a zero delta, so
    /// the returned delta is pure fees. Safe to call when there are no fees to realize — it is
    /// simply a no-op poke in that case.
    function collectFees() external {
        if (!positionActive) revert NoActivePosition();
        poolManager.unlock(abi.encode(Action.CollectFees, bytes("")));
    }

    /// @notice Burns the caller's shares and pays out their proportional claim on the vault's
    /// total economic assets (idle + live position principal + pending fees).
    /// @dev `minAmount0`/`minAmount1` are the caller's slippage protection against price movement
    /// between transaction construction and execution — see contract-level design notes for why
    /// no deadline is added. Reverts `ZeroPayout` rather than burning shares for nothing if the
    /// computed claim rounds to zero on both sides.
    function withdraw(uint256 sharesToBurn, uint256 minAmount0, uint256 minAmount1)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (sharesToBurn == 0) revert ZeroWithdrawal();
        if (balanceOf[msg.sender] < sharesToBurn) revert InsufficientBalance();

        uint256 _totalSupply = totalSupply;

        // Floors, favoring the vault (remaining shareholders) over the withdrawing caller.
        amount0 = FixedPointMathLib.mulDivDown(totalAssets0(), sharesToBurn, _totalSupply);
        amount1 = FixedPointMathLib.mulDivDown(totalAssets1(), sharesToBurn, _totalSupply);
        if (amount0 == 0 && amount1 == 0) revert ZeroPayout();
        if (amount0 < minAmount0 || amount1 < minAmount1) {
            revert SlippageExceeded(amount0, minAmount0, amount1, minAmount1);
        }

        uint128 liquidityToRemove;
        if (positionActive) {
            (uint128 liveLiquidity,,) = StateLibrary.getPositionInfo(
                poolManager, poolId, address(this), activeTickLower, activeTickUpper, POSITION_SALT
            );
            // The final withdrawal that would leave only the permanently-locked MINIMUM_LIQUIDITY
            // circulating must remove the ENTIRE live position, not the floored proportional
            // fraction — otherwise a permanent, un-removable liquidity dust sliver would remain
            // forever and `positionActive` could never return to false.
            liquidityToRemove = (sharesToBurn == _totalSupply - MINIMUM_LIQUIDITY)
                ? liveLiquidity
                : uint128(FixedPointMathLib.mulDivDown(liveLiquidity, sharesToBurn, _totalSupply));
        }

        _burn(msg.sender, sharesToBurn);

        if (positionActive) {
            poolManager.unlock(abi.encode(Action.Withdraw, abi.encode(msg.sender, amount0, amount1, liquidityToRemove)));
        } else {
            _payout(msg.sender, amount0, amount1);
        }

        emit Withdraw(msg.sender, sharesToBurn, amount0, amount1);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Dispatches on an action the vault itself encoded — `data` is never accepted from an
    /// external caller, so this is not an externally-influenceable branch. Re-entering either
    /// `openPosition` or `rebalance` mid-callback would call `poolManager.unlock` a second time,
    /// which PoolManager itself rejects (`AlreadyUnlocked`) independently of any state here.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);

        (Action action, bytes memory payload) = abi.decode(data, (Action, bytes));

        if (action == Action.OpenPosition) {
            _createPosition(approvedTickLower, approvedTickUpper);
        } else if (action == Action.Rebalance) {
            (int24 newTickLower, int24 newTickUpper) = abi.decode(payload, (int24, int24));

            _removePosition();

            approvedTickLower = newTickLower;
            approvedTickUpper = newTickUpper;
            emit ApprovedRangeUpdated(newTickLower, newTickUpper);

            _createPosition(newTickLower, newTickUpper);
        } else if (action == Action.CollectFees) {
            _collectFees();
        } else {
            (address recipient, uint256 amount0, uint256 amount1, uint128 liquidityToRemove) =
                abi.decode(payload, (address, uint256, uint256, uint128));
            _withdrawFromPosition(liquidityToRemove);
            _payout(recipient, amount0, amount1);
        }

        return "";
    }

    /// @dev Deploys currently-idle reserves into a brand new position at `[tickLower, tickUpper]`.
    /// Shared by `openPosition` (position didn't exist) and `rebalance` (position was just
    /// removed) — both must go through the exact same mechanism.
    function _createPosition(int24 tickLower, int24 tickUpper) private {
        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(tickUpper);

        uint256 idle0 = reserve0;
        uint256 idle1 = reserve1;

        uint128 liquidity =
            LiquidityAmounts.getLiquidityForAmounts(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, idle0, idle1);
        if (liquidity == 0) revert ZeroLiquidity();

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: int256(uint256(liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );

        _settleDelta(currency0, callerDelta.amount0());
        _settleDelta(currency1, callerDelta.amount1());

        // Reserves fall by exactly what PoolManager actually charged — never by `idle0`/`idle1`,
        // since getLiquidityForAmounts may not have needed the full amount on one side (e.g. the
        // range only partially overlaps the current price). Any unused amount stays idle.
        reserve0 = _applyDelta(idle0, callerDelta.amount0());
        reserve1 = _applyDelta(idle1, callerDelta.amount1());

        positionActive = true;
        activeTickLower = tickLower;
        activeTickUpper = tickUpper;

        emit PositionOpened(
            tickLower,
            tickUpper,
            liquidity,
            _negativeMagnitude(callerDelta.amount0()),
            _negativeMagnitude(callerDelta.amount1())
        );
    }

    /// @dev Removes 100% of the vault's currently active position and credits the recovered
    /// principal (and any accrued fees, which PoolManager already folds into the same delta) back
    /// into idle reserves. Reads the live liquidity from PoolManager rather than trusting any
    /// cached value, and verifies via a second live read that removal actually zeroed it out.
    function _removePosition() private {
        int24 tickLower = activeTickLower;
        int24 tickUpper = activeTickUpper;

        (uint128 liquidity,,) =
            StateLibrary.getPositionInfo(poolManager, poolId, address(this), tickLower, tickUpper, POSITION_SALT);
        if (liquidity == 0) revert ZeroLiquidity();

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidity)),
                salt: POSITION_SALT
            }),
            ""
        );

        _settleDelta(currency0, callerDelta.amount0());
        _settleDelta(currency1, callerDelta.amount1());

        reserve0 = _applyDelta(reserve0, callerDelta.amount0());
        reserve1 = _applyDelta(reserve1, callerDelta.amount1());

        (uint128 remainingLiquidity,,) =
            StateLibrary.getPositionInfo(poolManager, poolId, address(this), tickLower, tickUpper, POSITION_SALT);
        if (remainingLiquidity != 0) revert PositionNotFullyRemoved(remainingLiquidity);

        positionActive = false;

        emit PositionRemoved(
            tickLower,
            tickUpper,
            liquidity,
            _positiveMagnitude(callerDelta.amount0()),
            _positiveMagnitude(callerDelta.amount1())
        );
    }

    /// @dev Pokes the active position (zero-liquidity `modifyLiquidity`) to realize accrued fees.
    /// Per `Position.update`/`Pool.modifyLiquidity` (verified against pinned source), a zero
    /// liquidityDelta skips the principal-delta computation entirely, so `callerDelta` here is
    /// exactly the fee amounts — settled and credited to idle reserves via the same generic
    /// helpers used everywhere else, no separate fee-specific settlement path required.
    function _collectFees() private {
        int24 tickLower = activeTickLower;
        int24 tickUpper = activeTickUpper;

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: 0, salt: POSITION_SALT}),
            ""
        );

        _settleDelta(currency0, callerDelta.amount0());
        _settleDelta(currency1, callerDelta.amount1());

        reserve0 = _applyDelta(reserve0, callerDelta.amount0());
        reserve1 = _applyDelta(reserve1, callerDelta.amount1());

        emit FeesCollected(_positiveMagnitude(callerDelta.amount0()), _positiveMagnitude(callerDelta.amount1()));
    }

    /// @dev Removes exactly `liquidityToRemove` from the active position (which may be `0` — a
    /// valid poke that still realizes full pending fees, per `Position.update`) and credits
    /// whatever PoolManager returns (principal slice + full fees, per the verified fee mechanics)
    /// into idle reserves. Unlike `_removePosition` (Stage 4A, which always fully drains and
    /// requires the result to be zero), this only flips `positionActive` false when the live
    /// liquidity genuinely reaches zero — a partial withdrawal must leave the position active with
    /// its remaining liquidity, range, and PoolManager ownership untouched.
    function _withdrawFromPosition(uint128 liquidityToRemove) private {
        int24 tickLower = activeTickLower;
        int24 tickUpper = activeTickUpper;

        (BalanceDelta callerDelta,) = poolManager.modifyLiquidity(
            _poolKey(),
            ModifyLiquidityParams({
                tickLower: tickLower,
                tickUpper: tickUpper,
                liquidityDelta: -int256(uint256(liquidityToRemove)),
                salt: POSITION_SALT
            }),
            ""
        );

        _settleDelta(currency0, callerDelta.amount0());
        _settleDelta(currency1, callerDelta.amount1());

        reserve0 = _applyDelta(reserve0, callerDelta.amount0());
        reserve1 = _applyDelta(reserve1, callerDelta.amount1());

        (uint128 remainingLiquidity,,) =
            StateLibrary.getPositionInfo(poolManager, poolId, address(this), tickLower, tickUpper, POSITION_SALT);
        if (remainingLiquidity == 0) {
            positionActive = false;
        }
    }

    /// @dev Pays `amount0`/`amount1` to `to` out of idle reserves. Reverts rather than ever
    /// paying out more than the vault actually holds — a defensive invariant, not merely an
    /// expected outcome (see contract-level design notes: both the claim and the liquidity slice
    /// removed for it are floored in the vault's favor, so this should never trigger in practice).
    function _payout(address to, uint256 amount0, uint256 amount1) private {
        if (amount0 > reserve0 || amount1 > reserve1) {
            revert InsufficientVaultAssets(amount0, reserve0, amount1, reserve1);
        }
        reserve0 -= amount0;
        reserve1 -= amount1;
        if (amount0 > 0) SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency0)), to, amount0);
        if (amount1 > 0) SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency1)), to, amount1);
    }

    /// @notice The token amounts currently represented by the active position's principal
    /// (excludes fees — see `pendingFees`). Zero if no position is active.
    /// @dev Uses the LIVE liquidity and LIVE sqrt price (never the approved range, never a cached
    /// liquidity value) — mirrors exactly the branch structure `Pool.modifyLiquidity` itself uses
    /// (price below/inside/above the range), via `SqrtPriceMath.getAmount0/1Delta`, the same
    /// production function PoolManager calls internally for real settlement.
    function positionAmounts() public view returns (uint256 amount0, uint256 amount1) {
        if (!positionActive) return (0, 0);

        (uint128 liquidity,,) = StateLibrary.getPositionInfo(
            poolManager, poolId, address(this), activeTickLower, activeTickUpper, POSITION_SALT
        );
        if (liquidity == 0) return (0, 0);

        (uint160 sqrtPriceX96,,,) = StateLibrary.getSlot0(poolManager, poolId);
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtPriceAtTick(activeTickLower);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtPriceAtTick(activeTickUpper);

        (amount0, amount1) = _amountsForLiquidity(sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity);
    }

    /// @notice The fees currently accrued to the active position but not yet realized into idle
    /// reserves. Zero if no position is active. Purely a view — calling this never changes state.
    /// @dev Replicates `Position.update`'s exact fee formula (verified against pinned source),
    /// reading the position's cached checkpoint via `StateLibrary.getPositionInfo` and the pool's
    /// current fee growth via `StateLibrary.getFeeGrowthInside`. The subtraction is `unchecked`
    /// because fee-growth wraparound is intentional (same as in `Position.sol` itself), not an
    /// error condition.
    function pendingFees() public view returns (uint256 fees0, uint256 fees1) {
        if (!positionActive) return (0, 0);

        (uint128 liquidity, uint256 feeGrowthInside0LastX128, uint256 feeGrowthInside1LastX128) = StateLibrary.getPositionInfo(
            poolManager, poolId, address(this), activeTickLower, activeTickUpper, POSITION_SALT
        );

        (uint256 feeGrowthInside0X128, uint256 feeGrowthInside1X128) =
            StateLibrary.getFeeGrowthInside(poolManager, poolId, activeTickLower, activeTickUpper);

        unchecked {
            fees0 = FullMath.mulDiv(feeGrowthInside0X128 - feeGrowthInside0LastX128, liquidity, FixedPoint128.Q128);
            fees1 = FullMath.mulDiv(feeGrowthInside1X128 - feeGrowthInside1LastX128, liquidity, FixedPoint128.Q128);
        }
    }

    /// @notice The vault's total economic token0 assets: idle reserve + live position principal +
    /// unrealized accrued fees. Deliberately NOT combined with `totalAssets1()` into a single
    /// value — token0 and token1 are not fungible with each other without a price conversion this
    /// vault does not introduce.
    function totalAssets0() public view returns (uint256) {
        (uint256 principal0,) = positionAmounts();
        (uint256 fees0,) = pendingFees();
        return reserve0 + principal0 + fees0;
    }

    /// @notice The vault's total economic token1 assets — see `totalAssets0`.
    function totalAssets1() public view returns (uint256) {
        (, uint256 principal1) = positionAmounts();
        (, uint256 fees1) = pendingFees();
        return reserve1 + principal1 + fees1;
    }

    /// @dev Mirrors `Pool.modifyLiquidity`'s price-vs-range branch structure to compute the token
    /// amounts represented by `liquidity` between two sqrt price boundaries, rounding down (never
    /// overstating recoverable assets).
    function _amountsForLiquidity(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceLowerX96,
        uint160 sqrtPriceUpperX96,
        uint128 liquidity
    ) private pure returns (uint256 amount0, uint256 amount1) {
        if (sqrtPriceX96 <= sqrtPriceLowerX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        } else if (sqrtPriceX96 < sqrtPriceUpperX96) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPriceX96, sqrtPriceUpperX96, liquidity, false);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceX96, liquidity, false);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtPriceLowerX96, sqrtPriceUpperX96, liquidity, false);
        }
    }

    /// @notice The vault's single `PoolKey`, reassembled from its immutable components.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey();
    }

    /// @notice The live liquidity of the vault's position, read directly from PoolManager.
    /// @dev Deliberately not cached in vault storage — PoolManager is the only source of truth
    /// for this value, and caching it here would risk drifting from reality once a future
    /// rebalance/withdraw stage can change it.
    function positionLiquidity() external view returns (uint128 liquidity) {
        (liquidity,,) = StateLibrary.getPositionInfo(
            poolManager, poolId, address(this), activeTickLower, activeTickUpper, POSITION_SALT
        );
    }

    function _poolKey() private view returns (PoolKey memory) {
        return PoolKey({currency0: currency0, currency1: currency1, fee: fee, tickSpacing: tickSpacing, hooks: hooks});
    }

    /// @dev Settles one side of a PoolManager delta per the verified sign convention: negative
    /// means the vault owes PoolManager (sync, transfer, settle) — the case for adding liquidity;
    /// positive means PoolManager owes the vault (take) — the case for removing liquidity, where
    /// principal and any accrued fees arrive together in the same delta; zero needs nothing.
    function _settleDelta(Currency currency, int128 delta) private {
        if (delta < 0) {
            uint256 amountOwed = uint256(uint128(-delta));
            poolManager.sync(currency);
            SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency)), address(poolManager), amountOwed);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(delta)));
        }
    }

    /// @dev Applies a settled `BalanceDelta` side to a reserve/balance amount: a negative delta
    /// (paid out) subtracts, a positive delta (received) adds, zero is a no-op.
    function _applyDelta(uint256 base, int128 delta) private pure returns (uint256) {
        if (delta < 0) return base - uint256(uint128(-delta));
        if (delta > 0) return base + uint256(uint128(delta));
        return base;
    }

    function _positiveMagnitude(int128 delta) private pure returns (uint256) {
        return delta > 0 ? uint256(uint128(delta)) : 0;
    }

    function _negativeMagnitude(int128 delta) private pure returns (uint256) {
        return delta < 0 ? uint256(uint128(-delta)) : 0;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert InsufficientAllowance();
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (to == address(0)) revert TransferToZeroAddress();
        uint256 fromBalance = balanceOf[from];
        if (fromBalance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBalance - amount;
        }
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function _mint(address to, uint256 amount) private {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function _burn(address from, uint256 amount) private {
        balanceOf[from] -= amount;
        totalSupply -= amount;
        emit Transfer(from, address(0), amount);
    }

    /// @dev Babylonian-method integer square root, identical to Uniswap V2's `Math.sqrt`.
    function _sqrt(uint256 y) private pure returns (uint256 z) {
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
