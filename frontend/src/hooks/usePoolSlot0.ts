"use client";

import { useReadContract } from "wagmi";
import { poolManagerExtsloadAbi } from "@/abis/poolManagerExtsload";
import { POOL_MANAGER_ADDRESS } from "@/lib/config";
import { decodeSlot0, poolStateSlot } from "@/lib/price";

/**
 * Reads the live sqrtPriceX96/tick directly from PoolManager storage via extsload,
 * replicating StateLibrary.getSlot0's slot arithmetic. The Vault contract has no
 * direct getter for this — it's the one value the frontend must source from
 * PoolManager rather than the Vault.
 */
export function usePoolSlot0(poolId?: `0x${string}`) {
  const slot = poolId ? poolStateSlot(poolId) : undefined;

  const { data, isLoading, error, refetch } = useReadContract({
    address: POOL_MANAGER_ADDRESS,
    abi: poolManagerExtsloadAbi,
    functionName: "extsload",
    args: slot ? [slot] : undefined,
    query: { enabled: Boolean(slot), refetchInterval: 5000 },
  });

  if (!data) return { isLoading, error, refetch, slot0: undefined };

  return { isLoading, error, refetch, slot0: decodeSlot0(data) };
}
