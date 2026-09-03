import { defineChain } from "viem";

function requireAddress(name: string, value: string | undefined): `0x${string}` {
  if (!value || !/^0x[a-fA-F0-9]{40}$/.test(value)) {
    throw new Error(
      `Missing or invalid ${name}. Copy .env.example to .env.local and fill in your deployed addresses.`
    );
  }
  return value as `0x${string}`;
}

export const VAULT_ADDRESS = requireAddress(
  "NEXT_PUBLIC_VAULT_ADDRESS",
  process.env.NEXT_PUBLIC_VAULT_ADDRESS
);
export const POOL_MANAGER_ADDRESS = requireAddress(
  "NEXT_PUBLIC_POOL_MANAGER_ADDRESS",
  process.env.NEXT_PUBLIC_POOL_MANAGER_ADDRESS
);
export const TOKEN0_ADDRESS = requireAddress(
  "NEXT_PUBLIC_TOKEN0_ADDRESS",
  process.env.NEXT_PUBLIC_TOKEN0_ADDRESS
);
export const TOKEN1_ADDRESS = requireAddress(
  "NEXT_PUBLIC_TOKEN1_ADDRESS",
  process.env.NEXT_PUBLIC_TOKEN1_ADDRESS
);

export const CHAIN_ID = Number(process.env.NEXT_PUBLIC_CHAIN_ID ?? "31337");
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL ?? "http://127.0.0.1:8545";

export const anvilChain = defineChain({
  id: CHAIN_ID,
  name: "Local Anvil",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: {
    default: { http: [RPC_URL] },
  },
});
