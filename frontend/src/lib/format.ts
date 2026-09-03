import { formatUnits, parseUnits } from "viem";

export function formatToken(amount: bigint, decimals: number, maxFractionDigits = 6): string {
  const formatted = formatUnits(amount, decimals);
  const [whole, frac] = formatted.split(".");
  if (!frac) return whole;
  return `${whole}.${frac.slice(0, maxFractionDigits)}`;
}

export function parseToken(amount: string, decimals: number): bigint {
  if (!amount || Number.isNaN(Number(amount))) return 0n;
  return parseUnits(amount, decimals);
}

export function shortenAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}
