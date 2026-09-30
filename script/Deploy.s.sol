// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {StealthFactory} from "../src/StealthFactory.sol";
import {StealthVault} from "../src/StealthVault.sol";
import {IPonsFactory, IPonsFeeEscrow} from "../src/interfaces/IPons.sol";
import {IUniswapV3Pool, IWETH9, IERC20} from "../src/interfaces/IUniswapV3.sol";

/// Addresses read from the verified contracts on Robinhood Chain (4663) and exercised by the fork tests.
/// Re-run `forge test --match-contract Fork --fork-url robinhood` right before a real deploy.
library RH {
    address internal constant PONS = 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e;
    address internal constant ESCROW = 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e;
    address internal constant HOOK = 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address internal constant POOL_WETH_USDG = 0x52e65B17fB6E5BA00Ed806f37Afcd2DaA50271Ca; // 0.01%, WETH is token0
}

/// The factory, in one broadcast.
///   GUARDIAN=0x.. ATTESTER=0x.. TREASURY=0x.. \
///   forge script script/Deploy.s.sol:DeployFactory --rpc-url robinhood --broadcast --private-key $DEPLOYER_PK
/// GUARDIAN  a cold wallet: vetoes pending roots, rotates the attester (2-day delay), closes new launches
/// ATTESTER  the signing key's address (the key itself never needs ETH: roots are relayed)
/// TREASURY  receives the 2.5% treasury share, the route fees, and the $STEALTH share until that vault exists
contract DeployFactory is Script {
    function run() external returns (StealthFactory factory) {
        address guardian = vm.envAddress("GUARDIAN");
        address attester = vm.envAddress("ATTESTER");
        address treasury = vm.envAddress("TREASURY");
        require(guardian != address(0) && attester != address(0) && treasury != address(0), "addresses");
        require(guardian != attester, "guardian and attester must be different keys");

        vm.startBroadcast();
        factory = new StealthFactory(
            StealthVault.Wiring({
                pons: IPonsFactory(RH.PONS),
                escrow: IPonsFeeEscrow(RH.ESCROW),
                hook: RH.HOOK,
                weth: IWETH9(RH.WETH),
                usdg: IERC20(RH.USDG),
                pool: IUniswapV3Pool(RH.POOL_WETH_USDG),
                treasury: treasury
            }),
            guardian,
            attester
        );
        vm.stopBroadcast();

        console2.log("StealthFactory", address(factory));
        console2.log("VaultDeployer ", address(factory.deployer()));
        console2.log("block         ", block.number);
    }
}

/// One coin through the factory. Prints the predicted vault first and asserts the real one matches.
///   FACTORY=0x.. NAME="Stealthpad" SYMBOL=STEALTH TAX_BPS=300 SALT=stealth FIRST_BUY_WEI=0 \
///   LOGO=https://app.stealthpad.online/brand/icon-512.png DESCRIPTION="..." WEBSITE=https://stealthpad.online \
///   forge script script/Deploy.s.sol:LaunchCoin --rpc-url robinhood --broadcast --private-key $LAUNCHER_PK
contract LaunchCoin is Script {
    function run() external returns (address vault, address token) {
        StealthFactory factory = StealthFactory(vm.envAddress("FACTORY"));
        StealthVault.LaunchInput memory input;
        input.name = vm.envString("NAME");
        input.symbol = vm.envString("SYMBOL");
        input.logo = vm.envOr("LOGO", string(""));
        input.description = vm.envOr("DESCRIPTION", string(""));
        input.socials.website = vm.envOr("WEBSITE", string(""));
        input.socials.twitter = vm.envOr("SOCIAL", string(""));
        input.salt = keccak256(bytes(vm.envString("SALT")));
        uint16 tax = uint16(vm.envUint("TAX_BPS"));
        uint256 firstBuy = vm.envOr("FIRST_BUY_WEI", uint256(0));

        vm.startBroadcast();
        address predicted = factory.predict(msg.sender, input.salt, tax);
        console2.log("predicted vault", predicted);
        uint256 fee = IPonsFactory(RH.PONS).launchFee();
        (vault, token) = factory.launch{value: fee + firstBuy}(input, tax, 0);
        vm.stopBroadcast();

        require(vault == predicted, "vault address differs from the prediction: stop");
        console2.log("vault", vault);
        console2.log("token", token);
        console2.log("curve", StealthVault(payable(vault)).curve());
    }
}

/// Reads a vault back from the chain: what the launchpad records, and the vault's own state.
///   VAULT=0x.. forge script script/Deploy.s.sol:Inspect --rpc-url robinhood
contract Inspect is Script {
    function run() external view {
        StealthVault v = StealthVault(payable(vm.envAddress("VAULT")));
        console2.log("token              ", v.token());
        console2.log("curve              ", v.curve());
        console2.log("creator tax bps    ", v.taxBps());
        console2.log("fee route intact   ", v.feeRouteIntact());
        (address n, uint256 at,) = v.pendingOverride();
        console2.log("pending override   ", n, at);
        console2.log("pending ETH        ", v.pendingEth());
        console2.log("rounds             ", v.roundCount());
        console2.log("active root round  ", v.activeRoot().roundId);
        console2.log("unclaimed USDG     ", v.unclaimed());
    }
}
