// Real PoolManager function, verified against lib/uniswap-hooks/lib/v4-core/src/interfaces/IExtsload.sol.
// Used to read raw pool storage (Pool.State slot0: sqrtPriceX96/tick/protocolFee/lpFee) without
// needing a separately-deployed StateView lens contract.
export const poolManagerExtsloadAbi = [
  {
    type: "function",
    name: "extsload",
    stateMutability: "view",
    inputs: [{ name: "slot", type: "bytes32" }],
    outputs: [{ name: "value", type: "bytes32" }],
  },
] as const;
