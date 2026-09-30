// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// The surface of the launchpad's V2 contracts that Stealthpad touches, copied from the verified
/// source of PonsV2LaunchFactory 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e on Robinhood Chain (4663).

interface IPonsFactory {
    struct Socials {
        string twitter;
        string telegram;
        string discord;
        string website;
        string farcaster;
    }

    struct TokenParams {
        string name;
        string symbol;
        string logo;
        string description;
        Socials socials;
        address creatorFeeRecipient;
        uint16 creatorTaxBps;
        bool buybackEnabled;
        bytes32 expectedEconomics;
        bytes32 salt;
    }

    function launchFee() external view returns (uint256);

    function previewLaunchEconomics(uint256 launchConfigId, address pairToken) external view returns (bytes32);

    function launchToken(
        TokenParams calldata params,
        uint256 launchConfigId,
        address pairToken,
        address[] calldata snipeTaxExemptions
    ) external payable returns (address token, address curve);

    /// A pending launchpad-owner override of a coin's creator fee recipient (3-day timelock).
    function pendingCreatorFeeRecipient(address token)
        external
        view
        returns (address newRecipient, uint256 effectiveAt, uint256 expiresAt);
}

interface IPonsCurve {
    function buy(uint256 quoteIn, uint256 minTokensOut, address recipient) external payable returns (uint256 tokensOut);

    function sell(uint256 tokensIn, uint256 minQuoteOut, address recipient) external returns (uint256 quoteOut);

    /// Callable by the launchpad's sweep operator or by the coin's deployer (here: the vault).
    function sweepFees(uint256 minBuybackTokensOut) external;

    function creatorTaxBalance() external view returns (uint256);

    function getReserves() external view returns (uint256 quoteReserve, uint256 tokenReserve);

    function graduated() external view returns (bool);
}

interface IPonsHook {
    /// Callable by the sweep operator or the pool's creator (the fee recipient). A non-operator call
    /// reverts while coin-side fees are pending conversion; only the operator can convert those.
    function sweepPoolFees(bytes32 poolId, uint256 minConversionQuoteOut, uint256 minBuybackTokensOut) external;
}

interface IPonsFeeEscrow {
    /// Pays msg.sender its whole credited balance, by call.
    function claim() external returns (uint256 amount);

    function balanceOf(address recipient) external view returns (uint256);
}
