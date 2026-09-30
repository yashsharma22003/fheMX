import { formatUnits } from 'viem'

export const usd = (n: number, digits = 2) =>
  `$${n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits })}`

export const fromPrice8 = (p: bigint) => Number(p) / 1e8

/** GMX 30-decimal USD amount -> number */
export const fromUsd30 = (v: bigint) => Number(v / 10n ** 24n) / 1e6

export const token = (amount: bigint, decimals: number, digits = 4) =>
  Number(formatUnits(amount, decimals)).toLocaleString('en-US', { maximumFractionDigits: digits })

export const short = (hex: string, lead = 6, tail = 4) => (hex.length > lead + tail + 2 ? `${hex.slice(0, lead)}…${hex.slice(-tail)}` : hex)

export function ago(unixSeconds: number | bigint, now = Date.now() / 1000) {
  const s = Math.max(0, Math.round(now - Number(unixSeconds)))
  if (s < 60) return `${s}s ago`
  if (s < 3600) return `${Math.floor(s / 60)}m ago`
  if (s < 86400) return `${Math.floor(s / 3600)}h ago`
  return `${Math.floor(s / 86400)}d ago`
}

export const time = (unixSeconds: number | bigint) =>
  new Date(Number(unixSeconds) * 1000).toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', second: '2-digit' })

/** Parse a user-typed number ("2,400.50") safely; NaN if invalid. */
export const parseNum = (s: string) => {
  const n = Number(s.replace(/,/g, '').trim())
  return s.trim() === '' ? NaN : n
}
