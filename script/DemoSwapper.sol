// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice Minimal real swapper for the local Anvil demo — not a router, not production code.
/// Extracted verbatim from `TestSwapper` in test/CuratedLiquidityVaultFees.t.sol (already proven
/// correct by that suite's fee-accrual tests) so the demo can generate genuine PoolManager swap
/// fees without pulling in a full router/Permit2/UniversalRouter dependency.
contract DemoSwapper is IUnlockCallback {
    IPoolManager internal immutable manager;
    PoolKey internal key;
    address internal immutable trader;

    constructor(IPoolManager _manager, PoolKey memory _key, address _trader) {
        manager = _manager;
        key = _key;
        trader = _trader;
    }

    function swap(bool zeroForOne, int256 amountSpecified) external {
        manager.unlock(abi.encode(zeroForOne, amountSpecified));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        uint160 sqrtPriceLimitX96 = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;

        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: sqrtPriceLimitX96
            }),
            ""
        );

        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return "";
    }

    function _settle(Currency currency, int128 delta) internal {
        if (delta < 0) {
            manager.sync(currency);
            MockERC20(Currency.unwrap(currency)).transfer(address(manager), uint256(uint128(-delta)));
            manager.settle();
        } else if (delta > 0) {
            manager.take(currency, trader, uint256(uint128(delta)));
        }
    }
}
