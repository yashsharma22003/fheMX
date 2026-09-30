import { createPublicClient, createWalletClient, http, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { arbitrumSepolia } from "viem/chains";
import { createCofheClient, createCofheConfig } from "@cofhe/sdk/node";
import { arbSepolia } from "@cofhe/sdk/chains";
import { env } from "./config.ts";

export const PUBLIC_RPC = "https://sepolia-rollup.arbitrum.io/rpc";

/** viem clients for Arbitrum Sepolia, signing with `keyVar` from the environment. */
export function clients(keyVar = "PRIVATE_KEY") {
  const transport = http(env("ARBITRUM_SEPOLIA_RPC_URL", PUBLIC_RPC));
  const raw = env(keyVar).trim();
  const account = privateKeyToAccount((raw.startsWith("0x") ? raw : `0x${raw}`) as Hex);
  return {
    account,
    publicClient: createPublicClient({ chain: arbitrumSepolia, transport }),
    walletClient: createWalletClient({ chain: arbitrumSepolia, transport, account }),
  };
}

/** A CoFHE client connected to Arbitrum Sepolia with the given viem clients. */
export async function cofhe(c: ReturnType<typeof clients>) {
  const client = createCofheClient(createCofheConfig({ supportedChains: [arbSepolia] }));
  await client.connect(c.publicClient as never, c.walletClient as never);
  return client;
}
