// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IPonsFactory} from "../src/interfaces/IPons.sol";
import {TickMath} from "../src/lib/TickMath.sol";
import {FullMath} from "../src/lib/FullMath.sol";

/// Stand-ins for the launchpad, WETH, USDG and the Uniswap v3 pool, shaped like the verified sources:
/// fee and creator tax ride the quote leg of a buy, only the deployer may sweep, the escrow is a pull
/// ledger paid by call, and the pool pulls its input through the swap callback.

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;

    constructor(string memory n, string memory s, uint8 d) {
        name = n;
        symbol = s;
        decimals = d;
    }

    function mint(address to, uint256 v) public {
        totalSupply += v;
        balanceOf[to] += v;
    }

    function transfer(address to, uint256 v) public virtual returns (bool) {
        balanceOf[msg.sender] -= v;
        balanceOf[to] += v;
        return true;
    }

    function burn(uint256 v) external {
        balanceOf[msg.sender] -= v;
        totalSupply -= v;
    }
}

contract MockWETH is MockERC20 {
    constructor() MockERC20("Wrapped Ether", "WETH", 18) {}

    function deposit() external payable {
        mint(msg.sender, msg.value);
    }

    function withdraw(uint256 v) external {
        balanceOf[msg.sender] -= v;
        totalSupply -= v;
        payable(msg.sender).transfer(v);
    }
}

interface ISwapCallback {
    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes calldata data) external;
}

/// WETH/USDG pool. Fills exact-input WETH at the price of `tick`, minus `fillLossBps` to simulate a
/// bad fill. Holds real USDG inventory, so the vault's impact cap reads a real balance.
contract MockV3Pool {
    address public token0;
    address public token1;
    int24 public tick;
    uint16 public fillLossBps;
    bool public tooOld;

    constructor(address t0, address t1, int24 tick_) {
        token0 = t0;
        token1 = t1;
        tick = tick_;
    }

    function setTick(int24 t) external {
        tick = t;
    }

    function setFillLoss(uint16 bps) external {
        fillLossBps = bps;
    }

    function setTooOld(bool v) external {
        tooOld = v;
    }

    function slot0() external view returns (uint160, int24, uint16, uint16, uint16, uint8, bool) {
        return (TickMath.getSqrtRatioAtTick(tick), tick, 0, 1000, 1000, 0, true);
    }

    function observe(uint32[] calldata secondsAgos) external view returns (int56[] memory cum, uint160[] memory spl) {
        require(!tooOld, "OLD");
        cum = new int56[](secondsAgos.length);
        spl = new uint160[](secondsAgos.length);
        for (uint256 i; i < secondsAgos.length; i++) {
            cum[i] = int56(tick) * int56(int256(block.timestamp - secondsAgos[i]));
        }
    }

    function increaseObservationCardinalityNext(uint16) external {}

    /// token1 raw per 1e18 token0 raw at `tick`
    function _price1Per0() internal view returns (uint256) {
        uint160 s = TickMath.getSqrtRatioAtTick(tick);
        return FullMath.mulDiv(FullMath.mulDiv(s, s, 2 ** 96), 1e18, 2 ** 96);
    }

    function swap(address recipient, bool zeroForOne, int256 amountSpecified, uint160, bytes calldata data)
        external
        returns (int256 amount0, int256 amount1)
    {
        require(amountSpecified > 0, "exact input only");
        uint256 amountIn = uint256(amountSpecified);
        uint256 out;
        if (zeroForOne) out = FullMath.mulDiv(amountIn, _price1Per0(), 1e18);
        else out = FullMath.mulDiv(amountIn, 1e18, _price1Per0());
        out = (out * (10_000 - fillLossBps)) / 10_000;

        address tIn = zeroForOne ? token0 : token1;
        address tOut = zeroForOne ? token1 : token0;
        uint256 before = MockERC20(tIn).balanceOf(address(this));
        MockERC20(tOut).transfer(recipient, out);
        (amount0, amount1) = zeroForOne ? (int256(amountIn), -int256(out)) : (-int256(out), int256(amountIn));
        ISwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        require(MockERC20(tIn).balanceOf(address(this)) >= before + amountIn, "IIA");
    }
}

contract MockEscrow {
    mapping(address => uint256) public balanceOf;

    function credit(address recipient) external payable {
        balanceOf[recipient] += msg.value;
    }

    function claim() external returns (uint256 amount) {
        amount = balanceOf[msg.sender];
        balanceOf[msg.sender] = 0;
        (bool ok,) = payable(msg.sender).call{value: amount}("");
        require(ok, "claim pay failed");
    }
}

contract MockCurve {
    uint256 public constant PHANTOM = 1.68 ether;
    uint256 public constant FEE_BPS = 100;
    MockERC20 public immutable token;
    MockEscrow public immutable escrow;
    address public immutable deployer;
    address public creatorFeeRecipient;
    uint256 public creatorTaxBps;
    uint256 public trackedQuote;
    uint256 public quoteFeeBalance;
    uint256 public creatorTaxBalance;
    bool public graduated;

    constructor(MockERC20 t, MockEscrow e, address deployer_, address recipient, uint256 taxBps) {
        token = t;
        escrow = e;
        deployer = deployer_;
        creatorFeeRecipient = recipient;
        creatorTaxBps = taxBps;
    }

    function getReserves() public view returns (uint256 quoteReserve, uint256 tokenReserve) {
        quoteReserve = PHANTOM + trackedQuote - quoteFeeBalance - creatorTaxBalance;
        tokenReserve = token.balanceOf(address(this));
    }

    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 out) {
        require(!graduated, "graduated");
        require(msg.value == quoteIn && quoteIn != 0, "value");
        (uint256 q, uint256 t) = getReserves();
        uint256 fee = (quoteIn * FEE_BPS) / 10_000;
        uint256 tax = (quoteIn * creatorTaxBps) / 10_000;
        uint256 net = quoteIn - fee - tax;
        out = (net * t) / (q + net);
        require(out >= minTokensOut, "slippage");
        trackedQuote += quoteIn;
        quoteFeeBalance += fee;
        creatorTaxBalance += tax;
        token.transfer(recipient, out);
    }

    function sweepFees(uint256) external {
        require(msg.sender == deployer, "NotFeeSweepOperator");
        uint256 tax = creatorTaxBalance;
        uint256 fee = quoteFeeBalance;
        creatorTaxBalance = 0;
        quoteFeeBalance = 0;
        trackedQuote -= (tax + fee);
        if (tax != 0) escrow.credit{value: tax}(creatorFeeRecipient);
        if (fee != 0) payable(address(0xFEE)).transfer(fee);
    }

    function setGraduated(bool g) external {
        graduated = g;
    }
}

contract MockPons {
    struct LaunchedToken {
        address token;
        address curve;
        address deployer;
        address creatorFeeRecipient;
        address pairToken;
        uint256 graduationThreshold;
        uint24 poolFee;
        int24 tickSpacing;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        uint8 phase;
        uint256 sweptQuote;
        uint256 sweptTokens;
        uint256 sweptAt;
        bool exists;
    }

    MockEscrow public immutable escrow;
    uint256 public launchFee = 0.0005 ether;
    mapping(address => LaunchedToken) internal _launched;
    mapping(address => address) public pendingRecipient;
    address[] public lastExempt;

    constructor(MockEscrow e) {
        escrow = e;
    }

    function previewLaunchEconomics(uint256, address) external pure returns (bytes32) {
        return keccak256("econ");
    }

    function launchToken(IPonsFactory.TokenParams calldata p, uint256, address pairToken, address[] calldata exempt)
        external
        payable
        returns (address token, address curve)
    {
        require(msg.value == launchFee, "fee");
        require(p.expectedEconomics == keccak256("econ"), "econ");
        require(p.creatorTaxBps <= 1000, "tax");
        lastExempt = exempt;
        MockERC20 t = new MockERC20(p.name, p.symbol, 18);
        MockCurve c = new MockCurve(t, escrow, msg.sender, p.creatorFeeRecipient, p.creatorTaxBps);
        t.mint(address(c), 1_000_000_000 ether);
        token = address(t);
        curve = address(c);
        _launched[token] = LaunchedToken({
            token: token,
            curve: curve,
            deployer: msg.sender,
            creatorFeeRecipient: p.creatorFeeRecipient,
            pairToken: pairToken,
            graduationThreshold: 4.2 ether,
            poolFee: 0,
            tickSpacing: 200,
            creatorTaxBps: p.creatorTaxBps,
            buybackEnabled: p.buybackEnabled,
            phase: 0,
            sweptQuote: 0,
            sweptTokens: 0,
            sweptAt: 0,
            exists: true
        });
    }

    function getLaunchedToken(address token) external view returns (LaunchedToken memory) {
        return _launched[token];
    }

    function ownerRedirect(address token, address newRecipient) external {
        _launched[token].creatorFeeRecipient = newRecipient;
    }

    function proposeRedirect(address token, address newRecipient) external {
        pendingRecipient[token] = newRecipient;
    }

    function pendingCreatorFeeRecipient(address token) external view returns (address, uint256, uint256) {
        address n = pendingRecipient[token];
        return n == address(0) ? (address(0), 0, 0) : (n, block.timestamp + 3 days, block.timestamp + 6 days);
    }
}

contract Rejecting {
    receive() external payable {
        revert("no thanks");
    }
}
