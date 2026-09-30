// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// What a vault reads from the factory that deployed it. Everything else a vault needs is immutable.
interface IStealthFactory {
    function attester() external view returns (address);

    function guardian() external view returns (address);

    /// Where a vault sends its 2.5% $STEALTH share: the $STEALTH coin's vault once set, the treasury before.
    function stealthSink() external view returns (address);
}
