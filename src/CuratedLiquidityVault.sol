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
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

import {ICuratedLiquidityVault} from "./interfaces/ICuratedLiquidityVault.sol";

/// @notice Pools token0/token1 deposits behind a single curator-managed Uniswap v4 position.
/// @dev STAGE 3: adds the ability to deploy idle reserves into exactly one real PoolManager
/// position. Still does NOT implement withdrawals, partial removal, rebalancing, or fee
/// collection/pokes — those are later stages. The vault's own shares double as the ERC-20 share
/// token (no separate contract), matching "no unnecessary abstractions".
contract CuratedLiquidityVault is ICuratedLiquidityVault, IUnlockCallback {
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
    error ZeroLiquidity();
    error TransferToZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

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

        poolManager.unlock("");
    }

    /// @inheritdoc IUnlockCallback
    /// @dev The only reachable action in this stage is opening the vault's single position — it
    /// is unconditional here because `openPosition` already gates `positionActive` before ever
    /// calling `unlock`, and PoolManager's own single-unlock-per-call lock (`AlreadyUnlocked`)
    /// independently prevents this from being re-entered mid-callback. The `data` parameter is
    /// intentionally ignored: nothing about this operation is caller-configurable.
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);

        int24 tickLower = approvedTickLower;
        int24 tickUpper = approvedTickUpper;

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

        uint256 amount0Paid = _settleDelta(currency0, callerDelta.amount0());
        uint256 amount1Paid = _settleDelta(currency1, callerDelta.amount1());

        // Reserves fall by exactly what PoolManager actually charged — never by `idle0`/`idle1`,
        // since getLiquidityForAmounts may not have needed the full amount on one side (e.g. the
        // range only partially overlaps the current price). Any unused amount stays idle.
        reserve0 = idle0 - amount0Paid;
        reserve1 = idle1 - amount1Paid;

        positionActive = true;
        activeTickLower = tickLower;
        activeTickUpper = tickUpper;

        emit PositionOpened(tickLower, tickUpper, liquidity, amount0Paid, amount1Paid);

        return "";
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
    /// means the vault owes PoolManager (sync, transfer, settle); positive means PoolManager owes
    /// the vault (take); zero needs nothing. Returns the amount paid (0 if owed or unowed).
    function _settleDelta(Currency currency, int128 delta) private returns (uint256 amountPaid) {
        if (delta < 0) {
            amountPaid = uint256(uint128(-delta));
            poolManager.sync(currency);
            SafeTransferLib.safeTransfer(ERC20(Currency.unwrap(currency)), address(poolManager), amountPaid);
            poolManager.settle();
        } else if (delta > 0) {
            poolManager.take(currency, address(this), uint256(uint128(delta)));
        }
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
