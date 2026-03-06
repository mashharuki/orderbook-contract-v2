// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
// EN: MockStableCoin is a simple ERC20 + Permit token for testing flows.
// 中文: MockStableCoin 是用于测试流程的简单 ERC20 + Permit 代币。
pragma solidity 0.8.24;

import "solady/src/tokens/ERC20.sol";

contract MockStableCoin is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory symbol_) {
        _name = symbol_;
        _symbol = symbol_;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
