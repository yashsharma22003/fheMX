'use client'

import { useCallback, useEffect, useState } from 'react'

export interface Settings {
  slippagePct: string
  fallbackPct: string
  executionFeeEth: string
  checkBudgetEth: string
  confirmCancel: boolean
}

export const DEFAULT_SETTINGS: Settings = {
  slippagePct: '1',
  fallbackPct: '8',
  executionFeeEth: '0.001',
  checkBudgetEth: '0.001',
  confirmCancel: true,
}

const KEY = 'fhemx.settings.v1'

/** Per-browser order defaults. Storage can be unavailable (private mode); defaults are used then. */
export function useSettings() {
  const [settings, setSettings] = useState<Settings>(DEFAULT_SETTINGS)
  useEffect(() => {
    try {
      const raw = window.localStorage.getItem(KEY)
      if (raw) setSettings({ ...DEFAULT_SETTINGS, ...JSON.parse(raw) })
    } catch {}
  }, [])
  const save = useCallback((next: Settings) => {
    setSettings(next)
    try {
      window.localStorage.setItem(KEY, JSON.stringify(next))
    } catch {}
  }, [])
  return { settings, save }
}
