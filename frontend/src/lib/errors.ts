import { BaseError, ContractFunctionRevertedError } from "viem";

// Human-readable messages for the exact custom errors declared on CuratedLiquidityVault
// (see src/CuratedLiquidityVault.sol). Kept as a plain lookup instead of pulling in a
// generic ABI-decoding UI library.
const ERROR_MESSAGES: Record<string, (args: readonly unknown[]) => string> = {
  NotCurator: () => "Only the curator can perform this action.",
  PositionActive: () => "The vault already has an active position; close it first.",
  NoActivePosition: () => "The vault has no active position.",
  ZeroLiquidity: () => "This would add or remove zero liquidity.",
  InsufficientVaultAssets: (args) =>
    `The vault doesn't hold enough idle assets for this payout (requested ${args[0]}/${args[2]}, available ${args[1]}/${args[3]}).`,
  SlippageExceeded: (args) =>
    `Slippage check failed: would receive ${args[0]}/${args[2]}, minimum was ${args[1]}/${args[3]}.`,
  InvalidRange: () => "Invalid tick range: lower tick must be less than upper tick.",
  InsufficientBalance: () => "You don't have enough vault shares for this withdrawal.",
  InsufficientAllowance: () => "Insufficient allowance for this transfer.",
  IncorrectRatio: () => "Deposit amounts don't match the vault's current reserve ratio.",
  ZeroDeposit: () => "Deposit amounts cannot both be zero.",
  ZeroSharesMinted: () => "This deposit would mint zero shares.",
  ZeroWithdrawal: () => "Share amount to withdraw cannot be zero.",
  ZeroPayout: () => "This withdrawal would pay out zero of both tokens.",
  PositionAlreadyActive: () => "The vault already has an active position.",
  PositionNotFullyRemoved: () => "Liquidity was not fully removed from the position.",
};

export function describeContractError(error: unknown): string {
  if (error instanceof BaseError) {
    const revertError = error.walk(
      (e) => e instanceof ContractFunctionRevertedError
    ) as ContractFunctionRevertedError | undefined;
    if (revertError?.data?.errorName) {
      const handler = ERROR_MESSAGES[revertError.data.errorName];
      if (handler) return handler(revertError.data.args ?? []);
      return `Transaction reverted: ${revertError.data.errorName}`;
    }
    return error.shortMessage ?? error.message;
  }
  if (error instanceof Error) return error.message;
  return "An unknown error occurred.";
}
