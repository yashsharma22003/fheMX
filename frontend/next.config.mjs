import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))

// wagmi's connectors (pulled in by RainbowKit) import Coinbase's SDK, which references optional x402 payment
// packages that aren't installed. This app never uses that connector, so they resolve to an empty module.
const OPTIONAL_UNUSED = [
  '@x402/core/client',
  '@x402/evm',
  '@x402/evm/exact/client',
  '@x402/evm/upto/client',
  '@x402/svm/exact/client',
  // Optional in WalletConnect's logger and MetaMask's SDK (React Native storage); unused in a browser build.
  'pino-pretty',
  '@react-native-async-storage/async-storage',
]
const EMPTY = './lib/stubs/empty.js'

// Build and dev run on webpack (`--webpack` in package.json): Next 16's default Turbopack stalled indefinitely
// on this dependency graph (wallet connectors + CoFHE's WebAssembly worker) on 2026-09-30.
/** @type {import('next').NextConfig} */
const nextConfig = {
  // The app imports the monorepo's shared package and its network/deployment JSON.
  transpilePackages: ['@sealed/shared'],
  // Keep `next dev` from writing extra docs files into the project.
  agentRules: false,
  turbopack: {
    root: join(here, '..'),
    resolveAlias: Object.fromEntries(OPTIONAL_UNUSED.map((m) => [m, EMPTY])),
  },
  webpack: (config) => {
    // `$` = exact match (a bare key would also capture subpaths like '@x402/evm/exact/client').
    for (const m of OPTIONAL_UNUSED) config.resolve.alias[`${m}$`] = join(here, EMPTY)
    return config
  },
  images: { unoptimized: true },
}

export default nextConfig
