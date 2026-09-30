// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {StealthFactory} from "../src/StealthFactory.sol";
import {StealthVault} from "../src/StealthVault.sol";
import {IPonsFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {IUniswapV3Pool, IWETH9, IERC20} from "../src/interfaces/IUniswapV3.sol";
import {Twap} from "../src/lib/Twap.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {MockERC20, MockWETH, MockV3Pool, MockEscrow, MockCurve, MockPons, Rejecting} from "./Mocks.sol";

/// Merkle trees built the way the attester builds them: double-hashed (address, uint256) leaves,
/// sorted-pair hashing, an odd node carried up unchanged.
abstract contract MerkleHelper {
    function _leaf(address a, uint256 amt) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(a, amt))));
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function _up(bytes32[] memory level) internal pure returns (bytes32[] memory next) {
        next = new bytes32[]((level.length + 1) / 2);
        for (uint256 i; i < next.length; i++) {
            next[i] = 2 * i + 1 < level.length ? _pair(level[2 * i], level[2 * i + 1]) : level[2 * i];
        }
    }

    function _root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) level = _up(level);
        return level[0];
    }

    function _proof(bytes32[] memory leaves, uint256 idx) internal pure returns (bytes32[] memory proof) {
        bytes32[] memory tmp = new bytes32[](32);
        uint256 n;
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 sib = idx ^ 1;
            if (sib < level.length) tmp[n++] = level[sib];
            level = _up(level);
            idx /= 2;
        }
        proof = new bytes32[](n);
        for (uint256 i; i < n; i++) proof[i] = tmp[i];
    }
}

contract StealthVaultTest is Test, MerkleHelper {
    uint256 constant ATTESTER_PK = 0xA77E57;
    int24 constant TICK = -197460; // ≈ $2,659 per ETH with WETH (18) as token0 and USDG (6) as token1

    MockEscrow escrow;
    MockPons pons;
    MockWETH weth;
    MockERC20 usdg;
    MockV3Pool pool;
    StealthFactory factory;
    StealthVault vault;
    MockERC20 coin;
    MockCurve curve;

    address guardian = makeAddr("guardian");
    address treasury = makeAddr("treasury");
    address launcher = makeAddr("launcher");
    address trader = makeAddr("trader");
    address keeper = makeAddr("keeper");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address deposit = makeAddr("route-deposit");

    function setUp() public {
        escrow = new MockEscrow();
        pons = new MockPons(escrow);
        weth = new MockWETH();
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        pool = new MockV3Pool(address(weth), address(usdg), TICK);
        usdg.mint(address(pool), 10_000_000e6);
        vm.warp(1_800_000_000);

        factory = new StealthFactory(_wiring(), guardian, vm.addr(ATTESTER_PK));
        (vault, coin, curve) = _launch(launcher, "Glass", "GLASS", 300, 0, "glass");
        vm.deal(trader, 1_000 ether);
    }

    function _wiring() internal view returns (StealthVault.Wiring memory) {
        return StealthVault.Wiring({
            pons: IPonsFactory(address(pons)),
            escrow: IPonsFeeEscrow(address(escrow)),
            hook: address(0xB00C),
            weth: IWETH9(address(weth)),
            usdg: IERC20(address(usdg)),
            pool: IUniswapV3Pool(address(pool)),
            treasury: treasury
        });
    }

    function _input(string memory name, string memory symbol, bytes32 salt)
        internal
        pure
        returns (StealthVault.LaunchInput memory i)
    {
        i.name = name;
        i.symbol = symbol;
        i.logo = "https://app.stealthpad.online/img/x.webp";
        i.description = "test";
        i.salt = salt;
    }

    function _launch(address who, string memory name, string memory symbol, uint16 tax, uint256 firstBuy, bytes32 salt)
        internal
        returns (StealthVault v, MockERC20 t, MockCurve c)
    {
        vm.deal(who, 10 ether);
        uint256 value = pons.launchFee() + firstBuy; // read before the prank, or the prank is spent on it
        vm.prank(who);
        (address va, address to) = factory.launch{value: value}(_input(name, symbol, salt), tax, 0);
        v = StealthVault(payable(va));
        t = MockERC20(to);
        c = MockCurve(payable(v.curve()));
    }

    /// Trades that leave `taxEth` of creator tax in the curve.
    function _trade(MockCurve c, uint256 taxEth, uint16 taxBps) internal {
        uint256 quoteIn = (taxEth * 10_000 + taxBps - 1) / taxBps; // rounded up: exactly taxEth of tax
        vm.prank(trader);
        c.buy{value: quoteIn}(quoteIn, 0, trader);
    }

    function _sign(StealthVault v, uint64 roundId, bytes32 root, uint256 total, bytes32 seed)
        internal
        view
        returns (bytes memory)
    {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(ATTESTER_PK, v.hashPostRoot(roundId, root, total, seed));
        return abi.encodePacked(r, s, sv);
    }

    function _price() internal view returns (uint256) {
        return Twap.ratioWad(TickMath.getSqrtRatioAtTick(pool.tick()), true);
    }

    // ── launch ─────────────────────────────────────────────────────────────────

    function test_launch_names_the_vault_deployer_and_fee_recipient() public view {
        MockPons.LaunchedToken memory info = pons.getLaunchedToken(address(coin));
        assertEq(info.deployer, address(vault), "deployer");
        assertEq(info.creatorFeeRecipient, address(vault), "recipient");
        assertEq(info.creatorTaxBps, 300, "tax");
        assertFalse(info.buybackEnabled, "buyback off");
        assertEq(vault.taxBps(), 300);
        assertEq(vault.token(), address(coin));
        assertEq(factory.vaultOf(address(coin)), address(vault));
        assertTrue(factory.isVault(address(vault)));
        assertTrue(vault.feeRouteIntact());
    }

    function test_first_buy_goes_to_the_launcher_without_snipe_tax() public {
        (, MockERC20 t,) = _launch(alice, "Buy", "BUY", 300, 0.05 ether, "buy");
        assertGt(t.balanceOf(alice), 0, "first buy landed");
        assertEq(pons.lastExempt(0), alice, "launcher exempt from snipe tax");
    }

    function test_predict_matches_the_deployed_vault() public {
        address predicted = factory.predict(alice, bytes32("veil"), 500);
        (StealthVault v,,) = _launch(alice, "Veil", "VEIL", 500, 0, "veil");
        assertEq(address(v), predicted);
    }

    function test_tax_must_be_a_whole_percent_from_1_to_5() public {
        uint16[5] memory bad = [uint16(0), 50, 250, 600, 1000];
        for (uint256 i; i < bad.length; i++) {
            vm.deal(alice, 1 ether);
            vm.prank(alice);
            vm.expectRevert(abi.encodeWithSelector(StealthFactory.BadTax.selector, bad[i]));
            factory.launch{value: 0.0005 ether}(_input("X", "X", bytes32(i)), bad[i], 0);
        }
    }

    function test_guardian_can_close_new_launches_only() public {
        vm.prank(guardian);
        factory.setLaunchesOpen(false);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(StealthFactory.LaunchesClosed.selector);
        factory.launch{value: 0.0005 ether}(_input("X", "X", "x"), 100, 0);
        // the existing vault still runs rounds
        _trade(curve, 0.05 ether, 300);
        vm.prank(keeper);
        vault.runRound();
    }

    function test_vault_launch_is_factory_only_and_once() public {
        StealthVault.LaunchInput memory i = _input("X", "X", "x");
        vm.expectRevert(StealthVault.OnlyFactory.selector);
        vault.launch(i, alice, 0);
        vm.deal(address(factory), 1 ether);
        vm.prank(address(factory));
        vm.expectRevert(StealthVault.AlreadyLaunched.selector);
        vault.launch{value: 0.0005 ether}(i, alice, 0);
    }

    // ── rounds ─────────────────────────────────────────────────────────────────

    function test_round_splits_92_3_and_5_and_swaps_the_holders_share() public {
        _trade(curve, 1 ether, 300);
        assertEq(vault.pendingEth(), 1 ether, "creator tax visible before the sweep");
        assertTrue(vault.roundReady());

        uint256 tBefore = treasury.balance;
        vm.prank(keeper);
        uint64 id = vault.runRound();
        assertEq(id, 1);

        assertEq(keeper.balance, 0.03 ether, "tip 3%");
        // no $STEALTH vault yet: its 2.5% goes to the treasury with the treasury's own 2.5%
        assertEq(treasury.balance - tBefore, 0.05 ether, "protocol 5%");
        uint256 expected = (0.92 ether * _price()) / 1e18;
        StealthVault.Round memory r = vault.rounds(1);
        assertEq(r.holdersUsdg, expected, "92% swapped at the pool price");
        assertEq(r.ethBudget, 1 ether);
        assertEq(usdg.balanceOf(address(vault)), expected);
        assertEq(vault.unclaimed(), expected);
        assertEq(address(vault).balance, 0);
        assertFalse(vault.roundReady());
    }

    function test_round_waits_for_the_cooldown_and_the_minimum() public {
        _trade(curve, 0.019 ether, 300);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StealthVault.BelowMinimum.selector, 0.019 ether));
        vault.runRound();

        _trade(curve, 0.02 ether, 300);
        vm.prank(keeper);
        vault.runRound();

        _trade(curve, 0.5 ether, 300);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(StealthVault.CoolingDown.selector, block.timestamp + 1 hours));
        vault.runRound();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        assertEq(vault.runRound(), 2);
    }

    function test_round_is_capped_by_pool_depth_and_the_rest_waits() public {
        // shrink the pool to 100,000 USDG: one round may swap at most 1,000 USDG
        vm.prank(address(pool));
        usdg.transfer(address(0xdead), 9_900_000e6);
        _trade(curve, 2 ether, 300);
        vm.prank(keeper);
        vault.runRound();
        StealthVault.Round memory r = vault.rounds(1);
        assertApproxEqAbs(r.holdersUsdg, 1_000e6, 2, "capped at 1% of the pool's USDG");
        assertGt(address(vault).balance, 1.5 ether, "the rest waits for the next round");
    }

    function test_a_bad_fill_reverts_the_round() public {
        _trade(curve, 0.5 ether, 300);
        pool.setFillLoss(200); // 2% worse than the TWAP, past the 1.5% guard
        vm.prank(keeper);
        vm.expectPartialRevert(StealthVault.SwapOutTooLow.selector);
        vault.runRound();
    }

    function test_a_stale_oracle_blocks_rounds_not_funds() public {
        _trade(curve, 0.5 ether, 300);
        pool.setTooOld(true);
        vm.prank(keeper);
        vm.expectRevert(bytes("OLD"));
        vault.runRound();
        pool.setTooOld(false);
        vm.prank(keeper);
        vault.runRound();
    }

    function test_stealth_vault_receives_2_5_percent_of_other_rounds() public {
        (StealthVault sv,, MockCurve sc) = _launch(launcher, "Stealthpad", "STEALTH", 300, 0, "stealth");
        vm.prank(guardian);
        factory.setStealthVault(address(sv));
        assertEq(factory.stealthSink(), address(sv));

        _trade(curve, 1 ether, 300);
        uint256 tBefore = treasury.balance;
        vm.prank(keeper);
        vault.runRound();
        assertEq(address(sv).balance, 0.025 ether, "2.5% to the $STEALTH vault, in ETH");
        assertEq(treasury.balance - tBefore, 0.025 ether, "2.5% to the treasury");

        // the $STEALTH vault's own round keeps its 2.5% for $STEALTH holders: 94.5% swapped
        _trade(sc, 1 ether, 300);
        vm.prank(keeper);
        sv.runRound();
        StealthVault.Round memory r = sv.rounds(1);
        assertEq(r.ethBudget, 1.025 ether);
        uint256 holdersEth = 1.025 ether - (1.025 ether * 300) / 10_000 - (1.025 ether * 250) / 10_000;
        assertEq(r.holdersUsdg, (holdersEth * _price()) / 1e18);
    }

    function test_setting_the_stealth_vault_is_guarded_and_once() public {
        vm.expectRevert(StealthFactory.OnlyGuardian.selector);
        factory.setStealthVault(address(vault));
        vm.prank(guardian);
        vm.expectRevert(StealthFactory.NotOurVault.selector);
        factory.setStealthVault(alice);
        vm.prank(guardian);
        factory.setStealthVault(address(vault));
        vm.prank(guardian);
        vm.expectRevert(StealthFactory.AlreadySet.selector);
        factory.setStealthVault(address(vault));
    }

    function test_a_refusing_treasury_cannot_block_a_round() public {
        Rejecting r = new Rejecting();
        StealthVault.Wiring memory w = _wiring();
        w.treasury = address(r);
        StealthFactory f = new StealthFactory(w, guardian, vm.addr(ATTESTER_PK));
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (address va,) = f.launch{value: 0.0005 ether}(_input("R", "R", "r"), 200, 0);
        StealthVault v = StealthVault(payable(va));
        _trade(MockCurve(payable(v.curve())), 0.5 ether, 200);
        vm.prank(keeper);
        v.runRound();
        assertEq(keeper.balance, 0.015 ether, "the caller is still paid");
        assertEq(address(v).balance, 0.025 ether, "the refused 5% stays as next round's budget");
    }

    // ── roots and claims ───────────────────────────────────────────────────────

    function _roundWithRoot(StealthVault v, MockCurve c, address[] memory who, uint256[] memory amt, bytes32 seed)
        internal
        returns (bytes32[] memory leaves)
    {
        leaves = new bytes32[](who.length);
        uint256 total;
        for (uint256 i; i < who.length; i++) {
            leaves[i] = _leaf(who[i], amt[i]);
            total += amt[i];
        }
        uint64 id = uint64(v.roundCount());
        bytes32 root = _root(leaves);
        v.postRoot(id, root, total, seed, _sign(v, id, root, total, seed));
        c; // silence
    }

    function _oneRound() internal returns (uint256 usdgAssigned) {
        _trade(curve, 1 ether, 300);
        vm.prank(keeper);
        vault.runRound();
        usdgAssigned = vault.rounds(vault.roundCount()).cumulativeHolders;
    }

    function test_claims_wait_for_the_root_delay_then_pay_cumulatively() public {
        uint256 assigned = _oneRound();
        address[] memory who = new address[](3);
        (who[0], who[1], who[2]) = (alice, bob, carol);
        uint256[] memory amt = new uint256[](3);
        amt[0] = assigned / 2;
        amt[1] = assigned / 3;
        amt[2] = assigned - amt[0] - amt[1] - 7; // 7 raw units roll forward (below the floor)
        bytes32[] memory leaves = _roundWithRoot(vault, curve, who, amt, keccak256("seed-1"));

        StealthVault.Root memory p = vault.pendingRoot();
        assertEq(p.roundId, 1);
        assertEq(p.activeAt, block.timestamp + 2 hours);

        // before the delay: the active root is still empty
        vm.prank(alice);
        vm.expectRevert(StealthVault.BadProof.selector);
        vault.claim(amt[0], _proof(leaves, 0), alice, 0);

        vm.warp(block.timestamp + 2 hours);
        vm.prank(alice);
        vault.claim(amt[0], _proof(leaves, 0), alice, 0);
        assertEq(usdg.balanceOf(alice), amt[0], "USDG to the same wallet, no fee");

        vm.prank(alice);
        vm.expectRevert(StealthVault.NothingToClaim.selector);
        vault.claim(amt[0], _proof(leaves, 0), alice, 0);

        // someone else's leaf cannot be claimed by alice
        vm.prank(alice);
        vm.expectRevert(StealthVault.BadProof.selector);
        vault.claim(amt[1], _proof(leaves, 1), alice, 0);

        // bob routes his claim to a deposit address and pays the 0.20% route fee
        uint256 tBefore = usdg.balanceOf(treasury);
        vm.prank(bob);
        vault.claim(amt[1], _proof(leaves, 1), deposit, 20);
        uint256 fee = (amt[1] * 20) / 10_000;
        assertEq(usdg.balanceOf(deposit), amt[1] - fee);
        assertEq(usdg.balanceOf(treasury) - tBefore, fee);
        assertEq(vault.totalRouteFees(), fee);

        vm.prank(carol);
        vm.expectRevert(StealthVault.FeeTooHigh.selector);
        vault.claim(amt[2], _proof(leaves, 2), carol, 21);

        // round two: a new cumulative root; carol collects both rounds in one claim
        vm.warp(block.timestamp + 1 hours);
        uint256 assigned2 = _oneRound();
        uint256 add = assigned2 - assigned;
        uint256[] memory amt2 = new uint256[](3);
        amt2[0] = amt[0] + add / 2;
        amt2[1] = amt[1];
        amt2[2] = amt[2] + (add - add / 2);
        bytes32[] memory leaves2 = _roundWithRoot(vault, curve, who, amt2, keccak256("seed-2"));
        vm.warp(block.timestamp + 2 hours);
        vm.prank(carol);
        vault.claim(amt2[2], _proof(leaves2, 2), carol, 0);
        assertEq(usdg.balanceOf(carol), amt2[2]);
        vm.prank(alice);
        vault.claim(amt2[0], _proof(leaves2, 0), alice, 0);
        assertEq(usdg.balanceOf(alice), amt2[0], "alice gets only the difference");
        assertGe(usdg.balanceOf(address(vault)), vault.unclaimed(), "vault covers every unclaimed unit");
    }

    function test_the_guardian_can_veto_a_pending_root_and_nothing_else() public {
        uint256 assigned = _oneRound();
        address[] memory who = new address[](1);
        who[0] = alice;
        uint256[] memory amt = new uint256[](1);
        amt[0] = assigned;
        _roundWithRoot(vault, curve, who, amt, "s");

        vm.prank(alice);
        vm.expectRevert(StealthVault.OnlyGuardian.selector);
        vault.veto();

        vm.prank(guardian);
        vault.veto();
        assertEq(vault.pendingRoot().activeAt, 0, "pending root removed");

        // a corrected root can be posted for the same round
        amt[0] = assigned - 1;
        bytes32[] memory leaves = _roundWithRoot(vault, curve, who, amt, "s2");
        vm.warp(block.timestamp + 2 hours);
        vm.prank(guardian);
        vm.expectRevert(StealthVault.NothingToVeto.selector);
        vault.veto(); // too late: matured roots cannot be vetoed
        vm.prank(alice);
        vault.claim(amt[0], _proof(leaves, 0), alice, 0);
        assertEq(usdg.balanceOf(alice), assigned - 1);
    }

    function test_post_root_rejects_bad_input() public {
        uint256 assigned = _oneRound();
        bytes32 root = keccak256("root");
        // over-assigning is impossible
        {
            bytes memory sig_ = _sign(vault, 1, root, assigned + 1, "s");
            vm.expectRevert(abi.encodeWithSelector(StealthVault.TotalTooHigh.selector, assigned + 1, assigned));
            vault.postRoot(1, root, assigned + 1, "s", sig_);
        }
        // unknown round
        {
            bytes memory sig_ = _sign(vault, 2, root, assigned, "s");
            vm.expectRevert(StealthVault.BadRound.selector);
            vault.postRoot(2, root, assigned, "s", sig_);
        }
        // wrong signer
        {
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, vault.hashPostRoot(1, root, assigned, "s"));
            vm.expectRevert(StealthVault.BadSignature.selector);
            vault.postRoot(1, root, assigned, "s", abi.encodePacked(r, s, v));
        }
        // a signature for another vault does not verify here (the domain binds the vault)
        (StealthVault other,,) = _launch(alice, "Other", "OTH", 100, 0, "other");
        bytes memory foreign = _sign(other, 1, root, assigned, "s");
        vm.expectRevert(StealthVault.BadSignature.selector);
        vault.postRoot(1, root, assigned, "s", foreign);
    }

    function test_post_root_ordering() public {
        uint256 assigned = _oneRound();
        bytes32 root = keccak256("root");
        vault.postRoot(1, root, assigned, "s", _sign(vault, 1, root, assigned, "s"));
        // one pending root at a time
        vm.warp(block.timestamp + 1 hours);
        _oneRound();
        {
            bytes memory sig_ = _sign(vault, 2, root, assigned, "s");
            vm.expectRevert(abi.encodeWithSelector(StealthVault.PendingRoot.selector, block.timestamp + 1 hours));
            vault.postRoot(2, root, assigned, "s", sig_);
        }
        // after it matures: no going back to round 1, and no shrinking the total
        vm.warp(block.timestamp + 1 hours);
        {
            bytes memory sig_ = _sign(vault, 1, root, assigned, "s");
            vm.expectRevert(StealthVault.StaleRound.selector);
            vault.postRoot(1, root, assigned, "s", sig_);
        }
        bytes memory sig = _sign(vault, 2, root, assigned - 1, "s");
        vm.expectRevert(StealthVault.TotalDecreased.selector);
        vault.postRoot(2, root, assigned - 1, "s", sig);
    }

    function test_claim_rejects_bad_recipients() public {
        uint256 assigned = _oneRound();
        address[] memory who = new address[](1);
        who[0] = alice;
        uint256[] memory amt = new uint256[](1);
        amt[0] = assigned;
        bytes32[] memory leaves = _roundWithRoot(vault, curve, who, amt, "s");
        vm.warp(block.timestamp + 2 hours);
        vm.startPrank(alice);
        vm.expectRevert(StealthVault.BadRecipient.selector);
        vault.claim(assigned, _proof(leaves, 0), address(0), 0);
        vm.expectRevert(StealthVault.BadRecipient.selector);
        vault.claim(assigned, _proof(leaves, 0), address(vault), 0);
        vm.stopPrank();
    }

    // ── keys ───────────────────────────────────────────────────────────────────

    function test_attester_rotation_waits_two_days() public {
        uint256 newPk = 0xBEEF;
        vm.expectRevert(StealthFactory.OnlyGuardian.selector);
        factory.proposeAttester(vm.addr(newPk));
        vm.prank(guardian);
        factory.proposeAttester(vm.addr(newPk));
        vm.expectRevert(abi.encodeWithSelector(StealthFactory.AttesterNotReady.selector, block.timestamp + 2 days));
        factory.acceptAttester();
        vm.warp(block.timestamp + 2 days);
        factory.acceptAttester(); // anyone may finish it
        assertEq(factory.attester(), vm.addr(newPk));

        uint256 assigned = _oneRound();
        bytes32 root = keccak256("r");
        {
            bytes memory sig_ = _sign(vault, 1, root, assigned, "s");
            vm.expectRevert(StealthVault.BadSignature.selector);
            vault.postRoot(1, root, assigned, "s", sig_);
        } // old key
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(newPk, vault.hashPostRoot(1, root, assigned, "s"));
        vault.postRoot(1, root, assigned, "s", abi.encodePacked(r, s, v));
    }

    function test_guardian_moves_in_two_steps() public {
        vm.prank(guardian);
        factory.proposeGuardian(alice);
        vm.prank(bob);
        vm.expectRevert(StealthFactory.OnlyPendingGuardian.selector);
        factory.acceptGuardian();
        vm.prank(alice);
        factory.acceptGuardian();
        assertEq(factory.guardian(), alice);
    }

    function test_pending_pons_override_is_visible() public {
        pons.proposeRedirect(address(coin), alice);
        (address n,,) = vault.pendingOverride();
        assertEq(n, alice);
        pons.ownerRedirect(address(coin), alice);
        assertFalse(vault.feeRouteIntact());
    }

    // ── fuzz: whatever the split and the claims, the vault covers every unclaimed unit ──

    function testFuzz_vault_always_covers_unclaimed(uint96 taxWei, uint8 aShare, uint8 roundsN) public {
        uint256 tax = bound(uint256(taxWei), 0.02 ether, 5 ether);
        uint256 n = bound(uint256(roundsN), 1, 4);
        address[] memory who = new address[](2);
        (who[0], who[1]) = (alice, bob);
        uint256[] memory amt = new uint256[](2);
        bytes32[] memory leaves;
        for (uint256 k; k < n; k++) {
            _trade(curve, tax, 300);
            vm.prank(keeper);
            vault.runRound();
            uint256 assigned = vault.rounds(vault.roundCount()).cumulativeHolders;
            amt[0] = (assigned * bound(uint256(aShare), 0, 100)) / 100;
            amt[1] = assigned - amt[0];
            if (amt[0] < vault.claimed(alice)) amt[0] = vault.claimed(alice);
            if (amt[0] + amt[1] > assigned) amt[1] = assigned - amt[0];
            leaves = _roundWithRoot(vault, curve, who, amt, bytes32(k));
            vm.warp(block.timestamp + 2 hours);
            if (amt[0] > vault.claimed(alice)) {
                vm.prank(alice);
                vault.claim(amt[0], _proof(leaves, 0), alice, 20);
            }
            assertGe(usdg.balanceOf(address(vault)), vault.unclaimed());
            vm.warp(block.timestamp + 1 hours);
        }
        if (amt[1] > vault.claimed(bob)) {
            vm.prank(bob);
            vault.claim(amt[1], _proof(leaves, 1), deposit, 0);
        }
        assertGe(usdg.balanceOf(address(vault)), vault.unclaimed());
        assertEq(vault.totalClaimed(), vault.claimed(alice) + vault.claimed(bob));
    }
}
