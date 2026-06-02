// SPDX-License-Identifier: LicenseRef-PolyForm-Noncommercial-1.0.0
pragma solidity 0.8.24;

import {Sera} from "../../src/Sera.sol";
import {Vault} from "../../src/Vault.sol";
import {SeraLib, MatchData, Order, BPS_DENOMINATOR} from "../../src/SeraLib.sol";

contract SeraCertoraHarness is Sera {
    constructor(address initialOwner, Vault _vault) Sera(initialOwner, _vault) {}

    function certoraBpsDenominator() external pure returns (uint256) {
        return BPS_DENOMINATOR;
    }

    function certoraHashOrder(Order calldata order) external pure returns (bytes32) {
        return SeraLib.getOrderHashCalldata(order);
    }

    function certoraExecutionValues(MatchData calldata matchData, uint256 effectiveAmount0, uint256 effectiveAmount1) external pure returns (uint256 executionValue0, uint256 executionValue1) {
        return SeraLib._executionValues(matchData, effectiveAmount0, effectiveAmount1);
    }

    function certoraCalculateSettlement(MatchData calldata matchData, uint256 executionValue0, uint256 executionValue1, uint256 effectiveAmount0, uint256 effectiveAmount1, bytes32 orderHash0, bytes32 orderHash1) external returns (uint256 protocolFee0, uint256 protocolFee1, uint256 protocolTake0, uint256 protocolTake1, uint256 resultExecutionValue0, uint256 resultExecutionValue1, bool order0FullyFilled, bool order1FullyFilled) {
        SettlementCalc memory calc = _calculateSettlement(matchData, executionValue0, executionValue1, effectiveAmount0, effectiveAmount1, orderHash0, orderHash1);

        return (calc.protocolFee0, calc.protocolFee1, calc.protocolTake0, calc.protocolTake1, calc.executionValue0, calc.executionValue1, calc.order0FullyFilled, calc.order1FullyFilled);
    }

    function certoraValidateOrderCommon(Order calldata order, bytes32 orderHash, uint256 matchAmount) external view returns (uint256 filled) {
        return _validateOrderCommon(order, orderHash, matchAmount);
    }

    function certoraSlippageShares() external view returns (uint64 makerShareBps, uint64 takerShareBps, uint64 protocolShareBps, uint64 totalBps) {
        SlippageShare memory shares = slippageShares;
        return (shares.makerShareBps, shares.takerShareBps, shares.protocolShareBps, shares.totalBps);
    }

    function certoraSlippageSharesValid() external view returns (bool) {
        SlippageShare memory shares = slippageShares;
        return shares.totalBps != 0 && uint256(shares.makerShareBps) + uint256(shares.takerShareBps) + uint256(shares.protocolShareBps) == shares.totalBps;
    }

    function certoraTokenConfig(address token) external view returns (bool isWhitelisted, uint248 minAmount) {
        TokenConfig memory config = tokenConfigs[token];
        return (config.isWhitelisted, config.minAmount);
    }

    function certoraVaultBalanceOf(address token, address user) external view returns (uint256) {
        return vault.balanceOf(token, user);
    }
}
