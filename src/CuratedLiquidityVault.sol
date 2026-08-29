// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {ERC20} from "solmate/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/utils/SafeTransferLib.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {ICuratedLiquidityVault} from "./interfaces/ICuratedLiquidityVault.sol";

/// @notice Pools token0/token1 deposits behind a single curator-managed Uniswap v4 position.
/// @dev STAGE 2: covers configuration, curator range updates, deposits, and the ERC-20 share
/// token. Deliberately does NOT deploy liquidity, rebalance, withdraw, or collect fees yet — see
/// `unlockCallback`. The vault's own shares double as the ERC-20 share token (no separate
/// contract), matching "no unnecessary abstractions".
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

    /// @notice Internally tracked deposited balances used for share pricing. Deliberately NOT
    /// live `token.balanceOf(this)`: a bare ERC-20 `transfer()` straight to this contract must not
    /// be able to move share pricing, since nothing minted shares for it.
    uint256 public reserve0;
    uint256 public reserve1;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Deposit(address indexed depositor, uint256 amount0, uint256 amount1, uint256 shares);
    event ApprovedRangeUpdated(int24 tickLower, int24 tickUpper);
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
    error LiquidityManagementNotImplemented();
    error TransferToZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    constructor(
        IPoolManager _poolManager,
        PoolKey memory _poolKey,
        address _curator,
        int24 _initialTickLower,
        int24 _initialTickUpper
    ) {
        if (address(_poolManager) == address(0)) revert ZeroPoolManagerAddress();
        if (_curator == address(0)) revert ZeroCuratorAddress();
        if (Currency.unwrap(_poolKey.currency0) == address(0)) revert ZeroCurrencyAddress();
        if (Currency.unwrap(_poolKey.currency1) == address(0)) revert ZeroCurrencyAddress();
        if (_initialTickLower >= _initialTickUpper) revert InvalidRange(_initialTickLower, _initialTickUpper);

        poolManager = _poolManager;
        currency0 = _poolKey.currency0;
        currency1 = _poolKey.currency1;
        fee = _poolKey.fee;
        tickSpacing = _poolKey.tickSpacing;
        hooks = _poolKey.hooks;
        poolId = _poolKey.toId();
        curator = _curator;

        approvedTickLower = _initialTickLower;
        approvedTickUpper = _initialTickUpper;
    }

    /// @inheritdoc ICuratedLiquidityVault
    function approvedRange() external view returns (int24 tickLower, int24 tickUpper) {
        return (approvedTickLower, approvedTickUpper);
    }

    /// @notice Updates the curator-approved range. Does NOT move any liquidity — no position
    /// exists yet at this stage, and even once one does, this function must remain pure
    /// configuration; moving liquidity is a separate, explicit rebalance action in a later stage.
    function updateApprovedRange(int24 newTickLower, int24 newTickUpper) external {
        if (msg.sender != curator) revert NotCurator(msg.sender);
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

    /// @inheritdoc IUnlockCallback
    /// @dev Liquidity management does not exist yet (STAGE 2). This still checks the caller
    /// first, so an unauthorized address gets a distinct, meaningful revert rather than relying
    /// on "no logic exists" as an accidental substitute for access control.
    function unlockCallback(bytes calldata) external view returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager(msg.sender);
        revert LiquidityManagementNotImplemented();
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
