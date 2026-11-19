# PoC for Bull.family bug bounty report B-27

## Website `/d/` trusts the escrow address from the server — malicious server points open + pay at an attacker contract and the buyer pays in full with no deal on chain

**Report B-27** (K-841). Website chunk under test: `website-deal-chunk.js` —
the `/d/` deal-room chunk live 19 Nov 2026, sha256
`4140f5163dc863341ecab713d67f62982d7908422705b26c4940904f7e64320c`, 12,878 bytes
(`https://www.bull.family/d/`, chunk `page-16d1cf063b916c2c.js`).

### The bug

Module 82193 of the chunk exports the hardcoded escrow address:

```js
let i = "0xd961cA37e339E14e0D3478383a252E218fe7aa4a"; // HI, the v3 escrow
```

but `.HI` is used **0 times** in the whole chunk — the pin exists in the bundle
and is never applied.

- `M(e)` ("1. Open escrow deal") sends `createDeal` to `n.escrow.address`
  from the server's `GET /api/buyer/<token>` response. Its only post-check is
  that a `DealCreated` event exists in the receipt.
- `V(e)` ("2. Pay") approves and pays to `s = e.escrowAddress ||
  n.escrow.address` — also server-supplied.

A malicious/compromised API server returns an attacker contract as the escrow
address. The `POST /api/quote` response is FULLY HONEST (honest seller, honest
sellToken, honest amounts, a real seller-signed consent for the real escrow).
The attacker contract accepts any calldata and emits a fake `DealCreated`
event, so `M(e)` passes its post-check; `V(e)` then approves the full amount
and calls the attacker's `fundPayment`, and the attacker pulls the full
approval. **The victim pays the full 500 USDG and receives 0 tokens. No deal
exists on the real v3 escrow at all.**

This is NOT B-24: B-24's attacker is a malicious *seller* swapping `sellToken`
in their own consent while the escrow is honest — a real deal is created and
settles in worthless tokens. Here the attacker is the *server*, every param is
honest, and no deal is created anywhere. Control C2 proves the B-24 fix
(comparing every param against the offer) does NOT catch this. It is NOT
B-02/B-22 either: those are fields inside a deal on the real escrow; here the
escrow address itself is fake. Dedupe risk, stated honestly: HIGH vs B-02
(same root-cause family — server-supplied data never verified against intent;
different surface/field/attacker/effect).

Caveat, stated explicitly: the escrow address IS displayed on the page as a
truncated link ("On-chain escrow contract: <link>") — display is not
verification; there is no comparison anywhere in the code.

### Reproduce

Local Anvil chain 4663, mock malicious Bull API, verbatim replica of the
website's `M(e)` + `V(e)` logic from the chunk, live escrow v3 bytecode
etched, no real funds, no mainnet, no Bull infrastructure:

```bash
anvil --port 8547 --chain-id 4663
npm install
node run-poc.mjs   # cases P1, C0, C1, C2
```

Forge leg: `cd chain && forge test` — `Round14B.t.sol` 2/2 (the fake escrow
emits the fake `DealCreated` and drains the 500 USDG approval; the real escrow
REJECTS the same unsigned consent).

### Measured (fresh Anvil, 19 Nov 2026)

```
P1  EXPLOITED: M(e) sent createDeal to the attacker contract, no error
    (fake DealCreated id 1 passed the post-check); V(e) approved +
    fundPayment to the attacker; attacker +500 USDG; 0 deals on real v3
    escrow (nextId still 1); buyer holds 0 T
C0  control OK: honest escrow -> real deal id 1 settles (status 2),
    buyer receives 100 T, attacker +0
C1  control OK: replica WITH the escrow pin (HI + the two legacy escrows
    hardcoded in module 82193) REFUSES the attacker address before sending
    anything (0 funds out; no fake/real deal id consumed)
C2  control EXPLOITED: replica with ALL params-vs-offer comparisons
    (the B-24 fix) but NO escrow pin -> attack still succeeds, attacker
    +500 USDG again, buyer +0 T (every param is honest; only the address
    is fake)
EXPLOITED: 2/2 (P1, C2) | CONTROLS OK: 2/2 (C0, C1)
```

### Suggested fix

In `M(e)` (and `V(e)`), compare `n.escrow.address` (and `e.escrowAddress`)
against the hardcoded set in module 82193 (`HI` + the two legacy escrows) and
refuse to send anything if it is not one of them — the constant is already in
the bundle; it only needs to be used. Do the same for any other
server-supplied contract address the page sends transactions to.

### Files

- `run-poc.mjs` — the runner (mock API + replica `M(e)`/`V(e)` + cases P1/C0/C1/C2)
- `website-deal-chunk.js` — the verbatim `/d/` chunk (sha `4140f516…`)
- `chain/` — forge project (`src/AttackerEscrow.sol`, `src/Mocks.sol`,
  `test/Round14A.t.sol`, `test/Round14B.t.sol`, live bytecode etches)
- `poc-result.json` — measured results
