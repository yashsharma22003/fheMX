'use client'

import { toast } from 'sonner'
import type { Hex } from 'viem'
import { usePublicClient } from 'wagmi'
import { CHAIN_ID, txUrl } from './config'
import { humanError } from './errors'

/** Explicit EIP-1559 fees for a wallet call. */
export type Fees = { maxFeePerGas: bigint; maxPriorityFeePerGas: bigint }

/** Wraps a wallet call: pending toast, wait for confirmation, success / error toast with an explorer link.
 *  `send` receives fees to spread into the call: wallets otherwise price at the current base fee, which
 *  Arbitrum's moving base fee often overtakes before inclusion. Arbitrum charges only the base fee, so the
 *  2x headroom costs nothing extra. */
export function useTx() {
  const client = usePublicClient({ chainId: CHAIN_ID })
  return async function run(label: string, send: (fees: Fees) => Promise<Hex>, onDone?: () => void): Promise<boolean> {
    const id = toast.loading(`${label}: confirm in your wallet`)
    try {
      const { baseFeePerGas } = await client!.getBlock()
      const hash = await send({ maxFeePerGas: (baseFeePerGas ?? (await client!.getGasPrice())) * 2n, maxPriorityFeePerGas: 0n })
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
