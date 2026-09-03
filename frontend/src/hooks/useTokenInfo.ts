"use client";

import { useReadContracts } from "wagmi";
import { erc20Abi } from "@/abis/erc20";
import { VAULT_ADDRESS } from "@/lib/config";

export function useTokenInfo(tokenAddress?: `0x${string}`, account?: `0x${string}`) {
  const { data, isLoading, error, refetch } = useReadContracts({
    contracts: tokenAddress
      ? [
          { address: tokenAddress, abi: erc20Abi, functionName: "decimals" },
          { address: tokenAddress, abi: erc20Abi, functionName: "symbol" },
          {
            address: tokenAddress,
            abi: erc20Abi,
            functionName: "balanceOf",
            args: [account ?? "0x0000000000000000000000000000000000000000"],
          },
          {
            address: tokenAddress,
            abi: erc20Abi,
            functionName: "allowance",
            args: [account ?? "0x0000000000000000000000000000000000000000", VAULT_ADDRESS],
          },
        ]
      : [],
    query: { enabled: Boolean(tokenAddress), refetchInterval: 5000 },
  });

  if (!data || !tokenAddress) {
    return { isLoading, error, refetch, token: undefined };
  }

  const [decimals, symbol, balance, allowance] = data;

  return {
    isLoading,
    error,
    refetch,
    token: {
      decimals: decimals?.result,
      symbol: symbol?.result,
      balance: balance?.result,
      allowance: allowance?.result,
    },
  };
}
