// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice The minimal view surface CuratedLiquidityHook needs from CuratedLiquidityVault.
/// @dev This is a project-internal interface, not a Uniswap v4 interface. It exists so the hook
/// can read the curator-approved range directly from the vault instead of duplicating it in its
/// own storage. CuratedLiquidityVault (not yet implemented) must implement this function.
interface ICuratedLiquidityVault {
    /// @notice The tick range the vault's single liquidity position is currently approved to occupy.
    function approvedRange() external view returns (int24 tickLower, int24 tickUpper);
}
