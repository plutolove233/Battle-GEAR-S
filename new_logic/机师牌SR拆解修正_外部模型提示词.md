# 机师牌 SR 011-028 拆解修正 · 外部模型提示词

> **你没有此前会话的记忆，以下文件必须全部一并发给你**（缺一会导致约定/格式/权威缺失）。按本提示词修正并完善 SR 拆解，输出修订版全文。

---

## 零、需要输入给模型的文件（共 7 份，全部贴出）

| # | 文件路径 | 作用 | 性质 |
|---|---------|------|------|
| 1 | `new_logic/机师牌SR拆解修正_外部模型提示词.md`（本文件） | 修正指令 + delta 清单 + 约定重申 | **指令** |
| 2 | `new_logic/机师牌效果逻辑拆解_SR_011-028.txt` | 你此前输出的 SR 拆解，人类已在歧义点处标注「▶ 回答：…」「补充：」「重要补充：」 | **待修正对象** |
| 3 | `new_logic/机师牌效果逻辑拆解_SSR_001-010.txt` | 已裁定的 SSR 拆解（当作/视为/立即使用/光环/请求等机制的工作范例 + 输出格式参照 + 既有 effect_id 命名） | **参照**（约定/格式/模式） |
| 4 | `new_logic/机师牌_全部机师牌信息.txt` | 88 张机师牌原文（名称/阵营/稀有度/数值/技能文本）-- 修正时核对原文，不得偏 | **权威·原文** |
| 5 | `new_logic/行动牌的效果与逻辑.txt` | 23 张行动牌逐效果拆解（当作/视为 引用的具名牌效果链权威 + 时点映射参照） | **权威·效果** |
| 6 | `new_logic/各动作的生命周期与时点.txt` | 各动作时点顺序（时点选择权威） | **权威·时点** |
| 7 | `new_logic/机斗战甲规则书.txt` | 完整规则（歧义裁定权威） | **权威·规则** |

**冲突优先级**：本提示词第三节 delta 清单 = 人类裁定 > 文件 7 规则书 > 文件 5/6 > 文件 3 SSR 范例 > 你原拆解推理。文件 2 的「▶ 回答/补充/重要补充」标注即人类裁定，必须落实。

> 若单次输入过长，可分批：先发文件 1+2+3（指令+待修正+参照），再发文件 4-7（权威）。但 7 份都必须在该次会话内全部送达。

---

## 你的角色

你此前产出了 Battle-GEAR-S（机斗战甲，Godot 4.6 回合制 1v1 战棋）的机师牌 SR 档（pilot_011-028）效果拆解。人类已在你输出的每个歧义点处做了裁定标注：
- `▶ 回答：智能体选择正确` = 你原选择对，保留。
- `▶ 回答：候选正确` = **你原选择错，改用「候选」**。
- `▶ 回答：[新内容]` = 按新内容改（可能既非原选也非候选）。
- `补充：` / `重要补充：` = 补充机制或 UI 要求，须并入相关 effect 的拆解与测试。

**裁定是最高权威**，高于你原拆解的默认推理。本次任务：**通读你原拆解 + 全部裁定标注，输出修订版全文**，使每个 effect 的 conditions/target_rules/costs/actions/实现预告/顺序与坑/测试场景都符合裁定。

你没有此前会话的记忆，故下方重申核心语义。

---

## 一、核心语义（重申，勿违背）

### 1.1 Action Engine 效果体系
- 只用新 Action + Timing 体系；**不碰**旧 hook / legacy CardEffect / `CUSTOM_EFFECT_CHECK_TEXT`。
- 机师设于 `slot_id=&"pilot"` 槽，整局常驻；效果按 `card_instance_id` 注册为 permanent listener；`binding_context={card_instance_id, mech_id, player_id, slot_id=&"pilot", card_def_id}`。
- 换机师：先注销旧实例全部 permanent listener（按 card_instance_id），再注册新实例；派生光环/变量按 `source_card_instance_id` 隔离与清理。
- `ActionEffect` 字段：`effect_id/display_name/description/mode/priority/listen_timing/listen_action_type/conditions/target_rules/costs/actions/requires_effect/once_per_turn_key/once_per_turn_max/once_per_game_key/permanent_while_in_hand/availability_condition/availability_priority`。
- **priority**：`TimingEngine` sort `return pa > pb` -> **数值越大越先执行**；范围 **-1~30**（常规=10、-1最低、20/30 顺序保证、**上限 30**）。勿用 100/80 等超标值。

### 1.2 机师效果四形态
- **LISTEN 永久监听（被动）**：监听某动作类型某时点。
- **DIRECT 主动**：主阶段 skill_bar 按钮触发，conditions 含 `IS_OWNER_MAIN_PHASE`。
- **AVAILABILITY 响应**：ATTACK_AT 响应窗口可选。
- **派生值/权限型**：不注册监听器，查询点实时重算 helper / 由面板或 validator 识别。

### 1.3 关键机制语义
- **当作X（转化，出牌前）**：消耗 N 张行动牌获「虚拟转化牌」（无实体、无类型），使用=用 X 的效果。遵循 X 使用条件：攻击类需范围内目标 + **消耗回合攻击数（=主动攻击）**；迎击类只能 ATTACK_AT 响应对我方的攻击；辅助类主阶段。是攻击则触发 ATTACK_*，**不触发 USE_ACTION_***。
- **视为X（替换，出牌后）**：已打出实体牌（有类型、已计攻击数）后把原效果抹掉换成 X 效果；可按 priority 多次洗。
- **立即使用**：经完整 use_action_card 链；效果引出的攻击 = **被动攻击，不计回合攻击数**（仍需范围内目标与武器）。主动攻击 = 玩家自发无效果引导（武器攻击、投掷飞弹、当作转化攻击）。
- **每回合N次 vs 我方回合N次**：「每回合N次」=任意玩家一回合 N 次（对方回合触发占对方额度）；「我方回合N次」=仅我方回合 N 次。「本局游戏1次」= `once_per_game_key`。
- **X 变量**：本局持续累积，**绑定 card_instance_id**（不同机师分开），不随回合重置；有上限标上限。
- **阵营全队**：「场上所有X阵营」含敌方同阵营；不限敌我。
- **范围**：「X格范围内」= 六角距离 X 环（`_HexGrid.distance`，odd-q offset），与攻击范围（BFS 地形）不同；绿格不额外计。
- **执行顺序**：「并」/未说 = 同时；「之后」= 前一个完成后再执行下一个。

### 1.4 既有件（复用优先，勿重复造）
- **时点**：`ROUND_START/TURN_BEFORE_START/TURN_START/TURN_AFTER_START/TURN_BEFORE_END/TURN_END/TURN_AFTER_END`、`ATTACK_BEFORE/ATTACK_PRE/ATTACK_AT/ATTACK_AFTER/ATTACK_SETTLE`、`USE_ACTION_BEFORE/AT/AFTER/SETTLE`、`STAT_MOD_*`、`BASIC_MOVE_*`、`SET_EQUIP_*`、`GAIN_CARD_BEFORE/AFTER/SETTLE`、`DISCARD_BEFORE/AFTER/SETTLE`、`EFFECT_FIRE_*`、`HP_CHANGE_BEFORE/AFTER/SETTLE`、`DAMAGE_CHANGE_BEFORE/AFTER/SETTLE`、`DAMAGE_REDIRECT_WINDOW`、`SHOP_*`、`SHOW_CARD_*`。
- **条件 op**：`ALWAYS/IS_OWNER_MAIN_PHASE/SOURCE_OWNER_IS_ATTACKER/SOURCE_OWNER_IS_TARGET/SELF_MECH_IS_ATTACKER/SELF_MECH_IS_ATTACK_TARGET/ATTACK_HIT/PAYLOAD_ATTACK_HIT/PAYLOAD_ATTACK_MISS/ATTACK_WAS_RESPONDED/ATTACK_TARGET_ALIVE/OWNER_POWER_ABOVE_OR_EQUAL/SELF_DAMAGE_TOKENS_ABOVE/HAS_ACTION_CARD_IN_HAND/OWNER_ACTION_HAND_EMPTY/USED_CARD_TYPE_IS/USED_COUNTER_CARD/PAYLOAD_CARD_HAS_TAG/EQUIPPED_WEAPON_KIND/WEAPON_NAME_CONTAINS/VARIABLE_ABOVE/VARIABLE_EQUALS/HAS_FACTION` 等。
- **目标规则**：`NO_TARGET/TARGET_IS_MECH/TARGET_IN_RANGE/CHOOSE_OTHER_MECH/CHOOSE_ENEMY_MECH_IN_RANGE/CHOOSE_MECH_IN_RANGE/CHOOSE_MECH_IN_VARIABLE_RANGE/CHOOSE_OWN_SLOT/CHOOSE_OWN_WEAPON` 等。
- **动作**：`TREAT_CARD_AS_NAMED_TYPE/TRANSFER_ACTION_CARDS/FORCE_MECH_ACTION/DECLARE_CARD_TYPE/ROLL_D6/INCREMENT_VARIABLE/SET_VARIABLE/SWAP_HAND_LIMIT_AND_ATTACK_COUNT/GRANT_EFFECT_TO_FACTION/TOGGLE_EFFECT_ON_MECH/TOGGLE_AURA_TARGET/REDIRECT_HEAL_TO_DAMAGE/REDIRECT_REMOVE_TO_PLACE_TOKENS/GAIN_SPECIFIC_CARD/EXECUTE_ATTACK(passive=true)/EXECUTE_STAT_MODIFY/EXECUTE_USE_ACTION_CARD/EXECUTE_SHOW_CARD/EXECUTE_DISCARD/EXECUTE_STEAL/EXECUTE_GAIN_CARD/MODIFY_ARMOR/MODIFY_MECH_POWER/SPEND_POWER/RESTORE_POWER/DRAW_ACTION/DRAW_EQUIPMENT/GAIN_GOLD/SPEND_GOLD/HEAL_HP/DEAL_DAMAGE/PLACE_DAMAGE_TOKENS/MODIFY_DAMAGE_TOKENS/REMOVE_DAMAGE_TOKENS/MODIFY_ATTACK_MIGHT/MODIFY_ATTACK_MARKERS/MODIFY_ATTACK_POWER/MODIFY_ATTACK_RANGE/MODIFY_ACTION_HAND_LIMIT/MODIFY_ATTACK_COUNT/ADD_STATUS/REMOVE_STATUS/CHOOSE_ONE/CHOOSE_MANY_CARDS` 等。
- **effect_id 命名**：沿用既有 `pilot_XXX_effect_YY[a/b/c]`；分支用 a/b/c。

---

## 二、修正规则

1. 逐张通读你原拆解 + 该牌所有歧义点的「▶ 回答」「补充」「重要补充」。
2. **人类推翻你默认处（「候选正确」或新内容）必改**--见第三节 delta 清单。
3. **「智能体选择正确」**：保留原选择，但在拆解正文中**显式确认**裁定结论（如时序、对象范围、是否计攻击数等），并在测试场景补对应断言。
4. **「补充」「重要补充」**：把补充的机制/UI 要求并入对应 effect 的「动作/人类 UI/测试场景」，必要时新增 condition/action。
5. 不得臆断新歧义；仍未覆盖的读法保留 `▶ 回答：` 空行。
6. GDScript 字面量须精确可粘（StringName 用 `&"..."`，嵌套层级清晰）。
7. 修订后每个 effect 仍含完整结构：牌头/effect_ids/效果拆解(含 GDScript 字面量)/实现预告/顺序与坑/测试场景/歧义点。

---

## 三、本批关键 delta 清单（人类推翻你默认处，必改）

> 下列是你原选错或需按新内容改的条目。其余「智能体选择正确」的条目按第二节规则 3 处理。

### pilot_012 玛丽尔
- **歧义2（新内容，重大）**：多目标攻击时，**对 2 个目标分别计算**--每个目标都执行夺牌-动力；命中的话多个目标分别计算，**每命中一次就可以执行一次** effect_02 奖励；「每回合1次」是**按攻击计数**（一次攻击里多目标都算这一次攻击的额度，不是每目标各 1 次）。
- 歧义1：候选正确（目标无行动牌时**可发动只减3动力**）。

### pilot_013 巴托洛夫
- **歧义2（候选正确，推翻你「选1台」）**：多目标攻击时「攻击目标」=**所有当前目标**都施加护甲/动力-4 与伤害+3（不是选1台）。
- **歧义3（新内容）**：动力-4 是**同时减动力上限与当前数值**（护甲同理减上限与当前），减上限的部分持续到下个我方回合开始到期移除，当前值钳制。（不是「只减总动力属性」也非「只减当前」）。

### pilot_014 亚伦
- **歧义2（候选正确，推翻你「不消失」）**：被选机师中途更换或亚伦换下时，**已施加的行动牌上限+2 立即消失**（modifier 随来源/目标机师离场移除）。
- **重要补充（须并入）**：亚伦对**刻托**（会互换上限/攻击数的机师）使用行动牌上限增益时，**让刻托记录亚伦的增益**：若刻托互换数值，亚伦的增益**从行动牌上限转移到攻击数**；亚伦增益到期时，取消的是「刻托记录的增益」，还原当前所在位置（攻击数）的数值。-> 需新增/扩展 modifier 跟踪机制：modifier 带 `source_effect_id` + `bound_stat`，互换时迁移 `bound_stat`。

### pilot_018 苔丝
- **歧义1（候选正确）**：攻击方不足 3 张行动牌时，**弃置其全部不足数量**（仍发动，弃剩余全部）。

### pilot_021 塔莉娅
- **歧义1（候选正确，推翻你「选1台」）**：可把抽到的 3 张牌**分别分配给范围内任意多台机甲**；UI：列出这 3 张牌和可给牌的所有机甲，用**滑槽方式**置入。
- **歧义2（候选正确）**：「本回合无法使用」状态**绑定 card_instance**，保留至当前活动回合结束（转交后仍限制）。
- 歧义3 补充：来源标签被再转交第三方后使用**仍触发**塔莉娅抽2（识破偷的也算，只要是别人从塔莉娅处拿到的牌）。

### pilot_022 提比里安
- **歧义4（候选正确，推翻你「仅未设置」）**：可弃置的武器装备牌**包括所有武器装备牌，不管在哪**（已设置/未设置/备用区均可），没说就是所有。

### pilot_023 坎得
- **歧义2（候选正确）**：维修能**对自己用**（按原维修规则）；4 格扩展是**扩展**，原来的对象（自己/相邻）也在。

### pilot_026 伊万
- **歧义2（新内容，推翻你「待裁定」）**：设陷状态**不能取消放置**。本效果是把原来的 **2 层设陷状态直接变为 4 层**（+2 层机会），具体放置/取消按具体设陷牌的效果来，不是本机师效果的事。

### pilot_027 维罗妮卡
- **歧义1（候选正确）**：主动给予金币**不触发**第一条（我方获半），因为这样没意义。第一条只拦截第三方/系统给金。

### pilot_028 乌尔
- **歧义1（候选正确）**：无法或拒绝交 2 张牌时，**取消使用并留手**（不交保护费还想用牌？不行）。

---

## 四、补充/重要补充细化并入要求

除第三节外，下列「补充/重要补充」须并入相关 effect：

- **pilot_011 歧义1（时序精细化）**：「立即回复4动力」在**转化的同时执行**；「抽1张」在**转化效果全流程结算后**执行（需跑完疾行/反击的效果全流程，**包括反击的效果攻击**）。修正 actions 顺序与挂起说明。
- **pilot_011 歧义2**：可转移的攻击目标**不含「陷阱标记」**（旁边的陷阱标记被选为攻击目标时，迪恩不能转）。补 condition 排除陷阱标记目标。
- **pilot_015 歧义1**：「还原威力」清除所有非基础武器数值修正；**若武器威力是衰减的（如等离子螺旋茂），也还原为武器原本的威力**（不是衰减后的当前值）。
- **pilot_016 歧义2（UI）**：当默多克即将使用某行动牌时，若效果次数还够，**再询问他是直接使用还是展示后用其他2张牌转化**（其他牌不足2张就不问）。
- **pilot_020 补充**：「联合」行动牌的弃置此牌抽1**算入**肯德的弃置行动牌计数；弃置超上限的行动牌是在**回合结束时点之后、回合结束后时点之前**的操作，故肯德「大于3：回合结束后抽被弃置数量（最多6）」**也计算回合结束弃置超上限的行动牌数量**。修正 effect_04/05 的计数时点与计数口径。
- **pilot_014 重要补充**：见第三节（亚伦+刻托增益转移）。

---

## 五、输出格式（修订版全文）

按 pilot_011 -> 028 顺序，每张牌完整输出（与原格式一致）：

```
═══════════════════════════════════════════════════════════
[机师牌 0XX] 名称  （阵营:X 稀有度:SR 费用:X 行动牌上限:X 回合攻击数:X）
═══════════════════════════════════════════════════════════
效果文本：...
本拆解 effect_ids：[...]

──────────── 效果拆解（pilot_0XX_effect_YY ...）────────────
首句：...
display_name / description / 优先级 / 模式 / listen_timing / 植入 / binding_context
触发条件 conditions（GDScript 字面量 + 解释）
目标规则 target_rules
成本 costs
依赖/限次
动作 actions（GDScript 字面量 + 逐行注释 + 执行顺序 + 人类UI）
值解析

──────────── 实现预告 ────────────
复用 / 需新增（逐条【名称/语义/参数/仿哪个既有/登记点】）

──────────── 顺序与坑 ────────────

──────────── 测试场景 ────────────
场景a/b/c...（前置/操作/断言）

歧义点：
[歧义N] ... ▶ 回答：[已填裁定]
═══════════════════════════════════════════════════════════
```

格式要点：
1. conditions/target_rules/costs/actions 给**可直接粘进代码的 GDScript 字面量**（StringName 用 `&"..."`）。
2. 每个动作附 `#` 行内注释说明改什么字段/调什么。
3. 多动作写清先后与挂起点（「之后」体现为顺序）。
4. 测试场景每张至少「正常/取消/条件不满足」3 类，delta 处补专项断言。
5. 歧义点保留并填入裁定结论（不再留空）。

---

## 六、硬约束

1. 裁定最高权威，高于你原推理。
2. 只用 Action+时点体系，不碰旧 hook/CUSTOM_EFFECT_CHECK_TEXT。
3. PvP 双人类玩家；不管 AI。
4. 逐效果独立 effect_id；机制相同优先复用既有 op/动作，新建仅当确实无匹配。
5. effect_ids 沿用既有命名，手工维护。
6. 不臆断；未覆盖歧义留空 ▶ 回答行。
7. GDScript 字面量精确，priority 在 -1~30 内。

---

## 七、开始

先通读全部 7 份输入文件（第零节）：重点是你原 SR 拆解（文件 2）的裁定标注、SSR 范例（文件 3）的约定与格式、机师牌原文（文件 4）、行动牌效果与时点权威（文件 5/6）、规则书（文件 7）。然后按第二~四节修正、按第五节格式，输出 pilot_011-028 修订版全文。从 pilot_011 开始。输出过长停在牌边界等「继续」。
