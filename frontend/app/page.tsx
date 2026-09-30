'use client'

import { useState } from 'react'
import { AccountView } from '@/components/account'
import { OrdersView } from '@/components/orders'
import { SettingsView } from '@/components/settings'
import { Shell, type Tab } from '@/components/shell'
import { TradeView } from '@/components/trade'
import { useOrders } from '@/lib/hooks'

export default function Page() {
  const [tab, setTab] = useState<Tab>('Trade')
  const [selected, setSelected] = useState<string>()
  const { orders, loading, refetch } = useOrders()
  const openCount = orders.filter((o) => o.state === 'Sealed' || o.state === 'Watching' || o.state === 'At GMX').length

  return (
    <Shell active={tab} onNavigate={setTab} openOrders={openCount}>
      {tab === 'Trade' && <TradeView onSealed={() => { refetch(); setSelected(undefined); setTab('Orders') }} />}
      {tab === 'Orders' && <OrdersView orders={orders} loading={loading} refetch={refetch} selectedId={selected} onSelect={setSelected} />}
      {tab === 'Account' && <AccountView />}
      {tab === 'Settings' && <SettingsView />}
    </Shell>
  )
}
