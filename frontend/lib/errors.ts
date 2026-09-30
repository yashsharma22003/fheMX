import { BaseError, ContractFunctionRevertedError, UserRejectedRequestError, formatEther } from 'viem'

/** Turn a wallet / contract error into one human sentence. */
export function humanError(err: unknown): string {
  if (err instanceof BaseError) {
    if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
    const revert = err.walk((e) => e instanceof ContractFunctionRevertedError)
    if (revert instanceof ContractFunctionRevertedError && revert.data?.errorName) {
      const a = (revert.data.args ?? []) as readonly unknown[]
      switch (revert.data.errorName) {
        case 'InsufficientFreeBalance':
          return `Your account needs more free balance (needs ${formatEther(a[0] as bigint)}, has ${formatEther(a[1] as bigint)} in the token's units). Deposit first.`
        case 'CheckBudgetTooLow':
          return `Check budget must cover at least one check (${formatEther(a[1] as bigint)} ETH).`
        case 'ExecutionFeeTooLow':
          return `Execution fee must be at least ${formatEther(a[1] as bigint)} ETH.`
        case 'FallbackSlippageTooHigh':
          return 'Fallback slippage can be at most 10%.'
        case 'UnsupportedCollateral':
          return "That token can't be collateral on this market."
        case 'UnsupportedMarket':
          return 'Market not supported.'
        case 'NotOrderOwner':
        case 'OrderNotOpen':
          return "This order can't be changed any more."
        case 'InvalidSigner':
          return 'Encryption proof rejected: re-encrypt from this wallet and try again.'
        case 'AdapterOrdersInFlight':
        case 'ManualCloseInFlight':
          return 'Wait for your pending order to settle first.'
        default:
          return `Transaction reverted: ${revert.data.errorName}.`
      }
    }
    return err.shortMessage || err.message
  }
  return err instanceof Error ? err.message : String(err)
}
