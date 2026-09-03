"use client";

import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useVaultReads } from "@/hooks/useVaultReads";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { vaultAbi } from "@/abis/vault";
import { erc20Abi } from "@/abis/erc20";
import { VAULT_ADDRESS } from "@/lib/config";
import { formatToken, parseToken } from "@/lib/format";
import { describeContractError } from "@/lib/errors";
import { TxStatus } from "./TxStatus";

export function DepositForm() {
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

  const [amount0Str, setAmount0Str] = useState("");
  const [amount1Str, setAmount1Str] = useState("");

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
  const amount0 = parseToken(amount0Str, d0);
  const amount1 = parseToken(amount1Str, d1);
  const isFirstDeposit = vault.totalSupply === 0n;

  const ratioOk =
    isFirstDeposit ||
    (amount0 > 0n &&
      amount1 > 0n &&
      vault.reserve0 !== undefined &&
      vault.reserve1 !== undefined &&
      amount0 * vault.reserve1 === amount1 * vault.reserve0);

  const reserve0 = vault.reserve0;
  const reserve1 = vault.reserve1;

  function suggestAmount1() {
    if (!reserve0 || reserve0 === 0n || !reserve1) return;
    const suggested = (amount0 * reserve1) / reserve0;
    setAmount1Str(formatToken(suggested, d1, d1));
  }

  const needsApproval0 = token0.allowance !== undefined && token0.allowance < amount0;
  const needsApproval1 = token1.allowance !== undefined && token1.allowance < amount1;
  const insufficientBalance0 = token0.balance !== undefined && amount0 > token0.balance;
  const insufficientBalance1 = token1.balance !== undefined && amount1 > token1.balance;

  function approve(tokenAddress: `0x${string}`, amount: bigint) {
    reset();
    writeContract({
      address: tokenAddress,
      abi: erc20Abi,
      functionName: "approve",
      args: [VAULT_ADDRESS, amount],
    });
  }

  function submitDeposit() {
    reset();
    writeContract({
      address: VAULT_ADDRESS,
      abi: vaultAbi,
      functionName: "deposit",
      args: [amount0, amount1],
    });
  }

  const canDeposit =
    amount0 + amount1 > 0n &&
    ratioOk &&
    !needsApproval0 &&
    !needsApproval1 &&
    !insufficientBalance0 &&
    !insufficientBalance1;

  return (
    <div className="panel">
      <h2>Deposit</h2>
      {isFirstDeposit && (
        <p className="hint">
          This is the first deposit — any ratio of the two tokens is accepted, it sets the vault&apos;s
          initial price.
        </p>
      )}
      <label>
        {token0.symbol} amount
        <input
          value={amount0Str}
          onChange={(e) => setAmount0Str(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
        />
      </label>
      <label>
        {token1.symbol} amount
        <input
          value={amount1Str}
          onChange={(e) => setAmount1Str(e.target.value)}
          placeholder="0.0"
          inputMode="decimal"
        />
      </label>
      {!isFirstDeposit && (
        <button className="btn btn-ghost" type="button" onClick={suggestAmount1}>
          Fill {token1.symbol} to match current ratio
        </button>
      )}
      {!isFirstDeposit && amount0 > 0n && amount1 > 0n && !ratioOk && (
        <p className="tx-error">
          Amounts don&apos;t match the vault&apos;s current reserve ratio exactly. Deposits must match
          ratio precisely — no partial swap is performed. Use the fill button above for an exact match.
        </p>
      )}
      {insufficientBalance0 && <p className="tx-error">Insufficient {token0.symbol} balance.</p>}
      {insufficientBalance1 && <p className="tx-error">Insufficient {token1.symbol} balance.</p>}

      {needsApproval0 && (
        <button className="btn btn-secondary" onClick={() => approve(vault.token0 as `0x${string}`, amount0)}>
          Approve {token0.symbol}
        </button>
      )}
      {needsApproval1 && (
        <button className="btn btn-secondary" onClick={() => approve(vault.token1 as `0x${string}`, amount1)}>
          Approve {token1.symbol}
        </button>
      )}
      <button className="btn btn-primary" disabled={!canDeposit || isPending} onClick={submitDeposit}>
        Deposit
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
