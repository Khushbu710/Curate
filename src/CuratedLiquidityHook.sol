// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {ICuratedLiquidityVault} from "./interfaces/ICuratedLiquidityVault.sol";

/// @notice Enforces that the single pool this hook is attached to is managed exclusively by one
/// vault, and only within that vault's curator-approved tick range.
/// @dev Deliberately small: it holds no accounting state and duplicates none of the vault's
/// storage. It reads the approved range from the vault via `ICuratedLiquidityVault.approvedRange`
/// (a `view` call) at the moment liquidity is added or removed.
contract CuratedLiquidityHook is BaseHook {
    /// @notice The only address permitted to add or remove liquidity in this pool.
    address public immutable vault;

    /// @notice The only pool this hook is permitted to act on.
    PoolId public immutable poolId;

    /// @notice Thrown when a party other than `vault` attempts to add or remove liquidity.
    error NotVault(address sender);

    /// @notice Thrown when the callback's PoolKey does not resolve to this hook's configured pool.
    error WrongPool(PoolId providedPoolId);

    /// @notice Thrown when a genuine add/remove targets a range other than the vault's approved one.
    error RangeNotApproved(int24 tickLower, int24 tickUpper);

    /// @notice Thrown when the vault address supplied at construction is the zero address.
    error ZeroVaultAddress();

    constructor(IPoolManager _poolManager, address _vault, PoolId _poolId) BaseHook(_poolManager) {
        if (_vault == address(0)) revert ZeroVaultAddress();
        vault = _vault;
        poolId = _poolId;
    }

    /// @dev Only `beforeAddLiquidity` and `beforeRemoveLiquidity` are enabled. Everything else
    /// — including both `afterAddLiquidity`/`afterRemoveLiquidity` and all swap/donate/initialize
    /// callbacks — is left disabled: this hook enforces curation, not swap or fee behavior.
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    function _beforeAddLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _checkSenderAndPool(sender, key);
        _checkApprovedRange(params.tickLower, params.tickUpper);
        return IHooks.beforeAddLiquidity.selector;
    }

    function _beforeRemoveLiquidity(
        address sender,
        PoolKey calldata key,
        ModifyLiquidityParams calldata params,
        bytes calldata
    ) internal view override returns (bytes4) {
        _checkSenderAndPool(sender, key);
        // liquidityDelta <= 0 reaches this callback (see Hooks.beforeModifyLiquidity). A delta of
        // exactly 0 is a fee poke: it changes no principal and no range, so it must stay
        // permissionless and is deliberately NOT range-checked. Only a genuine removal
        // (liquidityDelta < 0) is required to target the approved range.
        if (params.liquidityDelta < 0) {
            _checkApprovedRange(params.tickLower, params.tickUpper);
        }
        return IHooks.beforeRemoveLiquidity.selector;
    }

    function _checkSenderAndPool(address sender, PoolKey calldata key) private view {
        if (sender != vault) revert NotVault(sender);
        PoolId providedPoolId = key.toId();
        if (PoolId.unwrap(providedPoolId) != PoolId.unwrap(poolId)) revert WrongPool(providedPoolId);
    }

    function _checkApprovedRange(int24 tickLower, int24 tickUpper) private view {
        (int24 approvedTickLower, int24 approvedTickUpper) = ICuratedLiquidityVault(vault).approvedRange();
        if (tickLower != approvedTickLower || tickUpper != approvedTickUpper) {
            revert RangeNotApproved(tickLower, tickUpper);
        }
    }
}
