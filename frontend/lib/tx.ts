'use client'

import { toast } from 'sonner'
import type { Hex } from 'viem'
import { usePublicClient } from 'wagmi'
import { CHAIN_ID, txUrl } from './config'
import { humanError } from './errors'

/** Wraps a wallet call: pending toast, wait for confirmation, success / error toast with an explorer link. */
export function useTx() {
  const client = usePublicClient({ chainId: CHAIN_ID })
  return async function run(label: string, send: () => Promise<Hex>, onDone?: () => void): Promise<boolean> {
    const id = toast.loading(`${label}: confirm in your wallet`)
    try {
      const hash = await send()
      toast.loading(`${label}: waiting for confirmation`, { id, action: { label: 'View', onClick: () => window.open(txUrl(hash), '_blank') } })
      const receipt = await client!.waitForTransactionReceipt({ hash })
      if (receipt.status !== 'success') throw new Error('Transaction reverted')
      toast.success(`${label}: done`, { id, action: { label: 'View', onClick: () => window.open(txUrl(hash), '_blank') } })
      onDone?.()
      return true
    } catch (err) {
      toast.error(`${label} failed`, { id, description: humanError(err) })
      return false
    }
  }
}
