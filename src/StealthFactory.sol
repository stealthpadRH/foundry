// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {StealthVault} from "./StealthVault.sol";
import {VaultDeployer} from "./VaultDeployer.sol";
import {IPonsFactory, IPonsFeeEscrow} from "./interfaces/IPons.sol";
import {IUniswapV3Pool, IWETH9, IERC20} from "./interfaces/IUniswapV3.sol";
import {IStealthFactory} from "./interfaces/IStealthFactory.sol";

/// @title StealthFactory
/// @notice Launches every Stealthpad coin: deploys the coin's StealthVault at a predictable address and
/// has it launch the coin on Pons V2 in the same transaction, so the vault is the coin's deployer and
/// creator fee recipient from block one.
///
/// Every power this contract keeps is listed here:
///  - guardian: may veto a vault's pending root (in the vault), propose a new attester, which takes
///    effect ATTESTER_DELAY later, close or reopen NEW launches, and hand the role to a new key in two
///    steps. It cannot move funds, change a split or a tax, or stop a round or a claim.
///  - stealthVault: set exactly once, to a vault this factory created (the $STEALTH coin's).
contract StealthFactory is IStealthFactory {
    uint64 public constant ATTESTER_DELAY = 2 days;

    IPonsFactory public immutable pons;
    IPonsFeeEscrow public immutable escrow;
    address public immutable hook;
    IWETH9 public immutable weth;
    IERC20 public immutable usdg;
    IUniswapV3Pool public immutable pool;
    address public immutable treasury;
    VaultDeployer public immutable deployer;

    address public guardian;
    address public pendingGuardian;
    address public attester;
    address public pendingAttester;
    uint64 public pendingAttesterAt;
    bool public launchesOpen = true;

    /// The $STEALTH coin's vault. Set once; must be one of this factory's own vaults.
    address public stealthVault;

    mapping(address vault => bool) public isVault;
    mapping(address token => address vault) public vaultOf;
    address[] public vaults;

    event CoinLaunched(address indexed token, address indexed vault, address indexed launcher, uint16 taxBps, address curve);
    event StealthVaultSet(address indexed vault);
    event AttesterProposed(address indexed attester, uint64 effectiveAt);
    event AttesterChanged(address indexed previous, address indexed attester);
    event GuardianProposed(address indexed guardian);
    event GuardianChanged(address indexed previous, address indexed guardian);
    event LaunchesOpen(bool open);

    error OnlyGuardian();
    error OnlyPendingGuardian();
    error BadTax(uint16 taxBps);
    error LaunchesClosed();
    error AlreadySet();
    error NotOurVault();
    error NoPendingAttester();
    error AttesterNotReady(uint64 effectiveAt);
    error ZeroAddress();

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert OnlyGuardian();
        _;
    }

    constructor(StealthVault.Wiring memory w, address guardian_, address attester_) {
        if (guardian_ == address(0) || attester_ == address(0) || w.treasury == address(0)) revert ZeroAddress();
        pons = w.pons;
        escrow = w.escrow;
        hook = w.hook;
        weth = w.weth;
        usdg = w.usdg;
        pool = w.pool;
        treasury = w.treasury;
        guardian = guardian_;
        attester = attester_;
        deployer = new VaultDeployer();
        emit GuardianChanged(address(0), guardian_);
        emit AttesterChanged(address(0), attester_);
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Launch
    // ─────────────────────────────────────────────────────────────────────────────

    /// Send the Pons launch fee, plus anything extra to spend on a first buy for yourself.
    /// @param taxBps the coin's creator tax: 100, 200, 300, 400 or 500 (1% to 5%), fixed forever
    function launch(StealthVault.LaunchInput calldata input, uint16 taxBps, uint256 minTokensOut)
        external
        payable
        returns (address vault, address token)
    {
        if (!launchesOpen) revert LaunchesClosed();
        if (taxBps < 100 || taxBps > 500 || taxBps % 100 != 0) revert BadTax(taxBps);
        StealthVault v = StealthVault(payable(deployer.deploy(_salt(msg.sender, input.salt), _wiring(), taxBps)));
        vault = address(v);
        isVault[vault] = true;
        vaults.push(vault);
        token = v.launch{value: msg.value}(input, msg.sender, minTokensOut);
        vaultOf[token] = vault;
        emit CoinLaunched(token, vault, msg.sender, taxBps, v.curve());
    }

    /// The address a vault would get, before anything is sent. Shown to the launcher up front.
    function predict(address launcher, bytes32 salt, uint16 taxBps) external view returns (address) {
        return deployer.predict(_salt(launcher, salt), _wiring(), taxBps);
    }

    function vaultCount() external view returns (uint256) {
        return vaults.length;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // The $STEALTH sink
    // ─────────────────────────────────────────────────────────────────────────────

    /// Once, by the guardian, right after the $STEALTH coin launches through this factory.
    function setStealthVault(address vault) external onlyGuardian {
        if (stealthVault != address(0)) revert AlreadySet();
        if (!isVault[vault]) revert NotOurVault();
        stealthVault = vault;
        emit StealthVaultSet(vault);
    }

    function stealthSink() external view returns (address) {
        return stealthVault == address(0) ? treasury : stealthVault;
    }

    // ─────────────────────────────────────────────────────────────────────────────
    // Guardian and attester keys
    // ─────────────────────────────────────────────────────────────────────────────

    function proposeAttester(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingAttester = next;
        pendingAttesterAt = uint64(block.timestamp) + ATTESTER_DELAY;
        emit AttesterProposed(next, pendingAttesterAt);
    }

    /// Anyone may finish a proposed attester change once its delay has passed.
    function acceptAttester() external {
        address next = pendingAttester;
        if (next == address(0)) revert NoPendingAttester();
        if (block.timestamp < pendingAttesterAt) revert AttesterNotReady(pendingAttesterAt);
        emit AttesterChanged(attester, next);
        attester = next;
        pendingAttester = address(0);
        pendingAttesterAt = 0;
    }

    function cancelAttester() external onlyGuardian {
        pendingAttester = address(0);
        pendingAttesterAt = 0;
        emit AttesterProposed(address(0), 0);
    }

    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        emit GuardianProposed(next);
    }

    function acceptGuardian() external {
        if (msg.sender != pendingGuardian || msg.sender == address(0)) revert OnlyPendingGuardian();
        emit GuardianChanged(guardian, msg.sender);
        guardian = msg.sender;
        pendingGuardian = address(0);
    }

    /// Closes or reopens NEW launches. Existing vaults, their rounds and their claims are unaffected.
    function setLaunchesOpen(bool open) external onlyGuardian {
        launchesOpen = open;
        emit LaunchesOpen(open);
    }

    // ─────────────────────────────────────────────────────────────────────────────

    function _wiring() private view returns (StealthVault.Wiring memory) {
        return StealthVault.Wiring({
            pons: pons,
            escrow: escrow,
            hook: hook,
            weth: weth,
            usdg: usdg,
            pool: pool,
            treasury: treasury
        });
    }

    function _salt(address launcher, bytes32 salt) private pure returns (bytes32) {
        return keccak256(abi.encode(launcher, salt));
    }
}
