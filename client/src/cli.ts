// User CLI: fund your account, place sealed orders, cancel, withdraw, inspect.
// Order fields are encrypted locally with @cofhe/sdk and bound to your address and the adapter,
// so only ciphertext (plus the public terms) goes on-chain.
//
//   pnpm -F client cli account
//   pnpm -F client cli fund 0.05
//   pnpm -F client cli order --kind limit --side long --size 100 --trigger 2400 --slippage 100 --collateral 0.02
//   pnpm -F client cli order --kind stop  --side long --size 100 --trigger 2300 --slippage 100
//   pnpm -F client cli status 1
//   pnpm -F client cli cancel 1
//   pnpm -F client cli withdraw 0.01
import { parseArgs } from "node:util";
import { formatEther, parseEther, toHex, pad, type Hex } from "viem";
import { Encryptable } from "@cofhe/sdk";
import {
  sealedOrderAdapterAbi,
  userAccountAbi,
  loadDeployment,
  loadNetwork,
  clients,
  cofhe,
  toSizeUsd6,
  toPrice8,
  fromPrice8,
  OrderKind,
  Status,
  GmxOutcome,
} from "@sealed/shared";

const deployment = loadDeployment();
const network = loadNetwork();
const c = clients("PRIVATE_KEY");
const adapter = { address: deployment.adapter, abi: sealedOrderAdapterAbi } as const;
const wnt = network.gmx.wnt;
const market = network.markets.ETH_USD.marketToken;

async function accountAddress() {
  return c.publicClient.readContract({ ...adapter, functionName: "accountOf", args: [c.account.address] });
}

async function wait(label: string, hash: Hex) {
  const receipt = await c.publicClient.waitForTransactionReceipt({ hash });
  console.log(`${label}: ${receipt.status} (tx ${hash}, gas ${receipt.gasUsed})`);
  return receipt;
}

const orderIdArg = (s: string | undefined) => pad(toHex(BigInt(s ?? "0")), { size: 32 });

const commands: Record<string, (args: string[]) => Promise<void>> = {
  async account() {
    const account = await accountAddress();
    const deployed = (await c.publicClient.getCode({ address: account })) !== undefined;
    const total = await c.publicClient.getBalance({ address: account });
    console.log(`owner    ${c.account.address}`);
    console.log(`account  ${account}${deployed ? "" : " (created on your first order; you can fund it now)"}`);
    console.log(`balance  ${formatEther(total)} ETH`);
    if (deployed) {
      const free = await c.publicClient.readContract({ address: account, abi: userAccountAbi, functionName: "freeBalance", args: [wnt] });
      console.log(`free     ${formatEther(free)} ETH (the rest is locked by open orders)`);
    }
  },

  async fund([amount]) {
    const hash = await c.walletClient.sendTransaction({ to: await accountAddress(), value: parseEther(amount ?? "0") });
    await wait("fund", hash);
  },

  async order(argv) {
    const { values } = parseArgs({
      args: argv,
      options: {
        kind: { type: "string", default: "limit" },
        side: { type: "string", default: "long" },
        size: { type: "string" },
        trigger: { type: "string" },
        slippage: { type: "string", default: "100" },
        fallback: { type: "string", default: "800" },
        collateral: { type: "string", default: "0" },
        fee: { type: "string", default: "0.001" },
      },
    });
    const kind = { limit: OrderKind.LimitIncrease, stop: OrderKind.StopLoss, tp: OrderKind.TakeProfit }[values.kind!];
    if (kind === undefined) throw new Error("--kind must be limit, stop or tp");
    if (!values.size || !values.trigger) throw new Error("--size (USD) and --trigger (USD) are required");

    const fhe = await cofhe(c);
    console.log("encrypting side, size, trigger and slippage locally…");
    const [isLong, size, trigger, slippage, proof] = await fhe
      .encryptInputs([
        Encryptable.bool(values.side === "long"),
        Encryptable.uint64(toSizeUsd6(Number(values.size))),
        Encryptable.uint64(toPrice8(Number(values.trigger))),
        Encryptable.uint32(BigInt(values.slippage!)),
      ])
      .setConsumingContract(deployment.adapter)
      .execute();

    const hash = await c.walletClient.writeContract({
      ...adapter,
      functionName: "submitOrder",
      args: [
        {
          market,
          kind,
          collateralToken: wnt,
          collateral: kind === OrderKind.LimitIncrease ? parseEther(values.collateral!) : 0n,
          executionFee: parseEther(values.fee!),
          fallbackSlippageBps: Number(values.fallback),
          isLong,
          sizeUsd6: size,
          triggerPrice8: trigger,
          slippageBps: slippage,
          inputProof: proof,
        },
      ],
    });
    await wait("submitOrder", hash);
    const count = await c.publicClient.readContract({ ...adapter, functionName: "orderCount" });
    console.log(`order id ${count} (only side/size/trigger/slippage ciphertext is on-chain)`);
  },

  async status([id]) {
    const orderId = orderIdArg(id);
    const o = await c.publicClient.readContract({ ...adapter, functionName: "orderOf", args: [orderId] });
    const check = await c.publicClient.readContract({ ...adapter, functionName: "checkOf", args: [orderId] });
    const fill = await c.publicClient.readContract({ ...adapter, functionName: "fillOf", args: [orderId] });
    console.log(`status   ${Status[o.status]}  kind ${Object.keys(OrderKind)[o.kind]}  account ${o.account}`);
    if (check.lastCheckAt) console.log(`checked  at ${new Date(Number(check.lastCheckAt) * 1000).toISOString()}, price $${fromPrice8(check.checkPrice8)}`);
    if (fill.gmxKey !== pad("0x0", { size: 32 })) {
      const [outcome] = await c.publicClient.readContract({ address: o.account, abi: userAccountAbi, functionName: "outcomeOf", args: [orderId] });
      console.log(`fired    size $${Number(fill.sizeDeltaUsd / 10n ** 24n) / 1e6}, ${fill.isLong ? "long" : "short"}, GMX ${GmxOutcome[outcome]}${fill.rearmed ? " (re-armed)" : ""}`);
    }
  },

  async cancel([id]) {
    await wait("cancelOrder", await c.walletClient.writeContract({ ...adapter, functionName: "cancelOrder", args: [orderIdArg(id)] }));
  },

  async withdraw([amount]) {
    const hash = await c.walletClient.writeContract({
      address: await accountAddress(),
      abi: userAccountAbi,
      functionName: "withdraw",
      args: [wnt, parseEther(amount ?? "0"), c.account.address],
    });
    await wait("withdraw", hash);
  },
};

const [command, ...rest] = process.argv.slice(2);
const run = commands[command ?? ""];
if (!run) {
  console.log(`commands: ${Object.keys(commands).join(", ")}`);
  process.exit(1);
}
await run(rest);
