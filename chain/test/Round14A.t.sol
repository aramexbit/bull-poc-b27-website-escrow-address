// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Mocks.sol";

// ROUND 14 — Team A (forge / on-chain).
// Live Agreement v3 (0x84c6…, zerofee etch) + live Streams (0xF02a…, etched
// stream.hex, fabricated storage — NO createStream, forbidden step never
// attempted). Throwaway keys only.
//
// K-801: deal("milestones") per-step amount check has a LOWER bound only
//   (total/n - tol) and no UPPER bound short of total -> server front-loads
//   ~100% into milestone 1; arbiter attesting milestone 1 pays ~everything.
// K-804: deal("scheduled_payment") kind-0 value never checked (B-23 gap,
//   template B-23 did not cover) -> value=now releases immediately.
// K-802: agree()/deal() never verify createAgreement msg.value / feeWei ->
//   does the contract keep excess ETH sent with the step?
// K-813..K-818: streams access-control, fresh probes (caller matrix).
contract Round14ATest is Test {
    address constant AGREEMENT = 0x84C6D5dAf99BC65ed3A1D26Ca88ffa834D143999;
    address constant STREAM = 0xF02aD48D7Ae63F17941E78AAF228C1450Db13891;

    uint256 constant PAYER_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant PAYEE_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant ARB_PK = 0x47e179ec1974f892c2cd3b0cf1a4ec6a36e72a0a0d26ccaa2aa5c8ad6b9b47a8;
    address payer; address payee; address arbiter; address stranger;
    MockERC20 token;

    struct Cond { uint8 kind; address target; bytes data; uint256 value; }
    struct Params { address payee; address asset; uint256 amount; uint64 expiry; bytes32 termsHash; Cond[] conditions; }
    struct Quote { uint256 feeWei; uint64 expiry; bytes sig; }

    bytes4 constant SEL_WITHDRAW = 0x2e1a7d4d;
    bytes4 constant SEL_CANCEL = 0x40e58ee5;
    bytes4 constant SEL_PAUSE = 0x136439dd;
    bytes4 constant SEL_RESUME = 0x414000b5;
    bytes4 constant SEL_REDIRECT = 0xadfecd8a;

    function setUp() public {
        vm.chainId(4663);
        payer = vm.addr(PAYER_PK);
        payee = vm.addr(PAYEE_PK);
        arbiter = vm.addr(ARB_PK);
        stranger = vm.addr(0x9999);
        vm.etch(AGREEMENT, vm.parseBytes(vm.readFile("bytecode/agreement-84c6-zerofee.hex")));
        vm.store(AGREEMENT, bytes32(uint256(9)), bytes32(uint256(1))); // guard unlocked
        vm.store(AGREEMENT, bytes32(uint256(0)), bytes32(uint256(1))); // nextId = 1
        vm.etch(STREAM, vm.parseBytes(vm.readFile("bytecode/stream.hex")));
        vm.store(STREAM, bytes32(uint256(4)), bytes32(uint256(1))); // streams reentrancy guard unlocked
        token = new MockERC20();
        token.mint(payer, 1000000000); // raw units; treat 1 unit = 1 micro-USDG (6 dec)
        token.mint(STREAM, 100000 ether);
        vm.deal(payer, 100 ether);
        vm.deal(payee, 10 ether);
        vm.deal(arbiter, 10 ether);
        vm.deal(stranger, 10 ether);
        vm.warp(1000);
    }

    // ---- Agreement helpers ----
    function _quote() internal view returns (Quote memory) {
        return Quote({feeWei: 0, expiry: uint64(block.timestamp + 3600), sig: new bytes(65)});
    }
    function _quoteFee(uint256 feeWei) internal view returns (Quote memory) {
        return Quote({feeWei: feeWei, expiry: uint64(block.timestamp + 3600), sig: new bytes(65)});
    }
    function _create(address payee_, uint256 amount_, Cond[] memory conds, uint256 value_) internal returns (bool ok, uint256 id) {
        return _createTerms(payee_, amount_, conds, value_, bytes32(uint256(0)));
    }
    function _createTerms(address payee_, uint256 amount_, Cond[] memory conds, uint256 value_, bytes32 terms_) internal returns (bool ok, uint256 id) {
        Params memory p = Params({payee: payee_, asset: address(token), amount: amount_,
            expiry: uint64(block.timestamp + 30 days), termsHash: terms_, conditions: conds});
        bytes memory ret;
        vm.prank(payer);
        (ok, ret) = AGREEMENT.call{value: value_}(
            abi.encodeWithSelector(bytes4(0x8952f925), p, _quote()));
        if (ok) id = abi.decode(ret, (uint256));
    }
    function _createEth(address payee_, uint256 amount_, Cond[] memory conds, uint256 value_, uint256 feeWei_) internal returns (bool ok, uint256 id) {
        Params memory p = Params({payee: payee_, asset: address(0), amount: amount_,
            expiry: uint64(block.timestamp + 30 days), termsHash: bytes32(uint256(0)), conditions: conds});
        bytes memory ret;
        vm.prank(payer);
        (ok, ret) = AGREEMENT.call{value: value_}(
            abi.encodeWithSelector(bytes4(0x8952f925), p, _quoteFee(feeWei_)));
        if (ok) id = abi.decode(ret, (uint256));
    }
    function _attest(uint256 id, address from) internal returns (bool) {
        vm.prank(from);
        (bool ok,) = AGREEMENT.call(abi.encodeWithSelector(bytes4(0xa3bb24cc), id, uint256(0)));
        return ok;
    }
    function _release(uint256 id) internal returns (bool) {
        (bool ok,) = AGREEMENT.call(abi.encodeWithSelector(bytes4(0x37bdc99b), id));
        return ok;
    }
    function _attestCond(uint8 kind, address target) internal pure returns (Cond[] memory c) {
        c = new Cond[](1);
        c[0] = Cond({kind: kind, target: target, data: "", value: 0});
    }

    // ---- K-801: milestones front-load — contract leg ----
    // Total 500,000,000 units (500 USDG), n=2. Honest split 250M/250M.
    // Skewed split 499,999,999 / 1: arbiter attests milestone 1 -> payee
    // collects 499,999,999 after ONE attestation instead of 250,000,000.
    function testK801MilestonesFrontLoad() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        (bool ok1, uint256 id1) = _createTerms(payee, 499999999, _attestCond(1, arbiter), 0, bytes32(uint256(1)));
        (bool ok2, uint256 id2) = _createTerms(payee, 1, _attestCond(1, arbiter), 0, bytes32(uint256(2)));
        assertTrue(ok1 && ok2, "both skewed milestone agreements must be creatable");
        assertTrue(_attest(id1, arbiter), "arbiter attests milestone 1");
        uint256 before = token.balanceOf(payee);
        assertTrue(_release(id1), "release milestone 1 must succeed after attestation");
        uint256 gained = token.balanceOf(payee) - before;
        emit log_named_uint("K-801 skewed m1 payout (units, 1e6 = 1 USDG)", gained);
        emit log_named_uint("K-801 honest m1 payout would be", 250000000);
        assertEq(gained, 499999999, "front-loaded milestone 1 pays 499,999,999 units after one attestation");
        // Milestone 2 is dust; total paid across both can never exceed 500M,
        // so the skew moves 249,999,999 units EARLY, not extra — the loss is
        // the staged-payment protection, realised at first attestation.
        assertEq(id2, id1 + 1, "milestone ids sequential");
    }

    function testK801MilestonesHonestControl() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        (bool ok1, uint256 id1) = _createTerms(payee, 250000000, _attestCond(1, arbiter), 0, bytes32(uint256(1)));
        (bool ok2,) = _createTerms(payee, 250000000, _attestCond(1, arbiter), 0, bytes32(uint256(2)));
        assertTrue(ok1 && ok2, "honest split must be creatable");
        assertTrue(_attest(id1, arbiter), "arbiter attests milestone 1");
        uint256 before = token.balanceOf(payee);
        assertTrue(_release(id1), "release milestone 1");
        assertEq(token.balanceOf(payee) - before, 250000000, "honest milestone 1 pays exactly 250,000,000");
    }

    // ---- K-804: scheduled_payment kind-0 value=now -> immediate release ----
    function testK804TimeAfterValueNow() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        Cond[] memory c = new Cond[](1);
        c[0] = Cond({kind: 0, target: address(0), data: "", value: block.timestamp});
        (bool ok, uint256 id) = _create(payee, 500000000, c, 0);
        assertTrue(ok, "kind-0 value=now agreement must be creatable");
        uint256 before = token.balanceOf(payee);
        bool rel = _release(id);
        emit log_named_uint("K-804 kind-0 value=now release ok", rel ? 1 : 0);
        assertTrue(rel, "release must succeed immediately when time_after value is now");
        assertEq(token.balanceOf(payee) - before, 500000000, "payee collects full 500M at once");
    }

    function testK804TimeAfterFutureControl() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        Cond[] memory c = new Cond[](1);
        c[0] = Cond({kind: 0, target: address(0), data: "", value: block.timestamp + 48 hours});
        (bool ok, uint256 id) = _create(payee, 500000000, c, 0);
        assertTrue(ok, "kind-0 future agreement must be creatable");
        assertFalse(_release(id), "release must FAIL while time_after is in the future");
    }

    // ---- K-828: kind-1 (attest) condition with a nonzero value ----
    // agree()'s #matchConditions requires v==0 for attest, but deal()'s
    // shape check never reads the value. Does the contract care?
    function testK828Kind1NonzeroValue() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        Cond[] memory c = new Cond[](1);
        c[0] = Cond({kind: 1, target: arbiter, data: "", value: 12345 ether});
        (bool ok, uint256 id) = _create(payee, 500000000, c, 0);
        assertTrue(ok, "kind-1 with nonzero value must be creatable (contract ignores the value)");
        assertTrue(_attest(id, arbiter), "arbiter attests");
        uint256 before = token.balanceOf(payee);
        assertTrue(_release(id), "release succeeds");
        assertEq(token.balanceOf(payee) - before, 500000000, "payee collects full amount; the nonzero value changed nothing");
        emit log_string("K-828: kind-1 value is ignored by the contract - no impact, KILL");
    }

    // ---- K-802: does createAgreement keep excess ETH? ----
    // ANSWER: NO — the contract enforces exact msg.value and reverts
    // WrongAmount() on any excess. The SDK cap therefore cannot be
    // exceeded through the step value; the overcharge path is dead.
    // (The feeWei=0.05 variant below still creates, but only with a
    // feeSigner-signed quote for that fee — a precondition outside the
    // established step-tampering threat model. See K-802 verdict.)
    function testK802FeeExcessTokenAgreement() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        // feeWei=0 in the quote, but the step carries 0.05 ETH of value
        // (the most #agreeCap / #send allow for a token agreement).
        (bool ok,) = _create(payee, 500000000, _attestCond(1, arbiter), 0.05 ether);
        assertFalse(ok, "create with 0.05 ETH excess value must REVERT (WrongAmount)");
        emit log_string("K-802: token agreement + 0.05 ETH excess value reverts WrongAmount - overcharge via value is dead");
    }

    function testK802FeeWeiCharged() public {
        vm.prank(payer);
        token.approve(AGREEMENT, 1000000000);
        uint256 contractBefore = address(AGREEMENT).balance;
        // Quote says feeWei = 0.05 ETH, step carries exactly that.
        Params memory p = Params({payee: payee, asset: address(token), amount: 500000000,
            expiry: uint64(block.timestamp + 30 days), termsHash: bytes32(uint256(0)), conditions: _attestCond(1, arbiter)});
        vm.prank(payer);
        (bool ok, bytes memory ret) = AGREEMENT.call{value: 0.05 ether}(
            abi.encodeWithSelector(bytes4(0x8952f925), p, _quoteFee(0.05 ether)));
        assertTrue(ok, "create with feeWei=0.05 ETH must succeed (zero-sig passes zerofee etch)");
        if (ok) emit log_named_uint("K-802 feeWei=0.05 agreement id", abi.decode(ret, (uint256)));
        emit log_named_uint("K-802 feeWei=0.05: ETH kept by contract (wei)", address(AGREEMENT).balance - contractBefore);
    }

    function testK802FeeExcessEthAgreement() public {
        // ETH agreement, amount 1 ETH, step carries 1.05 ETH + 0.05 ETH
        // (the most #agreeCap allows: 105% + 0.05 fee).
        (bool ok,) = _createEth(payee, 1 ether, _attestCond(1, arbiter), 1.10 ether, 0);
        assertFalse(ok, "ETH create with 1.10 ETH value must REVERT (WrongAmount)");
        emit log_string("K-802: ETH agreement + 0.10 ETH excess value reverts WrongAmount - overcharge via value is dead");
    }

    // ---- Streams helpers (fabricated storage, round-13 layout) ----
    function _base(uint256 id) internal pure returns (bytes32) {
        return keccak256(abi.encode(id, uint256(1)));
    }
    function _fabricate(uint256 id, uint256 amount_, uint256 withdrawn_, uint64 start_, uint64 end_, uint64 pausedAt_, uint8 kind_) internal {
        bytes32 b = _base(id);
        vm.store(STREAM, b, bytes32(uint256(uint160(payer))));
        vm.store(STREAM, bytes32(uint256(b) + 1), bytes32(uint256(uint160(payee))));
        vm.store(STREAM, bytes32(uint256(b) + 2), bytes32(uint256(uint160(arbiter))));
        vm.store(STREAM, bytes32(uint256(b) + 3), bytes32(uint256(uint160(address(token)))));
        vm.store(STREAM, bytes32(uint256(b) + 4), bytes32(amount_));
        vm.store(STREAM, bytes32(uint256(b) + 5), bytes32(withdrawn_));
        uint256 packed = uint256(start_) | (uint256(end_) << 64) | (uint256(pausedAt_) << 128) | (uint256(kind_) << 192);
        vm.store(STREAM, bytes32(uint256(b) + 6), bytes32(packed));
    }
    function _callAs(address who, bytes memory data) internal returns (bool ok, bytes memory ret) {
        vm.prank(who);
        (ok, ret) = STREAM.call(data);
    }

    // ---- K-813: withdraw called by the PAYER (not the payee) ----
    function testK813WithdrawByPayer() public {
        _fabricate(1, 1000 ether, 0, 1000, 87400, 0, 1);
        vm.warp(1000 + 43200); // halfway: vested 500
        uint256 payeeBefore = token.balanceOf(payee);
        (bool ok,) = _callAs(payer, abi.encodeWithSelector(SEL_WITHDRAW, uint256(1)));
        uint256 delta = token.balanceOf(payee) - payeeBefore;
        emit log_named_uint("K-813 withdraw-by-payer ok", ok ? 1 : 0);
        emit log_named_uint("K-813 payee delta", delta);
        // Either outcome is safe: withdraw is permissionless-but-payee-only
        // in effect (pays the payee) or it reverts. Record, do not overclaim.
    }

    // ---- K-814: cancel called by a STRANGER ----
    function testK814CancelByStranger() public {
        _fabricate(2, 1000 ether, 0, 1000, 87400, 0, 1);
        vm.warp(1000 + 43200);
        uint256 payeeBefore = token.balanceOf(payee);
        uint256 payerBefore = token.balanceOf(payer);
        (bool ok,) = _callAs(stranger, abi.encodeWithSelector(SEL_CANCEL, uint256(2)));
        emit log_named_uint("K-814 cancel-by-stranger ok", ok ? 1 : 0);
        assertFalse(ok, "stranger cancel must revert (only payer cancels)");
        assertEq(token.balanceOf(payee) - payeeBefore, 0, "failed cancel pays nobody");
        assertEq(token.balanceOf(payer) - payerBefore, 0, "failed cancel refunds nobody");
    }

    // ---- K-815: pause called by the PAYER (not the arbiter) ----
    function testK815PauseByPayer() public {
        _fabricate(3, 1000 ether, 0, 1000, 87400, 0, 1);
        (bool ok,) = _callAs(payer, abi.encodeWithSelector(SEL_PAUSE, uint256(3)));
        emit log_named_uint("K-815 pause-by-payer ok", ok ? 1 : 0);
        assertFalse(ok, "payer pause must revert (only arbiter pauses)");
    }

    // ---- K-816: redirect called by the PAYER — theft if it works ----
    function testK816RedirectByPayer() public {
        _fabricate(4, 1000 ether, 0, 1000, 87400, 0, 1);
        (bool ok,) = _callAs(payer, abi.encodeWithSelector(SEL_REDIRECT, uint256(4), payer));
        emit log_named_uint("K-816 redirect-by-payer ok", ok ? 1 : 0);
        assertFalse(ok, "payer redirect must revert (only payee redirects)");
        vm.warp(1000 + 43200);
        uint256 payerBefore = token.balanceOf(payer);
        uint256 payeeBefore = token.balanceOf(payee);
        (bool wok,) = _callAs(stranger, abi.encodeWithSelector(SEL_WITHDRAW, uint256(4)));
        assertTrue(wok, "withdraw after failed redirect must succeed");
        assertEq(token.balanceOf(payer) - payerBefore, 0, "payer gains nothing from failed redirect");
        assertEq(token.balanceOf(payee) - payeeBefore, 500 ether, "payee still receives the vested 500");
    }

    // ---- K-817: resume called by the PAYER ----
    function testK817ResumeByPayer() public {
        _fabricate(5, 1000 ether, 0, 1000, 87400, 2000, 1);
        (bool ok,) = _callAs(payer, abi.encodeWithSelector(SEL_RESUME, uint256(5)));
        emit log_named_uint("K-817 resume-by-payer ok", ok ? 1 : 0);
        assertFalse(ok, "payer resume must revert (only arbiter resumes)");
    }

    // ---- K-818: withdraw called by the ARBITER ----
    function testK818WithdrawByArbiter() public {
        _fabricate(6, 1000 ether, 0, 1000, 87400, 0, 1);
        vm.warp(1000 + 43200);
        uint256 payeeBefore = token.balanceOf(payee);
        (bool ok,) = _callAs(arbiter, abi.encodeWithSelector(SEL_WITHDRAW, uint256(6)));
        uint256 delta = token.balanceOf(payee) - payeeBefore;
        emit log_named_uint("K-818 withdraw-by-arbiter ok", ok ? 1 : 0);
        emit log_named_uint("K-818 payee delta", delta);
        // Record only: withdraw paying the payee regardless of caller is
        // safe (no diversion); a revert is equally safe.
    }
}
