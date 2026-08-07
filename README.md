# TONFAIR Smart Contracts & Emergency Refund

This repository contains the source code for the TONFAIR exchange on-chain components and an independent emergency refund interface.

## 📄 Smart Contracts
* `contracts/vault.tolk` — Funds vault and settlement logic.
* `contracts/event_pool.tolk` — Event pool management.
    
## 🚨 Emergency Escape Hatch
If the primary exchange interface is unavailable, you can withdraw your funds directly from the smart contract using our independent decentralized page hosted on GitHub Pages:

🔗 **[Launch Emergency Refund](https://tonfair.github.io/tonfair/refund)**

*This page runs entirely client-side (in your browser), interacts directly with the contract via TON RPC, and does not depend on the exchange backend.*

    
```mermaid
sequenceDiagram
    actor User as 🧑 Trader
    participant Vault as 🔒 Personal Vault<br/>(on-chain contract)
    participant EventPool as 📜 EventPool<br/>(Escrow Contract)
    participant Exchange as 🏦 Exchange
    participant Oracle as ⚖️ Oracle<br/>(Independent)

    rect rgba(100, 149, 237, 0.10)
        Note over User,Exchange: 1 · Deposit & Bet Matching
        User->>Vault: Deposit TON to personal on-chain Vault
        Note over Vault: The exchange can only move funds INTO deals —<br/>it can never withdraw them. Non-custodial by design.
        User->>Exchange: Place a bet (e.g. "Chelsea wins")
        Exchange->>Vault: Instruct transfer to escrow
        Vault->>EventPool: ✅ Funds locked in smart contract (both sides)
        Note over EventPool: At this point neither the exchange nor anyone else<br/>can touch the funds — only the contract logic can release them.
    end

    rect rgba(255, 165, 0, 0.10)
        Note over Exchange,EventPool: 2 · Optimistic Oracle — Exchange Proposes Result
        Exchange->>EventPool: Propose result  (e.g. "Chelsea 2:1")
        Note over EventPool: A 6-hour challenge window opens.<br/>The exchange merely suggests an outcome — it cannot enforce it.
    end

    rect rgba(72, 199, 116, 0.10)
        Note over User,Oracle: 3 · Settlement
        alt ✅ No challenge — result accepted
            Note over EventPool: 6 hours pass with no objection.<br/>Settle is permissionless — the exchange does not need to act.
            User->>EventPool: Trigger Settle (anyone can call)
            EventPool->>Vault: ✅ Automatic payout to winner's Vault
        else ⚠️ Trader disputes the result
            User->>EventPool: Challenge + 10 TON deposit
            Note over Oracle,EventPool: Dispute escalated to an independent Oracle.<br/>The Oracle is set at deploy time and cannot be changed.
            Oracle->>EventPool: OracleResolve — independent cryptographic verdict
            Note over EventPool: Exchange was wrong → challenger receives 10 TON back.<br/>Exchange was right  → deposit kept as anti-spam fee.
            EventPool->>Vault: ✅ Payout according to Oracle verdict
        end
    end

    rect rgba(236, 100, 100, 0.12)
        Note over User,Oracle: 🛡️ Emergency Exits — funds always recoverable, no trust required
        Note over EventPool: Exchange never proposes a result within 3 days of event start:<br/>→ any trader calls Settle → full refund, no exchange or oracle needed.
        Note over EventPool: Oracle never resolves an open dispute within 3 days:<br/>→ any trader calls Settle → full refund, no exchange or oracle needed.
        Note over Vault: Even if the exchange shuts down permanently,<br/>traders recover 100 % of their funds on-chain.
    end

    rect rgba(180, 140, 210, 0.10)
        Note over User,Vault: 4 · Withdraw to Personal Wallet (anytime)
        User->>Vault: Request withdrawal
        Note over Vault: Exchange cannot block withdrawals — only delay<br/>briefly (5 min) to close open orders gracefully.
        Vault->>User: TON sent directly to trader's wallet
    end
```

---

