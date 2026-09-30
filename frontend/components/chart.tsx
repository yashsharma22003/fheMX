'use client'

import { usePriceHistory } from '@/lib/hooks'
import { ago, usd } from '@/lib/format'
import type { MarketInfo } from '@/lib/config'

/** Line chart of the market's last Chainlink rounds; optionally draws the user's draft trigger (local only). */
export function PriceChart({ market, trigger }: { market: MarketInfo; trigger?: number }) {
  const { data } = usePriceHistory(market.index.feed)
  const W = 760
  const H = 230
  if (!data || data.length < 2) {
    return <div className="chart-wrap"><div className="chart-meta"><span><span className="live-dot" /> Chainlink {market.label}</span><span>loading…</span></div><div className="chart-empty">Loading price history…</div></div>
  }
  const prices = data.map((d) => d.price)
  const lo = Math.min(...prices, trigger && trigger > 0 ? trigger : Infinity)
  const hi = Math.max(...prices, trigger && trigger > 0 ? trigger : -Infinity)
  const pad = (hi - lo) * 0.12 || hi * 0.001
  const min = lo - pad
  const max = hi + pad
  const x = (i: number) => (i / (data.length - 1)) * W
  const y = (p: number) => H - ((p - min) / (max - min)) * H
  const line = data.map((d, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)} ${y(d.price).toFixed(1)}`).join(' ')
  const last = data[data.length - 1]
  const first = data[0]
  const change = ((last.price - first.price) / first.price) * 100
  const ty = trigger && trigger > 0 ? y(trigger) : undefined
  const fmtTime = (t: number) => new Date(t * 1000).toLocaleTimeString('en-US', { hour: '2-digit', minute: '2-digit' })
  return (
    <div className="chart-wrap">
      <div className="chart-meta"><span><span className="live-dot" /> Chainlink {market.label} · last {data.length} updates</span><span>updated {ago(last.t)}</span></div>
      <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label={`${market.label} price chart`}>
        <defs><linearGradient id="chartFill" x1="0" x2="0" y1="0" y2="1"><stop offset="0" stopColor="#8b5cf6" stopOpacity=".25" /><stop offset="1" stopColor="#8b5cf6" stopOpacity="0" /></linearGradient></defs>
        <g className="grid"><path d="M0 46H760M0 92H760M0 138H760M0 184H760" /></g>
        <path className="area" d={`${line} L${W} ${H} L0 ${H}Z`} />
        <path className="line" d={line} />
        {ty !== undefined && <><line className="trigger-line" x1="0" x2={W} y1={ty} y2={ty} /><text x="14" y={ty - 6} className="trigger-label">your sealed trigger · only on your screen</text></>}
      </svg>
      <div className="chart-axis"><span>{fmtTime(first.t)}</span><span className={change >= 0 ? 'up' : 'down'}>{change >= 0 ? '+' : ''}{change.toFixed(2)}% over window</span><span>{fmtTime(last.t)}</span><strong>{usd(last.price)}</strong></div>
    </div>
  )
}
