# 机师牌落码 SSR · 下一 session 接力提示词

> 本文件是给**下一个 session** 的任务书，承接上一个 session 的进度。**直接复制本文件内容作为下个 session 的开场提示词即可开工。**

---

## 0. 权威来源与裁定优先级（必读）

1. **权威拆解**：`new_logic/机师牌效果逻辑拆解_SSR_001-010.txt`（外部模型已输出）。其中每个 effect 的「回答」「补充」「重要补充」是**用户检查裁定的结果，权威最高**，与拆解正文冲突时以裁定为准。先重读该文件 + 本提示词第 2 节「已完成进度」+ 第 3 节「待做」。
2. **任务书原版**：`new_logic/机师牌落码_SSR001-010+机师系统_下一session提示词.md`（含裁定 delta 清单第 1 节、共享新增件清单第 4 节、落码顺序第 5 节）。
3. **记忆**：先用记忆。`MEMORY.md` 里 `pilot-system-infra-progress-2026-08-05` 是当前进度记忆；`gdscript-lambda-value-capture`、`pilot-effects-decomp-and-semantics-2026-08-05` 等相关。每完成一块更新进度记忆。
4. **先做 PvP 双人类玩家，不管 AI**。逻辑和 UI 按 `player_id` 通用路由，要能轻松复用到任意数量人类玩家。

---

## 1. 注意事项（必须遵守，与用户约定）

1. **先不管 AI**，主要做 PvP 人类玩家的逻辑和 UI，要通用（按 player_id 路由弹窗/操作，不 hardcoded player/enemy）。
2. **不要做多余的阅读和动作**，有记忆就用记忆，立即开始。也记得存/更新记忆。
3. **操作过程中不懂不确定的地方问我**（不要停止/结束操作后再问，在过程中商量着来），多问少错。
4. **不要用 Agent（subagent）**。不要用 python3，用 python。
5. **要保证先前测试全部通过无引入回归**。
6. **Godot 在 `F:/Godot_4.6/Godot_v4.6-stable_win64.exe`**，每次测试用 timeout 即时关闭，否则爆内存：
   ```bash
   timeout 150 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd 2>&1 | grep -E "TESTS (PASSED|FAILED)|FAIL " | head -5
   ```
7. **用中文回复用户**（用户看不懂英文）。代码/标识符/文件内注释保持英文。

---

## 2. 已完成进度（上一 session，18 测试全过，整套无回归）

### 2.1 基础设施（infra，已完成）

- **`once_per_game_key`**：`ActionEffect.gd` 加字段 + `TimingEngine._once_per_game_used` 存储/校验/标记（guard 在 `_execute_effect` once_per_turn guard 后；mark 在 4 处含 resume 路径）+ `can_trigger_active_effect` 检查。测试 `test_timing_listener.gd::test_once_per_game_*`。
- **`GameSetupService.set_pilot / unset_pilot / _register_pilot_effects`**：放牌进 pilot 槽 + 数值联动（`pilot.attack_limit`→`PlayerState.attack_limit`+`MechState.max_attacks_per_turn`；`action_card_limit`→`PlayerState.action_card_limit`）+ 注册效果到 TimingEngine（binding_context.slot_id=&"pilot"）+ aura register/unregister + recalc_power_limits。换机师：unset（注销 listener + unregister aura）+ set 新。
- **`ActionPilotEffects.gd`**（`scripts/generated_database/`，class_name 避开 legacy `GeneratedPilotEffects`）：`build_pilot_effects()` + `get_effects_for_pilot(card_def_id, context)` + `is_pilot_derived_effect` + aura helper（`register/unregister/toggle_aura_target`/`get_faction_pilot_aura_bonus`/`get_pilot_005_empire_power_bonus`/`get_pilot_002_federation_armor_bonus`/`is_aura_active_for_mech`）+ `get_pilot_008_x` + pilot_006 mark/tag + pilot_009 control。
- **MechState 接入派生光环**：`get_total_power()` 算入 `POWER_CAP_MODIFIER` + `pilot_005` 帝国光环；`get_armor()` 算入 `pilot_002` 联邦光环。
- **条件 op（ConditionChecker 加 match 分支）**：`SELF_MECH_ALIVE/ATTACKER_ALIVE/ATTACK_HAS_TARGET/HAS_OTHER_MECH_IN_HEX_RANGE/HAS_OTHER_MECH_ON_FIELD/HAS_ANY_MECH_ON_FIELD/SELF_EFFECTIVE_ARMOR_ABOVE/SOURCE_RUNTIME_MODIFIER_EXISTS/USED_CARD_EXECUTOR_IS_SELF/PAYLOAD_IS_PHYSICAL_ACTION_CARD/OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW/SELF_MECH_IS_ATTACKER_OR_TARGET/OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE/PILOT_AURA_ACTIVE_FOR_MECH/PAYLOAD_PHYSICAL_CARD_DEF_ID_IS/DISCARD_CONTAINS_CARD_DEF_ID/SOURCE_CARD_INSTANCE_CAN_BE_GAINED/HP_CHANGE_METHOD_IS/DAMAGE_CHANGE_METHOD_IS/HP_CHANGE_AMOUNT_ABOVE/DAMAGE_CHANGE_AMOUNT_ABOVE/PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE/ATTACK_TARGET_HAS_SOURCE_MARK/ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD/ATTACK_SOURCE_ACTION_CARD_TYPE_IS/ATTACK_SOURCE_CARD_CAN_BE_CLAIMED/HAS_ACTION_CARD_TYPE_IN_HAND/PAYLOAD_EFFECT_CHAIN_COMPLETED/PAYLOAD_REPEAT_DEPTH_BELOW`。
- **动作（atomic，ActionService `_is_atomic_action` + 顶部特殊处理或 match dispatch）**：`POWER_CAP_MODIFIER`(modify_mech_power mode=cap_bonus) / `CLEAR_SOURCE_STAT_MODIFIERS` / `SET_ATTACK_DEFENSE_STAT_SOURCE` / `REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE`(视为强袭/闪击/预判) / `PILOT_005_DISCARD_OPPOSING`(弃对侧2不足2弃全部) / `PILOT_008_RECOVER_REPAIR`(回收维修+X) / `SET_ROUND_MARKED_TARGET` / `DRAW_ACTION_AND_TAG_IF_ATTACK`(抽攻击牌挂 passive_attack_bonus 不立即用) / `CLAIM_RESOLVED_ATTACK_SOURCE_CARD`(夺牌+claimed 标记) / `GRANT_TEMP_CARD_CONTROL`(非排他控制) / `REPEAT_USED_ACTION_EFFECT_CHAIN`(克隆 DIRECT effect 重新执行，repeat_depth 防递归)。
- **其它**：`_eval_expr` 加 `$binding_context.mech_effective_armor`；`modify_armor` 加 `runtime_tag`；`stat_modify_action` 传 `mode/runtime_tag/source_card_id`；`increment_variable` 支持 `source_card_instance_id` keying + `max_value`（顶部特殊处理传 payload）；`use_action_card._step_execute_effects` 末尾设 `record["effect_chain_completed"]=true`；`use_action_card._step_settle` 跳过 `claimed_by_pilot_007` 牌；`swap_hand_limit_and_attack_count` 改持久语义；`toggle_aura_target` 支持 `toggle` 模式调 ActionPilotEffects。

### 2.2 已落码机师 effect（机制层 + 测试，`ActionPilotEffects.build_pilot_effects()`）

| 机师 | 完成 effect | 待做 |
|---|---|---|
| pilot_001 阿克罗姆 | effect_01 双重生效(REPEAT) | 集成测试 |
| pilot_002 莱比尔 | effect_02 联邦护甲+4 / effect_03 toggle | **effect_01 batch transform** |
| pilot_004 玛沙 | effect_01/02/03a/03b 全 | 集成测试 |
| pilot_005 肯特 | effect_01/02/03 全 | 集成测试 |
| pilot_006 里昂 | effect_01 悬赏 / effect_02 追击 | **effect_03 战后逼迫** |
| pilot_007 珀修斯 | effect_01 反夺攻击牌 | **effect_02 缺类型弃抽** |
| pilot_008 安德洛美达 | effect_01a/01b/02/03 全 | 集成测试 |
| pilot_009 美杜莎 | effect_01 蛇发支配(控制状态) | **使用受控牌 + 立即弃置全部** |
| pilot_010 刻托 | effect_01/02/03 全 | 集成测试 |
| pilot_003 瑟尔基尔 | — | **全部（最复杂）** |

测试文件：`tests/test_pilot_system.gd`（18 测试，已注册到 `run_tests.gd`）。测试模式：`_new_battle()` 建 BattleState + context；`_make_pilot_instance(gs, cdb, card_id, owner)` 建机师牌实例；直接调 `game_actions.xxx` 验证动作语义（不依赖 effect 触发）；effect 触发集成测试用 `fire_timing` + `resume_pending_effect(action_id, {"chosen_option_index":0})`。

---

## 3. 待做清单（详细，按优先级）

### 3.1 剩余 effect 落码

#### A. pilot_002 莱比尔 effect_01（batch transform，最复杂）
- 机制：联邦机师可交任意张行动牌给5格内其他机甲，接收者当作进攻/防御之一使用，交牌者抽2。
- 需新增：`GRANT_TRANSFER_BATCH_AS_NAMED_TYPE`（把转移牌绑定为不可拆分批次，接收者获得一次性"当作具名牌使用"权限，进攻分支 DIRECT + 防御分支 AVAILABILITY）。复用 `TRANSFER_ACTION_CARDS`/`CHOOSE_MANY_CARDS`/`EXECUTE_SHOW_CARD`。
- 裁定（权威）：交牌不进临时区，直接给目标手牌，整体当作1次进攻/防御；莱比尔离场后所有权限和增益都没了（不保留已转移批次权限）。
- 授予机制：仿 pilot_005 effect_01 的 `_grant_pilot_005_to_empire_mechs`，向联邦机师授予 DIRECT 进攻 + AVAILABILITY 防御能力。`_register_pilot_effects` 里 `pilot_002_effect_01` 已跳过（provider），需补授予逻辑。

#### B. pilot_006 里昂 effect_03（战后逼迫）
- 机制：我方攻击结算后，选5格内其他机甲，其选择立即使用1张攻击牌或受4伤害（二选一不可逃，取消选牌回落4伤害）。
- 需新增：`CHOOSE_TARGET_AND_EXECUTE`（选目标 + 被选目标二选一）+ `MECH_HAS_USABLE_ATTACK_CARD` 条件。
- 裁定：战后逼迫必须原始攻击牌（当作转化的进攻/强袭/猛击不算攻击牌，不能响应）；取消选牌回落4伤害。

#### C. pilot_007 珀修斯 effect_02（缺类型弃抽）
- 机制：我方使用攻击牌时，peek 目标手牌，计算缺攻击/迎击/辅助类型数 X，弃目标 X+1 张，我方抽 X+1。
- 需新增：`CALCULATE_MISSING_ACTION_CARD_TYPES` + `CHOOSE_ATTACK_TARGET_ENTRY`（多目标选1，pilot_006/007 共用）+ `RUNTIME_TARGET_HAND_AT_LEAST` 条件。
- 裁定：手牌不足 X+1 时弃全部剩余仍抽 X+1（X 决定抽牌数，与实际弃置量无关）；**查看全部目标并分别结算**（不选1台）；当作/飞弹不触发 effect_01（必须攻击牌发动的攻击）。

#### D. pilot_009 美杜莎（使用受控牌 + 立即弃置全部）
- 机制：控制目标该类型牌后，美杜莎可使用（use_action_card 校验 controller 可用）或立即弃置全部该类型牌。
- 需：改 `use_action_card._step_validate_card` 支持受控牌（controller 可用目标手牌，executor=controller）；`CHOOSE_MANY_CARDS` 立即弃置全部受控牌（裁定：必须全部弃置，含0）。
- 裁定：非排他控制（双方可用先用者得）；必须全弃该类型所有牌；持续光环到回合结束（新获同类型牌也受控）；换下立即解除。`GRANT_TEMP_CARD_CONTROL` + `is_card_type_controlled_by` 已建。

#### E. pilot_003 瑟尔基尔（最复杂，最后做）
- effect_01：DIRECT，正面随机插牌堆 + 可选置顶。`INSERT_ACTION_CARDS_FACE_UP_RANDOM` + `CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP`。
- effect_02：新时点 `CARD_LEAVE_ACTION_DECK_BEFORE`，离堆强制我方使用。`IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK` + `CANCEL_PARENT_CARD_TRANSFER`。
- effect_03：`GAIN_CARD_BEFORE` 监听，跳过正面牌。`SKIP_FACE_UP_ACTION_DECK_CARDS` + `MODIFY_GAIN_CARD_COUNT_IF_TARGET_IS_SELF`。
- **effect_03 UI 改案（重要补充，权威）**：不每次抽牌都问。点 effect_03 按钮弹**复选框列表**（列出所有玩家含自己），瑟尔基尔勾选"抽牌跳过正面牌"的玩家，提交后生效；被勾选玩家抽牌遇正面牌自动跳过；**仅当瑟尔基尔自己被勾选且本次即将抽的牌里会包含正面牌时**，本次抽牌数+1（按"次"计，一次抽 N 张只+1 变 N+1）；未勾选玩家不能跳过。复选框可随时改，提交后更新。
- 裁定：换机师后离堆效果不保留但牌仍正面朝上（被别人抽走入手变正常牌，别人不可见只持有者可见）；原抽牌者不补抽（用抽牌机会使牌离堆）；pilot_003 JSON 缺 effect_03，需补。
- 需扩展 `ActionCardState`：`face_up_in_deck` + `runtime_metadata`。

### 3.2 UI（用户定：机师效果按钮放 equipment_panel 机师槽旁）
- **机师效果按钮**：扫描该机师 card_instance_id 的 permanent listener，DIRECT 主动效果出可点按钮（条件不符置灰），被动置灰。悬停浮窗显示效果/状态/已用次数/剩余次数/X 变量。按钮放 `equipment_panel` 机师槽旁（用户选定）。
- **剩余回合攻击数显示**：UI 实时反映 `max_attacks_per_turn - attack_count_this_turn`。回合开始重置（TurnService 已重置 attack_count_this_turn，确认）。
- **弹窗按 player_id 通用路由**：所有 CHOOSE_ONE/CHOOSE_INTEGER/目标选择/弃牌选择等弹窗，按 effect 拥有者/被选者 player_id 路由到对应人类玩家窗口（多人类玩家可复用）。仿现有 `_effect_popup_owner_pid` / `_popup_owner` 机制。

### 3.3 开局机师选择流程（infra 2.1）
- **随机三选一**：`CampaignState.generate_random_pilot_selection(count=3)`（Fisher-Yates，仿 `generate_random_equipment_selection`，从 `CardDatabase.list_cards_by_kind(&"pilot")` 全量池抽）。
- **扣 cost**：`select_pilot_with_cost(pilot_id)`：校验 `PlayerState.gold >= pilot.cost`，扣金币，设 selected_pilot。
- **置入机师区**：选机师后调 `GameSetupService.set_pilot(mech_id, pilot_card_instance)`。
- **UI**：`app_root` 出击准备屏新增机师选择 UI（显示3张随机机师牌：名称/阵营/稀有度/费用/技能文本），玩家点选1张→扣 cost→显示剩余金币→进装备选择。初始金币15。PvP 流程；教程（tutorial_campaign）保留 pilots[0] 流程。
- 「重新随机机师」按钮（可选，与装备 reroll 一致）。

### 3.4 dev 模式机师操作（infra 2.6）
- `DevModeService` 已有 `_pilot_card_ids`。扩展：**更换机师**（下拉选机师→走 set_pilot：unset 旧 + register 新 + 重算数值）；**修改数值**（编辑 attack_limit/action_card_limit/gold/cost，即时重算 max_attacks_per_turn 等）。dev 面板加机师操作区（仿装备编辑区）。

### 3.5 PvP state_snapshot 同步
- `net/state_snapshot.gd` 已同步 `action_card_limit/attack_limit/max_attacks_per_turn`（行 268-304），需补：`attack_count_this_turn`、机师 card_instance_id + def、X 变量（pilot_008）、正面牌（pilot_003，双端一致种子）、pilot_009 控制状态、pilot_006 悬赏标记。

### 3.6 集成测试
- 每个 effect 至少跑拆解文「测试场景」的 a/b/c（正常/取消/条件不满足）。用 `fire_timing` + `resume_pending_effect(action_id, {"chosen_option_index":N})` 触发 LISTEN effect + CHOOSE_ONE。
- PvP 双人类玩家场景：两窗口操作，验证跨玩家弹窗（请求、强制二选一、peek）、状态同步。
- 换机师测试：dev 模式换机师→旧 listener 注销 + 派生光环失效 + 变量隔离（pilot_008 X 不转移、pilot_009 控制立即解除、pilot_002 授予全清）。
- **裁决 delta 专项测试**：pilot_006 抽攻击牌不立即用、pilot_009 双方可用+必须全弃+持续光环+换下即解、pilot_010 进临时区即计数、pilot_008 设置装备移损伤触发、pilot_001 迎击不可重复。

---

## 4. 关键坑（必读）

- **GeneratedActionEffects 在 `scripts/action_core/`**（非 generated_database）。
- **DeckState 字段 `action_discard_pile`**（非 action_discard）。
- **card_id 带_名字后缀**：`action_002_强袭`/`action_006_闪击`/`action_007_预判`/`action_013_维修`/`pilot_004_玛沙` 等。effect_ids 须手工核对 JSON 补全（pilot_004 已补 03a/03b，pilot_008 已改 01a/01b，pilot_003 待补 effect_03）。
- **priority higher-first**：TimingEngine sort `pa > pb`，数值越大越先；范围 -1~30，常规 10，顺序保证 20/30，上限 30。`ActionEffect.gd` 注释已修正。
- **modify_mech_power 即时改 power 不留痕**（无 runtime_tag/层），pilot_004 转换层用 `POWER_CAP_MODIFIER` 新机制解决（get_total_power 算入）。
- **GDScript lambda 按值捕获 int/bool**：测试信号计数须用 Array（`var fired: Array = []; signal.connect(func(eid): fired.append(eid))`），否则假通过。
- **atomic params 的 `$binding_context`/`$payload` 字符串**：atomic 顶部特殊处理需从 payload 取值（ga.replace/ga.set/ga.toggle 已处理 `begins_with("$")` fallback payload）。
- **`_register_pilot_effects` provider（pilot_005/002 effect_01）须在 `effect==null` 检查前处理**（provider 无 ActionEffect 定义）。
- **`INCREMENT_VARIABLE` 顶部特殊处理**：有 `source_card_instance_id`/`max_value` 时传 payload（pilot_008 X 绑 card_id）。
- **当作=出牌前转化（虚拟牌无类型、攻击类消耗回合攻击数=主动）；视为=出牌后替换（已计攻击数）；立即使用=被动不计攻击数**。
- **机师 effect 注册 binding_context 必须含 `slot_id=&"pilot"` + `card_def_id`**，派生光环/变量按 `source_card_instance_id` 隔离。
- **换机师**：unregister by card_instance_id + unregister_faction_aura + 清派生（pilot_003 离堆效果不保留、pilot_008 X 不转移、pilot_009 控制立即解除、pilot_002 授予全清）。

---

## 5. 落码顺序建议

1. **先做剩余简单 effect**：pilot_006 effect_03（CHOOSE_TARGET_AND_EXECUTE）/ pilot_007 effect_02（CALCULATE_MISSING_TYPES）/ pilot_009 使用受控牌+立即弃置。
2. **pilot_002 effect_01** batch transform（GRANT_TRANSFER_BATCH_AS_NAMED_TYPE）。
3. **pilot_003 瑟尔基尔**（最复杂，新时点 + 正面牌 + 复选框 UI）。
4. **UI**：equipment_panel 机师槽旁效果按钮 + 剩余攻击数显示 + 弹窗 player_id 路由。
5. **开局选择流程**（infra 2.1）+ **dev 模式**（infra 2.6）。
6. **PvP state_snapshot** 补机师数值。
7. **集成测试** + 裁决 delta 专项测试。

每完成一块：跑 `timeout 150 ... run_tests.gd` 确认无回归 → 更新 `pilot-system-infra-progress` 记忆 → 继续。过程中不确定就问用户，不要停。

---

## 6. 开工

按第 5 节顺序。先读 `new_logic/机师牌效果逻辑拆解_SSR_001-010.txt` 对应节 + 应用裁定 → 写 ActionEffect 定义/新增件 → 跑测试。先做 PvP 人类玩家。立即开始。
