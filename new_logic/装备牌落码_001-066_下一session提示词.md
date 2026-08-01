# 装备牌效果落码（001-066）· 下一 Session 启动提示词

> 用法：把本文件全文作为新 Claude Code session 的第一条消息。该 session 据此把装备牌 001-066 的效果落地为代码 + 测试。

---

## 你的任务

你是 Battle-GEAR-S（机斗战甲，Godot 4.6 回合制战棋）的**装备牌效果实现工程师**。根据已完成的拆解文档 `new_logic/装备牌效果拆解_001-066.txt`，把装备牌 001-066 的效果落地为可运行代码 + 测试，全程保持 `run_tests` 全绿、无回归。

**最高优先级原则：和我（用户）多做讨论。不会的、不确定的就问我，绝不自己猜。** 拆解里有 82 个歧义点，其中 81 个还没裁定（▶ 回答行空白）——这些就按照智能体所选的方案来就行了，实在觉得智能体选得有问题再问我。

---

## 第一步：按顺序读这些

1. 本提示词全文。
2. `new_logic/装备牌效果拆解_001-066.txt` —— **落码依据**（66 张牌 / 11 套装，逐张含效果拆解+实现预告+顺序与坑+测试场景+歧义点）。
3. `.claude/agents/effect-coder.md` —— 效果体系知识基 + 关键坑 + 文件落点（该智能体虽是拆解-only，但其「效果组成与运行逻辑」「关键既有约定与坑」「文件落点」三章对落码同样适用，必读）。
4. `new_logic/装备牌效果拆解_外部模型提示词.md` 的「二、既有件清单」—— 时点/条件op/目标规则/原子动作/已实现 effect_id 001-031+089 **全清单**（落码时引用，别重复造）。
5. 记忆 `C:\Users\m1396\.claude\projects\f--Battle-GEAR-S\memory\equipment-fullset-redesign.md` —— 进度 + 既有 effect_id 映射 + 已知待办（part_019 半完成 5 步等）。其它相关记忆见 `MEMORY.md`。
6. 权威规则文档（冲突时**以此为准**）：`new_logic/机斗战甲规则书.txt`、`new_logic/各动作的生命周期与时点.txt`、`new_logic/行动牌的效果与逻辑.txt`。

---

## 拆解文件怎么读

每张牌一节，结构：
- **牌头**：名称/部位/护甲/动力/耐久/金币 + 效果文本 + `effect_ids`
- **效果拆解**：优先级 / 模式 / 植入 / `conditions`/`target_rules`/`costs`/`actions`（**GDScript 字面量，可直接粘进 `set_xxx()`**）/ 执行顺序 / 人类 UI
- **实现预告**：复用既有 effect_id / 需新建 `effect_NNN` / 需新增 op/动作/helper（附登记点）
- **顺序与坑**：优先级理由、边界
- **测试场景**：a/b/c… 每个含 前置 / 操作 / 断言（具体到字段名与期望值）
- **歧义点**：`[歧义N] … ▶ 回答：____`
  - ▶ 回答行**有内容** = 我已裁定，照此落码。
  - ▶ 回答行**空白** = 未裁定，**落码前必须问我**。
  - 已知 1 条已裁定：**line 767**——动力+1 = 当前动力+1（可超上限，**不增加上限**，如 5/5→6/5）。这与现有 `effect_008`（计入 `get_total_power` 上限）实现冲突，落码到帝国头部/相关派生动力效果时**先和我确认怎么改**。

---

## 落码规则（按拆解的「实现预告」分类执行）

### A. 标「复用 effect_XXX」的牌
- 核对现有代码（`GeneratedEquipmentEffects.gd`）与拆解/新权威文本一致。
- **新文本与现有代码行为不同的牌**（如 009/019/025/027/029/030/032/038 等，拆解里会标「需重构」）：按新文本重构既有 effect 定义。
- 同步 `data/cards/equipment_parts.json` 的 `effect_ids` 数组（**手维护，勿重新生成、勿改 xlsx/导出工具**）。

### B. 标「需新建 effect_NNN」的牌
- 在 `scripts/generated_database/GeneratedEquipmentEffects.gd` 的 `build_equipment_effects()` 末尾加 `ActionEffect.new()` 块，**直接用拆解给的 conditions/target_rules/costs/actions 字面量**，仿周围风格（box-drawing 注释分隔符、注释密度）。
- effect_id 从 032 起递增（拆解已分配，照它的编号）。

### C. 标「需新增条件 op」
- 进 `scripts/action_core/ConditionChecker.gd` 的 `check_single` match 加分支 + 语义实现，仿拆解给的「仿哪个既有 op」。
- 装备牌专用 op 用 `_equip_mech_id`/`_equip_player_id`/`_equip_card_instance_id` helper 取来源。

### D. 标「需新增原子动作」
- 进 `scripts/action_core/ActionService.gd`：
  1. `_is_atomic_action` 列表（约 line 173）登记新 type；
  2. `_execute_atomic_action`（约 line 289）加特判实现；
  3. `_dispatch_atomic_action`（约 line 633）加分发。
- 仿拆解给的范式（如 `DISCARD_SELF_FROM_SLOT` 仿 `DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS`）。

### E. 标「需新增复杂交互动作」（如 `CHOOSE_INTEGER`）
- 在 `scripts/action_core/TimingEngine.gd` 的 `_execute_actions` 拦截（仿 `CHOOSE_ONE`/`OFFER_DAMAGE_REDIRECT` 的挂起/恢复范式），弹窗交 app_root + 对应 panel。

### F. 派生值型效果
- `GeneratedEquipmentEffects.gd` 加 `compute_*`/`card_damage_immune_armor_amount` 类 helper；
- 接入点：`MechState.get_armor`（护甲类）/ `MechState.get_total_power`（动力类）/ `MechSlotState.get_effective_armor(mech)`（区域护甲类）。
- **不注册监听器**。注意用户裁定（line 767）：动力+1 是加当前动力非上限——派生动力效果可能要改接 `current_power` 而非 `get_total_power`，先和我确认。

### G. 注册
- `scripts/action_defs/set_equipment_action.gd` 的 `_register_equipment_effects`：确认按 `effect_ids` 注册 permanent listener（binding_context 注入 card_instance_id/mech_id/player_id/slot_id）。
- DIRECT 主动效果也在此注册，由装备面板"发动"按钮 / skill_bar 触发 `action_service.execute("effect_fire",{source})`。

### H. UI 接线
- DIRECT 主动效果 → `scripts/ui/equipment_panel.gd`"发动"按钮 / `skill_bar.gd`。
- 新弹窗 → `scripts/app/app_root.gd` + 新建/复用 panel；PvP 路由复用既有 `_popup_owner` 范式。

### I. JSON
- `data/cards/equipment_parts.json`：每张牌的 `effect_ids` 数组按拆解改（手维护）。

---

## 测试

- 按拆解的「测试场景」写 `tests/test_equipment_effects.gd`（或专用 `tests/test_equipment_<套装>.gd`）的 `test_` 方法。
- **复用现有建局/驱动范式**：`_new_battle()`、`_ensure_equipment_in_hand()`、`_pump_frames(n)`；攻击流驱动见 `tests/test_flash_counter_order.gd`（选武器/选目标/响应窗口/损伤放置的逐帧驱动）。
- `test_` 前缀方法返回 `true` 或错误串；在 `tests/run_tests.gd` 注册（先看它是否按前缀自动枚举）。
- 用 `await Engine.get_main_loop().process_frame` flush deferred（`call_deferred` 的动作恢复靠帧驱动）。
- 跑测试：`timeout 240 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`
  - **Godot 用后即关**（timeout 防爆内存）。
  - 失败可自修；**反复失败 ≥3 轮停止自修**，汇报问题清单（失败用例/报错/定位/候选修法）给我，不要无限循环改。

---

## 工作流（和我商量着来，多问少错）

1. **先建绿基线**：跑一次现有 `run_tests`，确认全绿，记下用例总数。落码过程中每批改完都要回到全绿。
2. **按套装推进**（11 套装，001-066）：
   - 套装1 量产装（001-006）最简单（全复用 effect_001 + JSON + 测试），先热身。
   - 每个套装开始前：**收集该套装所有空白 ▶ 回答歧义，一次性列给我裁定**（别一次问 81 个，按套装分批）。
   - 拿到裁定后落码：effect 定义 / 新 op / 新动作 / 派生值 / JSON / 注册 / UI。
   - 写该套装的测试 → 跑 `run_tests` 保绿 → 汇报（改了哪些文件、测试结果、遗留点）→ 再进下一套装。
3. **新机制（新 op/动作/helper/复杂交互）落码前**：先给我看实现方案（仿哪个既有件、登记在哪、参数、接入点），我确认后再写代码。
4. **不确定就问**：任何拆解没说清、与现有代码冲突、或你觉得有多种实现方式的，先问我，不要猜。
5. 用 TodoWrite 跟踪套装进度；每个套装一个 todo。

---

## 硬约束

1. **唯一权威**：规则文档 > 拆解文件 > 既有件清单。冲突以规则文档为准。
2. **全面弃 hook**：只用 Action+时点体系（TimingEngine），不碰 `scripts/effect_core/` 旧 hook。消息层走时点+SessionLogger。
3. **先 PvP 人类玩家 + UI**：逻辑/UI 对任意数量人类玩家可复用；AI 逻辑暂不管。
4. **逐效果独立实现**但**机制相同优先复用既有 op/原子动作/effect_id**，新建仅当确实无匹配。
5. **数据层 `data/cards/equipment_parts.json` 是手维护运行时权威源**（effect_ids 手工维护；导出工具只产单数 effect_unimplemented，勿重新生成、勿改 xlsx/导出工具）。
6. **不得引入回归**：每批改完 `run_tests` 全绿。
7. **用 `python` 不是 python3**。
8. **Godot 用后即关**（timeout 240 防爆内存）。
9. **改动前先 Read 目标文件**；Edit 用唯一 old_string；不重读刚编辑的文件；仿周围代码风格。

---

## 关键文件落点

| 改什么 | 文件 | 位置 |
|--------|------|------|
| 装备效果定义 | `scripts/generated_database/GeneratedEquipmentEffects.gd` | `build_equipment_effects()` + 派生值 helper 区 |
| 新条件 op | `scripts/action_core/ConditionChecker.gd` | `check_single` match |
| 新原子动作 | `scripts/action_core/ActionService.gd` | `_is_atomic_action`(~L173) + `_execute_atomic_action`(~L289) + `_dispatch_atomic_action`(~L633) |
| 新复杂交互动作 | `scripts/action_core/TimingEngine.gd` | `_execute_actions` 拦截 |
| 时点常量 | `scripts/action_core/TimingConst.gd` | —— |
| 目标规则 | `scripts/action_core/TargetChecker.gd` | `check_single` match |
| 派生值接入 | `scripts/runtime/MechState.gd` / `MechSlotState.gd` | `get_armor`/`get_total_power` / `get_effective_armor(mech)` |
| 效果注册 | `scripts/action_defs/set_equipment_action.gd` | `_register_equipment_effects` |
| JSON effect_ids | `data/cards/equipment_parts.json` | 每张牌的 `effect_ids` |
| DIRECT 主动 UI | `scripts/ui/equipment_panel.gd` / `skill_bar.gd` | "发动"按钮 |
| 弹窗接线 | `scripts/app/app_root.gd` | —— |
| 测试 | `tests/test_equipment_effects.gd` 等 | `tests/run_tests.gd` 注册 |

---

## 关键坑（勿重复踩，详见 effect-coder.md）

- **优先级错开保序**：同一时点同优先级按注册序/座次跑。需严格先后时用 priority 错开（counter_e2=20 先于 flash_e2=10；predict_e2=30 先于 cover_e1=10；近战头部转换 priority20 先于近战威力+2 priority10）。
- **fire_timing 首循环丢剩余监听器**：optional 弹窗置 attack waiting_timing 时首循环 return 会丢弃后续同级监听器；靠提优先级规避，勿改 fire_timing 的 waiting_timing 分支。
- **弃置全量走 `discard_card` 动作**发 DISCARD_BEFORE/AFTER/SETTLE，reason 常量（`damage_durability`/`equipment_replace`/`turn_cleanup`/`sell`/`sell_set_equipment`/`effect_self_discard`）按 reason 过滤防循环；离场诱发监听 DISCARD_AFTER（牌在 tmp_zone）。
- **损伤放置走 `damage_change` 动作**，`DAMAGE_REDIRECT_WINDOW` 一次性汇总转移窗（非逐点），写 redirect_plan。
- **派生值型不注册监听器**，查询点实时重算。
- **状态挂 A 时点、fire 在 B 时点时，target 须用 `$binding_context.xxx`** 而非 `$payload.xxx`。
- **effective_weapon_type**：武器类型相关效果读 `attack.record.effective_weapon_type`（近战头部转换在 ATTACK_BEFORE priority20 改写，结算清理）；基础武器虚拟 ID `frame_base_weapon_X`，取 range 用 `get_base_weapon`。
- **离开手牌不再触发**：`_listener_card_still_active` 仅校验 `permanent_while_in_hand` 的牌仍在 action_hand。
- **GDScript4 坑**：RefCounted 的 `.get(key,default)` 只接 1 参（用属性访问）；lambda 标量按值捕获（断言用数组元素承载）；`int == &"StringName"` 会崩（先 `String()` 转）；StringName 比较用 `String(a)==String(b)` 更稳。

---

## 开场

读完上述文件后，先向我汇报：(1) 你理解的总体任务与范围；(2) 你扫到的、按套装分组的未裁定歧义清单（先从套装1-2 开始列）；(3) 你的落码推进计划（套装顺序、每批大小）。等我确认后再开写。**全程多问少错。**
