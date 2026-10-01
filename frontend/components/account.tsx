'use client'

import { useState } from 'react'
import { erc20Abi, parseUnits } from 'viem'
import { useSendTransaction, useWriteContract } from 'wagmi'
import { userAccountAbi } from '@sealed/shared/browser'
import { addressUrl, CHAIN_ID, FAUCETS, tokens, type TokenKey } from '@/lib/config'
import { token as fmtToken } from '@/lib/format'
import { useUserAccount } from '@/lib/hooks'
import { useTx } from '@/lib/tx'
import { LockMark } from './ui'

export function AccountView() {
  const { owner, account, deployed, balances, refetch } = useUserAccount()
  const { sendTransactionAsync } = useSendTransaction()
  const { writeContractAsync } = useWriteContract()
  const run = useTx()
  const [depKey, setDepKey] = useState<TokenKey>('WETH')
  const [depAmount, setDepAmount] = useState('0.02')
  const [wdKey, setWdKey] = useState<TokenKey>('WETH')
  const [wdAmount, setWdAmount] = useState('')

  if (!owner) return <div className="content"><Title /><div className="empty-note"><LockMark /><div><strong>Connect your wallet to see your account.</strong></div></div></div>

  const walletEth = balances?.find((b) => b.token.native)?.wallet ?? 0n
  const dep = tokens[depKey]
  const wd = tokens[wdKey]
  const wdFree = balances?.find((b) => b.token.key === wdKey)?.free ?? 0n

  async function deposit() {
    let amount: bigint
    try { amount = parseUnits(depAmount, dep.decimals) } catch { return }
    if (dep.native) await run('Deposit ETH', (fees) => sendTransactionAsync({ ...fees, to: account!, value: amount, chainId: CHAIN_ID }), refetch)
    else await run(`Deposit ${dep.symbol}`, (fees) => writeContractAsync({ ...fees, address: dep.address, abi: erc20Abi, functionName: 'transfer', args: [account!, amount], chainId: CHAIN_ID }), refetch)
  }
  async function withdraw() {
    let amount: bigint
    try { amount = parseUnits(wdAmount, wd.decimals) } catch { return }
    await run(`Withdraw ${wd.symbol}`, (fees) => writeContractAsync({ ...fees, address: account!, abi: userAccountAbi, functionName: 'withdraw', args: [wd.address, amount, owner!], chainId: CHAIN_ID }), refetch)
  }

  return (
    <div className="content">
      <Title />
      <div className="account-address">
        <span className="eyebrow">{deployed ? 'Your account contract' : 'Predicted account address'}</span>
        <strong>{account}</strong>
        <span className="muted">{deployed ? 'Only you can withdraw from it.' : 'Created automatically on your first sealed order. You can fund it now.'} <a className="text-link" href={addressUrl(account!)} target="_blank" rel="noreferrer">Arbiscan ↗</a></span>
      </div>

      <div className="balance-grid">
        {(balances ?? []).map((b) => (
          <div className="balance-card" key={b.token.key}>
            <span className="eyebrow">{b.token.symbol}{b.token.native ? ' (native)' : ''}</span>
            <strong>{fmtToken(b.free, b.token.decimals, 6)}</strong>
            <span>free · {fmtToken(b.locked, b.token.decimals, 6)} locked by open orders</span>
            <span className="muted">wallet: {fmtToken(b.wallet, b.token.decimals, 6)}</span>
          </div>
        ))}
      </div>

      <div className="funds-grid">
        <section className="panel">
          <div className="panel-head"><div><span className="eyebrow">Deposit</span><h2>Fund your account</h2></div></div>
          <div className="collateral-row">
            <select className="select-box" value={depKey} onChange={(e) => setDepKey(e.target.value as TokenKey)}>{Object.values(tokens).map((t) => <option key={t.key} value={t.key}>{t.symbol}</option>)}</select>
            <div className="input-box"><input value={depAmount} onChange={(e) => setDepAmount(e.target.value)} aria-label="Deposit amount" /><span>{dep.symbol}</span></div>
          </div>
          <button className="primary-action" onClick={deposit}>Deposit <span>→</span></button>
          <p className="microcopy">{dep.native ? 'A plain ETH transfer to your account contract.' : `A ${dep.symbol} transfer from your wallet to your account contract.`}</p>
        </section>
        <section className="panel">
          <div className="panel-head"><div><span className="eyebrow">Withdraw</span><h2>Free balance only</h2></div></div>
          <div className="collateral-row">
            <select className="select-box" value={wdKey} onChange={(e) => setWdKey(e.target.value as TokenKey)}>{Object.values(tokens).map((t) => <option key={t.key} value={t.key}>{t.symbol}</option>)}</select>
            <div className="input-box"><input value={wdAmount} onChange={(e) => setWdAmount(e.target.value)} placeholder="0.0" aria-label="Withdraw amount" /><button className="max-btn" onClick={() => setWdAmount(fmtToken(wdFree, wd.decimals, wd.decimals).replace(/,/g, ''))}>max</button></div>
          </div>
          <button className="primary-action secondary" onClick={withdraw} disabled={!deployed}>Withdraw to wallet <span>→</span></button>
          <p className="microcopy">Locked funds become free when an order fills or is cancelled.</p>
        </section>
      </div>

      {walletEth === 0n && (
        <div className="info-banner"><LockMark /><div><strong>Your wallet has no Arbitrum Sepolia ETH.</strong><p>{FAUCETS.map((f, i) => <span key={f.url}>{i ? ' · ' : ''}<a className="text-link" href={f.url} target="_blank" rel="noreferrer">{f.label} ↗</a></span>)}</p></div></div>
      )}
      <div className="info-banner"><LockMark /><div><strong>Funds live in your account contract.</strong><p>The adapter can only move them into your own GMX orders; it can&apos;t withdraw. Your GMX positions are held by this account too.</p></div></div>
    </div>
  )
}

function Title() {
  return <div className="page-title"><div><span className="eyebrow">Your smart contract wallet</span><h1>Account</h1><p>One account per wallet. It holds your collateral and is the GMX account for your positions.</p></div></div>
}
