'use client'

import { useEffect, useState } from 'react'
import { useSettings, DEFAULT_SETTINGS, type Settings } from '@/lib/settings'
import { LockMark } from './ui'

export function SettingsView() {
  const { settings, save } = useSettings()
  const [draft, setDraft] = useState<Settings>(settings)
  const [saved, setSaved] = useState(false)
  useEffect(() => setDraft(settings), [settings])
  const set = (k: keyof Settings) => (e: React.ChangeEvent<HTMLInputElement>) => {
    setSaved(false)
    setDraft({ ...draft, [k]: e.target.type === 'checkbox' ? e.target.checked : e.target.value })
  }
  const field = (k: keyof Settings, label: string, unit: string) => (
    <label className="settings-field"><span>{label}</span><div className="settings-input"><input value={String(draft[k])} onChange={set(k)} aria-label={label} /><b>{unit}</b></div></label>
  )
  return (
    <div className="content">
      <div className="page-title"><div><span className="eyebrow">Terminal preferences</span><h1>Settings</h1><p>Defaults for new order tickets. Stored only in this browser.</p></div></div>
      <div className="settings-grid">
        <section className="settings-card">
          <div className="settings-card-head"><div><span className="eyebrow">Order defaults</span><h2>Execution preferences</h2></div><span className="settings-icon">⌘</span></div>
          {field('slippagePct', 'Slippage', '%')}
          {field('fallbackPct', 'Fallback slippage (re-arm)', '%')}
          {field('executionFeeEth', 'Execution fee per GMX attempt', 'ETH')}
          {field('checkBudgetEth', 'Check budget per order', 'ETH')}
          <button className="primary-action settings-save" onClick={() => { save(draft); setSaved(true) }}>{saved ? 'Saved' : 'Save preferences'} <span>→</span></button>
          <button className="text-link reset" onClick={() => { save(DEFAULT_SETTINGS); setSaved(true) }}>Reset to defaults</button>
        </section>
        <section className="settings-card">
          <div className="settings-card-head"><div><span className="eyebrow">Interface</span><h2>Safety</h2></div><span className="settings-icon">◈</span></div>
          <label className="toggle-row"><span><strong>Confirm before cancelling</strong><small>Ask before an order is cancelled</small></span><input type="checkbox" checked={draft.confirmCancel} onChange={set('confirmCancel')} /></label>
        </section>
      </div>
      <div className="settings-note"><LockMark /><div><strong>Privacy defaults stay local.</strong><p>fheMX sends no order values or preferences to any server. Order fields are encrypted in your browser before you sign.</p></div></div>
    </div>
  )
}
