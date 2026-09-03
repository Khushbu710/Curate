"use client";

import { useReadContracts } from "wagmi";
import { vaultAbi } from "@/abis/vault";
import { VAULT_ADDRESS } from "@/lib/config";

const contract = { address: VAULT_ADDRESS, abi: vaultAbi } as const;

/**
 * Batches every vault view read the dashboard needs into one multicall.
 * All of these are directly exposed by CuratedLiquidityVault — no separate
 * PoolManager call is needed except for the live pool price (see usePoolSlot0).
 */
export function useVaultReads(account?: `0x${string}`) {
  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: [
      { ...contract, functionName: "curator" },
      { ...contract, functionName: "token0" },
      { ...contract, functionName: "token1" },
      { ...contract, functionName: "fee" },
      { ...contract, functionName: "tickSpacing" },
      { ...contract, functionName: "approvedRange" },
      { ...contract, functionName: "positionActive" },
      { ...contract, functionName: "activeTickLower" },
      { ...contract, functionName: "activeTickUpper" },
      { ...contract, functionName: "positionLiquidity" },
      { ...contract, functionName: "positionAmounts" },
      { ...contract, functionName: "pendingFees" },
      { ...contract, functionName: "totalAssets0" },
      { ...contract, functionName: "totalAssets1" },
      { ...contract, functionName: "reserve0" },
      { ...contract, functionName: "reserve1" },
      { ...contract, functionName: "totalSupply" },
      { ...contract, functionName: "poolId" },
      {
        ...contract,
        functionName: "balanceOf",
        args: [account ?? "0x0000000000000000000000000000000000000000"],
      },
    ],
    query: { enabled: true, refetchInterval: 5000 },
  });

  if (!data) return { isLoading, error, refetch, vault: undefined };

  const [
    curator,
    token0,
    token1,
    fee,
    tickSpacing,
    approvedRange,
    positionActive,
    activeTickLower,
    activeTickUpper,
    positionLiquidity,
    positionAmounts,
    pendingFees,
    totalAssets0,
    totalAssets1,
    reserve0,
    reserve1,
    totalSupply,
    poolId,
    userShareBalance,
  ] = data;

  return {
    isLoading,
    error,
    refetch,
    vault: {
      curator: curator.result,
      token0: token0.result,
      token1: token1.result,
      fee: fee.result,
      tickSpacing: tickSpacing.result,
      approvedTickLower: approvedRange.result?.[0],
      approvedTickUpper: approvedRange.result?.[1],
      positionActive: positionActive.result,
      activeTickLower: activeTickLower.result,
      activeTickUpper: activeTickUpper.result,
      positionLiquidity: positionLiquidity.result,
      positionAmount0: positionAmounts.result?.[0],
      positionAmount1: positionAmounts.result?.[1],
      pendingFees0: pendingFees.result?.[0],
      pendingFees1: pendingFees.result?.[1],
      totalAssets0: totalAssets0.result,
      totalAssets1: totalAssets1.result,
      reserve0: reserve0.result,
      reserve1: reserve1.result,
      totalSupply: totalSupply.result,
      poolId: poolId.result,
      userShareBalance: userShareBalance.result,
    },
  };
}
