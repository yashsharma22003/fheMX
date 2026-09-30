import { connectorsForWallets } from '@rainbow-me/rainbowkit'
import { injectedWallet, metaMaskWallet, rabbyWallet, walletConnectWallet } from '@rainbow-me/rainbowkit/wallets'
import { createConfig, http } from 'wagmi'
import { arbitrumSepolia } from 'wagmi/chains'
import { RPC_URL } from './config'

const projectId = process.env.NEXT_PUBLIC_WALLETCONNECT_PROJECT_ID

// Browser-extension wallets work without a WalletConnect project id; mobile wallets need one.
const connectors = connectorsForWallets(
  [
    {
      groupName: 'Wallets',
      wallets: projectId ? [metaMaskWallet, rabbyWallet, injectedWallet, walletConnectWallet] : [injectedWallet],
    },
  ],
  { appName: 'fheMX', projectId: projectId ?? 'fhemx-no-walletconnect' },
)

export const wagmiConfig = createConfig({
  chains: [arbitrumSepolia],
  connectors,
  transports: { [arbitrumSepolia.id]: http(RPC_URL) },
  ssr: true,
})
