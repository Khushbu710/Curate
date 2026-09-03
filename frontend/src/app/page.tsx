"use client";

import { useAccount } from "wagmi";
import { ConnectWallet } from "@/components/ConnectWallet";
import { Dashboard } from "@/components/Dashboard";
import { DepositForm } from "@/components/DepositForm";
import { WithdrawForm } from "@/components/WithdrawForm";
import { CuratorPanel } from "@/components/CuratorPanel";

export default function Home() {
  const { isConnected } = useAccount();

  return (
    <main className="page">
      <header className="page-header">
        <h1>Curated Liquidity Vault</h1>
        <ConnectWallet />
      </header>

      {!isConnected ? (
        <p>Connect a wallet on the local Anvil network to view the vault.</p>
      ) : (
        <>
          <Dashboard />
          <div className="forms-row">
            <DepositForm />
            <WithdrawForm />
          </div>
          <CuratorPanel />
        </>
      )}
    </main>
  );
}
