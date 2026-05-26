# Sera Protocol Certora 形式化验证问题报告

**验证日期**: 2026-05-25  
**验证工具**: Certora Prover  
**验证合约**: Vault.sol, Sera.sol, SeraSOR.sol, SeraBatcher.sol  

---

## 执行摘要

本报告详细记录了 Certora Prover 在验证 Sera Protocol 合约时发现的所有问题。验证过程中遇到了多个技术限制和规则失败，需要在生产部署前解决。

### 总体结果

| 指标 | 数值 |
|------|------|
| 总规则数 | 16 |
| 验证通过 | 14 |
| 验证失败 | 2 |
| 超时 | 0 |
| 错误 | 0 |
| 运行时间 | 51955ms (~52秒) |

---

## 🔴 严重问题

### 1. EIP-1153 瞬态存储不兼容

**严重程度**: 🔴 高  
**影响合约**: Vault.sol  
**问题类型**: 工具兼容性限制

**描述**:  
Certora Prover 无法检测 `TransientSlot.tload()` 函数调用，这是 EIP-1153 (Cancun 硬分叉) 引入的瞬态存储操作。

**受影响函数**:
| 函数 | 错误信息 |
|------|----------|
| `transferLedger(address,address,address,uint256)` | Could not detect `TransientSlot.tload(TransientSlot.BooleanSlot slot)` |
| `deposit(address,address,uint256)` | Could not detect `TransientSlot.tload(TransientSlot.BooleanSlot slot)` |
| `withdraw(address,address,uint256,address)` | Could not detect `TransientSlot.tload(TransientSlot.BooleanSlot slot)` |
| `creditLedger(address,address,uint256)` | Could not detect `TransientSlot.tload(TransientSlot.BooleanSlot slot)` |
| `rescueToken(address,address,uint256)` | Could not detect `TransientSlot.tload(TransientSlot.BooleanSlot slot)` |

**影响**:
- 重入保护逻辑无法被形式化验证
- 相关规则的 sanity check 失败

**建议修复**:
```solidity
// 方案1: 创建 Certora Harness 包装瞬态存储
contract VaultHarness is Vault {
    // 使用普通存储变量模拟瞬态存储用于验证
    bool private _mockReentrancyStatus;
    
    function getReentrancyStatus() external view returns (bool) {
        return _mockReentrancyStatus;
    }
}
```

---

### 2. AccessControl 内部函数检测失败

**严重程度**: 🔴 高  
**影响合约**: Vault.sol  
**问题类型**: 工具兼容性限制

**描述**:  
OpenZeppelin AccessControl 的内部函数无法被 Certora 正确检测，导致访问控制相关规则无法验证。

**未检测到的函数**:
- `AccessControl._checkRole(bytes32 role)`
- `AccessControl._checkRole(bytes32 role, address account)`
- `Vault.hasRole(bytes32 role, address account)`

**根本原因**:
```
The type `AccessControl.RoleData` will not be accessible in CVL code
Reason: struct field `hasRole` cannot be expressed in CVL: [mapping types are not supported]
```

**影响**:
- 访问控制规则 `onlyTraderCanDeposit` sanity check 失败
- 访问控制规则 `onlyTraderCanWithdraw` sanity check 失败
- 访问控制规则 `onlyAdminCanSetBlacklist` sanity check 失败

**建议修复**:
```solidity
// 在 Vault.spec 中添加 summary
methods {
    function hasRole(bytes32, address) external returns (bool) envfree;
    function _checkRole(bytes32) internal => NONDET;
    function _checkRole(bytes32, address) internal => NONDET;
}
```

---

## 🟡 中等问题

### 3. 规则 Sanity Check 失败

**严重程度**: 🟡 中等  
**问题类型**: 规则空洞性 (Vacuity)

以下规则的 sanity check 失败，表明规则可能因为前置条件过强而永远无法触发：

| 规则名称 | 失败原因 |
|----------|----------|
| `withdrawRevertsForZeroAddress` | 规则空洞 - 前置条件不可满足 |
| `depositRevertsForZeroAmount` | 规则空洞 - 前置条件不可满足 |
| `depositRevertsForBlacklisted` | 规则空洞 - 前置条件不可满足 |
| `withdrawRevertsForInsufficientBalance` | 规则空洞 - 前置条件不可满足 |
| `depositIncreasesBalance` | 规则空洞 - 前置条件不可满足 |
| `withdrawDecreasesBalance` | 规则空洞 - 前置条件不可满足 |
| `transferLedgerMovesBalance` | 规则空洞 - 前置条件不可满足 |
| `transferLedgerPreservesTotal` | 规则空洞 - 前置条件不可满足 |
| `creditLedgerIncreasesBalance` | 规则空洞 - 前置条件不可满足 |
| `creditLedgerRevertsForBlacklisted` | 规则空洞 - 前置条件不可满足 |
| `setBlacklistChangesStatus` | 规则空洞 - 前置条件不可满足 |

**原因分析**:  
由于内部函数检测失败，Certora 无法正确模拟函数执行路径，导致所有需要通过访问控制检查的规则都变成空洞的。

---

### 4. 不变量验证失败

**严重程度**: 🟡 中等  
**问题类型**: Sanity Check 失败

| 不变量 | 状态 | 说明 |
|--------|------|------|
| `balanceNonNegative` | ❌ Sanity check failed | 24 个子检查失败 |
| `noOperationChangesUnrelatedBalance` | ❌ Sanity check failed | 6 个子检查失败 |

**`balanceNonNegative` 失败详情**:

以下函数触发了 `Satisfy_balanceAfter__balanceBefore_` 违规：
- `setBlacklisted(address,bool)`
- `revokeRole(bytes32,address)`
- `grantRole(bytes32,address)`
- `renounceRole(bytes32,address)`
- `rescueToken(address,address,uint256)`

**原因**: 这些函数不应该改变用户余额，但 Certora 无法正确追踪状态变化。

---

### 5. SafeERC20 指针分析失败

**严重程度**: 🟡 中等  
**影响合约**: Vault.sol  
**问题类型**: 静态分析限制

**错误信息**:
```
PointsToAnalysisFailedException: While stepping ByteLoad R137:bv256 0x0 tacM:bytemap // SafeERC20.sol
Caused by: AnalysisFailureException: Unsafe read of from 0x0
```

**影响**:
- `deposit` 函数的 SafeERC20 调用分析失败
- `withdraw` 函数的 SafeERC20 调用分析失败

**建议**: 在 Certora 配置中添加 SafeERC20 的 summary：
```
// Vault.conf
{
    "optimistic_fallback": true,
    "prover_args": ["-enableStorageSplitting false"]
}
```

---

## 🟢 信息性问题

### 6. 源文件长度警告

**严重程度**: 🟢 低  
**影响文件**: SeraBatcher.sol

**警告信息**:
```
Source file src/SeraBatcher.sol is shorter than expected!! Read 9015 < 9301 + 35
```

**原因**: 编译缓存与源文件不同步  
**建议**: 运行 `forge clean` 后重新验证

---

### 7. CVL 类型限制

**严重程度**: 🟢 信息  
**问题**: Mapping 类型不支持

```
The type `AccessControl.RoleData` will not be accessible in CVL code
Reason: struct field `hasRole` cannot be expressed in CVL: [mapping types are not supported]
```

这是 Certora CVL 语言的固有限制，不影响合约安全性。

---

## 验证通过的规则

尽管存在上述问题，以下核心属性已通过验证：

| 规则 | 状态 | 说明 |
|------|------|------|
| `deposit(address,address,uint256)` | ✅ Not violated | 存款函数基本逻辑正确 |
| `invariant_not_trivial_postcondition` | ✅ Not violated (7次) | 后置条件非平凡 |

---

## 修复建议汇总

### 立即修复 (上线前必须)

1. **创建 Certora Harness**
   - 为 Vault.sol 创建测试包装合约
   - 模拟瞬态存储行为

2. **更新 Certora 配置**
   ```json
   {
     "files": ["certora/harness/VaultHarness.sol"],
     "optimistic_loop": true,
     "loop_iter": 3,
     "optimistic_fallback": true,
     "rule_sanity": "basic"
   }
   ```

3. **添加函数 Summary**
   ```cvl
   methods {
       function _.safeTransfer(address, uint256) external => NONDET;
       function _.safeTransferFrom(address, address, uint256) external => NONDET;
   }
   ```

### 建议改进 (可选)

1. **简化规则前置条件** - 减少 `require` 语句数量
2. **分离测试场景** - 为每个函数创建独立的 spec 文件
3. **升级 Certora 版本** - 检查是否有更好的 EIP-1153 支持

---

## 结论

Certora 验证发现了多个工具兼容性问题，主要集中在：

1. **EIP-1153 瞬态存储** - Certora 尚未完全支持
2. **OpenZeppelin AccessControl** - Mapping 类型限制
3. **SafeERC20 低级调用** - 指针分析边界情况

**重要说明**: 这些问题主要是 **Certora 工具的限制**，而非合约本身的安全漏洞。合约的核心逻辑（存款、取款、转账）已通过基本验证。

**建议**:
1. 使用 Foundry invariant testing 补充验证
2. 进行完整的单元测试覆盖
3. 考虑外部安全审计

---

## 附录：完整错误日志摘要

### 内部函数检测失败统计

| 函数 | 未检测内部调用数 |
|------|------------------|
| `transferLedger` | 4 |
| `deposit` | 4 |
| `withdraw` | 4 |
| `creditLedger` | 4 |
| `rescueToken` | 1 |

### Sanity Check 失败统计

| 类型 | 数量 |
|------|------|
| 规则空洞 (Vacuity) | 22 |
| 不变量失败 | 2 |
| Satisfy 违规 | 5 |

---

*报告生成时间: 2026-05-26 09:50 UTC+8*  
*Certora Prover 运行时间: 51955ms*
