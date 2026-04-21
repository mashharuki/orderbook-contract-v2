// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// MockStableCoinDecimals — variant of MockStableCoin with a configurable
// decimals() value. Used by the e2e fixture to simulate non-18-decimal
// tokens (e.g., 6-decimal USDC, 8-decimal WBTC) without rewriting every
// existing test that relies on the original MockStableCoin.
//
// Constructor takes (symbol, decimals_) and overrides ERC20.decimals() to
// return the supplied value.
pragma solidity 0.8.24;

import "solady/src/tokens/ERC20.sol";

contract MockStableCoinDecimals is ERC20 {
    string private _name;
    string private _symbol;
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) {
        _name = symbol_;
        _symbol = symbol_;
        _decimals = decimals_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
