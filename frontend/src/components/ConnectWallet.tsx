"use client";

import { useAccount, useConnect, useDisconnect, useSwitchChain } from "wagmi";
import { anvilChain } from "@/lib/config";
import { shortenAddress } from "@/lib/format";

export function ConnectWallet() {
  const { address, isConnected, chainId } = useAccount();
  const { connect, connectors, isPending } = useConnect();
  const { disconnect } = useDisconnect();
  const { switchChain } = useSwitchChain();

  if (!isConnected) {
    return (
      <button
        className="btn btn-primary"
        disabled={isPending}
        onClick={() => connect({ connector: connectors[0] })}
      >
        {isPending ? "Connecting..." : "Connect Wallet"}
      </button>
    );
  }

  const wrongNetwork = chainId !== anvilChain.id;

  return (
    <div className="wallet-status">
      {wrongNetwork ? (
        <button className="btn btn-warning" onClick={() => switchChain({ chainId: anvilChain.id })}>
          Wrong network — switch to {anvilChain.name}
        </button>
      ) : (
        <span className="badge">{anvilChain.name}</span>
      )}
      <span className="address">{shortenAddress(address!)}</span>
      <button className="btn btn-ghost" onClick={() => disconnect()}>
        Disconnect
      </button>
    </div>
  );
}
