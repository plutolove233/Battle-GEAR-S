# 新动作系统 UI 联动计划

## 现状分析

### 已完成的核心组件
- **ActionEngine** - 动作执行引擎（execute/continue/cancel）
- **ActionService** - 动作调度入口（execute/sub_action）
- **TimingEngine** - 时点分发与效果监听（fire_timing/handle_response_selection）
- **ActionUIBridge** - UI桥接层（request_ui_popup信号）
- **GeneratedActionEffects** - 23张行动牌效果定义
- **各种Action子类** - attack_action.gd、use_action_card_action.gd等

### 关键链路已存在
```
点击行动牌 → _on_action_card_clicked → choice_panel确认 → _on_choice_made
  → battle.execute_use_action_card → ActionService.execute("use_action_card")
  → UseActionCardAction → TimingEngine.fire_timing("USE_ACTION_AT")
  → 执行DIRECT效果 → EXECUTE_ATTACK → AttackAction
  → 时点 ATTACK_BEFORE/ATTACK_PRE/ATTACK_AT → 响应窗口
```

---

## 实施进度

### ✅ 阶段1：修复响应窗口联动（已完成）

#### 1.1 连接响应面板信号 ✅
**文件**: `scripts/app/app_root.gd`

已连接：
```gdscript
response_panel.availability_effect_selected.connect(_on_availability_effect_selected)
```

#### 1.2 实现可用效果选择回调 ✅
已实现 `_on_availability_effect_selected` 回调，将选中的效果传递给 TimingEngine.handle_response_selection()

#### 1.3 处理跳过响应 ✅
`_on_response_passed` 已调用 `timing_engine.handle_response_selection(action_id, [])`

#### 1.4 ActionUIBridge信号连接 ✅
已验证连接完整：request_ui_popup, action_input_resolved, timing_fired

### ✅ 阶段2：添加使用行动牌确认对话框（已完成）

#### 2.1 点击行动牌时弹出确认对话框 ✅
**文件**: `scripts/app/app_root.gd`

- 点击行动牌后先显示确认对话框（确定使用 / 取消）
- 检查攻击牌是否有可用目标（规则10）
- 迎击牌不能主动打出

#### 2.2 处理确认/取消 ✅
在 `_on_choice_made` 中处理：
- 确认：调用 `battle.execute_use_action_card()` 执行动作
- 取消：关闭面板，返回

---

## 待完成工作

### 阶段3：状态效果系统（部分实现）

需要在后续完成：
- 聚能状态（energy_apply）- 永久监听器
- 联合状态（unite_status）- 永久监听器
- 锁定状态（lock_status）- 永久监听器
- 折扣状态（discount_status）- 永久监听器

### 阶段4：行动牌特殊效果

需要后续实现：
- 推进效果2（使用迎击牌时触发）
- 掩护牌监听（攻击时前检测范围）
- 联合/锁定状态的目标选择

---

## 预期结果

完成以上步骤后：
1. ✅ 点击行动牌可以弹出确认对话框
2. ✅ 确认后通过 ActionService 执行完整流程
3. ✅ 攻击时弹出响应窗口，选择响应牌后执行对应效果
4. ⏳ 状态效果正确应用并显示在UI上
5. ⏳ 消息日志显示完整的动作/时点执行记录
