// Permissionless checker (design D3): anyone can run it. Each tick it
//   1. checks open orders when their market's Chainlink feed has a new answer,
//   2. decrypts each check's public result through CoFHE and executes the orders that fired,
//   3. settles fills, re-arms GMX cancellations once (D4) and reconciles lost GMX callbacks.
// Every step is logged to checker/metrics.jsonl (latency and gas), for the design §10 measurements.
import { appendFileSync } from "node:fs";
import { join } from "node:path";
import { parseAbiItem, type Address, type Hex } from "viem";
import {
  sealedOrderAdapterAbi,
  userAccountAbi,
  chainlinkFeedPriceVerifierAbi,
  aggregatorV3Abi,
  loadDeployment,
  loadNetwork,
  deploymentBlock,
  clients,
  cofhe,
  env,
  repoRoot,
  Status,
  GmxOutcome,
} from "@sealed/shared";

const POLL_MS = Number(env("CHECKER_POLL_MS", "10000"));
const LOG_CHUNK = 9_000n;
const ORDER_LIST = "0x86f7cfd5d8f8404e5145c91bebb8484657420159dabd0753d6a59f3de3f7b8c1" as Hex; // keccak256(abi.encode("ORDER_LIST"))

const deployment = loadDeployment();
const network = loadNetwork();
const c = clients("CHECKER_PRIVATE_KEY");
const fhe = await cofhe(c);
const adapter = { address: deployment.adapter, abi: sealedOrderAdapterAbi } as const;

const metricsFile = join(repoRoot, "checker", "metrics.jsonl");
function metric(event: string, data: Record<string, unknown>) {
  const line = JSON.stringify({ t: new Date().toISOString(), event, ...data }, (_, v) =>
    typeof v === "bigint" ? v.toString() : v,
  );
  appendFileSync(metricsFile, line + "\n");
  console.log(line);
}

// ─── order discovery ────────────────────────────────────────────────────────

const orderSealed = parseAbiItem(
  "event OrderSealed(bytes32 indexed orderId, address indexed owner, address indexed account, address market, uint8 kind, uint256 collateral, uint256 executionFee, uint256 protocolFeeReserve)",
);
const known = new Map<Hex, { market: Address; account: Address }>();
let scannedTo = (deploymentBlock() ?? BigInt(env("START_BLOCK", "0"))) - 1n;

async function discoverOrders() {
  const head = await c.publicClient.getBlockNumber();
  while (scannedTo < head) {
    const from = scannedTo + 1n;
    const to = from + LOG_CHUNK > head ? head : from + LOG_CHUNK;
    const logs = await c.publicClient.getLogs({ address: deployment.adapter, event: orderSealed, fromBlock: from, toBlock: to });
    for (const l of logs) known.set(l.args.orderId!, { market: l.args.market!, account: l.args.account! });
    scannedTo = to;
  }
}

// ─── helpers ────────────────────────────────────────────────────────────────

async function send(label: string, request: Parameters<typeof c.walletClient.writeContract>[0], extra = {}) {
  const started = Date.now();
  const hash = await c.walletClient.writeContract(request);
  const receipt = await c.publicClient.waitForTransactionReceipt({ hash });
  metric(label, { ...extra, hash, status: receipt.status, gasUsed: receipt.gasUsed, ms: Date.now() - started });
  return receipt;
}

async function decrypt(handle: Hex) {
  const started = Date.now();
  const result = await fhe.decryptForTx(handle).withoutACP().execute();
  return { value: result.decryptedValue, signature: result.signature, ms: Date.now() - started };
}

/** Update time of the market's index-token feed: a new answer is what makes a new check worthwhile. */
async function feedUpdatedAt(market: Address): Promise<bigint> {
  const info = await c.publicClient.readContract({ ...adapter, functionName: "marketOf", args: [market] });
  const [feed] = await c.publicClient.readContract({
    address: deployment.priceVerifier,
    abi: chainlinkFeedPriceVerifierAbi,
    functionName: "feedOf",
    args: [info.indexToken],
  });
  const round = await c.publicClient.readContract({ address: feed, abi: aggregatorV3Abi, functionName: "latestRoundData" });
  return round[3];
}

// ─── the three jobs ─────────────────────────────────────────────────────────

async function checkOpenOrders(open: Hex[], now: bigint) {
  const minInterval = BigInt(await c.publicClient.readContract({ ...adapter, functionName: "minCheckInterval" }));
  const byMarket = new Map<Address, Hex[]>();
  for (const id of open) {
    const { market } = known.get(id)!;
    const updatedAt = await feedUpdatedAt(market);
    const check = await c.publicClient.readContract({ ...adapter, functionName: "checkOf", args: [id] });
    const due = check.lastCheckAt === 0n || now >= check.lastCheckAt + minInterval;
    if (check.lastReportTimestamp < updatedAt && due) byMarket.set(market, [...(byMarket.get(market) ?? []), id]);
  }
  for (const [market, ids] of byMarket) {
    const feedTs = await feedUpdatedAt(market);
    await send("checkBatch", { ...adapter, functionName: "checkBatch", args: [market, ids, "0x"] } as never, {
      orders: ids.length,
      feedAgeS: now - feedTs,
    });
    for (const id of ids) await executeIfFired(id);
  }
}

async function executeIfFired(id: Hex) {
  const check = await c.publicClient.readContract({ ...adapter, functionName: "checkOf", args: [id] });
  const size = await decrypt(check.revealedSize);
  metric("decrypt", { orderId: id, fired: size.value !== 0n, ms: size.ms });
  if (size.value === 0n) return;

  const isLong = await decrypt(check.revealedIsLong);
  const slippage = await decrypt(check.revealedSlippage);
  await send(
    "execute",
    {
      ...adapter,
      functionName: "execute",
      args: [id, size.value, size.signature, isLong.value !== 0n, isLong.signature, Number(slippage.value), slippage.signature],
    } as never,
    { orderId: id },
  );
}

async function followUpFiredOrder(id: Hex) {
  const { account } = known.get(id)!;
  const [outcomeIndex, gmxKey] = await c.publicClient.readContract({
    address: account,
    abi: userAccountAbi,
    functionName: "outcomeOf",
    args: [id],
  });
  const outcome = GmxOutcome[outcomeIndex];
  if (outcome === "Executed") {
    await send("settle", { ...adapter, functionName: "settle", args: [id] } as never, { orderId: id });
  } else if (outcome === "Cancelled" || outcome === "Frozen") {
    const fill = await c.publicClient.readContract({ ...adapter, functionName: "fillOf", args: [id] });
    const ownerCancelled = await c.publicClient.readContract({
      address: account,
      abi: userAccountAbi,
      functionName: "cancelledByOwner",
      args: [id],
    });
    if (!fill.rearmed && !ownerCancelled) {
      await send("rearm", { ...adapter, functionName: "rearm", args: [id] } as never, { orderId: id });
    }
  } else if (outcome === "Pending") {
    const stillAtGmx = await c.publicClient.readContract({
      address: network.gmx.dataStore,
      abi: [parseAbiItem("function containsBytes32(bytes32,bytes32) view returns (bool)")],
      functionName: "containsBytes32",
      args: [ORDER_LIST, gmxKey],
    });
    if (!stillAtGmx) {
      await send("reconcile", { address: account, abi: userAccountAbi, functionName: "reconcile", args: [id] } as never, {
        orderId: id,
      });
    }
  }
}

// ─── loop ───────────────────────────────────────────────────────────────────

async function tick() {
  await discoverOrders();
  const now = (await c.publicClient.getBlock()).timestamp;
  const open: Hex[] = [];
  for (const id of known.keys()) {
    const order = await c.publicClient.readContract({ ...adapter, functionName: "orderOf", args: [id] });
    const status = Status[order.status];
    if (status === "Open") open.push(id);
    else if (status === "Fired") await followUpFiredOrder(id);
  }
  if (open.length) await checkOpenOrders(open, now);
}

console.log(`checker ${c.account.address} watching adapter ${deployment.adapter} every ${POLL_MS} ms`);
for (;;) {
  try {
    await tick();
  } catch (err) {
    metric("error", { message: err instanceof Error ? err.message.split("\n")[0] : String(err) });
  }
  await new Promise((r) => setTimeout(r, POLL_MS));
}
