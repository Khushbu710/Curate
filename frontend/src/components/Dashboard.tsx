"use client";

import { useAccount } from "wagmi";
import { useVaultReads } from "@/hooks/useVaultReads";
import { usePoolSlot0 } from "@/hooks/usePoolSlot0";
import { useTokenInfo } from "@/hooks/useTokenInfo";
import { formatToken } from "@/lib/format";
import { sqrtPriceX96ToPrice } from "@/lib/price";

export function Dashboard() {
  const { address } = useAccount();
  const { vault, isLoading: vaultLoading, error: vaultError } = useVaultReads(address);
  const { slot0 } = usePoolSlot0(vault?.poolId);
  const { token: token0 } = useTokenInfo(vault?.token0 as `0x${string}` | undefined, address);
  const { token: token1 } = useTokenInfo(vault?.token1 as `0x${string}` | undefined, address);

  if (vaultLoading && !vault) return <p>Loading vault state...</p>;
  if (vaultError) return <p className="tx-error">Failed to read vault: {vaultError.message}</p>;
  if (!vault) return null;

  const d0 = token0?.decimals ?? 18;
  const d1 = token1?.decimals ?? 18;
  const sym0 = token0?.symbol ?? "TOKEN0";
  const sym1 = token1?.symbol ?? "TOKEN1";

  const price =
    slot0 && token0?.decimals !== undefined && token1?.decimals !== undefined
      ? sqrtPriceX96ToPrice(slot0.sqrtPriceX96, d0, d1)
      : undefined;

  return (
    <div className="dashboard">
      <section className="panel">
        <h2>Pool</h2>
        <dl>
          <dt>Current tick</dt>
          <dd>{slot0 ? slot0.tick : "—"}</dd>
          <dt>Current price ({sym1} per {sym0})</dt>
          <dd>{price !== undefined ? price.toPrecision(8) : "—"}</dd>
          <dt>Fee tier</dt>
          <dd>{vault.fee !== undefined ? `${vault.fee / 10000}%` : "—"}</dd>
        </dl>
      </section>

      <section className="panel">
        <h2>Vault</h2>
        <dl>
          <dt>Approved range</dt>
          <dd>
            [{vault.approvedTickLower}, {vault.approvedTickUpper}]
          </dd>
          <dt>Position active</dt>
          <dd>{vault.positionActive ? "Yes" : "No"}</dd>
          {vault.positionActive && (
            <>
              <dt>Active range</dt>
              <dd>
                [{vault.activeTickLower}, {vault.activeTickUpper}]
              </dd>
              <dt>Position liquidity</dt>
              <dd>{vault.positionLiquidity?.toString()}</dd>
            </>
          )}
          <dt>Total assets ({sym0} / {sym1})</dt>
          <dd>
            {vault.totalAssets0 !== undefined ? formatToken(vault.totalAssets0, d0) : "—"} /{" "}
            {vault.totalAssets1 !== undefined ? formatToken(vault.totalAssets1, d1) : "—"}
          </dd>
          <dt>Idle reserves ({sym0} / {sym1})</dt>
          <dd>
            {vault.reserve0 !== undefined ? formatToken(vault.reserve0, d0) : "—"} /{" "}
            {vault.reserve1 !== undefined ? formatToken(vault.reserve1, d1) : "—"}
          </dd>
          <dt>Pending fees ({sym0} / {sym1})</dt>
          <dd>
            {vault.pendingFees0 !== undefined ? formatToken(vault.pendingFees0, d0) : "—"} /{" "}
            {vault.pendingFees1 !== undefined ? formatToken(vault.pendingFees1, d1) : "—"}
          </dd>
          <dt>Total shares</dt>
          <dd>{vault.totalSupply !== undefined ? formatToken(vault.totalSupply, 18) : "—"}</dd>
        </dl>
      </section>

      <section className="panel">
        <h2>Your position</h2>
        <dl>
          <dt>Share balance</dt>
          <dd>{vault.userShareBalance !== undefined ? formatToken(vault.userShareBalance, 18) : "—"}</dd>
          <dt>{sym0} balance</dt>
          <dd>{token0?.balance !== undefined ? formatToken(token0.balance, d0) : "—"}</dd>
          <dt>{sym1} balance</dt>
          <dd>{token1?.balance !== undefined ? formatToken(token1.balance, d1) : "—"}</dd>
        </dl>
      </section>
    </div>
  );
}
