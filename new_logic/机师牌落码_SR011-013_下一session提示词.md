# 机师牌 SR 011-013 落码 · 下一 session 提示词

> **直接开始落码，不要中途停**。前置 SSR 001-010 + 机师系统基础设施已提交（1527b42），本批只加 SR 三张机师效果 + 它们需要的新增件。权威拆解 = `new_logic/机师牌效果逻辑拆解_SR_修订版_011-013.txt`（修订版，含人类裁定，已落实在 effect 规格里）。歧义点的「▶ 回答」即最终结论，不再质疑。

---

## 0. 工作纪律（用户要求，必须遵守）

1. **只做 PvP 人类玩家**的逻辑和 UI，且要通用（任意数量人类玩家可复用，不要写死 P1/P2）。不管 AI。
2. **不要做多余阅读**：只读本提示词点名的文件 + 权威拆解。有记忆就用记忆（见 `C:\Users\m1396\.claude\projects\f--Battle-GEAR-S\memory\`，尤其中 `pilot-effects-decomp-and-semantics-2026-08-05.md`）。**每完成一个里程碑就存/更新记忆**。
3. **过程中不懂/不确定就问我**（用 AskUserQuestion 或直接问），**不要等做完一批再问**，多问少错。但能从拆解文/代码直接确定的不要问。
4. **不要用 Agent（subagent）**。**不要用 `python3`，用 `python`**。
5. **保证先前测试全部通过、无引入回归**：每加一个 effect/件就跑一次测试。
6. **Godot**：`F:\Godot_4.6\Godot_v4.6-stable_win64.exe`。每次跑测试**用 timeout 包住及时关闭**，否则爆内存：
   - `timeout 120 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`
7. **不要质疑我列出的问题**，这些问题都存在；不需要你核验日志，要你看日志我会说。

---

## 1. 前置状态（已就位，直接复用，勿重建）

SSR 批次已建好机师系统基础设施，本批**只在此基础上加 effect**：

- **`ActionEffect.gd`**：已有 `once_per_turn_key/max`、`once_per_game_key/max`、`availability_condition/priority`、`mode`(DIRECT/LISTEN/AVAILABILITY) 等全部字段。
- **`ActionPilotEffects.gd`**（`scripts/generated_database/`）：SSR 效果定义落点。`_card_effect_map`(card_def_id→effect_ids)、`get_effects_for_pilot`、派生值 helper（pilot_002/005 光环、pilot_008 X、pilot_006 mark、pilot_003 skip_players）已有。**SR 011-013 的 effect 定义加在本文件**，仿 SSR effect 写法（用 `_ActionEffect.new()` + `set_conditions/set_target_rules/set_costs/set_actions`）。
- **注册路径**：`GameSetupService.set_pilot(mech_id, pilot_card_instance)` → `_register_pilot_effects` → `timing_engine.register_permanent_listener(timing, effect, binding_context={card_instance_id, mech_id, player_id, slot_id=&"pilot", card_def_id})`。换机师 `unset_pilot` 注销旧 listener。**SR effect 自动走此路径，无需改注册逻辑**。
- **PvP 选机师流程**：`app_root.gd`（`_pvp_both_pilots_ready` 等）已实现双方选机师 + 锁步 set_pilot。
- **dev 模式**：`dev_mode_panel.gd` 已有 change_pilot（set/unset_pilot）。
- **priority 约定**：`TimingEngine` sort `return pa > pb` → **数值越大越先**，范围 -1~30（常规 10，顺序保证 20/30，**上限 30**）。`ActionEffect.gd:20` 注释「越小越先」是错的，别信。
- **核心语义**（已在记忆）：当作=出牌前转化（虚拟牌无类型、攻击类消耗回合攻击数=主动、迎击类走响应窗口、辅助类主阶段、不触发 USE_ACTION_*）；视为=出牌后替换；立即使用=被动攻击不计攻击数。

---

## 2. 任务：落码 pilot_011/012/013

权威规格在 `new_logic/机师牌效果逻辑拆解_SR_修订版_011-013.txt`，逐 effect 给了 GDScript 字面量。**照抄其 conditions/target_rules/costs/actions**，下面只列落码要点 + 新增件登记。

### pilot_013 巴托洛夫（先做，最简单，纯 LISTEN）
effect_ids：`pilot_013_effect_01`（非攻击伤害免疫）、`pilot_013_effect_02a`（自身+全部目标护甲/动力上限与当前值-4）、`pilot_013_effect_02b`（各命中目标攻击伤害+3）

- **effect_01**：LISTEN `HP_CHANGE_BEFORE`，priority 30。条件 `HP_CHANGE_TARGET_IS_SELF` + `HP_CHANGE_METHOD_IS(decrease)` + `HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE`。动作 `CANCEL_PARENT_ACTION`（只取消当前 hp_change，不取消来源其他动作/损伤）。
  - 关键：判断「攻击伤害」要核对 `root_attack_id` + 攻击步骤7来源标识（`created_by_attack_damage_step`），不能只看 reason 文本，防伪造。
  - 陷阱爆炸：伤害取消、损伤正常设置。
- **effect_02a**：LISTEN `ATTACK_PRE`，priority 20，`once_per_turn_key=pilot_013_effect_02`。自身 + 全部机甲目标（`ALL_CURRENT_ATTACK_MECH_TARGETS`）护甲/动力**上限与当前值各-4**（`EXECUTE_STAT_MODIFY` 的 `stat_changes` 数组，`max_delta`+`current_delta`，`apply_max_and_current_atomically=true`，`clamp_current_min=0`，`clamp_current_to_new_max=true`）。上限 modifier 持续到 `UNTIL_SOURCE_OWNER_NEXT_TURN_BEFORE_START`，`restore_current_on_expire=false`、`remove_max_modifier_on_expire=true`。自身只降一次；多目标用 `FOR_EACH_TARGET` 串行。写 `SET_ACTION_RECORD_FLAG(pilot_013_effect_02_fired, data.affected_target_ids)`。
- **effect_02b**：LISTEN `ATTACK_AFTER`，priority 20，`requires_effect=pilot_013_effect_02a`。对 `RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT` 的每个命中目标 `MODIFY_ATTACK_DAMAGE(attack_id, target_id, delta=3)`（改 `attack.record.per_target_results[target_id].damage`，**不另开 DEAL_DAMAGE**，故仍属攻击伤害、不被 effect_01 免疫）。

### pilot_012 玛丽尔（中，多目标夺牌）
effect_ids：`pilot_012_effect_01`（逐目标夺牌-动力）、`pilot_012_effect_02`（逐命中目标奖励）

- **effect_01**：LISTEN `ATTACK_PRE`，priority 10，`once_per_turn_key=pilot_012_effect_01`（**按攻击计 1 次**，多目标不重复计）。`CHOOSE_ONE` 总发动确认 → `FOR_EACH_TARGET`(全部机甲目标) 串行：`CONDITIONAL_ACTIONS`（`TARGET_HAS_ACTION_CARD` → `EXECUTE_STEAL` 选 1 张；无牌跳过夺牌）→ `MODIFY_MECH_POWER(target, -3, value_scope=CURRENT, method=decrease, min_value=0)`。全部完成 `SET_ACTION_RECORD_FLAG(pilot_012_effect_01_fired, affected_target_ids)`。
  - 关键裁定：目标无牌仍发动（只减动力，不弹空夺牌窗）；多目标全处理；陷阱标记不参与。
- **effect_02**：LISTEN `ATTACK_AFTER`，priority 10，`requires_effect=pilot_012_effect_01`。对 `ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG` 的每个命中目标，`CHOOSE_ONE`（可选）整体「抽1+回复3」（不可拆分）。
  - 关键裁定：每命中 1 个受影响目标就 1 次独立奖励选择；不占 effect_01 次数；两个目标都命中可抽2回6（受上限）。

### pilot_011 迪恩（最复杂，AVAILABILITY 转化 + 挡攻转移）
effect_ids：`pilot_011_effect_01a`（当作疾行）、`pilot_011_effect_01b`（当作反击）、`pilot_011_effect_02`（相邻挡攻）

- **effect_01a/01b**：AVAILABILITY `ATTACK_AT`，`availability_priority=5`。条件 `SELF_MECH_IS_ATTACK_TARGET` + `HAS_ACTION_CARD_IN_HAND(2)` + `ATTACK_NOT_RESPONDED`。cost `DISCARD_ACTION_CARD(2)`。共享 `once_per_turn_key=pilot_011_effect_01`（max 1）。动作 `TREAT_CARD_AS_NAMED_TYPE` 扩展参数：`on_conversion_committed_actions=[RESTORE_POWER 4]`（转化提交时立即回动力，先于移动）、`after_named_effect_chain_actions=[DRAW_ACTION 1]`（具名链全结算后抽1）、`await_complete_named_effect_chain=true`、01b 额外 `await_bound_attack_settle_effects=true`（反击效果2绑原攻击 ATTACK_SETTLE）。
  - 关键裁定：回4动力在转化提交时执行（影响疾行/反击移动预算）；抽1在**包括反击效果攻击在内的完整链**结算后；虚拟牌不触发 USE_ACTION_*。
- **effect_02**：AVAILABILITY `ATTACK_AT`，`availability_priority=10`。条件 `ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET(exclude_self, allowed=MECH, excluded=TRAP_MARKER)` + `SELF_MECH_IN_CURRENT_ATTACK_RANGE` + `ATTACK_NOT_RESPONDED` + `OWNER_CAN_USE_NAMED_COUNTER(疾行/反击, allow_physical, allow_virtual=[01a,01b])`。动作 `CHOOSE_AND_USE_NAMED_COUNTER`（列真实牌+虚拟来源），`before_use_committed_actions=[REDIRECT_ATTACK_TARGET_TO_SELF]`（正式使用前把选定机甲目标位改成迪恩），`rollback_actions_on_precommit_failure=[RESTORE_REDIRECTED_ATTACK_TARGET]`。
  - 关键裁定：只替换 1 个机甲目标；**陷阱标记不可转移**（即使相邻）；先改目标再执行迎击的自身目标校验；提交前失败回滚目标；提交后不可撤销。

---

## 3. 新增件清单（统一登记，按此顺序实现）

> 优先做 012/013 共用的「多目标迭代 + action record flag」基础件，再做 013，再做 012，最后 011。

### 3.1 条件 op（ConditionChecker.gd）
- `ATTACK_HAS_OTHER_MECH_TARGET`（012/013）：至少1个非攻击者自身的机甲目标；排除陷阱标记。
- `TARGET_HAS_ACTION_CARD(target_id, count)`（012）：动态 target_id 路径，检查持有行动牌。
- `ACTION_RECORD_FLAG_EQUALS(flag, value)`（012/013）：读 attack record 的 flag。
- `RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT(flag, target_ids_path)`（012/013）：标记目标集合中至少1台逐目标 hit=true。
- `HP_CHANGE_TARGET_IS_SELF`（013）：支持多目标 hp_change，仅匹配巴托洛夫目标项。
- `HP_CHANGE_METHOD_IS(method)`（013）。
- `HP_CHANGE_REASON_IS_NOT_ATTACK_DAMAGE`（013）：核对 `root_attack_id`+`created_by_attack_damage_step`，非只看 reason。
- `ATTACK_NOT_RESPONDED`（011）：attack record 未被任何迎击/响应标记。
- `ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET(self_mech_id, exclude_self, allowed_target_kinds=[MECH], excluded_target_kinds=[TRAP_MARKER])`（011）：相邻机甲目标，排除陷阱标记。
- `SELF_MECH_IN_CURRENT_ATTACK_RANGE`（011）：按当前攻击有效武器/范围验证迪恩是合法目标（不是纯六角距离）。
- `OWNER_CAN_USE_NAMED_COUNTER(named_types, allow_physical_cards, allow_virtual_sources, context_override)`（011）：真实牌或虚拟转化来源至少一个可用。

### 3.2 目标规则（TargetChecker.gd）
- `ALL_CURRENT_ATTACK_MECH_TARGETS(exclude_attacker, preserve_attack_target_order, allowed_target_kinds=[MECH])`（012/013）：自动取全部机甲目标，不弹选择 UI。
- `ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG(flag, target_ids_path, allowed_target_kinds=[MECH])`（012/013）：从 flag data 取命中目标。
- `CHOOSE_REDIRECTABLE_ADJACENT_MECH_ATTACK_TARGET(attack_id, protector_mech_id, min/max_count=1, exclude_self, allowed=MECH, excluded=TRAP_MARKER)`（011）：选1台可转移的相邻机甲目标，排除陷阱标记。

### 3.3 动作（ActionService.gd / TimingEngine._execute_actions）
- **`FOR_EACH_TARGET`**（复杂，012/013 共用）：参数 `targets, execution_mode=SERIAL, preserve_order, current_target_variable, actions`。串行执行每个目标，子动作/UI 暂停时父链暂停，当前目标完整结算后才下一目标。仿多目标攻击逐目标结算。
- **`CONDITIONAL_ACTIONS`**（复杂，012）：参数 `conditions, if_true_actions, if_false_actions`。条件成立走 true 分支否则 false。
- **`SET_ACTION_RECORD_FLAG`**（原子，012/013）：参数 `action_id, flag, value, data(支持数组 affected_target_ids/limit_counted_per_attack/self_mech_id)`。扩展 attack record 的 flags 字典。
- **`MODIFY_ATTACK_DAMAGE`**（原子，013）：参数 `attack_id, target_id, delta, min_value, reason, source_*`。改 `attack.record.per_target_results[target_id].damage`。仿 `MODIFY_ATTACK_MARKERS`。
- **`CHOOSE_AND_USE_NAMED_COUNTER`**（复杂，011）：参数 `named_types, responding_attack_id, executor_mech_id, protected_target_id, allow_physical_cards, allow_virtual_sources, candidate_context_override, transactional_until_use_committed, before_use_committed_actions, rollback_actions_on_precommit_failure`。列真实+虚拟来源，选来源支付成本，正式使用前执行 before hooks（改目标），失败回滚。
- **`REDIRECT_ATTACK_TARGET_TO_SELF`**（原子，011）：参数 `attack_id, protector_mech_id, replace_target_id, required_old_target_kind=MECH, forbid_old_target_kinds=[TRAP_MARKER], record_old_target, redirect_source_effect_id`。改 `attack.record.target_ids` 指定位，记录旧目标+索引。
- **`RESTORE_REDIRECTED_ATTACK_TARGET`**（原子，011）：按 redirect record 恢复旧目标+索引（仅提交前失败回滚用）。

### 3.4 扩展既有动作
- **`TREAT_CARD_AS_NAMED_TYPE`**（011）：加参数 `on_conversion_committed_actions`（转化提交时执行）、`after_named_effect_chain_actions`（具名链全结算后执行）、`await_complete_named_effect_chain`、`await_bound_attack_settle_effects`、`virtual_card_has_physical_instance/action_type=false`、`source_pilot_effect_id`。仿行动牌进临时区后等绑定监听器完成的 continuation。
- **`MODIFY_MECH_POWER`**（012）：支持 `value_scope=CURRENT`（只改当前动力不改上限）、`method=decrease`、`min_value=0`。
- **`EXECUTE_STAT_MODIFY`**（013）：支持 `stat_changes` 数组（每项 `stat_type/max_delta/current_delta`）、`apply_max_and_current_atomically`、`clamp_current_min`、`clamp_current_to_new_max`、`duration=UNTIL_SOURCE_OWNER_NEXT_TURN_BEFORE_START`、`duration_owner_id`、`source_card_instance_id/effect_id/source_target_id`、`restore_current_on_expire=false`、`remove_max_modifier_on_expire=true`。
- **`EXECUTE_STEAL`**（012）：支持 `card_kind=ACTION`、`chooser_id`、`optional`。
- **`CANCEL_PARENT_ACTION`**（013）：支持 `scope=CURRENT_ACTION`、`preserve_source_parent_action`（只取消当前 hp_change，不取消来源其他动作）。

### 3.5 新 duration 常量（TimingConst.gd）
- `UNTIL_SOURCE_OWNER_NEXT_TURN_BEFORE_START`（013）：持续到来源玩家下个 TURN_BEFORE_START。

### 3.6 新 availability_condition（TimingEngine 响应候选构建）
- `pilot_011_convert_to_dash_available` / `pilot_011_convert_to_counter_available` / `pilot_011_guard_adjacent_available`（011）：组合上述条件的可用性判断。

---

## 4. 落码顺序（小步，每步跑测试）

1. **读** `ActionPilotEffects.gd` 头部 + 一两个 SSR effect 写法（仿格式）+ 修订版拆解 011-013 全文。
2. **基础件（012/013 共用）**：`FOR_EACH_TARGET` + `SET_ACTION_RECORD_FLAG`/`ACTION_RECORD_FLAG_EQUALS` + `ATTACK_HAS_OTHER_MECH_TARGET` + `ALL_CURRENT_ATTACK_MECH_TARGETS` + `ALL_HIT_TARGETS_FROM_ACTION_RECORD_FLAG`/`RECORDED_AFFECTED_ATTACK_TARGET_HAS_HIT`。跑测试无回归。
3. **pilot_013**：effect_01（需 `HP_CHANGE_*` 条件 + `CANCEL_PARENT_ACTION` 扩展）→ effect_02a（`EXECUTE_STAT_MODIFY` 扩展 + `UNTIL_SOURCE_OWNER_NEXT_TURN_BEFORE_START` + `MODIFY_ATTACK_DAMAGE`）→ effect_02b。注册到 `ActionPilotEffects.gd` + `_card_effect_map`（pilot_cards.json effect_ids 已有，确认对齐）。跑 013 测试场景 a-l。
4. **pilot_012**：`MODIFY_MECH_POWER` CURRENT 扩展 + `TARGET_HAS_ACTION_CARD` + `CONDITIONAL_ACTIONS` + `EXECUTE_STEAL` 扩展 → effect_01 → effect_02。跑 012 测试 a-j。
5. **pilot_011**：`ATTACK_NOT_RESPONDED` + `ATTACK_HAS_ADJACENT_OTHER_MECH_TARGET` + `SELF_MECH_IN_CURRENT_ATTACK_RANGE` + `OWNER_CAN_USE_NAMED_COUNTER` + `CHOOSE_REDIRECTABLE_ADJACENT_MECH_ATTACK_TARGET` → `TREAT_CARD_AS_NAMED_TYPE` 扩展 → `CHOOSE_AND_USE_NAMED_COUNTER` + `REDIRECT_ATTACK_TARGET_TO_SELF` + `RESTORE_REDIRECTED_ATTACK_TARGET` → effect_01a/01b/02。跑 011 测试 a-l。
6. **机师 UI 按钮**：012/013 是 LISTEN（被动置灰按钮）；011 是 AVAILABILITY（响应窗口列项，不常驻按钮）。确认 skill_bar/响应窗口扫描到新 effect。
7. **全量回归**：`timeout 120 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`，全过。

每完成一张牌存一次记忆（更新 `pilot-effects-decomp-and-semantics-2026-08-05.md` 或新建 SR 落码进度记忆）。

---

## 5. 关键坑

- **priority 上限 30**，大先执行。013 effect_01 用 30（先于其他 HP_CHANGE_BEFORE 监听），013 effect_02a 用 20（先于响应窗口），02b 用 20。
- **013 effect_02a**：上限与当前值**同时**降 4（原子），上限持续到期移除、当前值不恢复。机师离场时清未到期上限 modifier，已扣当前值不回滚。
- **013 effect_01**：只免疫「生命减少」，不免疫损伤；判断攻击伤害必须核对 `root_attack_id`+步骤7标识，不只看 reason。
- **012 多目标**：effect_01 按攻击计 1 次（不是按目标）；每命中 1 目标 effect_02 各 1 次奖励；陷阱标记不参与。
- **011 当作转化**：回4动力在转化提交时（影响移动预算），抽1在完整链后（含反击效果攻击）；虚拟牌不触发 USE_ACTION_*；反击效果攻击 passive=true 不计攻击数。
- **011 挡攻**：先选来源付成本，正式使用前才改目标（`before_use_committed_actions`），改目标后迎击的 SELF_MECH_IS_ATTACK_TARGET 校验才通过；陷阱标记不可转移；提交前失败回滚目标。
- **GDScript 字面量**：StringName 用 `&"..."`，照抄拆解文的 conditions/target_rules/costs/actions。
- **effect_ids 对齐**：`data/cards/pilot_cards.json` 已有 pilot_011/012/013 的 effect_ids 数组，确认与 `ActionPilotEffects._card_effect_map` 一致；若不一致只做 ID 映射不改逻辑。

---

## 6. 开始

从第 4 节第 1 步开始。遇到不确定的机制/裁定时直接问我（不要停）。每步跑测试。`python` 不用 `python3`，不用 Agent。
