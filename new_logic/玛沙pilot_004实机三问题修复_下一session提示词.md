# 玛沙 pilot_004 实机三问题修复提示词

## 背景

pilot_004 玛沙重做已完成（2按钮：装甲转能 01a + 恢复 01b 隐藏 / 动力穿透 02）。上一 session 修了两个实机不弹窗的坑（listen_action_type `turn_cycle`->`turn`；虚拟 turn action 注册 registry）。现在大部分逻辑跑通，剩 3 个实机问题。**只改这3个问题，不要动其他逻辑，保证全量测试无回归。**

相关 memory：`pilot-004-masha-rework-2026-08-08`、`gain-card-unification-2026-08-08`。
约束：用中文回复用户；不要用 subagent；用 `python` 不用 `python3`；Godot=`F:/Godot_4.6/Godot_v4.6-stable_win64.exe`，测试用 timeout 跑完即关防爆内存；PvP 人类玩家逻辑+UI 通用。

---

## 问题1：玛沙在敌方回合转化，抽牌抽到了当前回合玩家（应抽玛沙拥有者）+ 回合流程顺序

### 1A. 抽牌抽错玩家（核心 bug）

**现象**：其他玩家回合开始时，玛沙选发动转化效果，EXECUTE_GAIN_CARD 抽的牌进了当前回合玩家的手牌，而非玛沙拥有者。

**根因**：`scripts/action_core/TimingEngine.gd` 的 CHOOSE_INTEGER 嵌套在 CHOOSE_ONE 分支内的 special-case（约 line 2823-2841），解析嵌套 actions 时只调 `_resolve_atomic_value`（逐个解析 $-占位符），**没走 `_resolve_atomic_params` 的自动注入逻辑**。effect_01a 的 EXECUTE_GAIN_CARD params 没显式 player_id（只有 from_zone/card_kind/count_expr/reason），于是 gain_card 的 `_extract_gain_card_params`（`scripts/action_core/ActionService.gd` 约 line 1174）走 `_resolve_atomic_params`，从 `parent_action.source.player_id` 取值。而 TurnService 虚拟 turn action 的 `source.player_id` 是**当前回合玩家**（`scripts/services/TurnService.gd` `_fire_timing` line 219），所以 gain_card 拿到当前回合玩家，覆盖了 binding_context.player_id（玛沙拥有者）。

**注意**：`_extract_gain_card_params` 内有 binding_context 回退（约 line `result["player_id"] = _gc_bc.get("player_id", &"")`），但 `_resolve_atomic_params` 先把 source.player_id 注入到 result["player_id"]（line 1189-1190），导致回退分支的 `if result["player_id"] == &""` 不成立，回退不生效。

**修复方向**：effect_01a 的 EXECUTE_GAIN_CARD params 应显式带 `"player_id": "$binding_context.player_id"`（玛沙拥有者），而非依赖自动注入。参考 pilot_002/pilot_012 已这么写（`"player_id": "$binding_context.player_id"`）。

但注意 CHOOSE_INTEGER 分支的 `_resolve_atomic_value`（line 2836-2837）是否解析 `$binding_context.player_id`？需确认 `_resolve_atomic_value` 支持 `$binding_context.xxx`。顶层 CHOOSE_INTEGER handler（约 line 2909）用 `_resolve_atomic_params`，支持。CHOOSE_ONE 分支内的 special-case 用的是 `_resolve_atomic_value`（逐个）--需确认它能否解析 `$binding_context.player_id`。若不能，要把 CHOOSE_INTEGER 分支的 actions 解析改为 `_resolve_atomic_params`（与顶层一致），或在 EXECUTE_GAIN_CARD 的 player_id 用 `_resolve_atomic_value` 解析 `$binding_context.player_id`。

**最稳妥**：①effect_01a EXECUTE_GAIN_CARD 加 `"player_id": "$binding_context.player_id"`；②确认 CHOOSE_INTEGER 分支 special-case 的 params 解析能处理 `$binding_context.xxx`（若 `_resolve_atomic_value` 不支持 `$binding_context.` 前缀，参考 `_eval_expr` 的 `binding_context` 特殊解析，或改用 `_resolve_atomic_params`）。同时 EXECUTE_STAT_MODIFY 的 target_id 已是 `$binding_context.mech_id`（玛沙机甲），确认同样能解析。

### 1B. 回合流程顺序（用户希望效果执行后才抽牌/金币）

**现象**：当前 TurnService.start_turn 顺序是 `fire TURN_START` -> `restore_power` -> `draw 2 action + 1 equipment` -> `gain gold` -> `fire TURN_AFTER_START`。用户希望按权威文档顺序：

```
1、回合开始前（TURN_BEFORE_START）
2、回合开始时（TURN_START）
3、回复机甲动力（TURN_START 时点的一部分/在其后）
3、抽取2行动牌、1装备牌、获得2金币（回合开始后）
4、回合进行中
```

用户原话："应该是回合开始时时点之后，才进行抽2行动牌、2金币、1装备牌（虽然这个无伤大雅，但我觉得不舒服）"。

**修复方向**：把 `restore_power` 挪到 `fire TURN_START` **之前**（或紧随其后但在抽牌前），保证 `fire TURN_START`（触发玛沙转化）在 `restore_power` 之后、`draw`/`gain_gold` 之前。即顺序改为：
`TURN_BEFORE_START` -> `restore_power` -> `fire TURN_START`（玛沙在此触发，power 已回复）-> `draw 2 action + 1 equipment` -> `gain gold` -> `fire TURN_AFTER_START`。

注意：玛沙转化效果会 `power +N`（cap_bonus 补满），必须在 `restore_power` 之后才有意义（否则补满后又被 restore 覆盖）。当前 restore_power 在 fire TURN_START 之后，玛沙转化在 restore_power 之后执行（弹窗异步），顺序碰巧对的，但改成 restore 先行更符合文档。

注意弹窗是异步的：fire TURN_START 挂起（玛沙 CHOOSE_ONE 弹窗）后，TurnService **不会阻塞**，继续执行 draw/gain_gold。这是正常的（玛沙转化抽牌在玩家确认后追加）。用户接受这个时序（他说"无伤大雅"只是顺序不舒服）。**改顺序即可，不要尝试同步等待弹窗**（那会卡死主线程）。

---

## 问题2：StepperPanel 非数字字符 + 范围标签不更新

**文件**：`scripts/ui/stepper_panel.gd`

### 2A. 允许输入非数字字符

**现象**：LineEdit 能输入字母等非数字字符并显示。

**根因**：`_on_text_changed`（line 134）过滤了数字到 `_current_value`，但**没把过滤后的文本 set_text 回 LineEdit**，所以非数字字符仍显示在输入框。另外 LineEdit 没设为纯数字模式。

**修复**：①`_on_text_changed` 过滤后调 `_line_edit.set_text(filtered)`（用 set_text 不触发 text_changed 回环）；或②在 `_ensure_layout` 给 LineEdit 设只允许数字（Godot 4 无原生数字模式，靠过滤）。注意 set_text 会移动光标到末尾，用户体验差，可用 caret_column 保存恢复。推荐：过滤后 set_text 回过滤值，若用户输入非法字符直接回退到纯数字。

### 2B. 范围标签 0~最大护甲 不随装备更新

**现象**：`range_hint` 标签显示的范围数字是旧值（没更新），但输入框实际判断的 max_value 是对的。

**根因**：`configure`（line 27）设了 `_min_value`/`_max_value`，但 `range_hint.text` 只在 `_ensure_layout`（line 39）里创建时设一次。第二次 configure 时 `_ensure_layout` 因 `if _vbox: return`（line 41）直接返回，**range_hint.text 不更新**。

**修复**：`configure` 末尾（或 `_refresh_value`）显式更新 range_hint.text：`range_hint.text = "范围：%d ~ %d" % [_min_value, _max_value]`。把 range_hint 存为成员变量或在 _ensure_layout 后单独更新。推荐：把 `_ensure_layout` 拆为"创建布局"和"更新值"两步，或 configure 里 `if range_hint: range_hint.text = ...`。

---

## 问题3：effect_02 应快过响应窗口（ATTACK_AT 响应窗口前触发）

**文件**：`scripts/generated_database/ActionPilotEffects.gd`（pilot_004_effect_02）+ 可能 `scripts/action_core/TimingEngine.gd`

**现象**：effect_02 监听 ATTACK_AT priority 30，但 ATTACK_AT 时点先开响应窗口（迎击），regular LISTEN 监听器（含 effect_02）被推迟到响应窗口关闭后（`_pending_regular_listeners`）才执行。用户希望 effect_02 在响应窗口**之前**触发（它是伤害计算效果，不是响应）。

用户原话："优先级改为30，应该是攻击时时点触发的，快过响应窗口，现在是慢于响应窗口，比较蠢。"

**根因**：`scripts/action_core/TimingEngine.gd` `fire_timing`（line 98）在 ATTACK_AT 时点先检查 AVAILABILITY 监听器（响应窗口），若有则 `_handle_response_window` 开窗 + 把 regular_listeners 暂存到 `_pending_regular_listeners`，等窗口关闭后 `_run_pending_regular_listeners` 补跑（line 194-201, 281）。effect_02 是 LISTEN 模式（非 AVAILABILITY），所以被推迟。

**修复方向（两选一，推荐方案A）**：

**方案A（改时点）**：effect_02 改监听 `ATTACK_PRE`（选择目标后、发动攻击前）而非 `ATTACK_AT`。ATTACK_PRE 在响应窗口之前 fire，effect_02 在响应窗口前触发。但需确认 ATTACK_PRE 时 attack 的 target_id/weapon_id 已确定（effect_02 的 SET_ATTACK_DEFENSE_STAT_SOURCE 需 target）。看 attack_action.gd 步骤：`select_weapon`(ATTACK_BEFORE) -> `select_target`(ATTACK_PRE) -> `execute_attack`(ATTACK_AT)。ATTACK_PRE 时 target 已选，可用。**但用户说"攻击时时点触发"**，可能坚持 ATTACK_AT。若用 ATTACK_PRE 需向用户确认。

**方案B（改 TimingEngine 让 LISTEN 在响应窗口前）**：在 fire_timing 的 ATTACK_AT 处理中，先执行非响应类的高优先级 LISTEN 效果（如 priority>=30 的"伤害计算"类），再开响应窗口。但这改动大、影响所有 ATTACK_AT LISTEN 效果，有回归风险（掩护 effect 等 LISTEN ATTACK_AT 的效果都受影响）。**不推荐**。

**推荐**：先向用户确认 effect_02 是否接受改用 ATTACK_PRE。若接受，改 `p004e2.listen_timing = _TC.ATTACK_PRE`（`scripts/generated_database/ActionPilotEffects.gd` 约 line 618）+ priority 30。若坚持 ATTACK_AT，走方案B（需仔细隔离"伤害计算类 LISTEN"与"响应窗口"，可能加 effect 标志位如 `pre_response: true` 让 fire_timing 优先执行）。

**注意 effect_02 的 SET_ATTACK_DEFENSE_STAT_SOURCE**：改时点后确认 attack_action._step_calculate_damage 读 defense_stat_source 的时机（ATTACK_AFTER），effect_02 在 ATTACK_PRE/AT 写入，ATTACK_AFTER 读取，payload 跨时点共享 record，应能读到。

---

## 验证

1. 改完跑专项测试：`timeout 240 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd 2>&1 | grep -E "pilot_004|FAIL|TESTS"`
2. 全量无回归：`timeout 240 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd 2>&1 | tail -5`
3. 若改了 effect_01a params（加 player_id）或 effect_02 时点，同步更新 `tests/test_pilot_004_masha.gd`（test1 验证抽牌数、test4/5 验证 effect_02）。test1 当前验证 `s.player.action_hand.size() != hand_before + 2`（玛沙抽2张），若 fix 1A 后玛沙在敌方回合转化，需新增/调整测试验证抽牌进玛沙手牌而非当前回合玩家。
4. 实机验证（用户手动）：玛沙在敌方回合转化 -> 抽牌进玛沙手牌；数值框只允许数字+范围标签更新；effect_02 在响应窗口前触发。

## 改动文件清单

- `scripts/generated_database/ActionPilotEffects.gd` - pilot_004 effect_01a EXECUTE_GAIN_CARD 加 player_id（+确认 EXECUTE_STAT_MODIFY target_id 解析）；effect_02 时点/priority（方案A改 ATTACK_PRE 或方案B加标志）
- `scripts/action_core/TimingEngine.gd` - CHOOSE_INTEGER 分支 special-case 的 params 解析确认支持 `$binding_context.xxx`（若方案B，加 pre_response 逻辑）
- `scripts/ui/stepper_panel.gd` - `_on_text_changed` 过滤后回写文本；`configure` 更新 range_hint.text
- `scripts/services/TurnService.gd` - restore_power 挪到 fire TURN_START 之前
- `tests/test_pilot_004_masha.gd` - 同步测试断言
