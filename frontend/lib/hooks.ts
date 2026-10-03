'use client'

import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { useRef } from 'react'
import { erc20Abi, parseAbi, zeroAddress, type Address, type Hex, type Log, type PublicClient } from 'viem'
import { useAccount, usePublicClient, useReadContract, useReadContracts } from 'wagmi'
import { aggregatorV3Abi, deploymentBlock, sealedOrderAdapterAbi, userAccountAbi } from '@sealed/shared/browser'
import { adapterAddress, CHAIN_ID, markets, tokens, type MarketInfo, type TokenInfo } from './config'

const adapter = { address: adapterAddress, abi: sealedOrderAdapterAbi, chainId: CHAIN_ID } as const
const getRoundDataAbi = parseAbi([
  'function getRoundData(uint80 roundId) view returns (uint80, int256, uint256, uint256, uint80)',
])

// ─── adapter parameters ─────────────────────────────────────────────────────

const PARAMS = [
  'minSizeUsd6',
  'maxSizeUsd6',
  'maxSlippageBps',
  'maxFallbackSlippageBps',
  'maxLeverage',
  'increaseFeeBps',
  'decreaseFeeFlat',
  'minExecutionFee',
  'checkFee',
  'checkFeeSpread',
  'minCheckInterval',
] as const

export type AdapterParams = Record<(typeof PARAMS)[number], bigint>

export function useAdapterParams(): AdapterParams | undefined {
  const { data } = useReadContracts({
    contracts: PARAMS.map((functionName) => ({ ...adapter, functionName })),
    query: { staleTime: Infinity },
  })
  if (!data || data.some((d) => d.status !== 'success')) return undefined
  return Object.fromEntries(PARAMS.map((k, i) => [k, BigInt(data[i].result as bigint | number)])) as AdapterParams
}

// ─── prices ─────────────────────────────────────────────────────────────────

export function usePrice(feed: Address) {
  const { data } = useReadContract({
    address: feed,
    abi: aggregatorV3Abi,
    functionName: 'latestRoundData',
    chainId: CHAIN_ID,
    query: { refetchInterval: 10_000 },
  })
  if (!data) return undefined
  return { price: Number(data[1]) / 1e8, updatedAt: Number(data[3]), roundId: data[0] }
}

/** The last `rounds` Chainlink answers, oldest first, for the chart. */
export function usePriceHistory(feed: Address, rounds = 60) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  return useQuery({
    queryKey: ['priceHistory', feed, rounds],
    enabled: !!client,
    refetchInterval: 60_000,
    queryFn: async () => {
      const latest = await client!.readContract({ address: feed, abi: aggregatorV3Abi, functionName: 'latestRoundData' })
      const ids = Array.from({ length: rounds }, (_, i) => latest[0] - BigInt(i)).filter((id) => id > 0n)
      const results = await client!.multicall({
        contracts: ids.map((id) => ({ address: feed, abi: getRoundDataAbi, functionName: 'getRoundData' as const, args: [id] as const })),
        allowFailure: true,
      })
      return results
        .filter((r) => r.status === 'success' && r.result[3] > 0n)
        .map((r) => {
          const round = r.result as readonly [bigint, bigint, bigint, bigint, bigint]
          return { t: Number(round[3]), price: Number(round[1]) / 1e8 }
        })
        .reverse()
    },
  })
}

// ─── the user's account ─────────────────────────────────────────────────────

export interface TokenBalance {
  token: TokenInfo
  free: bigint
  locked: bigint
  wallet: bigint
}

export function useUserAccount() {
  const { address: owner } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const { data: account } = useReadContract({ ...adapter, functionName: 'accountOf', args: [owner ?? zeroAddress], query: { enabled: !!owner } })

  const balances = useQuery({
    queryKey: ['balances', owner, account],
    enabled: !!owner && !!account && !!client,
    refetchInterval: 10_000,
    queryFn: async () => {
      const c = client!
      const deployed = !!(await c.getCode({ address: account! }))
      const list = Object.values(tokens)
      const out: TokenBalance[] = []
      for (const t of list) {
        const held = t.native
          ? await c.getBalance({ address: account! })
          : await c.readContract({ address: t.address, abi: erc20Abi, functionName: 'balanceOf', args: [account!] })
        const wallet = t.native
          ? await c.getBalance({ address: owner! })
          : await c.readContract({ address: t.address, abi: erc20Abi, functionName: 'balanceOf', args: [owner!] })
        let free = held
        let locked = 0n
        if (deployed) {
          ;[free, locked] = await Promise.all([
            c.readContract({ address: account!, abi: userAccountAbi, functionName: 'freeBalance', args: [t.address] }),
            c.readContract({ address: account!, abi: userAccountAbi, functionName: 'lockedBalance', args: [t.address] }),
          ])
        }
        out.push({ token: t, free, locked, wallet })
      }
      return { deployed, balances: out }
    },
  })

  return { owner, account, deployed: balances.data?.deployed ?? false, balances: balances.data?.balances, refetch: balances.refetch }
}

// ─── positions ──────────────────────────────────────────────────────────────

export interface Position {
  market: MarketInfo
  collateral: TokenInfo
  isLong: boolean
  sizeUsd: number
  /** exact GMX size, 30 decimals */
  sizeRaw: bigint
}

export function usePositions(account?: Address, deployed?: boolean) {
  const combos = markets.flatMap((market) =>
    market.collateral.flatMap((collateral) => [true, false].map((isLong) => ({ market, collateral, isLong }))),
  )
  const { data, refetch } = useReadContracts({
    contracts: combos.map((c) => ({
      address: account ?? zeroAddress,
      abi: userAccountAbi,
      functionName: 'positionSizeUsd' as const,
      args: [c.market.address, c.collateral.address, c.isLong] as const,
      chainId: CHAIN_ID,
    })),
    query: { enabled: !!account && !!deployed, refetchInterval: 15_000 },
  })
  const positions: Position[] = []
  data?.forEach((r, i) => {
    if (r.status === 'success' && (r.result as bigint) > 0n) {
      const raw = r.result as bigint
      positions.push({ ...combos[i], sizeRaw: raw, sizeUsd: Number(raw / 10n ** 24n) / 1e6 })
    }
  })
  return { positions, refetch }
}

// ─── adapter event log (scanned once, then incrementally) ───────────────────

const EVENTS = sealedOrderAdapterAbi.filter((x) => x.type === 'event')
const CHUNK = 9_000n

export type AdapterLog = Log<bigint, number, false> & { eventName: string; args: Record<string, unknown> }

async function scanLogs(client: PublicClient, from: bigint, to: bigint): Promise<AdapterLog[]> {
  const ranges: [bigint, bigint][] = []
  for (let a = from; a <= to; a += CHUNK) ranges.push([a, a + CHUNK - 1n > to ? to : a + CHUNK - 1n])
  const out: AdapterLog[] = []
  for (let i = 0; i < ranges.length; i += 5) {
    const batch = await Promise.all(
      ranges.slice(i, i + 5).map(([fromBlock, toBlock]) =>
        client.getLogs({ address: adapterAddress, events: EVENTS, fromBlock, toBlock }),
      ),
    )
    for (const logs of batch) out.push(...(logs as unknown as AdapterLog[]))
  }
  return out
}

/** All adapter events since deployment, kept across polls; only new blocks are fetched each time. */
export function useAdapterLogs() {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const cache = useRef<{ to: bigint; logs: AdapterLog[] }>({ to: deploymentBlock - 1n, logs: [] })
  return useQuery({
    queryKey: ['adapterLogs'],
    enabled: !!client,
    refetchInterval: 8_000,
    queryFn: async () => {
      const head = await client!.getBlockNumber()
      if (head > cache.current.to) {
        const fresh = await scanLogs(client!, cache.current.to + 1n, head)
        cache.current = { to: head, logs: [...cache.current.logs, ...fresh] }
      }
      return cache.current.logs
    },
  })
}

// ─── orders ─────────────────────────────────────────────────────────────────

export type OrderState =
  | 'Sealed'
  | 'Watching'
  | 'At GMX'
  | 'Filled, settling'
  | 'Re-arming'
  | 'Rejected'
  | 'Filled'
  | 'Cancelled'
  | 'Voided'

export interface OrderView {
  id: Hex
  num: number
  market: MarketInfo | undefined
  marketAddress: Address
  kind: number
  account: Address
  collateralToken: Address
  collateral: bigint
  fallbackSlippageBps: number
  handles: { isLong: Hex; size: Hex; trigger: Hex; slippage: Hex; valid: Hex }
  state: OrderState
  lastCheckAt: number
  checkPrice8: bigint
  /** Trailing stop only: highest and lowest checked price (8 decimals); zero before the first check */
  marks?: { high: bigint; low: bigint }
  checks: number
  checkBudget: bigint
  fill: { sizeDeltaUsd: bigint; isLong: boolean; slippage: number; acceptablePrice: bigint; protocolFee: bigint; gmxKey: Hex; rearmed: boolean }
  events: AdapterLog[]
  submitTx?: Hex
}

function deriveState(status: number, outcome: number, lastCheckAt: bigint, rearmed: boolean, voided: boolean): OrderState {
  if (status === 1) return lastCheckAt === 0n ? 'Sealed' : 'Watching'
  if (status === 3) {
    if (outcome === 1) return 'At GMX'
    if (outcome === 2) return 'Filled, settling'
    if (outcome === 3 || outcome === 4) return rearmed ? 'Rejected' : 'Re-arming'
    return 'At GMX'
  }
  if (status === 4) return 'Filled'
  return voided ? 'Voided' : 'Cancelled'
}

export function useOrders() {
  const { address: owner } = useAccount()
  const client = usePublicClient({ chainId: CHAIN_ID })
  const logs = useAdapterLogs()

  const sealed = (logs.data ?? []).filter(
    (l) => l.eventName === 'OrderSealed' && (l.args.owner as string)?.toLowerCase() === owner?.toLowerCase(),
  )
  const ids = sealed.map((l) => l.args.orderId as Hex)

  const orders = useQuery({
    // Keyed on the event count, not the poll time: a new key per poll left the list empty until it reloaded.
    queryKey: ['orders', owner, ids.join(','), logs.data?.length ?? 0],
    enabled: !!client && !!owner && ids.length > 0,
    placeholderData: keepPreviousData,
    queryFn: async (): Promise<OrderView[]> => {
      const c = client!
      const base = await c.multicall({
        contracts: ids.flatMap((id) => [
          { ...adapter, functionName: 'orderOf' as const, args: [id] as const },
          { ...adapter, functionName: 'checkOf' as const, args: [id] as const },
          { ...adapter, functionName: 'fillOf' as const, args: [id] as const },
        ]),
        allowFailure: false,
      })
      const views: OrderView[] = []
      for (let i = 0; i < ids.length; i++) {
        const id = ids[i]
        const o = base[i * 3] as any
        const ch = base[i * 3 + 1] as any
        const f = base[i * 3 + 2] as any
        const [lock, outcome, marks] = await Promise.all([
          c.readContract({ address: o.account, abi: userAccountAbi, functionName: 'lockOf', args: [id] }),
          c.readContract({ address: o.account, abi: userAccountAbi, functionName: 'outcomeOf', args: [id] }),
          Number(o.kind) === 3 ? c.readContract({ ...adapter, functionName: 'marksOf', args: [id] }) : undefined,
        ])
        const events = (logs.data ?? []).filter((l) => (l.args.orderId as string | undefined) === id)
        const voided = events.some((e) => e.eventName === 'OrderVoided')
        views.push({
          id,
          num: Number(BigInt(id)),
          market: markets.find((m) => m.address.toLowerCase() === (o.market as string).toLowerCase()),
          marketAddress: o.market,
          kind: Number(o.kind),
          account: o.account,
          collateralToken: o.collateralToken,
          collateral: o.collateral,
          fallbackSlippageBps: Number(o.fallbackSlippageBps),
          handles: { isLong: o.isLong, size: o.sizeUsd6, trigger: o.triggerPrice8, slippage: o.slippageBps, valid: o.intakeValid },
          state: deriveState(Number(o.status), Number(outcome[0]), ch.lastCheckAt, f.rearmed, voided),
          lastCheckAt: Number(ch.lastCheckAt),
          checkPrice8: ch.checkPrice8,
          marks,
          checks: events.filter((e) => e.eventName === 'OrderChecked').length,
          checkBudget: lock.checkBudget,
          fill: {
            sizeDeltaUsd: f.sizeDeltaUsd,
            isLong: f.isLong,
            slippage: Number(f.slippage),
            acceptablePrice: f.acceptablePrice,
            protocolFee: f.protocolFee,
            gmxKey: f.gmxKey,
            rearmed: f.rearmed,
          },
          events,
          submitTx: sealed.find((s) => s.args.orderId === id)?.transactionHash ?? undefined,
        })
      }
      return views.sort((a, b) => b.num - a.num)
    },
  })

  return { orders: orders.data ?? [], loading: logs.isLoading || orders.isLoading, refetch: () => logs.refetch() }
}

/** Block timestamps for a set of block numbers (for timelines). */
export function useBlockTimes(blocks: bigint[]) {
  const client = usePublicClient({ chainId: CHAIN_ID })
  const key = [...new Set(blocks.map(String))].sort()
  return useQuery({
    queryKey: ['blockTimes', key.join(',')],
    enabled: !!client && key.length > 0,
    staleTime: Infinity,
    placeholderData: keepPreviousData,
    queryFn: async () => {
      const entries = await Promise.all(
        key.map(async (b) => [b, Number((await client!.getBlock({ blockNumber: BigInt(b) })).timestamp)] as const),
      )
      return Object.fromEntries(entries) as Record<string, number>
    },
  })
}
