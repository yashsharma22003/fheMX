'use client'

import { useCallback, useState } from 'react'
import { maxUint256, parseEther } from 'viem'
import { useWriteContract } from 'wagmi'
import { userAccountAbi } from '@sealed/shared/browser'
import { CHAIN_ID, markets, type MarketInfo } from '@/lib/config'
import { ago, token as fmtToken, usd } from '@/lib/format'
import { usePositions, usePrice, useUserAccount, type Position } from '@/lib/hooks'
import { useSettings } from '@/lib/settings'
import { useTx } from '@/lib/tx'
import { PriceChart } from './chart'
import { Ticket, type TicketPrefill } from './ticket'
import { Metric } from './ui'

export function TradeView({ onSealed }: { onSealed: () => void }) {
  const [market, setMarket] = useState<MarketInfo>(markets[0])
  const [trigger, setTrigger] = useState(0)
  const [prefill, setPrefill] = useState<TicketPrefill>()
  const price = usePrice(market.index.feed)
  const acct = useUserAccount()
  const { positions, refetch: refetchPositions } = usePositions(acct.account, acct.deployed)
  const { settings } = useSettings()
  const { writeContractAsync } = useWriteContract()
  const run = useTx()
  const onTrigger = useCallback((t: number) => setTrigger(t), [])
  const freeEth = acct.balances?.find((b) => b.token.native)?.free

  function protect(p: Position, kind: 1 | 2) {
    setMarket(p.market)
    setPrefill({ kind, position: p, nonce: Date.now() })
  }

  async function close(p: Position) {
    if (!acct.account) return
    await run('Close position', () => writeContractAsync({
      address: acct.account!,
      abi: userAccountAbi,
      functionName: 'closePosition',
      chainId: CHAIN_ID,
      args: [{
        market: p.market.address,
        collateralToken: p.collateral.address,
        isLong: p.isLong,
        sizeDeltaUsd: p.sizeRaw,
        collateralDeltaAmount: 0n,
        acceptablePrice: p.isLong ? 0n : maxUint256, // market close at any price
        executionFee: parseEther(settings.executionFeeEth),
        callbackGasLimit: 500_000n,
      }],
    }), () => { refetchPositions(); acct.refetch() })
  }

  return (
    <div className="content">
      <div className="page-title">
        <div><span className="eyebrow">Verifiable and keyless privacy for your GMX orders.</span><h1>Trade without a tell.</h1><p>Encrypted order fields. Public execution. The chain never sees your strategy.</p></div>
        <div className="market-tabs">{markets.map((m) => <button key={m.key} className={m.key === market.key ? 'active' : ''} onClick={() => setMarket(m)}><small>MARKET</small><strong>{m.label}</strong></button>)}</div>
      </div>

      <div className="metrics">
        <Metric label={market.label} value={price ? usd(price.price) : '…'} detail={price ? `Chainlink · updated ${ago(price.updatedAt)}` : 'Chainlink feed'} />
        <Metric label="Open positions" value={String(positions.length)} detail={acct.deployed ? 'held by your account contract' : 'none yet'} />
        <Metric label="Your account" value={acct.owner ? (freeEth !== undefined ? `${fmtToken(freeEth, 18, 5)} ETH` : '…') : 'Not connected'} detail={acct.owner ? 'free to use for orders' : 'Connect to view balances'} />
      </div>

      <div className="trade-grid">
        <div>
          <PriceChart market={market} trigger={trigger} />
          <section className="panel positions-panel">
            <div className="panel-head"><div><span className="eyebrow">Your GMX positions</span><h2>{positions.length ? 'Protect with sealed exits' : 'No open positions'}</h2></div></div>
            {positions.length === 0 ? <p className="muted">Filled limit entries appear here. Add a sealed stop-loss or take-profit to any of them.</p> : (
              <div className="positions-list">
                {positions.map((p) => (
                  <div className="position-row" key={`${p.market.key}-${p.collateral.key}-${p.isLong}`}>
                    <div><strong className={p.isLong ? 'up' : 'down'}>{p.isLong ? 'Long' : 'Short'}</strong> {p.market.label}<span className="muted"> · {usd(p.sizeUsd)} · {p.collateral.symbol} collateral</span></div>
                    <div className="position-actions">
                      <button className="outline-button" onClick={() => protect(p, 1)}>Sealed stop-loss</button>
                      <button className="outline-button" onClick={() => protect(p, 2)}>Take-profit</button>
                      <button className="text-button" onClick={() => close(p)}>Close</button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </section>
        </div>
        <Ticket market={market} positions={positions} prefill={prefill} onTriggerChange={onTrigger} onSealed={onSealed} />
      </div>
    </div>
  )
}
