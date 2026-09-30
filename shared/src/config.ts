import { readFileSync, existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { Address } from "viem";

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

export interface NetworkConfig {
  chainId: number;
  gmx: Record<"dataStore" | "exchangeRouter" | "orderHandler" | "reader" | "roleStore" | "wnt", Address>;
  markets: Record<string, { marketToken: Address; indexToken: Address; longToken: Address; shortToken: Address }>;
  chainlinkFeeds: Record<string, Address>;
}

export interface Deployment {
  chainId: number;
  adapter: Address;
  factory: Address;
  priceVerifier: Address;
  accountImplementation: Address;
  feeCollector: Address;
}

export function loadNetwork(): NetworkConfig {
  return JSON.parse(readFileSync(join(repoRoot, "config", "networks", "arbitrum-sepolia.json"), "utf8"));
}

/** Live deployment written by `script/Deploy.s.sol`. Set DEPLOYMENT=dry-run to read the dry-run file. */
export function loadDeployment(): Deployment {
  const suffix = process.env.DEPLOYMENT === "dry-run" ? ".dry-run" : "";
  const file = join(repoRoot, "deployments", `arbitrum-sepolia${suffix}.json`);
  if (!existsSync(file)) throw new Error(`No deployment at ${file}. Run the deploy script first (see README).`);
  return JSON.parse(readFileSync(file, "utf8"));
}

/** L2 block of the deployment, from Foundry's broadcast receipts (Arbitrum `block.number` is the L1 block). */
export function deploymentBlock(): bigint | undefined {
  const file = join(repoRoot, "contracts", "broadcast", "Deploy.s.sol", "421614", "run-latest.json");
  if (!existsSync(file)) return undefined;
  const run = JSON.parse(readFileSync(file, "utf8")) as { receipts: { blockNumber: string }[] };
  const blocks = run.receipts.map((r) => BigInt(r.blockNumber));
  return blocks.length ? blocks.reduce((a, b) => (a < b ? a : b)) : undefined;
}

export function env(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (value === undefined || value === "") throw new Error(`Missing environment variable ${name} (see .env.example)`);
  return value;
}
