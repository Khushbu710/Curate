// sqrtPriceX96 / tick math, verified against StateLibrary.getSlot0 (v4-core) and TickMath.
// No @uniswap/v4-sdk dependency — this is the entire surface we need.

const POOLS_SLOT = 6n;

/**
 * Storage slot of `pools[poolId]` in PoolManager, matching
 * StateLibrary._getPoolStateSlot: keccak256(abi.encodePacked(poolId, uint256(6))).
 */
export function poolStateSlot(poolId: `0x${string}`): `0x${string}` {
  const packed = (poolId.slice(2) + POOLS_SLOT.toString(16).padStart(64, "0")) as string;
  return keccak256Hex(`0x${packed}`);
}

import { keccak256 as viemKeccak256 } from "viem";
function keccak256Hex(data: `0x${string}`): `0x${string}` {
  return viemKeccak256(data);
}

/**
 * Decodes the packed slot0 word read via PoolManager.extsload, matching
 * StateLibrary.getSlot0's assembly layout:
 *   [24 bits lpFee][24 bits protocolFee][24 bits tick][160 bits sqrtPriceX96]
 */
export function decodeSlot0(data: `0x${string}`): {
  sqrtPriceX96: bigint;
  tick: number;
} {
  const value = BigInt(data);
  const sqrtPriceX96 = value & ((1n << 160n) - 1n);
  let tickRaw = (value >> 160n) & ((1n << 24n) - 1n);
  // sign-extend 24-bit tick
  if (tickRaw & (1n << 23n)) {
    tickRaw -= 1n << 24n;
  }
  return { sqrtPriceX96, tick: Number(tickRaw) };
}

/**
 * Converts sqrtPriceX96 (Q64.96, price of token1 per token0 in raw token units)
 * into a human price of token1 per token0, adjusted for decimals.
 * price = (sqrtPriceX96 / 2^96)^2 * 10^(decimals0 - decimals1)
 */
export function sqrtPriceX96ToPrice(
  sqrtPriceX96: bigint,
  decimals0: number,
  decimals1: number
): number {
  const Q96 = 2 ** 96;
  const ratio = Number(sqrtPriceX96) / Q96;
  const rawPrice = ratio * ratio;
  return rawPrice * 10 ** (decimals0 - decimals1);
}

export function isTickSpacingAligned(tick: number, tickSpacing: number): boolean {
  return tick % tickSpacing === 0;
}
