'use client'

import { useEffect, useMemo, useState } from 'react'
import { erc20Abi, formatUnits, parseEther, parseUnits, type Hex } from 'viem'
import { useAccount, useSendTransaction, useWriteContract } from 'wagmi'
import { sealedOrderAdapterAbi } from '@sealed/shared/browser'
import { adapterAddress, CHAIN_ID, type MarketInfo, type TokenInfo } from '@/lib/config'
import { useCofhe } from '@/lib/cofhe'
import { humanError } from '@/lib/errors'
import { parseNum, token as fmtToken, usd } from '@/lib/format'
import { useAdapterParams, usePrice, useUserAccount, type Position } from '@/lib/hooks'
import { useSettings } from '@/lib/settings'
import { useTx } from '@/lib/tx'
import { firesBelow, KIND_LABEL, LockMark } from './ui'

export interface TicketPrefill {
  kind: 1 | 2
  position: Position
  nonce: number
}

type Phase = 'idle' | 'encrypting' | 'signing' | 'confirming' | 'done'

const STEP_LABEL: Record<string, string> = {
  initTfhe: 'Loading FHE engine',
  fetchKeys: 'Fetching encryption keys',
  pack: 'Encrypting fields',
  prove: 'Generating zero-knowledge proof',
  verify: 'Verifying with Fhenix',
}

export function Ticket({
  market,
  positions,
  prefill,
  onTriggerChange,
  onSealed,
}: {
  market: MarketInfo
  positions: Position[]
  prefill?: TicketPrefill
  onTriggerChange: (trigger: number) => void
  onSealed: () => void
}) {
  const { address, isConnected, chainId } = useAccount()
  const params = useAdapterParams()
  const { settings } = useSettings()
  const { client: cofhe, status: cofheStatus, error: cofheError } = useCofhe()
  const acct = useUserAccount()
  const indexPrice = usePrice(market.index.feed)
  const { writeContractAsync } = useWriteContract()
  const { sendTransactionAsync } = useSendTransaction()
  const run = useTx()

  const [kind, setKind] = useState(0)
  const [side, setSide] = useState<'long' | 'short'>('long')
  const [size, setSize] = useState('20')
  const [trigger, setTrigger] = useState('')
  const [slippage, setSlippage] = useState(settings.slippagePct)
  const [collateralKey, setCollateralKey] = useState(market.collateral[0].key)
  const [collateral, setCollateral] = useState('0.005')
  const [fallback, setFallback] = useState(settings.fallbackPct)
  const [execFee, setExecFee] = useState(settings.executionFeeEth)
  const [budget, setBudget] = useState(settings.checkBudgetEth)
  const [positionIdx, setPositionIdx] = useState(0)
  const [phase, setPhase] = useState<Phase>('idle')
  const [step, setStep] = useState<string>('')
  const [showAdvanced, setShowAdvanced] = useState(false)

  // Settings load asynchronously from storage.
  useEffect(() => {
    setSlippage(settings.slippagePct)
    setFallback(settings.fallbackPct)
    setExecFee(settings.executionFeeEth)
    setBudget(settings.checkBudgetEth)
  }, [settings])

  // Market change resets the collateral choice.
  useEffect(() => setCollateralKey(market.collateral[0].key), [market])

  const marketPositions = positions.filter((p) => p.market.key === market.key)
  const isEntry = kind === 0
  const position = !isEntry ? marketPositions[positionIdx] : undefined

  // Coming from a position's "Stop-loss" / "Take-profit" button.
  useEffect(() => {
    if (!prefill) return
    setKind(prefill.kind)
    const idx = marketPositions.findIndex(
      (p) => p.collateral.key === prefill.position.collateral.key && p.isLong === prefill.position.isLong,
    )
    setPositionIdx(Math.max(0, idx))
    setSize(prefill.position.sizeUsd.toFixed(2))
    setTrigger('')
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [prefill?.nonce])

  useEffect(() => {
    if (position) setSize(position.sizeUsd.toFixed(2))
  }, [position?.market.key, position?.collateral.key, position?.isLong])

  const collateralToken: TokenInfo = isEntry
    ? market.collateral.find((t) => t.key === collateralKey) ?? market.collateral[0]
    : position?.collateral ?? market.collateral[0]
  const collateralPrice = usePrice(collateralToken.feed)
  const isLong = isEntry ? side === 'long' : position?.isLong ?? true

  useEffect(() => onTriggerChange(parseNum(trigger) || 0), [trigger, onTriggerChange])

  // ─── validation (hidden caps first: a sealed order that breaks them is accepted but can never fire) ───
  const v = useMemo(() => {
    const errs: string[] = []
    const sizeN = parseNum(size)
    const trigN = parseNum(trigger)
    const slipN = parseNum(slippage)
    const collN = parseNum(collateral)
    const fbN = parseNum(fallback)
    let execWei = 0n
    let budgetWei = 0n
    let collWei = 0n
    try { execWei = parseEther(execFee || '0') } catch { errs.push('Execution fee is not a number.') }
    try { budgetWei = parseEther(budget || '0') } catch { errs.push('Check budget is not a number.') }
    try { collWei = isEntry ? parseUnits(collateral || '0', collateralToken.decimals) : 0n } catch { errs.push('Collateral is not a number.') }
    if (!params) return { errs: ['Loading limits…'], sizeN, trigN, slipN, collN, execWei, budgetWei, collWei, leverage: 0 }
    const minSize = Number(params.minSizeUsd6) / 1e6
    const maxSize = Number(params.maxSizeUsd6) / 1e6
    if (!(sizeN >= minSize && sizeN <= maxSize)) errs.push(`Size must be between ${usd(minSize, 0)} and ${usd(maxSize, 0)}.`)
    if (!(trigN > 0)) errs.push('Enter a trigger price.')
    if (!(slipN >= 0 && slipN * 100 <= Number(params.maxSlippageBps))) errs.push(`Slippage can be at most ${Number(params.maxSlippageBps) / 100}%.`)
    if (!(fbN >= 0 && fbN * 100 <= Number(params.maxFallbackSlippageBps))) errs.push(`Fallback slippage can be at most ${Number(params.maxFallbackSlippageBps) / 100}%.`)
    if (execWei < params.minExecutionFee) errs.push(`Execution fee must be at least ${formatUnits(params.minExecutionFee, 18)} ETH.`)
    if (budgetWei < params.checkFee) errs.push(`Check budget must cover at least one check (${formatUnits(params.checkFee, 18)} ETH).`)
    let leverage = 0
    if (isEntry) {
      if (!(collN > 0)) errs.push('Enter collateral.')
      else if (collateralPrice) {
        leverage = sizeN / (collN * collateralPrice.price)
        if (leverage > Number(params.maxLeverage)) errs.push(`Leverage ${leverage.toFixed(2)}× is above the ${Number(params.maxLeverage)}× maximum.`)
      }
    } else if (!position) errs.push('Open a position on this market first: stop-loss and take-profit protect an existing position.')
    return { errs, sizeN, trigN, slipN, collN, execWei, budgetWei, collWei, leverage }
  }, [size, trigger, slippage, collateral, fallback, execFee, budget, params, isEntry, collateralToken, collateralPrice, position])

  // ─── what the account must hold ───
  const need = useMemo(() => {
    if (!params) return undefined
    const reserve = isEntry ? (v.collWei * params.maxLeverage * params.increaseFeeBps) / 10_000n : 0n
    const ethForOrder = 2n * v.execWei + v.budgetWei + (isEntry ? 0n : params.decreaseFeeFlat)
    const tokenForOrder = isEntry ? v.collWei + reserve : 0n
    const ethNeed = ethForOrder + (collateralToken.native ? tokenForOrder : 0n)
    const tokNeed = collateralToken.native ? 0n : tokenForOrder
    const eth = acct.balances?.find((b) => b.token.native)
    const tok = acct.balances?.find((b) => b.token.key === collateralToken.key)
    const ethShort = eth ? (ethNeed > eth.free ? ethNeed - eth.free : 0n) : ethNeed
    const tokShort = tok && !collateralToken.native ? (tokNeed > tok.free ? tokNeed - tok.free : 0n) : 0n
    return { reserve, ethNeed, tokNeed, ethShort, tokShort, ethFree: eth?.free ?? 0n, tokFree: tok?.free ?? 0n }
  }, [params, isEntry, v, collateralToken, acct.balances])

  const wrongChain = isConnected && chainId !== CHAIN_ID
  const busy = phase !== 'idle' && phase !== 'done'
  const canSubmit = isConnected && !wrongChain && cofheStatus === 'ready' && v.errs.length === 0 && need && need.ethShort === 0n && need.tokShort === 0n && !busy

  async function depositShortfall() {
    if (!need || !acct.account) return
    if (need.ethShort > 0n) {
      await run('Deposit ETH', () => sendTransactionAsync({ to: acct.account!, value: need.ethShort, chainId: CHAIN_ID }), acct.refetch)
    }
    if (need.tokShort > 0n) {
      await run(`Deposit ${collateralToken.symbol}`, () =>
        writeContractAsync({ address: collateralToken.address, abi: erc20Abi, functionName: 'transfer', args: [acct.account!, need.tokShort], chainId: CHAIN_ID }), acct.refetch)
    }
  }

  async function seal() {
    if (!cofhe || !address) return
    try {
      setPhase('encrypting')
      setStep('initTfhe')
      const { Encryptable } = await import('@cofhe/sdk')
      const [hIsLong, hSize, hTrigger, hSlippage, proof] = await cofhe
        .encryptInputs([
          Encryptable.bool(isLong),
          Encryptable.uint64(BigInt(Math.round(v.sizeN * 1e6))),
          Encryptable.uint64(BigInt(Math.round(v.trigN * 1e8))),
          Encryptable.uint32(BigInt(Math.round(v.slipN * 100))),
        ])
        .setConsumingContract(adapterAddress)
        .onStep((s) => setStep(s))
        .execute()
      setPhase('signing')
      const ok = await run('Submit sealed order', async () => {
        const hash = await writeContractAsync({
          address: adapterAddress,
          abi: sealedOrderAdapterAbi,
          functionName: 'submitOrder',
          chainId: CHAIN_ID,
          args: [{
            market: market.address,
            kind,
            collateralToken: collateralToken.address,
            collateral: isEntry ? v.collWei : 0n,
            executionFee: v.execWei,
            fallbackSlippageBps: Math.round(parseNum(fallback) * 100),
            checkBudget: v.budgetWei,
            isLong: hIsLong as Hex,
            sizeUsd6: hSize as Hex,
            triggerPrice8: hTrigger as Hex,
            slippageBps: hSlippage as Hex,
            inputProof: proof as Hex,
          }],
        })
        setPhase('confirming')
        return hash
      })
      if (ok) {
        setPhase('done')
        acct.refetch()
        onSealed()
      } else setPhase('idle')
    } catch (err) {
      setPhase('idle')
      const { toast } = await import('sonner')
      toast.error('Encryption failed', { description: humanError(err) })
    }
  }

  const below = firesBelow(kind, isLong)
  const asset = market.asset
  const verb = isEntry ? (isLong ? 'Buys' : 'Sells') : kind === 1 ? 'Stops out' : 'Takes profit'
  const checksPaid = params && params.checkFee > 0n ? v.budgetWei / params.checkFee : 0n

  return (
    <section className="panel ticket-panel">
      <div className="panel-head"><div><span className="eyebrow">Create sealed order</span><h2>Order ticket</h2></div><span className="testnet-pill">TESTNET</span></div>

      <div className="field"><label>Type</label><div className="segmented">{KIND_LABEL.map((item, i) => (
        <button key={item} className={kind === i ? 'active' : ''} onClick={() => setKind(i)} disabled={busy}>{item}</button>
      ))}</div></div>

      {isEntry ? (
        <div className="field"><label>Side</label><div className="segmented">
          <button className={side === 'long' ? 'active long' : ''} onClick={() => setSide('long')} disabled={busy}>Long</button>
          <button className={side === 'short' ? 'active short' : ''} onClick={() => setSide('short')} disabled={busy}>Short</button>
        </div></div>
      ) : (
        <div className="field"><label>Position to protect</label>
          {marketPositions.length === 0 ? <div className="input-box muted-box">No open position on {market.label}</div> : (
            <select className="select-box" value={positionIdx} onChange={(e) => setPositionIdx(Number(e.target.value))} disabled={busy}>
              {marketPositions.map((p, i) => <option key={i} value={i}>{p.isLong ? 'Long' : 'Short'} {usd(p.sizeUsd)} · {p.collateral.symbol} collateral</option>)}
            </select>
          )}
        </div>
      )}

      <div className="form-grid">
        <div className="field"><label>Size <span>USD</span></label><div className="input-box"><span>$</span><input value={size} onChange={(e) => setSize(e.target.value)} disabled={busy} aria-label="Size USD" /></div>
          <small>{params ? `min ${usd(Number(params.minSizeUsd6) / 1e6, 0)} · max ${usd(Number(params.maxSizeUsd6) / 1e6, 0)}${isEntry ? ` · max ${params.maxLeverage}×` : ' · trimmed to your position'}` : '…'}</small></div>
        <div className="field"><label>Trigger price <span>USD</span></label><div className="input-box"><span>$</span><input value={trigger} onChange={(e) => setTrigger(e.target.value)} placeholder={indexPrice ? indexPrice.price.toFixed(2) : ''} disabled={busy} aria-label="Trigger price" /></div>
          <small>{verb} when {asset} {below ? '≤' : '≥'} trigger{indexPrice && v.trigN > 0 ? ` · now ${usd(indexPrice.price)} (${(((v.trigN - indexPrice.price) / indexPrice.price) * 100).toFixed(2)}%)` : ''}</small></div>
        <div className="field"><label>Slippage <span>%</span></label><div className="input-box"><input value={slippage} onChange={(e) => setSlippage(e.target.value)} disabled={busy} aria-label="Slippage" /><span>%</span></div><small>encrypted · around GMX&apos;s expected fill</small></div>
        {isEntry && collateralPrice && v.collN > 0 && <div className="field"><label>Effective leverage</label><div className="input-box">{v.leverage.toFixed(2)}×</div><small>{usd(v.collN * collateralPrice.price)} of collateral</small></div>}
      </div>

      {isEntry && (
        <div className="field"><label>Collateral</label><div className="collateral-row">
          <select className="select-box" value={collateralKey} onChange={(e) => setCollateralKey(e.target.value as typeof collateralKey)} disabled={busy}>
            {market.collateral.map((t) => <option key={t.key} value={t.key}>{t.symbol}</option>)}
          </select>
          <div className="input-box"><input value={collateral} onChange={(e) => setCollateral(e.target.value)} disabled={busy} aria-label="Collateral amount" /><span>{collateralToken.symbol}</span></div>
        </div><small>Any token in the {market.label} pool</small></div>
      )}

      <details className="advanced" open={showAdvanced} onToggle={(e) => setShowAdvanced((e.target as HTMLDetailsElement).open)}>
        <summary>Advanced parameters <span>⌄</span></summary>
        <div className="advanced-grid">
          <label>Fallback slippage %<input value={fallback} onChange={(e) => setFallback(e.target.value)} disabled={busy} /></label>
          <label>Execution fee ETH<input value={execFee} onChange={(e) => setExecFee(e.target.value)} disabled={busy} /></label>
          <label>Check budget ETH<input value={budget} onChange={(e) => setBudget(e.target.value)} disabled={busy} /></label>
        </div>
        <small className="advanced-note">Fallback slippage is public and used only if GMX rejects the first attempt. Two execution fees are locked (first try and one re-arm); unused fees and budget come back.</small>
      </details>

      <div className="sealed-checklist"><span className="eyebrow">Stays sealed</span>
        <div className="check-items"><span><b>{isEntry ? '✓' : '~'}</b> Side</span><span><b>{isEntry ? '✓' : '~'}</b> Size</span><span><b>✓</b> Trigger</span><span><b>✓</b> Slippage</span></div>
        <div className="public-items"><span>Public: market</span><span>type</span><span>collateral</span><span>budget</span></div>
        {!isEntry && <small className="advanced-note">For a stop-loss or take-profit, side and size can be inferred from your public position. The trigger stays hidden.</small>}
      </div>

      {need && isConnected && (
        <div className="need-box">
          <div className="need-row"><span>This order locks</span><strong>{fmtToken(need.ethNeed, 18, 6)} ETH{need.tokNeed > 0n ? ` + ${fmtToken(need.tokNeed, collateralToken.decimals)} ${collateralToken.symbol}` : ''}</strong></div>
          <div className="need-row muted"><span>Free in your account</span><span>{fmtToken(need.ethFree, 18, 6)} ETH{!collateralToken.native ? ` · ${fmtToken(need.tokFree, collateralToken.decimals)} ${collateralToken.symbol}` : ''}</span></div>
          {params && <div className="need-row muted"><span>Check budget</span><span>≈ {checksPaid.toString()} checks at {formatUnits(params.checkFee, 18)} ETH each (roughly 1–2 per minute on testnet)</span></div>}
          {(need.ethShort > 0n || need.tokShort > 0n) && <button className="outline-button need-deposit" onClick={depositShortfall} disabled={busy}>Deposit the difference: {need.ethShort > 0n ? `${fmtToken(need.ethShort, 18, 6)} ETH` : ''}{need.ethShort > 0n && need.tokShort > 0n ? ' + ' : ''}{need.tokShort > 0n ? `${fmtToken(need.tokShort, collateralToken.decimals)} ${collateralToken.symbol}` : ''}</button>}
        </div>
      )}

      {v.errs.length > 0 && isConnected && <ul className="form-errors">{v.errs.map((e) => <li key={e}>{e}</li>)}</ul>}

      {busy && (
        <div className="stepper">
          {(['initTfhe', 'fetchKeys', 'pack', 'prove', 'verify'] as const).map((s) => {
            const order = ['initTfhe', 'fetchKeys', 'pack', 'prove', 'verify']
            const cur = phase === 'encrypting' ? order.indexOf(step) : 5
            const i = order.indexOf(s)
            return <div key={s} className={i < cur ? 'done' : i === cur ? 'current' : ''}><span>{i < cur ? '✓' : i === cur ? '◌' : '·'}</span>{STEP_LABEL[s]}</div>
          })}
          <div className={phase === 'signing' ? 'current' : phase === 'confirming' ? 'done' : ''}><span>{phase === 'confirming' ? '✓' : phase === 'signing' ? '◌' : '·'}</span>Sign in your wallet</div>
          <div className={phase === 'confirming' ? 'current' : ''}><span>{phase === 'confirming' ? '◌' : '·'}</span>Confirming on Arbitrum Sepolia</div>
        </div>
      )}

      {!isConnected ? <div className="primary-action as-note">Connect a wallet to place sealed orders</div>
        : wrongChain ? <div className="primary-action as-note">Switch your wallet to Arbitrum Sepolia</div>
        : cofheStatus === 'error' ? <div className="form-errors">Couldn&apos;t start encryption: {cofheError}</div>
        : <button className="primary-action" onClick={seal} disabled={!canSubmit}><LockMark /> {cofheStatus !== 'ready' ? 'Preparing encryption…' : busy ? 'Sealing…' : 'Encrypt & seal order'} <span>→</span></button>}
      <p className="microcopy">Encryption happens in your browser. No plaintext order fields leave this device.</p>
    </section>
  )
}
