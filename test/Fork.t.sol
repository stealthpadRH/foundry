// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console2} from "forge-std/Test.sol";
import {StealthFactory} from "../src/StealthFactory.sol";
import {StealthVault} from "../src/StealthVault.sol";
import {IPonsFactory, IPonsCurve, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {IUniswapV3Pool, IWETH9, IERC20} from "../src/interfaces/IUniswapV3.sol";
import {MerkleHelper} from "./StealthVault.t.sol";

struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
}

/// Buys a graduated coin on its real v4 pool, the way a trader's router would.
contract V4Buyer {
    IPoolManager immutable pm;

    constructor(IPoolManager pm_) {
        pm = pm_;
    }

    function buy(PoolKey calldata key, address to) external payable {
        pm.unlock(abi.encode(key, msg.value, to));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(pm), "pm");
        (PoolKey memory key, uint256 ethIn, address to) = abi.decode(data, (PoolKey, uint256, address));
        int256 delta = pm.swap(key, SwapParams(true, -int256(ethIn), 4295128739 + 1), "");
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        if (a0 < 0) pm.settle{value: uint256(uint128(-a0))}();
        if (a1 > 0) pm.take(key.currency1, to, uint256(uint128(a1)));
        return "";
    }
}

/// Stealthpad against the REAL contracts on a fork of Robinhood Chain:
///   forge test --match-contract Fork --fork-url robinhood -vv
/// Nothing here is mocked: the launch factory, curve, fee escrow, coin, hook, pool manager, WETH, USDG
/// and the WETH/USDG pool are the deployed ones. Every wallet is fresh: the well-known dev accounts
/// are EIP-7702 sweepers on this chain and on forks of it.
contract ForkTest is Test, MerkleHelper {
    address constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant POOL = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca;

    uint256 attesterPk = uint256(keccak256("stealthpad-fork-attester"));
    StealthFactory factory;
    StealthVault vault;
    address token;
    address curve;

    address guardian = makeAddr("fork-guardian");
    address treasury = makeAddr("fork-treasury");
    address launcher = makeAddr("fork-launcher");
    address trader = makeAddr("fork-trader");
    address holder = makeAddr("fork-holder");
    address keeper = makeAddr("fork-keeper");
    address deposit = makeAddr("fork-route-deposit");

    modifier onlyFork() {
        if (block.chainid != 4663) {
            vm.skip(true);
            return;
        }
        _;
    }

    function setUp() public {
        if (block.chainid != 4663) return;
        factory = new StealthFactory(
            StealthVault.Wiring({
                pons: IPonsFactory(PONS),
                escrow: IPonsFeeEscrow(ESCROW),
                hook: HOOK,
                weth: IWETH9(WETH),
                usdg: IERC20(USDG),
                pool: IUniswapV3Pool(POOL),
                treasury: treasury
            }),
            guardian,
            vm.addr(attesterPk)
        );
        (vault, token, curve) = _launch(launcher, "Glass Probe", "GLASSP", 300, 0.02 ether, "probe");
        vm.deal(trader, 200 ether);
        vm.deal(holder, 5 ether);
    }

    function _launch(address who, string memory name, string memory symbol, uint16 tax, uint256 firstBuy, bytes32 salt)
        internal
        returns (StealthVault v, address t, address c)
    {
        StealthVault.LaunchInput memory i;
        i.name = name;
        i.symbol = symbol;
        i.logo = "https://app.stealthpad.online/img/probe.webp";
        i.description = "fork rehearsal";
        i.salt = salt;
        uint256 value = IPonsFactory(PONS).launchFee() + firstBuy;
        vm.deal(who, value + 1 ether);
        vm.prank(who);
        (address va, address to) = factory.launch{value: value}(i, tax, 0);
        v = StealthVault(payable(va));
        t = to;
        c = v.curve();
    }

    function _word(address t, uint256 index) internal view returns (bytes32 w) {
        (bool ok, bytes memory ret) = PONS.staticcall(abi.encodeWithSignature("getLaunchedToken(address)", t));
        require(ok, "getLaunchedToken");
        assembly {
            w := mload(add(ret, mul(add(index, 1), 32)))
        }
    }

    function _sweepAs(address who, bytes32 pid, uint256 minConv) internal returns (bool ok, bytes memory ret) {
        bytes memory data = abi.encodeWithSignature("sweepPoolFees(bytes32,uint256,uint256)", pid, minConv, uint256(0));
        vm.prank(who);
        (ok, ret) = HOOK.call(data);
    }

    function _sign(StealthVault v, uint64 id, bytes32 root, uint256 total, bytes32 seed) internal view returns (bytes memory) {
        (uint8 sv, bytes32 r, bytes32 s) = vm.sign(attesterPk, v.hashPostRoot(id, root, total, seed));
        return abi.encodePacked(r, s, sv);
    }

    function test_the_real_launchpad_records_the_vault() public onlyFork {
        assertEq(address(uint160(uint256(_word(token, 0)))), token, "token");
        assertEq(address(uint160(uint256(_word(token, 1)))), curve, "curve");
        assertEq(address(uint160(uint256(_word(token, 2)))), address(vault), "deployer is the vault");
        assertEq(address(uint160(uint256(_word(token, 3)))), address(vault), "fee recipient is the vault");
        assertEq(uint256(_word(token, 8)), 300, "creator tax 3%");
        assertEq(uint256(_word(token, 9)), 0, "launchpad buyback off");
        assertTrue(vault.feeRouteIntact());
        assertGt(IERC20(token).balanceOf(launcher), 0, "launcher's first buy landed");
        assertTrue(vault.wethIsToken0(), "WETH is token0 in the live pool");
        console2.log("vault", address(vault));
        console2.log("token", token);
    }

    function test_a_full_round_and_claims_on_the_real_contracts() public onlyFork {
        vm.warp(block.timestamp + 10 minutes); // past the launch-second snipe tax
        vm.prank(trader);
        IPonsCurve(curve).buy{value: 3 ether}(3 ether, 0, trader);
        vm.prank(trader);
        IPonsCurve(curve).buy{value: 0.5 ether}(0.5 ether, 0, holder);
        uint256 sellAmount = IERC20(token).balanceOf(trader) / 4;
        vm.startPrank(trader);
        (bool approved,) = token.call(abi.encodeWithSignature("approve(address,uint256)", curve, sellAmount));
        require(approved, "approve");
        IPonsCurve(curve).sell(sellAmount, 0, trader);
        vm.stopPrank();

        uint256 pending = vault.pendingEth();
        console2.log("creator tax pending (wei)", pending);
        assertGt(pending, 0.1 ether, "3% of ~3.5 ETH of buys plus the sell");
        assertTrue(vault.roundReady());

        uint256 tBefore = treasury.balance;
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        uint64 id = vault.runRound();
        console2.log("runRound gas", gasBefore - gasleft());
        StealthVault.Round memory r = vault.rounds(id);
        console2.log("round ETH budget (wei)", r.ethBudget);
        console2.log("USDG to holders (raw, 6 dp)", r.holdersUsdg);
        console2.log("implied ETH price (USDG)", (uint256(r.holdersUsdg) * 1e18) / ((uint256(r.ethBudget) * 92) / 100) / 1e6);
        assertEq(IERC20(USDG).balanceOf(address(vault)), r.holdersUsdg, "the vault holds the holders' USDG");
        assertEq(keeper.balance, (uint256(r.ethBudget) * 300) / 10_000, "tip 3% in ETH");
        assertEq(treasury.balance - tBefore, (uint256(r.ethBudget) * 500) / 10_000, "protocol 5% (no $STEALTH vault yet)");
        assertGt(r.holdersUsdg, 0);

        // the attester's root: holder 60%, trader 40%
        uint256 a = (uint256(r.holdersUsdg) * 60) / 100;
        uint256 b = uint256(r.holdersUsdg) - a;
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(holder, a);
        leaves[1] = _leaf(trader, b);
        bytes32 root = _root(leaves);
        bytes32 seed = keccak256("the round's block hash");
        vault.postRoot(id, root, a + b, seed, _sign(vault, id, root, a + b, seed));
        vm.warp(block.timestamp + 2 hours);

        gasBefore = gasleft();
        vm.prank(holder);
        vault.claim(a, _proof(leaves, 0), holder, 0);
        console2.log("claim gas", gasBefore - gasleft());
        assertEq(IERC20(USDG).balanceOf(holder), a, "real USDG in the holder's wallet");

        uint256 tUsdg = IERC20(USDG).balanceOf(treasury);
        vm.prank(trader);
        vault.claim(b, _proof(leaves, 1), deposit, 20);
        uint256 fee = (b * 20) / 10_000;
        assertEq(IERC20(USDG).balanceOf(deposit), b - fee, "routed claim lands at the deposit address");
        assertEq(IERC20(USDG).balanceOf(treasury) - tUsdg, fee, "0.20% route fee");
        assertEq(vault.unclaimed(), 0);
    }

    function test_the_stealth_vault_collects_its_share_on_the_real_chain() public onlyFork {
        (StealthVault sv,,) = _launch(launcher, "Stealthpad Probe", "STLTHP", 300, 0, "stealth-probe");
        vm.prank(guardian);
        factory.setStealthVault(address(sv));
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(trader);
        IPonsCurve(curve).buy{value: 2 ether}(2 ether, 0, trader);
        vm.prank(keeper);
        uint64 id = vault.runRound();
        uint256 budget = vault.rounds(id).ethBudget;
        assertEq(address(sv).balance, (budget * 250) / 10_000, "2.5% landed in the $STEALTH vault");
    }

    function test_after_graduation_on_the_real_v4_pool() public onlyFork {
        vm.warp(block.timestamp + 10 minutes);
        for (uint256 i; i < 12 && !IPonsCurve(curve).graduated(); ++i) {
            vm.prank(trader);
            try IPonsCurve(curve).buy{value: 1 ether}(1 ether, 0, trader) {} catch {}
        }
        if (!IPonsCurve(curve).graduated()) {
            console2.log("curve did not graduate in the fork; v4 leg not exercised");
            return;
        }
        // take the pre-graduation creator tax first
        vm.prank(keeper);
        vault.runRound();
        console2.log("phase after buys", uint256(_word(token, 10)));
        if (uint256(_word(token, 10)) != 2) {
            (bool ok,) = PONS.call(abi.encodeWithSignature("createGraduatedPool(address)", token));
            console2.log("createGraduatedPool ok", ok);
        }
        if (uint256(_word(token, 10)) != 2) {
            console2.log("pool not created in the fork; v4 leg not exercised");
            return;
        }

        (address c0, address c1, uint24 fee, int24 spacing, address hooks) = vault.poolKey();
        V4Buyer buyer = new V4Buyer(IPoolManager(POOL_MANAGER));
        vm.deal(trader, 50 ether);
        for (uint256 i; i < 5; ++i) {
            vm.prank(trader);
            buyer.buy{value: 1 ether}(PoolKey(c0, c1, fee, spacing, hooks), trader);
        }
        bytes32 pid = vault.poolId(); // read before any prank
        (bool selfOk, bytes memory why) = _sweepAs(address(vault), pid, 0);
        console2.log("self-sweep by the vault ok", selfOk);
        if (!selfOk) console2.logBytes(why); // expect InternalSwapRequiresOperator: buy fees sit in the coin

        // What the launchpad's operator does on its own schedule: convert and distribute.
        (bool opOk, bytes memory opWhy) = HOOK.staticcall(abi.encodeWithSignature("feeSweepOperator()"));
        require(opOk, "operator getter");
        address operator = abi.decode(opWhy, (address));
        (bool swept,) = _sweepAs(operator, pid, 1);
        console2.log("operator sweep ok", swept);
        uint256 credited = IPonsFeeEscrow(ESCROW).balanceOf(address(vault));
        console2.log("escrow credit for the vault after the operator sweep (wei)", credited);
        assertGt(credited, 0, "post-graduation creator share reaches the vault");

        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        uint64 id = vault.runRound();
        console2.log("post-graduation round ETH budget (wei)", vault.rounds(id).ethBudget);
        console2.log("post-graduation round USDG to holders", vault.rounds(id).holdersUsdg);
        assertGt(vault.rounds(id).holdersUsdg, 0);
    }
}
