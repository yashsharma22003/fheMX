import type { ReactNode } from 'react'
import type { OrderState } from '@/lib/hooks'

export function LockMark() {
  return <span className="lock-mark" aria-hidden="true">⌑</span>
}

const TONE: Record<OrderState, string> = {
  Sealed: 'violet',
  Watching: 'violet',
  'At GMX': 'amber',
  'Filled, settling': 'green',
  'Re-arming': 'amber',
  Rejected: 'red',
  Filled: 'green',
  Cancelled: 'grey',
  Voided: 'grey',
}

export function StatusPill({ state }: { state: OrderState }) {
  return <span className={`status-pill ${TONE[state]}`}><span className="status-dot" />{state}</span>
}

export function Metric({ label, value, detail }: { label: string; value: ReactNode; detail: ReactNode }) {
  return <div className="metric"><span className="eyebrow">{label}</span><strong>{value}</strong><span className="muted">{detail}</span></div>
}

export function Notice({ tone = 'violet', title, children }: { tone?: 'violet' | 'amber' | 'red'; title: string; children?: ReactNode }) {
  return <div className={`notice ${tone}`}><LockMark /><div><strong>{title}</strong>{children && <p>{children}</p>}</div></div>
}

export const KIND_LABEL = ['Limit entry', 'Stop-loss', 'Take-profit', 'Trailing stop'] as const
export const TRAILING_STOP = 3

/** Limit entry, stop-loss and trailing stop fire at or below the trigger for longs; take-profit is the reverse. */
export function firesBelow(kind: number, isLong: boolean) {
  return kind === 2 ? !isLong : isLong
}
