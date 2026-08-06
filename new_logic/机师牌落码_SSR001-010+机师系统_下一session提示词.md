# 机师牌落码 · SSR 001-010 + 机师牌系统 · 下一 session 提示词

> 本文件是给**写代码的 session** 的任务书。输入权威：`new_logic/机师牌效果逻辑拆解_SSR_001-010.txt`（外部模型拆解 + 人类裁定的「回答/补充/重要补充」）。**裁定优先级见第 1 节**，与拆解正文冲突时以裁定为准。先做 PvP 双人类玩家，**不管 AI**。

---

## 0. 任务总览

本次落码分两块：

**A. 机师牌系统（基础设施，先做）**
- 开局机师选择流程：随机抽 3 张机师牌 → 玩家三选一 → 初始 15 金币 → 扣除所选机师 `cost` → 置入机师区（`pilot` 槽）
- 基础数值联动：机师牌的 `attack_limit`/`action_card_limit` 写入 `PlayerState`/`MechState`，并在 UI 显示**当前剩余回合攻击数**
- 机师效果注册/注销（支持中途换机师）
- `ActionEffect` 新增 `once_per_game_key` 字段（本批 SSR 未用，但建系统时一并加上，后续批次要用）
- 机师 UI：每个 effect 一个按钮（主动可点标号 / 被动置灰），悬停浮窗显示效果/状态/已用/剩余/X
- dev 模式对机师牌的操作（更换机师 / 修改数值）
- PvP 状态同步（`net/state_snapshot.gd`）补机师数值与剩余攻击数

**B. SSR pilot_001-010 效果落码**（按拆解 + 裁定，逐张写 `ActionEffect` 定义 + 新增件 + 测试）

落码前先重读 `CLAUDE.md`（架构总览）与本提示词第 1 节裁定。

---

## 1. 裁定优先级与 delta 清单（必读，高于拆解正文）

拆解文每个 effect 的 GDScript 字面量是落码基线，但下列**人类裁定推翻了拆解默认**，实现时必须按裁定：

### pilot_001 阿克罗姆
- 歧义1-4：智能体选择正确（重复攻击 passive 不计攻击数；目标重新选；重复完整 effect 链；失败不返还次数）。
- **补充（重要）**：迎击牌一般**不能**生效两次（一次攻击只能被响应一次，第1张迎击结算后时点已过，第2次无法响应）。**掩护、推进**（使用迎击牌时使用的辅助类）可以生效两次。→ `REPEAT_USED_ACTION_EFFECT_CHAIN` 对迎击牌需判定不可重复（条件或动作内拦截）。

### pilot_002 莱比尔
- 歧义1（重大）：交出的牌**不进临时区**，直接交给目标机甲手牌，之后目标触发对应效果；整体当作 **1 次**进攻/防御使用。
- 歧义4（推翻拆解）：莱比尔**离场后所有权限和增益都没了**（不保留已转移批次权限）。→ 换/下莱比尔时立即撤销其所有授予能力 + 护甲光环。

### pilot_003 瑟尔基尔
- 歧义3（推翻拆解）：换机师后**离堆效果不保留**（metadata 不持续生效），但**牌仍正面朝上**；被别人抽走进入手牌后变成**正常牌**（对别人不可见，只持有者可见）。
- 歧义4（推翻拆解）：正面牌被抽走触发离堆效果后，**原抽牌者不补抽**（就是用这次抽牌机会使牌离堆的）。
- **重要补充（effect_03 UI 改案）**：不每次抽牌都问瑟尔基尔。改成：点 effect_03 按钮弹出**复选框列表**（列出所有玩家含自己），瑟尔基尔勾选「抽牌跳过正面牌」的玩家，提交后生效；被勾选玩家抽牌遇正面牌自动跳过；**仅当瑟尔基尔自己被勾选且本次即将抽的牌里会包含正面牌时**，本次抽牌数 +1（按「次」计，一次抽 N 张只 +1 变 N+1）；未勾选玩家不能跳过。复选框可随时改，提交后更新。

### pilot_004 玛沙
- 歧义1（补充）：转化护甲得到的动力**增加上限并补满**，护甲**减少上限**。UI 建议**输入框 + +1/+3 按钮**方便确定转化数值（不是滑条也行，但要有快捷按钮）。
- 歧义3：没有「攻击主体」歧义——「我方攻击或被攻击时」**都是玛沙的效果，只有他能用**（攻击方分支=玛沙是攻击者；被攻击分支=玛沙是目标）。

### pilot_005 肯特
- 歧义1（推翻拆解）：对侧手牌不足 2 张时**可以发动并弃置其全部剩余牌**（因为这是触发效果不是支付成本）。
- 歧义3：帝国机甲框架动力 +4 是**加上限并补满**（对所有帝国机甲框架生效，当前动力同步 +4）。

### pilot_006 里昂
- 歧义1（**重大推翻**）：抽到攻击牌**不立即使用**！只是给该牌一个增益：「不计回合攻击数」，**增益持续到该牌离开持有者手牌**。这就是一张有增益的普通攻击牌，不会即时使用。→ effect_02 不是「抽并立即使用」，而是「抽 1，若为攻击牌则给它挂 passive_attack_bonus 标记直到离手」。
- 歧义2：抽到攻击牌无法使用时牌本来就留手上（同歧义1）。
- 歧义4（补充）：战后逼迫目标「立即使用 1 张攻击牌」——**必须是原始攻击牌**，当作转化的进攻/强袭/猛击等虚拟牌**不算攻击牌**，不能响应这个效果。智能体选择正确（二选一不能逃，取消选牌回落 4 伤害）。

### pilot_007 珀修斯
- 歧义3（补充）：目标手牌不足 X+1 时，**弃置全部剩余牌，但仍抽 X+1**（X 决定抽牌数，与实际弃置量无关）。
- 歧义4（**推翻拆解**）：**查看全部目标并分别结算**（不是选 1 台）。多目标攻击时对每个目标都执行 peek + 缺类型计算 + 弃抽。
- 补充：当作转化攻击、投掷式飞弹无攻击牌攻击**不触发** effect_01（必须攻击牌发动的攻击）。

### pilot_008 安德洛美达
- 歧义3：等量伤害按**实际可回复量**（不是请求回复量）。
- 歧义4：等量损伤按**实际可移除量**（不是请求移除量）。
- **重要补充（逆转触发范围）**：
  - effect_02（回复→伤害）：范围内机甲使用维修回复生命（理论回复4，若满血差只差3则实际可回复3），取消回复3生命，之后受3伤害（**这3伤害算无源伤害，不算安德洛美达造成**）。
  - effect_03（移除损伤→设置损伤）：范围内机甲使用维修移除损伤（理论2个，若只有1个则实际1个），取消移除，安德洛美达弹损伤面板逐个设置（**这损伤算无源损伤**）。
  - **设置新装备牌移除旧区域损伤也触发 effect_03**：新装备牌（耐久 A）移除区域原有损伤（原 B 个，最多移除 A 个）→ 该移除动作取消 → 安德洛美达设置 min(A,B) 个损伤。

### pilot_009 美杜莎
- 歧义1（**推翻拆解**）：**双方都可使用**受控牌，先用者得（非排他控制）。→ `GRANT_TEMP_CARD_CONTROL` 不是排他锁定，原持有者仍可用。
- 歧义2（**推翻拆解**）：立即弃置**必须全部弃置**（因为限定的是该类型所有牌），不是可选任意张（含0）。
- 歧义3（**推翻拆解**）：**持续光环**，直到回合结束所有新获得的同类型牌也受控（不是只快照结算时的牌）。
- 歧义5（推翻拆解）：美杜莎被换下后**立即解除**控制（不是保留到回合结束）。
- 补充（UI）：使用别人牌的效果做成——按按钮列出可用牌选框，选择使用。

### pilot_010 刻托
- 歧义4（选候选）：use_action 取消时**已计数**（牌进临时区即算「使用的第 X 张」，因为是按使用牌计数）。→ 计数点在牌进入临时区时，不在 effect 执行成功后。
- 其余智能体选择正确。

---

## 2. 机师牌系统（基础设施，先做）

### 2.1 开局机师选择流程

**现状**：`scripts/campaign/campaign_state.gd` 的 `initialize()` 只取 `pilots[0]`（教程固定机师），`select_pilot(id)` 从教程列表选；`app_root.gd:_render_loadout_screen` 只显示机师名无选择 UI。无随机 3 / 花费流程。

**要做**（PvP 流程）：
1. `CampaignState` 新增 `generate_random_pilot_selection(count: int = 3) -> Array`：从 `registry.list_pilot_cards()` 全量池随机抽 3 张（Fisher-Yates，仿 `generate_random_equipment_selection`）。
2. 新增 `select_pilot_with_cost(pilot_id) -> Dictionary`：校验 `PlayerState.gold >= pilot.cost`，扣金币，设 `selected_pilot`。返回是否成功。
3. `app_root.gd` 出击准备屏新增机师选择 UI：显示 3 张随机机师牌（名称/阵营/稀有度/费用/技能文本），玩家点选 1 张 → 扣 cost → 显示剩余金币 → 进装备选择。
4. 初始金币 15（`PlayerState.gold=15` 已有）。扣 cost 后若不足不允许选。
5. 「重新随机机师」按钮（可选，与装备 reroll 一致）。

**注意**：教程战斗（tutorial_campaign）流程保留；新流程用于 PvP。区分入口。

### 2.2 基础数值联动

**现状**：`PlayerState` 有 `gold=15/action_card_limit=5/attack_limit=1` 默认值；`MechState` 有 `attack_count_this_turn/max_attacks_per_turn`。但机师牌的 `attack_limit`/`action_card_limit`（`PilotCardDef`）**未联动**到 PlayerState/MechState。

**要做**：
1. 设置机师时（`GameSetupService` 或 `set_pilot` 入口）把 `pilot.attack_limit` → `PlayerState.attack_limit` 与 `MechState.max_attacks_per_turn`；`pilot.action_card_limit` → `PlayerState.action_card_limit`。
2. **剩余回合攻击数显示**：UI 显示 `max_attacks_per_turn - attack_count_this_turn`（或 `attack_count_this_turn / max_attacks_per_turn`）。回合开始重置 `attack_count_this_turn=0`（TurnService 已有逻辑，确认）。
3. 换机师时重算并钳制当前动力/手牌上限。
4. `net/state_snapshot.gd` 已同步 `action_card_limit/attack_limit/max_attacks_per_turn`（行 268-304），确认补 `attack_count_this_turn`。

### 2.3 机师效果注册/注销（核心）

**模板**：`scripts/action_defs/set_equipment_action.gd:167 _register_equipment_effects` → `timing_engine.register_permanent_listener(timing, effect, binding_context)`。

**要做**：
1. 新增机师效果注册函数（建议 `GameSetupService` 或新 `PilotEffectRegistry`）：
   - 机师设置到 `pilot` 槽后，遍历其 effect_ids 对应的 `ActionEffect`，按 `mode`/`listen_timing` 注册 permanent listener。
   - `binding_context = {card_instance_id, mech_id, player_id, slot_id=&"pilot", card_def_id}`。
   - DIRECT 主动效果也注册（供 skill_bar 扫描出按钮，仿装备 DIRECT）。
2. **换机师支持**：`unregister_permanent_listeners_for_card(old_card_instance_id)`（TimingEngine 已有，行 648）→ 注册新机师 effect。清理旧机师的派生光环/变量（按 `source_card_instance_id`）。
3. 新增 `set_pilot` action（`scripts/action_defs/set_pilot_action.gd`，仿 `set_equipment_action`）或在 `GameSetupService` 直接走，供 dev 模式换机师复用。
4. effect 定义落点：新建 `scripts/action_core/GeneratedPilotEffects.gd`（新，ActionEffect 格式）或并入 `GeneratedActionEffects.gd`。**旧 `scripts/generated_database/GeneratedPilotEffects.gd`（legacy CardEffect 占位）本次替换**，effect_ids 沿用其命名。

### 2.4 ActionEffect 新增字段

`scripts/action_core/ActionEffect.gd` 加：
```
@export var once_per_game_key: StringName = &""
```
`ActionEngine`/`TimingEngine` 触发前校验本局已用次数（`GameState` 存 `{key@card_instance_id: used_count}`）。本批 SSR 未用，但建系统时加上。

### 2.5 机师 UI

**模板**：装备面板 skill_bar 扫描 DIRECT effect 出按钮。

**要做**：机师牌旁并列排放 effect 按钮（每 effect 1 个）：
- 主动 effect：可点击，标号 1/2/...，条件不符置灰。点击触发对应 effect。
- 被动 effect：置灰不可点。
- 悬停浮窗：效果介绍 / 当前状态 / 已用次数 / 剩余次数 / X 变量值。
- 数据来源：扫描该机师 card_instance_id 的所有 permanent listener + once_per_turn 状态 + 变量。

### 2.6 dev 模式机师操作

`scripts/services/DevModeService.gd` 已有 `_pilot_card_ids`（行 14/93）。扩展：
1. **更换机师**：下拉选机师 → 走 `set_pilot`（注销旧 + 注册新 + 重算数值）。
2. **修改数值**：编辑 `attack_limit`/`action_card_limit`/`gold`/`cost` 等（即时重算 max_attacks_per_turn 等）。
3. dev 面板加机师操作区（仿装备编辑区）。

---

## 3. SSR pilot_001-010 落码（逐张）

每张按拆解文的 GDScript 字面量写 `ActionEffect` 定义，注意第 1 节 delta。下方只列**关键机制 / 需新增件 / 裁定要点**，完整字面量以拆解文为准。

### pilot_001 阿克罗姆（effect_01）
- 机制：USE_ACTION_AFTER 监听，第1次效果链完成后可选再执行1次。
- 新增动作：`REPEAT_USED_ACTION_EFFECT_CHAIN`（克隆最终有效 effect 链，新动作ID，攻击 passive=true，不重发 USE_ACTION_*）。
- 新增条件：`USED_CARD_EXECUTOR_IS_SELF`、`PAYLOAD_IS_PHYSICAL_ACTION_CARD`、`PAYLOAD_EFFECT_CHAIN_COMPLETED`、`PAYLOAD_REPEAT_DEPTH_BELOW(max_depth=1)`。
- 扩展 use_action_card record：`effective_effect_ids`、`effect_chain_completed`、`repeat_depth`、`original_card_instance_id`。
- **裁定**：迎击牌不可重复（掩护/推进可）；第2次重新选目标；失败不返还次数。

### pilot_002 莱比尔（effect_01/02/03）
- effect_01：阵营光环授予联邦机师「交牌当作进攻/防御」能力。新增 `GRANT_TRANSFER_BATCH_AS_NAMED_TYPE`、faction aura provider（与 005 共用）。
- effect_02：派生值型，`MechState.get_armor()` 实时重算 +4/来源。
- effect_03：DIRECT toggle，`TOGGLE_AURA_TARGET`。
- **裁定**：交牌不进临时区直接给目标手牌，整体当作 1 次进攻/防御；莱比尔离场所有权限+增益清零。

### pilot_003 瑟尔基尔（effect_01/02/03）
- effect_01：DIRECT，正面随机插牌堆 + 可选置顶。新增 `INSERT_ACTION_CARDS_FACE_UP_RANDOM`、`CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP`。
- effect_02：新时点 `CARD_LEAVE_ACTION_DECK_BEFORE`，离堆强制我方使用，新增 `IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK`、`CANCEL_PARENT_CARD_TRANSFER`。
- effect_03：`GAIN_CARD_BEFORE` 监听，新增 `SKIP_FACE_UP_ACTION_DECK_CARDS`、`MODIFY_GAIN_CARD_COUNT_IF_TARGET_IS_SELF`。
- 扩展 `ActionCardState`：`face_up_in_deck`、`runtime_metadata`。
- **裁定**：换机师后离堆效果不保留但牌仍正面（被抽走入手变正常牌）；原抽牌者不补抽；effect_03 用复选框勾选玩家 UI（重要补充）。

### pilot_004 玛沙（effect_01/02/03a/03b）
- effect_01：TURN_START 监听，护甲转动力。新增 `CHOOSE_NUMERIC_VALUE`、`SELF_EFFECTIVE_ARMOR_ABOVE`、`CLEAR_SOURCE_STAT_MODIFIERS`。
- effect_02：TURN_BEFORE_START 清转换层（priority 30）。
- effect_03a/03b：ATTACK_PRE 监听，新增 `SET_ATTACK_DEFENSE_STAT_SOURCE`（改 attack record 防御值来源为 current_power）。
- **裁定**：转化动力加上限并补满+护甲减上限；输入框+按钮 UI；攻击/被攻击都是玛沙自己；任意玩家回合开始触发。

### pilot_005 肯特（effect_01/02/03）
- effect_01：阵营光环授予帝国机师 ATTACK_PRE 弃对侧 2 牌。新增 `SELF_MECH_IS_ATTACKER_OR_TARGET`、`OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE`、`CHOOSE_ATTACK_TARGET_ENTRY`（与 006/007 共用）。faction aura 与 002 共用。
- effect_02：派生值 `MechState.get_total_power()` +4/来源。
- effect_03：DIRECT toggle。
- **裁定**：对侧手牌不足 2 时弃全部剩余（非成本）；动力 +4 上限并补满。

### pilot_006 里昂（effect_01/02/03）
- effect_01：ROUND_START 选悬赏目标。新增 `SET_ROUND_MARKED_TARGET`、`ATTACK_TARGET_HAS_SOURCE_MARK`。
- effect_02：**裁定改案**——ATTACK_PRE 悬赏目标被攻击时攻击方抽 1，**若为攻击牌则挂 passive_attack_bonus 标记（不计回合攻击数，持续到离手）**，**不立即使用**。新增 `DRAW_ACTION_AND_TAG_IF_ATTACK`（而非 `DRAW_ACTION_AND_IF_ATTACK_IMMEDIATELY_USE_ON_TARGET`）。
- effect_03：ATTACK_SETTLE 选 5 格内目标二选一。新增 `CHOOSE_TARGET_AND_EXECUTE`、`MECH_HAS_USABLE_ATTACK_CARD`。
- **裁定**：抽到攻击牌不立即使用，只挂增益；战后逼迫必须原始攻击牌（不当作转化）；必须选目标。

### pilot_007 珀修斯（effect_01/02）
- effect_01：ATTACK_SETTLE 夺取攻击来源牌并可选立即使用。新增 `ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD`、`ATTACK_SOURCE_ACTION_CARD_TYPE_IS`、`ATTACK_SOURCE_CARD_CAN_BE_CLAIMED`、`CLAIM_RESOLVED_ATTACK_SOURCE_CARD`、`RUNTIME_CARD_IS_USABLE_BY_MECH`。use_action cleanup 支持 `cleanup_skip_card_ids`。
- effect_02：ATTACK_PRE peek 目标手牌 + 缺类型弃抽。新增 `CALCULATE_MISSING_ACTION_CARD_TYPES`、`RUNTIME_TARGET_HAND_AT_LEAST`、`CHOOSE_ATTACK_TARGET_ENTRY`。
- **裁定**：手牌不足 X+1 时弃全部剩余仍抽 X+1；**查看全部目标并分别结算**；当作/飞弹不触发 effect_01。

### pilot_008 安德洛美达（effect_01a/01b/02/03）
- effect_01a/01b：USE_ACTION_SETTLE / DISCARD_SETTLE 监听，回收维修 X+1。新增 `PAYLOAD_PHYSICAL_CARD_DEF_ID_IS`、`DISCARD_CONTAINS_CARD_DEF_ID`、`CHOOSE_ONE_CARD_FROM_PAYLOAD`、`SOURCE_CARD_INSTANCE_CAN_BE_GAINED`。
- effect_02：HP_CHANGE_BEFORE 回复→等量伤害（按**实际可回复量**，无源伤害）。`REDIRECT_HEAL_TO_DAMAGE`。
- effect_03：DAMAGE_CHANGE_BEFORE 移除→设置等量损伤（按**实际可移除量**，无源损伤）。新增 `PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE`、`HP_CHANGE_METHOD_IS`、`DAMAGE_CHANGE_METHOD_IS`、`DAMAGE_CHANGE_AMOUNT_ABOVE`。`REDIRECT_REMOVE_TO_PLACE_TOKENS`。
- X 变量：`INCREMENT_VARIABLE` 绑 `card_instance_id`，max 5。
- **裁定**：逆转按实际量；无源伤害/损伤；**设置新装备移除旧区域损伤也触发 effect_03**（取 min(耐久A, 原损伤B)）。

### pilot_009 美杜莎（effect_01）
- DIRECT，5 格内选目标 reveal 手牌 + 选类型弃 1 支付 + 控制目标该类型牌。新增 `HAS_ACTION_CARD_TYPE_IN_HAND`、`GRANT_TEMP_CARD_CONTROL`。`EXECUTE_SHOW_CARD`/`EXECUTE_DISCARD`/`CHOOSE_MANY_CARDS`。
- **裁定（全推翻拆解默认）**：
  - 非排他控制，**双方可用，先用者得**（`GRANT_TEMP_CARD_CONTROL` 不锁原持有者）。
  - 立即弃置**必须全部弃置**（该类型所有牌）。
  - **持续光环**到回合结束，新获同类型牌也受控。
  - 美杜莎换下后**立即解除**控制。
- UI：按按钮列可用牌选框选择使用。

### pilot_010 刻托（effect_01/02/03）
- effect_01：TURN_START 互换上限/攻击数 + 抽牌。`SWAP_HAND_LIMIT_AND_ATTACK_COUNT`（扩展 persist_orientation + 设 remaining_attack_count）。
- effect_02：USE_ACTION_AT 第1/2/3张攻击牌视为强袭/闪击/预判。新增 `REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE`、`OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW`、`USED_CARD_EXECUTOR_IS_SELF`、`PAYLOAD_IS_PHYSICAL_ACTION_CARD`。
- effect_03：权限型 helper `can_pilot_010_use_physical_attack_card`，第4张禁止。turn counter `pilot_010_attack_card_uses@pilot_instance@active_turn_id`。
- **裁定**：互换持久；不互换不抽；虚拟当作不计数；**牌进临时区即计数**（取消 use 也算）；每活动回合各自重置。

---

## 4. 共享新增件统一清单（统一登记，禁回退 CUSTOM_EFFECT_CHECK_TEXT）

### 4.1 ActionEffect 字段
- `once_per_game_key`（2.4）

### 4.2 时点（TimingConst）
- `CARD_LEAVE_ACTION_DECK_BEFORE`（003）

### 4.3 条件 op（ConditionChecker）
通用：`USED_CARD_EXECUTOR_IS_SELF`（001/010）、`PAYLOAD_IS_PHYSICAL_ACTION_CARD`（001/010/007）、`PAYLOAD_EFFECT_CHAIN_COMPLETED`、`PAYLOAD_REPEAT_DEPTH_BELOW`、`SELF_EFFECTIVE_ARMOR_ABOVE`（004）、`TURN_OWNER_IS_SELF`（004/010）、`HAS_OTHER_MECH_IN_HEX_RANGE`、`HAS_OTHER_MECH_ON_FIELD`、`HAS_ANY_MECH_ON_FIELD`、`HAS_ACTION_CARD_TYPE_IN_HAND`（009）、`RUNTIME_CARD_IS_USABLE_BY_MECH`、`RUNTIME_TARGET_HAND_AT_LEAST`（007）、`MECH_HAS_USABLE_ATTACK_CARD`（006）
攻击来源：`ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD`、`ATTACK_SOURCE_ACTION_CARD_TYPE_IS`、`ATTACK_SOURCE_CARD_CAN_BE_CLAIMED`、`SELF_MECH_IS_ATTACKER_OR_TARGET`（005）、`OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE`（005）、`ATTACK_TARGET_HAS_SOURCE_MARK`（006）、`ATTACK_HAS_TARGET`、`ATTACKER_ALIVE`、`SELF_MECH_ALIVE`
弃置/堆：`PAYLOAD_PHYSICAL_CARD_DEF_ID_IS`、`DISCARD_CONTAINS_CARD_DEF_ID`、`SOURCE_CARD_INSTANCE_CAN_BE_GAINED`（008）、`ACTION_DECK_HAS_FACE_UP_CARD`、`GAIN_SOURCE_IS`、`GAIN_REASON_IS`（003）
数值/变量：`PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE`、`HP_CHANGE_METHOD_IS`、`HP_CHANGE_AMOUNT_ABOVE`、`DAMAGE_CHANGE_METHOD_IS`、`DAMAGE_CHANGE_AMOUNT_ABOVE`（008）、`OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW`（010）、`SOURCE_RUNTIME_MODIFIER_EXISTS`（004）

### 4.4 动作（set_actions type）
`REPEAT_USED_ACTION_EFFECT_CHAIN`（001）、`GRANT_TRANSFER_BATCH_AS_NAMED_TYPE`（002）、`INSERT_ACTION_CARDS_FACE_UP_RANDOM`、`CHOOSE_ONE_INSERTED_CARD_TO_DECK_TOP`、`CANCEL_PARENT_CARD_TRANSFER`、`IMMEDIATELY_USE_DECK_CARD_OR_FALLBACK`、`SKIP_FACE_UP_ACTION_DECK_CARDS`、`MODIFY_GAIN_CARD_COUNT_IF_TARGET_IS_SELF`（003）、`CHOOSE_NUMERIC_VALUE`、`CLEAR_SOURCE_STAT_MODIFIERS`、`SET_ATTACK_DEFENSE_STAT_SOURCE`（004）、`CHOOSE_ATTACK_TARGET_ENTRY`（005/006/007）、`SET_ROUND_MARKED_TARGET`、`DRAW_ACTION_AND_TAG_IF_ATTACK`（006 裁定改案）、`CHOOSE_TARGET_AND_EXECUTE`（006）、`CLAIM_RESOLVED_ATTACK_SOURCE_CARD`、`CALCULATE_MISSING_ACTION_CARD_TYPES`（007）、`CHOOSE_ONE_CARD_FROM_PAYLOAD`、`GRANT_TEMP_CARD_CONTROL`（009，非排他）、`REPLACE_USED_ACTION_EFFECT_BY_SEQUENCE`（010）

### 4.5 复用既有
`TRANSFER_ACTION_CARDS`、`TREAT_CARD_AS_NAMED_TYPE`、`FORCE_MECH_ACTION`、`DECLARE_CARD_TYPE`、`ROLL_D6`、`INCREMENT_VARIABLE`、`SWAP_HAND_LIMIT_AND_ATTACK_COUNT`、`GRANT_EFFECT_TO_FACTION`、`TOGGLE_AURA_TARGET`、`TOGGLE_EFFECT_ON_MECH`、`REDIRECT_HEAL_TO_DAMAGE`、`REDIRECT_REMOVE_TO_PLACE_TOKENS`、`GAIN_SPECIFIC_CARD`、`EXECUTE_SHOW_CARD`/`EXECUTE_DISCARD`/`EXECUTE_USE_ACTION_CARD`/`EXECUTE_ATTACK`(passive)、`CHOOSE_ONE`/`CHOOSE_MANY_CARDS`、`MODIFY_ARMOR`/`MODIFY_MECH_POWER`/`SPEND_POWER`/`DRAW_ACTION`/`DEAL_DAMAGE`/`HEAL_HP`/`GAIN_GOLD`/`SPEND_GOLD`

---

## 5. 落码顺序建议

1. **系统 infra**：2.4（once_per_game_key）→ 2.2（数值联动）→ 2.3（注册/注销 + set_pilot）→ 2.5（UI 按钮）→ 2.1（选择流程）→ 2.6（dev）
2. **通用新增件**：4.3/4.4 中跨牌复用的先做（`USED_CARD_EXECUTOR_IS_SELF`、`PAYLOAD_IS_PHYSICAL_ACTION_CARD`、`CHOOSE_NUMERIC_VALUE`、`CHOOSE_ATTACK_TARGET_ENTRY`、faction aura provider、变量服务 card_instance_id keying）
3. **简单机师先**：pilot_004（玛沙，数值转化+攻击替换）、pilot_010（刻托，互换+视为序列）
4. **中等**：pilot_005（肯特，阵营光环）、pilot_002（莱比尔，批次转化）、pilot_001（阿克罗姆，重复链）
5. **复杂**：pilot_006（里昂，悬赏+增益而非立即用）、pilot_007（珀修斯，夺牌+多目标）、pilot_009（美杜莎，非排他控制）、pilot_008（安德洛美达，逆转+装备移损伤触发）、pilot_003（瑟尔基尔，牌堆正面牌+复选框 UI）

每张落码后跑该牌的测试场景（拆解文已给前置/操作/断言）。

---

## 6. 测试与验收

- 每张牌至少跑拆解文「测试场景」的 a/b/c（正常/取消/条件不满足）。
- PvP 双人类玩家场景：两窗口操作，验证跨玩家弹窗（请求、强制二选一、 peek）、状态同步。
- 换机师测试：dev 模式换机师 → 旧 listener 注销 + 派生光环失效 + 变量隔离（pilot_008 X 不转移）。
- 剩余攻击数显示：UI 实时反映 `max_attacks_per_turn - attack_count_this_turn`。
- **裁决 delta 专项测试**：pilot_006 抽攻击牌不立即用、pilot_009 双方可用+必须全弃+持续光环+换下即解、pilot_010 进临时区即计数、pilot_008 设置装备移损伤触发。
- 测试基建：`"F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`，SLog preload 代理规则不变。

---

## 7. 关键坑

- **priority 约定**：`TimingEngine` sort `return pa > pb` → **数值越大越先**；范围 -1~30，常规 10，顺序保证 20/30，**上限 30**（`ActionEffect.gd:19` 注释「越小越先」是错的，别信）。
- 当作=出牌前转化（虚拟牌无类型、攻击类消耗回合攻击数=主动）；视为=出牌后替换（已计攻击数）；立即使用=被动不计攻击数。
- 机师 effect 注册 binding_context 必须含 `slot_id=&"pilot"` + `card_def_id`，派生光环/变量按 `source_card_instance_id` 隔离。
- 换机师：unregister by card_instance_id + 清派生光环 + 清变量（按裁定：pilot_003 离堆效果不保留、pilot_008 X 不转移、pilot_009 控制立即解除、pilot_002 授予全清）。
- PvP 同步：机师数值、剩余攻击数、X 变量、正面牌（双端一致种子）都要进 `state_snapshot`。
- effect_ids 沿用旧 `GeneratedPilotEffects.gd` 命名，JSON 手工核对（拆解文第 7/15 条）。

---

## 8. 开始

按第 5 节顺序落码。每张牌：读拆解文对应节 → 应用第 1 节裁定 delta → 写 ActionEffect 定义 + 新增件登记 → 跑测试场景。系统 infra 先于效果。PvP only。
