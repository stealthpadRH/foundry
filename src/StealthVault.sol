// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsFactory, IPonsCurve, IPonsHook, IPonsFeeEscrow} from "./interfaces/IPons.sol";
import {IUniswapV3Pool, IWETH9, IERC20} from "./interfaces/IUniswapV3.sol";
import {IStealthFactory} from "./interfaces/IStealthFactory.sol";
import {FullMath} from "./lib/FullMath.sol";
import {TickMath} from "./lib/TickMath.sol";
import {Twap} from "./lib/Twap.sol";
import {MerkleProof} from "./lib/MerkleProof.sol";

/// @title StealthVault
/// @notice One per coin. It launches its coin on Pons V2 and is named, in the same transaction, as the
/// coin's deployer and creator fee recipient. Every wei of creator tax lands here and leaves in one
/// of four ways only: a holder's claim against a posted root, the round caller's tip, the $STEALTH
/// vault's share, and the treasury's share.
///
/// Deliberately absent: an owner, a withdraw, a rescue, a setter for any number below, an upgrade
/// path, delegatecall and selfdestruct.
///
/// Trust, stated plainly:
///  - The attester (read from the factory) computes each round's time-weighted snapshot off-chain and
///    signs a cumulative Merkle root. It never holds funds, but a wrong root would misassign unclaimed
///    USDG. So every root waits ROOT_DELAY before it can be claimed against, and during that window
///    the factory's guardian can veto it. Every leaf is published; anyone can recompute a root.
///  - The guardian can only veto a PENDING root. It cannot move funds, post a root, change the split
///    or the tax, or stop a round or a claim.
///  - The Pons V2 owner can queue a change of this coin's fee recipient behind a 3-day timelock.
///    Money already in this vault is untouchable by it; `pendingOverride()` exposes any such change.
contract StealthVault {
    // ── the numbers. Constants live in bytecode and have no setter by construction ──
    uint16 public constant HOLDERS_BPS = 9200;
    uint16 public constant CALLER_BPS = 300;
    uint16 public constant STEALTH_BPS = 250;
    uint16 public constant TREASURY_BPS = 250;
    uint256 public constant MIN_ROUND = 0.02 ether; // a round below this is not worth its gas
    uint64 public constant COOLDOWN = 1 hours; // between two rounds of this coin
    uint64 public constant ROOT_DELAY = 2 hours; // a root is claimable this long after it is posted
    uint16 public constant MAX_ROUTE_FEE_BPS = 20; // the most a claim may pay the treasury (0.20%)
    uint16 public constant IMPACT_CAP_BPS = 100; // one round's swap takes at most 1% of the pool's USDG
    uint16 public constant SLIPPAGE_BPS = 150; // vs the pool's own 30-minute TWAP
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;

    // ── wiring, fixed at construction ──
    struct Wiring {
        IPonsFactory pons;
        IPonsFeeEscrow escrow;
        address hook;
        IWETH9 weth;
        IERC20 usdg;
        IUniswapV3Pool pool; // WETH/USDG, Uniswap v3
        address treasury;
    }

    IStealthFactory public immutable factory;
    IPonsFactory public immutable pons;
    IPonsFeeEscrow public immutable escrow;
    address public immutable hook;
    IWETH9 public immutable weth;
    IERC20 public immutable usdg;
    IUniswapV3Pool public immutable pool;
    bool public immutable wethIsToken0;
    address public immutable treasury;
    uint16 public immutable taxBps; // the coin's creator tax, 100..500, fixed at launch by Pons

    // ── set exactly once, by launch() ──
    address public token;
    address public curve;
    uint24 public poolFee;
    int24 public tickSpacing;

    // ── rounds ──
    struct Round {
        uint64 at; // timestamp of the round
        uint128 ethBudget; // ETH the round split
        uint128 holdersUsdg; // USDG the round added for holders
        uint256 cumulativeHolders; // holders' USDG from round 1 through this one
    }

    Round[] private _rounds;
    uint64 public lastRoundAt;

    // ── roots: one active, at most one pending ──
    struct Root {
        bytes32 root;
        uint256 total; // cumulative USDG assigned to holders by this root
        uint64 roundId; // the last round it covers (1-based)
        uint64 activeAt; // when it becomes claimable
        bytes32 seed; // the snapshot seed the attester used (the hash of the round's block)
    }

    Root private _active;
    Root private _pending;

    // ── claims ──
    mapping(address holder => uint256 cumulative) public claimed;
    uint256 public totalClaimed;

    // ── lifetime totals, for anyone who wants to check the page against the chain ──
    uint256 public totalEthIn;
    uint256 public totalTips;
    uint256 public totalToStealth;
    uint256 public totalToTreasury;
    uint256 public totalRouteFees;

    bytes32 public constant POST_ROOT_TYPEHASH =
        keccak256("PostRoot(uint64 roundId,bytes32 root,uint256 total,bytes32 seed)");
    bytes32 private immutable _domainSeparator;
    uint256 private immutable _domainChainId;

    uint256 private _lock = 1;
    bool private _inSwap;

    event Launched(address indexed token, address indexed curve, uint16 taxBps);
    event FeesClaimed(uint256 amount);
    event RoundRun(
        uint64 indexed roundId,
        address indexed caller,
        uint256 ethBudget,
        uint256 usdgToHolders,
        uint256 tip,
        uint256 toStealth,
        uint256 toTreasury
    );
    event RootPosted(uint64 indexed roundId, bytes32 root, uint256 total, bytes32 seed, uint64 activeAt);
    event RootVetoed(uint64 indexed roundId, bytes32 root);
    event RootActivated(uint64 indexed roundId, bytes32 root, uint256 total);
    event Claimed(address indexed holder, address indexed to, uint256 amount, uint256 fee, uint64 rootRound);

    error OnlyFactory();
    error AlreadyLaunched();
    error NotLaunched();
    error Reentrancy();
    error CoolingDown(uint256 availableAt);
    error BelowMinimum(uint256 budget);
    error SwapOutTooLow(uint256 out, uint256 minOut);
    error OnlyPool();
    error TipFailed();
    error PendingRoot(uint256 activeAt);
    error BadRound();
    error StaleRound();
    error TotalDecreased();
    error TotalTooHigh(uint256 total, uint256 available);
    error BadSignature();
    error OnlyGuardian();
    error NothingToVeto();
    error FeeTooHigh();
    error BadRecipient();
    error BadProof();
    error NothingToClaim();
    error TransferFailed();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(Wiring memory w, uint16 taxBps_, address factory_) {
        factory = IStealthFactory(factory_);
        pons = w.pons;
        escrow = w.escrow;
        hook = w.hook;
        weth = w.weth;
        usdg = w.usdg;
        pool = w.pool;
        wethIsToken0 = w.pool.token0() == address(w.weth);
        treasury = w.treasury;
        taxBps = taxBps_;
        _domainChainId = block.chainid;
        _domainSeparator = _buildDomainSeparator();
    }

    /// Creator tax arrives from the escrow's claim; the $STEALTH vault also receives other vaults'
    /// shares here. Anyone may add to the next round's budget.
    receive() external payable {}

    // ─────────────────────────────────────────────────────────────────────────────
    // Launch: once, by the factory, in the transaction that deployed this vault
    // ─────────────────────────────────────────────────────────────────────────────

    struct LaunchInput {
        string name;
        string symbol;
        string logo;
        string description;
        IPonsFactory.Socials socials;
        bytes32 salt;
    }

    /// @param buyer receives the optional first buy, paid by any ETH sent beyond the launch fee
    function launch(LaunchInput calldata input, address buyer, uint256 minTokensOut)
        external
        payable
        nonReentrant
        returns (address token_)
    {
        if (msg.sender != address(factory)) revert OnlyFactory();
        if (token != address(0)) revert AlreadyLaunched();

        uint256 fee = pons.launchFee();
        address[] memory exempt = new address[](1);
        exempt[0] = buyer; // the launcher's own first buy is not charged the launch-second snipe tax

        // The fields that make this a Stealthpad coin are filled here, never taken from the caller.
        IPonsFactory.TokenParams memory params = IPonsFactory.TokenParams({
            name: input.name,
            symbol: input.symbol,
            logo: input.logo,
            description: input.description,
            socials: input.socials,
            creatorFeeRecipient: address(this),
            creatorTaxBps: taxBps,
            buybackEnabled: false,
            expectedEconomics: pons.previewLaunchEconomics(0, address(0)),
            salt: input.salt
        });

        address curve_;
        (token_, curve_) = pons.launchToken{value: fee}(params, 0, address(0), exempt);
        token = token_;
        curve = curve_;
        (poolFee, tickSpacing) = _readPoolTerms(token_);
        emit Launched(token_, curve_, taxBps);

        uint256 rest = msg.value - fee;
        if (rest != 0) IPonsCurve(curve_).buy{value: rest}(rest, minTokensOut, buyer);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Fees in. Anyone may call.
    // ─────────────────────────────────────────────────────────────────────────────

    /// Moves accrued creator tax into the escrow where this vault is allowed to, then claims whatever
    /// the escrow holds for it. Each step is best-effort: nothing to sweep is not an error.
    function sweepAndClaim() public returns (uint256 got) {
        if (token == address(0)) revert NotLaunched();
        if (!IPonsCurve(curve).graduated()) {
            try IPonsCurve(curve).sweepFees(0) {} catch {}
        } else {
            // Works only while no coin-side fees wait for conversion; otherwise the launchpad's
            // operator runs the sweep and credits the escrow, and this call is a no-op.
            try IPonsHook(hook).sweepPoolFees(poolId(), 0, 0) {} catch {}
        }
        if (escrow.balanceOf(address(this)) != 0) {
            got = escrow.claim();
            emit FeesClaimed(got);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Rounds. Anyone may call. The caller pays the gas and is paid CALLER_BPS of the round, in ETH.
    // ─────────────────────────────────────────────────────────────────────────────

    function runRound() external nonReentrant returns (uint64 roundId) {
        if (token == address(0)) revert NotLaunched();
        uint256 ready = uint256(lastRoundAt) + COOLDOWN;
        if (lastRoundAt != 0 && block.timestamp < ready) revert CoolingDown(ready);

        sweepAndClaim();

        uint256 budget = address(this).balance;
        if (budget < MIN_ROUND) revert BelowMinimum(budget);
        uint256 price = Twap.price(address(pool), wethIsToken0); // USDG raw per 1e18 wei
        uint256 cap = _roundCap(price);
        if (budget > cap) budget = cap; // the rest waits for the next round

        uint256 tip = (budget * CALLER_BPS) / BPS;
        uint256 toStealth = (budget * STEALTH_BPS) / BPS;
        uint256 toTreasury = (budget * TREASURY_BPS) / BPS;
        uint256 holdersEth = budget - tip - toStealth - toTreasury;

        address sink = factory.stealthSink();
        if (sink == address(this)) {
            // The $STEALTH vault's own share would pay itself: it stays with $STEALTH holders.
            holdersEth += toStealth;
            toStealth = 0;
        }

        uint256 usdgOut = _ethToUsdg(holdersEth, price);

        uint256 prev = _rounds.length == 0 ? 0 : _rounds[_rounds.length - 1].cumulativeHolders;
        _rounds.push(
            Round({
                at: uint64(block.timestamp),
                ethBudget: uint128(budget),
                holdersUsdg: uint128(usdgOut),
                cumulativeHolders: prev + usdgOut
            })
        );
        roundId = uint64(_rounds.length);
        lastRoundAt = uint64(block.timestamp);
        totalEthIn += budget;

        // A sink that refuses ETH must not block a round: the $STEALTH share falls back to the
        // treasury, and a refused treasury share simply stays here as next round's budget.
        if (toStealth != 0) {
            (bool okS,) = payable(sink).call{value: toStealth}("");
            if (!okS) {
                toTreasury += toStealth;
                toStealth = 0;
            }
        }
        if (toTreasury != 0) {
            (bool okT,) = payable(treasury).call{value: toTreasury}("");
            if (!okT) toTreasury = 0;
        }
        totalToStealth += toStealth;
        totalToTreasury += toTreasury;

        (bool okC,) = payable(msg.sender).call{value: tip}("");
        if (!okC) revert TipFailed();
        totalTips += tip;

        emit RoundRun(roundId, msg.sender, budget, usdgOut, tip, toStealth, toTreasury);
    }

    /// The most ETH one round may split: its holders' swap stays inside IMPACT_CAP_BPS of the pool's USDG.
    function _roundCap(uint256 price) private view returns (uint256) {
        uint256 usdgCap = (usdg.balanceOf(address(pool)) * IMPACT_CAP_BPS) / BPS;
        uint256 ethCap = FullMath.mulDiv(usdgCap, WAD, price);
        return FullMath.mulDiv(ethCap, BPS, HOLDERS_BPS);
    }

    /// Exact-input WETH → USDG on Uniswap v3, min out from the pool's own 30-minute TWAP.
    function _ethToUsdg(uint256 ethIn, uint256 price) private returns (uint256 usdgOut) {
        if (ethIn == 0) return 0;
        uint256 minOut = FullMath.mulDiv(FullMath.mulDiv(ethIn, price, WAD), BPS - SLIPPAGE_BPS, BPS);
        weth.deposit{value: ethIn}();
        uint256 before = usdg.balanceOf(address(this));
        _inSwap = true;
        pool.swap(
            address(this),
            wethIsToken0,
            int256(ethIn),
            wethIsToken0 ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1,
            ""
        );
        _inSwap = false;
        usdgOut = usdg.balanceOf(address(this)) - before;
        if (usdgOut < minOut) revert SwapOutTooLow(usdgOut, minOut);
    }

    /// Uniswap v3 asks for the input token here, inside swap().
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata) external {
        if (msg.sender != address(pool) || !_inSwap) revert OnlyPool();
        int256 owed = wethIsToken0 ? amount0Delta : amount1Delta;
        if (owed > 0 && !weth.transfer(msg.sender, uint256(owed))) revert TransferFailed();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Roots. Anyone may relay the attester's signature. One pending root at a time.
    // ─────────────────────────────────────────────────────────────────────────────

    function postRoot(uint64 roundId, bytes32 root, uint256 total, bytes32 seed, bytes calldata signature)
        external
        nonReentrant
    {
        _promote();
        if (_pending.activeAt != 0) revert PendingRoot(_pending.activeAt);
        if (roundId == 0 || roundId > _rounds.length) revert BadRound();
        if (roundId <= _active.roundId) revert StaleRound();
        if (total < _active.total) revert TotalDecreased();
        uint256 available = _rounds[roundId - 1].cumulativeHolders;
        if (total > available) revert TotalTooHigh(total, available);
        if (_recover(hashPostRoot(roundId, root, total, seed), signature) != factory.attester()) revert BadSignature();

        uint64 activeAt = uint64(block.timestamp) + ROOT_DELAY;
        _pending = Root({root: root, total: total, roundId: roundId, activeAt: activeAt, seed: seed});
        emit RootPosted(roundId, root, total, seed, activeAt);
    }

    /// The guardian's one power over a vault: stop a pending root before it becomes claimable.
    function veto() external {
        if (msg.sender != factory.guardian()) revert OnlyGuardian();
        if (_pending.activeAt == 0 || block.timestamp >= _pending.activeAt) revert NothingToVeto();
        emit RootVetoed(_pending.roundId, _pending.root);
        delete _pending;
    }

    /// Makes a matured pending root the active one. Claims and postRoot do this on their own.
    function promote() external {
        _promote();
    }

    function _promote() private {
        if (_pending.activeAt != 0 && block.timestamp >= _pending.activeAt) {
            _active = _pending;
            delete _pending;
            emit RootActivated(_active.roundId, _active.root, _active.total);
        }
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Claims. Cumulative: one claim collects every round since the last one. Nothing expires.
    // ─────────────────────────────────────────────────────────────────────────────

    /// @param cumulative the holder's total to date in the active root
    /// @param to the holder's wallet, or the deposit address of the holder's own route quote
    /// @param feeBps the route fee to the treasury, at most MAX_ROUTE_FEE_BPS (0 for a USDG claim)
    function claim(uint256 cumulative, bytes32[] calldata proof, address to, uint16 feeBps)
        external
        nonReentrant
        returns (uint256 paid)
    {
        _promote();
        if (feeBps > MAX_ROUTE_FEE_BPS) revert FeeTooHigh();
        if (to == address(0) || to == address(this)) revert BadRecipient();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, cumulative))));
        if (!MerkleProof.verify(proof, _active.root, leaf)) revert BadProof();
        uint256 already = claimed[msg.sender];
        if (cumulative <= already) revert NothingToClaim();

        uint256 due = cumulative - already;
        claimed[msg.sender] = cumulative;
        totalClaimed += due;

        uint256 fee = (due * feeBps) / BPS;
        if (fee != 0) {
            totalRouteFees += fee;
            _pay(treasury, fee);
        }
        paid = due - fee;
        _pay(to, paid);
        emit Claimed(msg.sender, to, due, fee, _active.roundId);
    }

    function _pay(address to, uint256 amount) private {
        (bool ok, bytes memory ret) = address(usdg).call(abi.encodeCall(IERC20.transfer, (to, amount)));
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TransferFailed();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Views: everything a keeper, a verifier or the app needs, with no backend in between
    // ─────────────────────────────────────────────────────────────────────────────

    function roundCount() external view returns (uint256) {
        return _rounds.length;
    }

    function rounds(uint256 roundId) external view returns (Round memory) {
        if (roundId == 0 || roundId > _rounds.length) revert BadRound();
        return _rounds[roundId - 1];
    }

    function activeRoot() external view returns (Root memory r) {
        r = _active;
        if (_pending.activeAt != 0 && block.timestamp >= _pending.activeAt) r = _pending;
    }

    function pendingRoot() external view returns (Root memory r) {
        if (_pending.activeAt != 0 && block.timestamp < _pending.activeAt) r = _pending;
    }

    /// ETH the next round would see before its cap: this balance, the escrow's credit, and creator
    /// tax still sitting in the curve (before graduation).
    function pendingEth() public view returns (uint256 total) {
        total = address(this).balance + escrow.balanceOf(address(this));
        if (token != address(0) && !IPonsCurve(curve).graduated()) {
            try IPonsCurve(curve).creatorTaxBalance() returns (uint256 t) {
                total += t;
            } catch {}
        }
    }

    function nextRoundAt() public view returns (uint256) {
        return lastRoundAt == 0 ? 0 : uint256(lastRoundAt) + COOLDOWN;
    }

    function roundReady() external view returns (bool) {
        return token != address(0) && block.timestamp >= nextRoundAt() && pendingEth() >= MIN_ROUND;
    }

    /// USDG in the vault that belongs to holders and has not been claimed yet.
    function unclaimed() external view returns (uint256) {
        uint256 assigned = _rounds.length == 0 ? 0 : _rounds[_rounds.length - 1].cumulativeHolders;
        return assigned - totalClaimed;
    }

    function poolKey()
        public
        view
        returns (address currency0, address currency1, uint24 fee, int24 spacing, address hooks)
    {
        return (address(0), token, poolFee, tickSpacing, hook);
    }

    function poolId() public view returns (bytes32) {
        return keccak256(abi.encode(address(0), token, poolFee, tickSpacing, hook));
    }

    /// True while the launchpad still records this vault as the coin's creator fee recipient.
    function feeRouteIntact() external view returns (bool) {
        return address(uint160(uint256(_launchedWord(token, 3)))) == address(this);
    }

    /// A pending launchpad-owner override of this coin's fee recipient, if one exists.
    function pendingOverride() external view returns (address newRecipient, uint256 effectiveAt, uint256 expiresAt) {
        return pons.pendingCreatorFeeRecipient(token);
    }

    function hashPostRoot(uint64 roundId, bytes32 root, uint256 total, bytes32 seed) public view returns (bytes32) {
        bytes32 structHash = keccak256(abi.encode(POST_ROOT_TYPEHASH, roundId, root, total, seed));
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function domainSeparator() public view returns (bytes32) {
        return block.chainid == _domainChainId ? _domainSeparator : _buildDomainSeparator();
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // internals
    // ─────────────────────────────────────────────────────────────────────────────

    /// getLaunchedToken returns a struct of static members, one word each, in order:
    /// token, curve, deployer, creatorFeeRecipient, pairToken, graduationThreshold, poolFee,
    /// tickSpacing, creatorTaxBps, buybackEnabled, phase. Reading words avoids importing the struct.
    function _launchedWord(address token_, uint256 index) private view returns (bytes32 word) {
        (bool ok, bytes memory ret) =
            address(pons).staticcall(abi.encodeWithSignature("getLaunchedToken(address)", token_));
        if (!ok || ret.length < (index + 1) * 32) return bytes32(0);
        assembly {
            word := mload(add(ret, mul(add(index, 1), 32)))
        }
    }

    function _readPoolTerms(address token_) private view returns (uint24 fee_, int24 spacing_) {
        fee_ = uint24(uint256(_launchedWord(token_, 6)));
        spacing_ = int24(int256(uint256(_launchedWord(token_, 7))));
    }

    function _buildDomainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("Stealthpad"),
                keccak256("1"),
                block.chainid,
                address(this)
            )
        );
    }

    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address) {
        if (sig.length != 65) return address(0);
        bytes32 r = bytes32(sig[0:32]);
        bytes32 s = bytes32(sig[32:64]);
        uint8 v = uint8(sig[64]);
        // reject the malleable upper half of the curve
        if (uint256(s) > 0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0) return address(0);
        if (v != 27 && v != 28) return address(0);
        return ecrecover(digest, v, r, s);
    }
}
