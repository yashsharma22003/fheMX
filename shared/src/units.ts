// Fixed-point formats used by SealedOrderAdapter (see its NatSpec).

/** USD amount -> size with 6 decimals (euint64). */
export const toSizeUsd6 = (usd: number): bigint => BigInt(Math.round(usd * 1e6));

/** USD price -> price with 8 decimals (euint64); matches Chainlink ETH/USD feed decimals. */
export const toPrice8 = (usd: number): bigint => BigInt(Math.round(usd * 1e8));

export const fromPrice8 = (price8: bigint): number => Number(price8) / 1e8;

export const OrderKind = { LimitIncrease: 0, StopLoss: 1, TakeProfit: 2 } as const;
export const Status = ["None", "Open", "Cancelled", "Fired", "Filled"] as const;
export const GmxOutcome = ["None", "Pending", "Executed", "Cancelled", "Frozen"] as const;
