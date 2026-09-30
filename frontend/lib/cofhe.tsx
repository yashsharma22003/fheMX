'use client'

import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { usePublicClient, useWalletClient } from 'wagmi'
import type { CofheClient } from '@cofhe/sdk'
import { CHAIN_ID } from './config'

type Status = 'idle' | 'connecting' | 'ready' | 'error'

interface CofheState {
  client: CofheClient | null
  status: Status
  error: string | null
}

const CofheContext = createContext<CofheState>({ client: null, status: 'idle', error: null })

/**
 * Connects a CoFHE client to the user's wallet. The SDK's browser build (TFHE WebAssembly and a proving
 * Web Worker) is loaded lazily, only in the browser, so it never runs during server rendering.
 */
export function CofheProvider({ children }: { children: ReactNode }) {
  const publicClient = usePublicClient({ chainId: CHAIN_ID })
  const { data: walletClient } = useWalletClient({ chainId: CHAIN_ID })
  const [state, setState] = useState<CofheState>({ client: null, status: 'idle', error: null })
  const clientRef = useRef<CofheClient | null>(null)
  const account = walletClient?.account?.address

  useEffect(() => {
    if (!publicClient || !walletClient || !account) {
      setState((s) => ({ ...s, status: 'idle' }))
      return
    }
    let cancelled = false
    setState((s) => ({ ...s, status: 'connecting', error: null }))
    ;(async () => {
      try {
        if (!clientRef.current) {
          const [{ createCofheClient, createCofheConfig }, { arbSepolia }] = await Promise.all([
            import('@cofhe/sdk/web'),
            import('@cofhe/sdk/chains'),
          ])
          clientRef.current = createCofheClient(createCofheConfig({ supportedChains: [arbSepolia] }))
        }
        // The SDK types its own viem instance; wagmi's clients are the same viem version at runtime.
        await clientRef.current.connect(publicClient as never, walletClient as never)
        if (!cancelled) setState({ client: clientRef.current, status: 'ready', error: null })
      } catch (err) {
        if (!cancelled) setState({ client: null, status: 'error', error: err instanceof Error ? err.message : String(err) })
      }
    })()
    return () => {
      cancelled = true
    }
  }, [publicClient, walletClient, account])

  return <CofheContext.Provider value={state}>{children}</CofheContext.Provider>
}

export const useCofhe = () => useContext(CofheContext)
