import { createConfig, http } from "wagmi";
import { injected } from "wagmi/connectors";
import { anvilChain } from "./config";

export const wagmiConfig = createConfig({
  chains: [anvilChain],
  connectors: [injected()],
  transports: {
    [anvilChain.id]: http(),
  },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
