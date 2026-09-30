import type { Metadata, Viewport } from 'next'
import './globals.css'
import { Providers } from './providers'

export const metadata: Metadata = {
  title: 'fheMX · Private GMX orders',
  description: 'Verifiable and keyless privacy for your GMX orders on Arbitrum Sepolia.',
  icons: { icon: { url: '/icon.svg', type: 'image/svg+xml' } },
}

export const viewport: Viewport = { colorScheme: 'dark', themeColor: '#08090c' }

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return (
    <html lang="en">
      <body className="antialiased">
        <Providers>{children}</Providers>
      </body>
    </html>
  )
}
