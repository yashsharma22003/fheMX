import type { Address } from 'viem'
import network from '../../config/networks/arbitrum-sepolia.json'
import deployment from '../../deployments/arbitrum-sepolia.json'

export const CHAIN_ID = 421614
export const EXPLORER = 'https://sepolia.arbiscan.io'
export const RPC_URL = process.env.NEXT_PUBLIC_RPC_URL || 'https://sepolia-rollup.arbitrum.io/rpc'

export const adapterAddress = deployment.adapter as Address
export const verifierAddress = deployment.priceVerifier as Address
export const factoryAddress = deployment.factory as Address

export type TokenKey = 'WETH' | 'BTC' | 'USDC_SG'

export interface TokenInfo {
  key: TokenKey
  symbol: string
  address: Address
  decimals: number
  /** WETH is held by the user's account as native ETH */
  native: boolean
  feed: Address
}

const feeds = network.chainlinkFeeds as Record<string, string>

export const tokens: Record<TokenKey, TokenInfo> = {
  WETH: { key: 'WETH', symbol: 'ETH', address: network.tokens.WETH.address as Address, decimals: 18, native: true, feed: feeds.ETH_USD as Address },
  BTC: { key: 'BTC', symbol: 'BTC', address: network.tokens.BTC.address as Address, decimals: 8, native: false, feed: feeds.BTC_USD as Address },
  USDC_SG: { key: 'USDC_SG', symbol: 'USDC', address: network.tokens.USDC_SG.address as Address, decimals: 6, native: false, feed: feeds.USDC_USD as Address },
}

export function tokenByAddress(address: string): TokenInfo | undefined {
  return Object.values(tokens).find((t) => t.address.toLowerCase() === address.toLowerCase())
}

export type MarketKey = 'ETH_USD' | 'BTC_USD'

export interface MarketInfo {
  key: MarketKey
  label: string
  asset: string
  address: Address
  index: TokenInfo
  /** tokens accepted as collateral: the market's pool tokens */
  collateral: TokenInfo[]
}

const m = network.markets as Record<string, { marketToken: string }>

export const markets: MarketInfo[] = [
  { key: 'ETH_USD', label: 'ETH / USD', asset: 'ETH', address: m.ETH_USD.marketToken as Address, index: tokens.WETH, collateral: [tokens.WETH, tokens.USDC_SG] },
  { key: 'BTC_USD', label: 'BTC / USD', asset: 'BTC', address: m.BTC_USD.marketToken as Address, index: tokens.BTC, collateral: [tokens.BTC, tokens.USDC_SG] },
]

export function marketByAddress(address: string): MarketInfo | undefined {
  return markets.find((x) => x.address.toLowerCase() === address.toLowerCase())
}

export const txUrl = (hash: string) => `${EXPLORER}/tx/${hash}`
export const addressUrl = (address: string) => `${EXPLORER}/address/${address}`

export const FAUCETS = [
  { label: 'Chainlink faucet', url: 'https://faucets.chain.link/arbitrum-sepolia' },
  { label: 'Alchemy faucet', url: 'https://www.alchemy.com/faucets/arbitrum-sepolia' },
  { label: 'Arbitrum bridge', url: 'https://bridge.arbitrum.io' },
]
