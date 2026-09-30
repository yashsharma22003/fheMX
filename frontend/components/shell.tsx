'use client'

import { ConnectButton } from '@rainbow-me/rainbowkit'
import type { ReactNode } from 'react'
import { LockMark } from './ui'

export type Tab = 'Trade' | 'Orders' | 'Account' | 'Settings'
const NAV: { id: Tab; icon: string }[] = [
  { id: 'Trade', icon: '＋' },
  { id: 'Orders', icon: '▤' },
  { id: 'Account', icon: '◉' },
  { id: 'Settings', icon: '≡' },
]

export function Shell({ active, onNavigate, openOrders, children }: { active: Tab; onNavigate: (t: Tab) => void; openOrders: number; children: ReactNode }) {
  return (
    <main className="app-shell">
      <aside className="sidebar">
        <div className="brand"><span className="brand-mark"><LockMark /></span><span>fhe<span className="brand-dot">MX</span></span></div>
        <div className="network"><span className="live-dot" /> Arbitrum Sepolia</div>
        <nav>
          {NAV.map((item) => (
            <button key={item.id} className={active === item.id ? 'nav-active' : ''} onClick={() => onNavigate(item.id)}>
              <span className="nav-icon">{item.icon}</span>{item.id}
              {item.id === 'Orders' && openOrders > 0 && <span className="nav-count">{openOrders}</span>}
            </button>
          ))}
        </nav>
        <div className="sidebar-bottom">
          <div className="privacy-note"><LockMark /><div><strong>Privacy is the feature.</strong><span>Encrypted before broadcast.</span></div></div>
        </div>
      </aside>
      <section className="main">
        <header className="topbar">
          <div className="breadcrumb"><span>Terminal</span><span>/</span><strong>{active}</strong></div>
          <div className="top-actions">
            <span className="feed-status"><span className="live-dot" /> Chainlink feeds · GMX V2 · testnet</span>
            <ConnectButton showBalance={false} chainStatus="icon" accountStatus="address" />
          </div>
        </header>
        {children}
      </section>
    </main>
  )
}
