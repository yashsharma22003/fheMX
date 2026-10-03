'use client'

import { useEffect, useState } from 'react'
import { formatUnits, parseEther } from 'viem'
import { useAccount, useWriteContract } from 'wagmi'
import { sealedOrderAdapterAbi } from '@sealed/shared/browser'
import { adapterAddress, CHAIN_ID, tokenByAddress, txUrl } from '@/lib/config'
import { useCofhe } from '@/lib/cofhe'
import { humanError } from '@/lib/errors'
import { ago, fromPrice8, fromUsd30, short, time, token as fmtToken, usd } from '@/lib/format'
import { useAdapterParams, useBlockTimes, type AdapterLog, type OrderView } from '@/lib/hooks'
import { useSettings } from '@/lib/settings'
import { useTx } from '@/lib/tx'
import { KIND_LABEL, LockMark, StatusPill, TRAILING_STOP } from './ui'

interface Unlocked {
  isLong: boolean
  size: number
  trigger: number
  slippage: number
  valid: boolean
}

/** Decrypts the owner's own sealed fields with a self-signed permit. Values stay in memory only. */
function useUnlock() {
  const { client } = useCofhe()
  const [values, setValues] = useState<Record<string, Unlocked>>({})
  const [busy, setBusy] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  async function unlock(o: OrderView) {
    if (!client) return
    setBusy(o.id)
    setError(null)
    try {
      const { FheTypes } = await import('@cofhe/sdk')
      await client.acp.getOrCreateSelfACP()
      const read = (h: string, t: number) => client.decryptForView(h, t as never).withACP().execute()
      const [isLong, size, trigger, slippage, valid] = await Promise.all([
        read(o.handles.isLong, FheTypes.Bool),
        read(o.handles.size, FheTypes.Uint64),
        read(o.handles.trigger, FheTypes.Uint64),
        read(o.handles.slippage, FheTypes.Uint32),
        read(o.handles.valid, FheTypes.Bool),
      ])
      setValues((v) => ({
        ...v,
        [o.id]: {
          isLong: Boolean(isLong),
          size: Number(size as bigint) / 1e6,
          // A trailing stop's trigger is its trail in basis points; shown as a percent.
          trigger: Number(trigger as bigint) / (o.kind === TRAILING_STOP ? 100 : 1e8),
          slippage: Number(slippage as bigint) / 100,
          valid: Boolean(valid),
        },
      }))
    } catch (err) {
      setError(humanError(err))
    } finally {
      setBusy(null)
    }
  }
  return { values, unlock, busy, error }
}

export function OrdersView({ orders, loading, refetch, selectedId, onSelect }: { orders: OrderView[]; loading: boolean; refetch: () => void; selectedId?: string; onSelect: (id: string) => void }) {
  const { isConnected } = useAccount()
  const unlock = useUnlock()
  const params = useAdapterParams()
  const selected = orders.find((o) => o.id === selectedId) ?? orders[0]

  if (!isConnected) return <div className="content"><Header /><div className="empty-note"><LockMark /><div><strong>Connect your wallet to see your sealed orders.</strong></div></div></div>
  if (!loading && orders.length === 0) return <div className="content"><Header /><div className="empty-note"><LockMark /><div><strong>No sealed orders yet.</strong><p>Place one from the Trade page. Only its public terms will ever be visible on-chain until it fires.</p></div></div></div>

  return (
    <div className="content">
      <Header onRefresh={refetch} />
      <div className="orders-layout">
        <div className="orders-stack">
          {loading && orders.length === 0 && <div className="muted">Loading orders…</div>}
          {orders.map((o) => {
            const checksLeft = params && params.checkFee > 0n ? Number(o.checkBudget / params.checkFee) : 0
            const open = o.state === 'Sealed' || o.state === 'Watching'
            return (
              <button className={`order-row ${selected?.id === o.id ? 'selected' : ''}`} key={o.id} onClick={() => onSelect(o.id)}>
                <div className="order-title"><StatusPill state={o.state} /><strong>{o.market?.label ?? short(o.marketAddress)}</strong><span>{KIND_LABEL[o.kind]}</span><span className="mono order-num">#{o.num}</span></div>
                <div className="order-data">
                  <div><small>CHECKS</small><b>{o.checks}{open ? ` · ${checksLeft} left` : ''}</b></div>
                  <div><small>LAST CHECK</small><b>{o.lastCheckAt ? `${usd(fromPrice8(o.checkPrice8))} · ${ago(o.lastCheckAt)}` : '—'}</b></div>
                  <div><small>PUBLIC TERMS</small><b>{publicTerms(o)}</b></div>
                </div>
                {open && checksLeft <= 3 && <div className={`budget-warning ${checksLeft === 0 ? 'red' : ''}`}>{checksLeft === 0 ? 'Not being watched: top up the check budget' : `Only ${checksLeft} checks left`}</div>}
              </button>
            )
          })}
        </div>
        {selected && <OrderDetail order={selected} unlock={unlock} refetch={refetch} />}
      </div>
    </div>
  )
}

function Header({ onRefresh }: { onRefresh?: () => void }) {
  return <div className="page-title"><div><span className="eyebrow">Private execution queue</span><h1>Your sealed orders</h1><p>Triggers stay hidden while orders are watched. Each check reveals only “fired” or “not yet”.</p></div>{onRefresh && <button className="outline-button" onClick={onRefresh}>Refresh</button>}</div>
}

function publicTerms(o: OrderView) {
  const t = tokenByAddress(o.collateralToken)
  if (o.kind === 0) return `${fmtToken(o.collateral, t?.decimals ?? 18)} ${t?.symbol ?? ''} locked`
  return `protects ${t?.symbol ?? ''} position`
}

function OrderDetail({ order: o, unlock, refetch }: { order: OrderView; unlock: ReturnType<typeof useUnlock>; refetch: () => void }) {
  const { address } = useAccount()
  const params = useAdapterParams()
  const { settings } = useSettings()
  const { status: cofheStatus } = useCofhe()
  const { writeContractAsync } = useWriteContract()
  const run = useTx()
  const [topUp, setTopUp] = useState('0.001')
  const mine = unlock.values[o.id]
  const open = o.state === 'Sealed' || o.state === 'Watching'
  const closable = open || o.state === 'Rejected' || o.state === 'Re-arming'
  const checksLeft = params && params.checkFee > 0n ? Number(o.checkBudget / params.checkFee) : 0
  const t = tokenByAddress(o.collateralToken)
  useEffect(() => setTopUp(settings.checkBudgetEth), [settings.checkBudgetEth])

  async function cancel() {
    if (settings.confirmCancel && !window.confirm(`Cancel order #${o.num}? This reveals only that an order existed.`)) return
    await run('Cancel order', (fees) => writeContractAsync({ ...fees, address: adapterAddress, abi: sealedOrderAdapterAbi, functionName: 'cancelOrder', args: [o.id], chainId: CHAIN_ID }), refetch)
  }
  async function top() {
    let amount: bigint
    try { amount = parseEther(topUp) } catch { return }
    await run('Top up check budget', (fees) => writeContractAsync({ ...fees, address: adapterAddress, abi: sealedOrderAdapterAbi, functionName: 'topUpCheckBudget', args: [o.id, amount], chainId: CHAIN_ID }), refetch)
  }

  return (
    <aside className="panel order-detail">
      <div className="panel-head"><div><span className="eyebrow">Order #{o.num} · {KIND_LABEL[o.kind]}</span><h2>{o.market?.label}</h2></div><StatusPill state={o.state} /></div>

      <div className="view-grid">
        <div className="view-card yours">
          <div className="view-head"><span><LockMark /> Your view</span>{!mine && <button onClick={() => unlock.unlock(o)} disabled={cofheStatus !== 'ready' || unlock.busy === o.id}>{unlock.busy === o.id ? 'Unlocking…' : 'Unlock'}</button>}</div>
          {mine ? (
            <>
              <div className="public-row"><span>Side</span><strong className={mine.isLong ? 'up' : 'down'}>{mine.isLong ? 'Long' : 'Short'}</strong></div>
              <div className="public-row"><span>Size</span><strong>{usd(mine.size)}</strong></div>
              {o.kind === TRAILING_STOP ? (
                <>
                  <div className="public-row"><span>Trail</span><strong>{mine.trigger}%</strong></div>
                  {o.marks && o.marks.high > 0n && <div className="public-row"><span>Stop now</span><strong>{usd(mine.isLong ? fromPrice8(o.marks.high) * (1 - mine.trigger / 100) : fromPrice8(o.marks.low) * (1 + mine.trigger / 100))}</strong></div>}
                </>
              ) : (
                <div className="public-row"><span>Trigger</span><strong>{usd(mine.trigger)}</strong></div>
              )}
              <div className="public-row"><span>Slippage</span><strong>{mine.slippage}%</strong></div>
              {!mine.valid && <p className="warn-text">This order breaks a limit (size, slippage or trigger) and can never fire. Cancel it to free your funds.</p>}
              <p>Decrypted with your signed permit. Nobody else can do this.</p>
            </>
          ) : (
            <><div className="view-value">Locked</div><div className="blur-lines"><span /><span /><span /></div><p>{unlock.error ?? 'Only your wallet can decrypt these values.'}</p></>
          )}
        </div>
        <div className="view-card public">
          <div className="view-head"><span>◌ Public view</span><span className="visible-label">visible on-chain</span></div>
          <div className="public-row"><span>Market</span><strong>{o.market?.label}</strong></div>
          <div className="public-row"><span>Type</span><strong>{KIND_LABEL[o.kind]}</strong></div>
          <div className="public-row"><span>Collateral</span><strong>{o.kind === 0 ? `${fmtToken(o.collateral, t?.decimals ?? 18)} ${t?.symbol}` : 'none (reduces a position)'}</strong></div>
          <div className="public-row"><span>Fallback slippage</span><strong>{o.fallbackSlippageBps / 100}%</strong></div>
          {o.kind === TRAILING_STOP && <div className="public-row"><span>High · low mark</span><strong>{o.marks && o.marks.high > 0n ? `${usd(fromPrice8(o.marks.high))} · ${usd(fromPrice8(o.marks.low))}` : 'set at first check'}</strong></div>}
          <div className="public-row handles"><span>Ciphertext handles (side · size · trigger · slippage)</span><strong>{[o.handles.isLong, o.handles.size, o.handles.trigger, o.handles.slippage].map((h) => short(h, 6, 0)).join(' · ')}</strong></div>
          {o.submitTx && <a className="text-link" href={txUrl(o.submitTx)} target="_blank" rel="noreferrer">See it on Arbiscan ↗</a>}
        </div>
      </div>

      {open && (
        <div className="budget-box">
          <div className="need-row"><span>Check budget</span><strong>{formatUnits(o.checkBudget, 18)} ETH · {checksLeft} checks left</strong></div>
          <div className="meter"><span style={{ width: `${Math.min(100, (checksLeft / Math.max(1, checksLeft + o.checks)) * 100)}%` }} /></div>
          <div className="topup-row"><div className="input-box"><input value={topUp} onChange={(e) => setTopUp(e.target.value)} aria-label="Top up amount" /><span>ETH</span></div><button className="outline-button" onClick={top}>Top up</button></div>
        </div>
      )}

      <Timeline order={o} />

      {closable && o.account && address && <button className="outline-button danger" onClick={cancel}>{open ? 'Cancel order' : 'Close order and free funds'}</button>}
    </aside>
  )
}

function Timeline({ order: o }: { order: OrderView }) {
  const times = useBlockTimes(o.events.map((e) => e.blockNumber!))
  const [showChecks, setShowChecks] = useState(false)
  const checks = o.events.filter((e) => e.eventName === 'OrderChecked')
  const at = (e: AdapterLog) => (times.data?.[String(e.blockNumber)] ? time(times.data[String(e.blockNumber)]) : '')

  const rows = o.events.filter((e) => e.eventName !== 'OrderChecked' || showChecks)
  return (
    <div className="timeline">
      <div className="timeline-head"><span className="eyebrow">Lifecycle</span>{checks.length > 0 && <button className="text-link" onClick={() => setShowChecks(!showChecks)}>{showChecks ? 'Hide' : 'Show'} {checks.length} checks</button>}</div>
      {rows.map((e, i) => (
        <div className={`tl-row ${e.eventName}`} key={`${e.transactionHash}-${e.logIndex}-${i}`}>
          <span className="tl-dot" />
          <div>
            <strong>{describe(e, o).title}</strong>
            <p>{describe(e, o).detail}</p>
            <a className="mono" href={txUrl(e.transactionHash!)} target="_blank" rel="noreferrer">{at(e) || short(e.transactionHash!)} ↗</a>
          </div>
        </div>
      ))}
      {!showChecks && checks.length > 0 && (o.state === 'Watching') && <div className="tl-row"><span className="tl-dot live" /><div><strong>Watching</strong><p>{checks.length} checks · last at {usd(fromPrice8(o.checkPrice8))} · {ago(o.lastCheckAt)}</p></div></div>}
      {o.state === 'Sealed' && <div className="tl-row"><span className="tl-dot live" /><div><strong>Waiting for the first check</strong><p>The checker evaluates it on the next Chainlink update.</p></div></div>}
    </div>
  )
}

function describe(e: AdapterLog, o: OrderView): { title: string; detail: string } {
  const a = e.args
  switch (e.eventName) {
    case 'OrderSealed':
      return { title: 'Sealed', detail: 'Encrypted in your browser and submitted' }
    case 'OrderChecked':
      return { title: 'Checked', detail: `at ${usd(fromPrice8(a.price8 as bigint))}` }
    case 'OrderFired':
      return { title: 'Fired · sent to GMX', detail: `revealed: ${a.isLong ? 'long' : 'short'} ${usd(fromUsd30(a.sizeDeltaUsd as bigint))}, ${o.fill.slippage / 100}% slippage` }
    case 'OrderRearmed':
      return { title: 'Re-armed', detail: `GMX rejected the first attempt; re-sent with ${o.fallbackSlippageBps / 100}% fallback slippage` }
    case 'OrderFilled': {
      const t = tokenByAddress(o.collateralToken)
      const fee = a.protocolFee as bigint
      return { title: 'Filled', detail: fee > 0n ? `protocol fee ${fmtToken(fee, o.kind === 0 ? t?.decimals ?? 18 : 18, 6)} ${o.kind === 0 ? t?.symbol : 'ETH'}` : 'no protocol fee' }
    }
    case 'OrderCancelled':
      return { title: 'Cancelled', detail: 'Funds released to your free balance' }
    case 'OrderVoided':
      return { title: 'Voided', detail: 'The position was already closed; nothing was sent to GMX' }
    case 'CheckBudgetToppedUp':
      return { title: 'Budget topped up', detail: `+${formatUnits(a.amount as bigint, 18)} ETH` }
    default:
      return { title: e.eventName, detail: '' }
  }
}
