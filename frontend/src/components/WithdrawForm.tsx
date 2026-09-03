"use client";

import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useVaultReads } from "@/hooks/useVaultReads";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { vaultAbi } from "@/abis/vault";
import { VAULT_ADDRESS } from "@/lib/config";
import { formatToken, parseToken } from "@/lib/format";
import { describeContractError } from "@/lib/errors";
import { TxStatus } from "./TxStatus";

const SLIPPAGE_BPS_DEFAULT = 50n; // 0.5%

export function WithdrawForm() {
  const { address } = useAccount();
  const { vault, refetch: refetchVault } = useVaultReads(address);
  const { token: token0, refetch: refetchToken0 } = useTokenInfo(
    vault?.token0 as `0x${string}` | undefined,
    address
  );
  const { token: token1, refetch: refetchToken1 } = useTokenInfo(
    vault?.token1 as `0x${string}` | undefined,
    address
  );

  const [sharesStr, setSharesStr] = useState("");
  const [minAmount0Str, setMinAmount0Str] = useState("");
  const [minAmount1Str, setMinAmount1Str] = useState("");

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) {
      refetchVault();
      refetchToken0();
      refetchToken1();
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  if (!vault || !token0 || !token1 || token0.decimals === undefined || token1.decimals === undefined) {
    return <p>Loading token info...</p>;
  }

  const d0 = token0.decimals;
  const d1 = token1.decimals;
  const shares = parseToken(sharesStr, 18);

  // Real vault valuation: totalAssets_i * shares / totalSupply — mirrors withdraw()'s
  // own mulDivDown math, not a naive reserves-only estimate.
  const estimated0 =
    vault.totalAssets0 !== undefined && vault.totalSupply && vault.totalSupply > 0n
      ? (vault.totalAssets0 * shares) / vault.totalSupply
      : 0n;
  const estimated1 =
    vault.totalAssets1 !== undefined && vault.totalSupply && vault.totalSupply > 0n
      ? (vault.totalAssets1 * shares) / vault.totalSupply
      : 0n;

  function fillSuggestedMinimums() {
    const min0 = (estimated0 * (10000n - SLIPPAGE_BPS_DEFAULT)) / 10000n;
    const min1 = (estimated1 * (10000n - SLIPPAGE_BPS_DEFAULT)) / 10000n;
    setMinAmount0Str(formatToken(min0, d0, d0));
    setMinAmount1Str(formatToken(min1, d1, d1));
  }

  const minAmount0 = parseToken(minAmount0Str, d0);
  const minAmount1 = parseToken(minAmount1Str, d1);
  const insufficientShares = vault.userShareBalance !== undefined && shares > vault.userShareBalance;

  const canWithdraw = shares > 0n && !insufficientShares;

  function submitWithdraw() {
    reset();
    writeContract({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "withdraw",
      args: [shares, minAmount0, minAmount1],
    });
  }

  return (
    <div className="panel">
      <h2>Withdraw</h2>
      <label>
        Shares to burn
        <input
          value={sharesStr}
          onChange={(e) => setSharesStr(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
        />
      </label>
      <p className="hint">
        Your balance: {vault.userShareBalance !== undefined ? formatToken(vault.userShareBalance, 18) : "—"}{" "}
        shares
      </p>
      {insufficientShares && <p className="tx-error">Insufficient share balance.</p>}

      <p className="hint">
        Estimated payout (as of last read, may drift before execution): {formatToken(estimated0, d0)}{" "}
        {token0.symbol} / {formatToken(estimated1, d1)} {token1.symbol}
      </p>

      <label>
        Minimum {token0.symbol} out
        <input
          value={minAmount0Str}
          onChange={(e) => setMinAmount0Str(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
        />
      </label>
      <label>
        Minimum {token1.symbol} out
        <input
          value={minAmount1Str}
          onChange={(e) => setMinAmount1Str(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
        />
      </label>
      <button className="btn btn-ghost" type="button" onClick={fillSuggestedMinimums}>
        Suggest minimums (0.5% slippage tolerance)
      </button>

      <button className="btn btn-primary" disabled={!canWithdraw || isPending} onClick={submitWithdraw}>
        Withdraw
      </button>

      <TxStatus
        pending={isPending}
        hash={hash}
        confirming={confirming}
        success={isSuccess}
        errorMessage={error ? describeContractError(error) : undefined}
      />
    </div>
  );
}
