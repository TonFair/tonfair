# TONFAIR Smart Contracts & Emergency Refund

This repository contains the source code for the TONFAIR exchange on-chain components and an independent emergency refund interface.

## 📄 Smart Contracts

* `contracts/vault.tolk` — Funds vault and settlement logic.
* `contracts/event_pool.tolk` — Event pool management.

## 🚨 Emergency Escape Hatch

If the primary exchange interface is unavailable, you can withdraw your funds directly from the smart contract using our independent decentralized page hosted on GitHub Pages:

🔗 **[Launch Emergency Refund](https://tonfair.github.io/tonfair/refund)**

*This page runs entirely client-side (in your browser), interacts directly with the contract via TON RPC, and does not depend on the exchange backend.*

## How It Works — Key Concepts

Four core guarantees: **non-custodial**, **atomic deal funding**, **optimistic oracle**, and **unconditional exit**.

```mermaid
sequenceDiagram
    actor User as 🧑 Trader
    participant Vault as 🔒 Personal Vault<br/>(On-chain Contract)
    participant EventPool as 📜 EventPool<br/>(Escrow Contract)
    participant Exchange as 🏦 Exchange
    participant Oracle as ⚖️ Oracle<br/>(Independent)

    rect rgba(100, 149, 237, 0.10)
        Note over User,Exchange: 1 · Deposit & Bet Matching
        User->>Vault: Deposit TON to personal on-chain Vault
        Note over Vault: The exchange can only move funds INTO matched deals —<br/>it can never withdraw them. Non-custodial by design.
        User->>Exchange: Place a bet (e.g. "Chelsea wins")
        Exchange->>Exchange: Match both sides and start one 60-second funding window
        Exchange->>Vault: Request both matched transfers with the same deadline
        Vault->>EventPool: Submit each side's funds and funding deadline
        Note over EventPool: The smart contract independently validates the deadline,<br/>participants, terms, and exact amount of both deposits.
        alt ✅ Both sides fund within 60 seconds
            EventPool-->>Exchange: DealFunded — on-chain funding confirmed
            Exchange-->>User: Deal opens only after confirmation
            Note over EventPool: Funds are now locked in escrow.<br/>Only contract logic can release them.
        else ⏱ Funding is incomplete when the window expires
            Exchange->>EventPool: Request expiry of the incomplete deal
            EventPool->>Vault: Refund received deposits minus on-chain refund fees
            EventPool-->>Exchange: DealExpired — on-chain cancellation confirmed
            Exchange-->>User: Deal cancelled
            Note over EventPool: Late deposits are rejected and refunded.<br/>The expired deal ID cannot be recreated.
        end
    end

    rect rgba(255, 165, 0, 0.10)
        Note over Exchange,EventPool: 2 · Optimistic Oracle — Exchange Proposes Result
        Exchange->>EventPool: Propose result (e.g. "Chelsea 2:1")
        Note over EventPool: A challenge window opens: 5 minutes for UP_DOWN events,<br/>6 hours for sports and prediction events.<br/>The exchange merely suggests an outcome — it cannot enforce it.
    end

    rect rgba(72, 199, 116, 0.10)
        Note over User,Oracle: 3 · Settlement
        alt ✅ No challenge — result accepted
            Note over EventPool: The applicable challenge window passes with no objection.<br/>Settlement is permissionless — the exchange does not need to act.
            User->>EventPool: Trigger Settle (anyone can call)
            EventPool->>Vault: ✅ Automatic payout to winner's Vault
        else ⚠️ Trader disputes the result
            User->>Vault: Request a Challenge
            Vault->>EventPool: Submit Challenge + 10 TON production deposit
            Note over Oracle,EventPool: The dispute is escalated to an independent Oracle.<br/>The Oracle is set at deployment and cannot be changed.
            Oracle->>EventPool: OracleResolve — independent cryptographic verdict
            Note over EventPool: Exchange was wrong → challenger receives 10 TON back.<br/>Exchange was right → deposit is retained as an anti-spam fee.
            EventPool->>Vault: ✅ Payout according to the Oracle verdict
        end
    end

    rect rgba(236, 100, 100, 0.12)
        Note over User,Oracle: 🛡️ Emergency Exits — funds always recoverable, no trust required
        Note over EventPool: Exchange never proposes a result within 3 days of event start:<br/>→ any trader calls Settle → full refund, no exchange or Oracle needed.
        Note over EventPool: Oracle never resolves an open dispute within 3 days:<br/>→ any trader calls Settle → full refund, no exchange or Oracle needed.
        Note over Vault: Even if the exchange shuts down permanently,<br/>traders can recover their funds on-chain.
    end

    rect rgba(180, 140, 210, 0.10)
        Note over User,Vault: 4 · Withdraw to Personal Wallet
        User->>Vault: Request withdrawal
        Note over Vault: The exchange cannot block withdrawals — the contract only enforces<br/>a 5-minute delay so open orders can be closed gracefully.
        Vault->>User: TON sent directly to the trader's wallet
    end
```

---
