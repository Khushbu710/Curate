"use client";

import { useEffect, useState } from "react";
import { useAccount, useWriteContract, useWaitForTransactionReceipt } from "wagmi";
import { useVaultReads } from "@/hooks/useVaultReads";
import { usePoolSlot0 } from "@/hooks/usePoolSlot0";
import { vaultAbi } from "@/abis/vault";
import { VAULT_ADDRESS } from "@/lib/config";
import { isTickSpacingAligned } from "@/lib/price";
import { describeContractError } from "@/lib/errors";
import { TxStatus } from "./TxStatus";

export function CuratorPanel() {
  const { address } = useAccount();
  const { vault, refetch: refetchVault } = useVaultReads(address);
  const { slot0 } = usePoolSlot0(vault?.poolId);

  const [newTickLower, setNewTickLower] = useState("");
  const [newTickUpper, setNewTickUpper] = useState("");
  const [confirmRebalance, setConfirmRebalance] = useState(false);

  const { writeContract, data: hash, isPending, error, reset } = useWriteContract();
  const { isLoading: confirming, isSuccess } = useWaitForTransactionReceipt({ hash });

  useEffect(() => {
    if (isSuccess) refetchVault();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [isSuccess]);

  if (!vault || vault.curator === undefined) return null;
  if (!address || address.toLowerCase() !== vault.curator.toLowerCase()) return null;

  const tickSpacing = vault.tickSpacing ?? 1;
  const lower = Number(newTickLower);
  const upper = Number(newTickUpper);
  const rangeEntered = newTickLower !== "" && newTickUpper !== "";
  const rangeValid =
    rangeEntered &&
    Number.isInteger(lower) &&
    Number.isInteger(upper) &&
    lower < upper &&
    isTickSpacingAligned(lower, tickSpacing) &&
    isTickSpacingAligned(upper, tickSpacing);

  const inRange = slot0 !== undefined && rangeValid && slot0.tick >= lower && slot0.tick < upper;

  function callVault(functionName: "updateApprovedRange" | "rebalance", args: readonly [number, number]) {
    reset();
    writeContract({ address: VAULT_ADDRESS, abi: vaultAbi, functionName, args: [args[0], args[1]] });
  }

  function openPosition() {
    reset();
    writeContract({ address: VAULT_ADDRESS, abi: vaultAbi, functionName: "openPosition" });
  }

  function collectFees() {
    reset();
    writeContract({ address: VAULT_ADDRESS, abi: vaultAbi, functionName: "collectFees" });
  }

  return (
    <div className="panel curator-panel">
      <h2>Curator controls</h2>

      <div className="curator-section">
        <h3>Range</h3>
        <label>
          New tick lower
          <input value={newTickLower} onChange={(e) => setNewTickLower(e.target.value)} placeholder="e.g. -600" />
        </label>
        <label>
          New tick upper
          <input value={newTickUpper} onChange={(e) => setNewTickUpper(e.target.value)} placeholder="e.g. 600" />
        </label>
        {rangeEntered && !rangeValid && (
          <p className="tx-error">
            Range must have lower &lt; upper and both ticks aligned to tick spacing ({tickSpacing}).
          </p>
        )}
        {rangeValid && (
          <p className="hint">{inRange ? "Current tick is inside this range." : "Current tick is outside this range."}</p>
        )}

        {!vault.positionActive && (
          <button
            className="btn btn-secondary"
            disabled={!rangeValid}
            onClick={() => callVault("updateApprovedRange", [lower, upper])}
          >
            Update approved range
          </button>
        )}

        {!vault.positionActive && (
          <button className="btn btn-primary" onClick={openPosition}>
            Open position (using approved range [{vault.approvedTickLower}, {vault.approvedTickUpper}])
          </button>
        )}

        {vault.positionActive && (
          <div className="rebalance-confirm">
            <p className="hint">
              Rebalance: close active range [{vault.activeTickLower}, {vault.activeTickUpper}] and reopen
              at [{newTickLower || "?"}, {newTickUpper || "?"}].
            </p>
            <label>
              <input
                type="checkbox"
                checked={confirmRebalance}
                onChange={(e) => setConfirmRebalance(e.target.checked)}
              />
              I confirm I want to close the active range and reopen at the new range above.
            </label>
            <button
              className="btn btn-warning"
              disabled={!rangeValid || !confirmRebalance}
              onClick={() => callVault("rebalance", [lower, upper])}
            >
              Rebalance
            </button>
          </div>
        )}
      </div>

      <div className="curator-section">
        <h3>Fees</h3>
        <button className="btn btn-secondary" disabled={!vault.positionActive} onClick={collectFees}>
          Collect fees
        </button>
      </div>

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
