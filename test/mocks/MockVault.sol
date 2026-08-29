// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ICuratedLiquidityVault} from "../../src/interfaces/ICuratedLiquidityVault.sol";

/// @notice Test double standing in for CuratedLiquidityVault, which is not yet implemented.
/// Exposes a settable approved range so tests can exercise the hook's range-checking logic.
contract MockVault is ICuratedLiquidityVault {
    int24 private _tickLower;
    int24 private _tickUpper;

    constructor(int24 tickLower_, int24 tickUpper_) {
        _tickLower = tickLower_;
        _tickUpper = tickUpper_;
    }

    function setApprovedRange(int24 tickLower_, int24 tickUpper_) external {
        _tickLower = tickLower_;
        _tickUpper = tickUpper_;
    }

    function approvedRange() external view returns (int24 tickLower, int24 tickUpper) {
        return (_tickLower, _tickUpper);
    }
}
