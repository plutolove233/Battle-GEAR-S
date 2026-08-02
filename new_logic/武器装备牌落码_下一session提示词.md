# 武器装备牌效果落码 · 下一 session 执行提示词

> 用法：把本文件全文作为新 session 的首条用户消息粘贴即可直接动工。本提示词自洽，配合拆解文件与记忆即可完成全部落码。

---

## 0. 开工前（必做，第一步）

1. **先把当前所有未提交改动提交并推送到 git main 分支**，作为武器落码的回退基线。包括 `new_logic/` 下所有新文件（本提示词、`Battle-GEAR-S_武器装备牌效果逻辑拆解_40张全量.txt`、`装备牌武器_全部装备牌信息.txt`、`装备牌武器效果拆解_外部模型提示词.md`、`装备牌效果拆解_外部模型提示词.md` 等）及任何已修改文件。提交信息写 `chore: 武器牌落码基线-拆解文件+提示词`，end with `Co-Authored-By: Claude <noreply@anthropic.com>`。若在 main 分支则直接提交（用户已授权合并到 main）。
2. 读取记忆 `weapon-effects-task-start-2026-08-02` 及 `MEMORY.md` 索引中武器/架构相关条目；读 `CLAUDE.md`。
3. 通读 `new_logic/Battle-GEAR-S_武器装备牌效果逻辑拆解_40张全量.txt`（拆解文件，3632行）——它是效果逻辑权威，含47个effect定义、总览表、新增件清单。

---

## 1. 任务

实现 **40 张武器装备牌的全部效果**（`equipment_effect_093`~`equipment_effect_139`，共 47 个 effect 定义），同步 `data/cards/equipment_weapons.json` 数值/文本/effect_ids 到权威 TXT，为每张牌写测试，保证全量测试通过且无引入回归。部件牌（001-092）已完成勿动。

---

## 2. 权威来源（冲突优先级，高→低）

1. **效果逻辑**：`new_logic/Battle-GEAR-S_武器装备牌效果逻辑拆解_40张全量.txt`（conditions/actions 字面量、时点、优先级、新增件、测试场景）。
2. **数值与效果文本**：`new_logic/装备牌武器_全部装备牌信息.txt`（damage/range/durability/cost/count/effect_text 以此为准）。
   - ⚠️ 拆解文件牌头数值有误：**014 等离子螺旋矛、015 高灼能双翼斧 威力应为 25（TXT），拆解文件误写 24**。一律以 TXT 为准。
3. **三份逻辑文档**（冲突裁定权威）：`new_logic/机斗战甲规则书.txt`、`new_logic/行动牌的效果与逻辑.txt`、`new_logic/各动作的生命周期与时点.txt`。
4. **记忆 + CLAUDE.md**：架构上下文。现存 `data/cards/equipment_weapons.json` 作废（effect_ids 089-129 与部件冲突、数值/文本与 TXT 不符），整体重写。

---

## 3. 全局裁定（拆解文件开头第 11-18 行，必须遵守）

- effect_id **093-139**，同机制牌共用一个 effect_id（见拆解文件末尾《effect_id 总览表》）。
- 武器仅**正面设置到 WEAPON 槽**时注册 permanent listener；备用区不注册；弃置/替换/卖出/翻面时注销。
- **ATTACK_AFTER 位于主损伤放置之前**：简单“命中后额外 N 损伤”用 `MODIFY_ATTACK_MARKERS(delta)`；需要观察实际放置区域的（06/07/21/22/25）改在 **ATTACK_SETTLE** 读 `damage_placement_log`。
- **“对此牌使用聚能时”** 统一监听聚能 `effect_fire` 的 `EFFECT_FIRE_AFTER`，并要求聚能动作把 `energy_target_weapon_instance_id` 写入 payload；条件用 `ENERGY_TARGET_IS_SELF`。每处保留歧义回答行。
- **直攻免牌**（32/36/39）仍走完整 attack 时点链（ATTACK_BEFORE/PRE/AT/AFTER/SETTLE），默认消耗本回合攻击次数；不创建 use_action_card 动作。
- 所有需玩家输入的 CHOOSE/弃牌/选格/损伤放置子动作把父动作置 `waiting_effect_action`，直到当前操作人类玩家确认或取消。
- “此牌发动的攻击”=条件含 `ATTACK_SOURCE_IS_SELF`（attack.weapon_instance_id == binding_context.card_instance_id）。

---

## 4. effect_id 总览表（见拆解文件第 3536-3585 行）

47 个定义：093-139。共用关系举例：097(03,09)、101(06,07,21,22)、105(11,12)、112/113/114(14,15)、115(18,19,23)、120(26,27)、125/126(29,30)、127(31)、128/129(32,36,39)、130(33)、131/132(34)、133(35)、135(37)、136(38)、137(39)、138/139(40)。完整表以拆解文件为准。

---

## 5. 新增件清单（去重；落码前先 grep 验证是否已存在，已存在则只扩展参数）

### 5.1 新增条件 op（登记 `scripts/action_core/ConditionChecker.gd` 或对应文件）
- `ENERGY_TARGET_IS_SELF`（读 effect_fire.payload.energy_target_weapon_instance_id == 本牌）——聚能联动核心
- `WEAPON_MODE_EQUALS` / `WEAPON_MODE_NOT_EQUALS`(mode)——流星钢锤形态
- `WEAPON_IS_ON_COOLDOWN`——武器冷却中（29/30）
- `WEAPON_IS_LOCKED_OUT`（或 helper `WEAPON_BLOCKED_BY_LOCK_STATUS`）——锁定期间不能攻击（10）
- `SOURCE_OWNER_IS_TURN_PLAYER`——来源玩家=当前回合玩家（14/15 回复）
- `WEAPON_STATUS_ABSENT`(status_type)——武器无某状态（14/15 未用标记）
- `TARGET_POWER_EQUALS`(value)——目标当前动力==值（24）
- `DAMAGE_TOKENS_NOT_ALL_IN_SAME_SLOT`——损伤未全同区（25，或给既有同区条件加 expected=false）
- `SELF_MECH_IS_DAMAGE_TARGET`——本牌机甲=损伤目标（盾牌）
- `DAMAGE_SOURCE_IS_ATTACK_OR_TRAP`——损伤来源是攻击或陷阱（盾牌）
- `PAYLOAD_DAMAGE_TOKENS_ABOVE`(threshold)——待放损伤>阈值（盾牌）
- `TARGET_HAS_ACTION_CARDS`(minimum)——目标有≥N张行动牌（05）
- `REPAIR_HAS_VALID_TARGET`(range)——有合法维修目标（33/37）
- `WEAPON_HAS_VALID_TRAP_CELL` / `WEAPON_HAS_VALID_TRAP_CELLS`(count)——范围内有可放陷阱格（36/39）
- `TARGET_CELL_CAN_HOLD_TRAP`——格子可放陷阱（36/39）
- `MULTI_ARM_HAS_AVAILABLE_OPTION` / `REPAIR_BRANCH_AVAILABLE`——多功能机械臂分支可用（37）
- `DISCARD_PARENT_ATTACK_WEAPON_IS_SELF`——弃牌的父攻击武器==本牌（28）
- `ATTACK_COUNT_ABOVE`(threshold)——攻击次数>阈值（32，确认是否已有 BELOW 需补 ABOVE）
- `ATTACK_VARIABLE_ABOVE`(scope,variable_name,threshold)——attack 作用域变量（11/12/24；若 `VARIABLE_ABOVE` 已支持 scope=attack 则复用）

### 5.2 新增/扩展原子动作（登记 `scripts/action_core/ActionService.gd` 的 `_is_atomic_action` + `_execute_atomic_action` + `_dispatch_atomic_action`）
- 扩展 `SET_WEAPON_STATS`：支持 `target_card_instance_id`/`might_delta`/`range_delta`/`duration=THIS_OWNER_TURN`/`stack`（聚能临时武器修正）
- 新增 `SET_WEAPON_MODE`(mode, refresh_parent_attack) + 可能 `REFRESH_ATTACK_STATS_FROM_WEAPON`（流星钢锤；刷新当前 attack 基础值只替换 base_might/base_range，不重叠 extra）
- 扩展 `PLACE_DAMAGE_TOKENS`：支持 `target_card_instance_id`/精确 `target_slot`/`executor_id`/`reason`（自损伤/额外损伤强制落点）
- 扩展 `MODIFY_MECH_POWER`：支持 `mode=current_only`/`current_and_temporary_max`/`min_value`/`duration`（24 减目标动力、34 加动力）
- 扩展 `MODIFY_WEAPON_POWER`：支持 `mode=increase/restore`/`clamp_max=printed_might`/`duration`/独立 modifier bucket（14/15 衰减与回复，不误清其他来源）
- 新增 `SET_ATTACK_MIGHT_FROM_PRINTED_WEAPON`(weapon_instance_id,bonus,ignore_self_damage_penalty,preserve_external_extra_might)（26 大型光束炮回复全值+2）
- 新增 `RANDOM_DISCARD_ACTION_CARD`(count,owner_id,reason,parent_attack_id)（28 雷爆磁轨炮；内部 EXECUTE_DISCARD(executor=system_random)，回写 was_last_action_card）
- 新增 `SET_WEAPON_COOLDOWN`(clear_timing,refresh/clear)（29/30 冷却）
- 扩展 `OFFER_DAMAGE_REDIRECT`：支持 `mode=all_or_nothing`/精确装备实例 `target_card_instance_id`/`reduction`/`min_points`/`optional`（盾牌 31/35/38）
- 扩展 `EXECUTE_ATTACK`：支持 `weapon_instance_id`/`cardless_weapon_attack`/`consume_turn_attack_count`/`skip_weapon_select`（直攻免牌）
- 扩展 `EXECUTE_USE_ACTION_CARD`：支持 `as_card_def_id`/`consume_original_card`（33/37 行动牌当维修）
- 扩展 `PLACE_OR_TRIGGER_TRAP`：支持 `mode=place`/`place_each`/`cell_id`/`cell_ids`（36/39）
- 新增 `DISCARD_ALL_FACE_UP_PARTS`(target_mech_id,slot_kinds,reason,preserve_slot_damage)（40；内部串行 EXECUTE_DISCARD，顺序头→躯干→右臂→左臂→右腿→左腿）
- 新增复合交互 `CHOOSE_MANY_MAP_CELLS`(count,distinct,range_source_weapon_instance_id,cell_rule)（39 双子机雷）
- 扩展 `INCREMENT_VARIABLE`：支持 `scope=attack`（11/12/24 标记变量）
- 扩展 `ADD_STATUS`：支持 `target_card_instance_id`/`refresh`/`duration=UNTIL_OWNER_TURN_AFTER_END`（14/15 weapon_used_this_turn）
- 扩展 `DISCARD_ACTION_CARD` 成本：支持 `card_type=attack` 过滤 + `reason`（01/02/16/17 被名响应）

### 5.3 新增派生值 helper（登记 `scripts/generated_database/GeneratedEquipmentEffects.gd`，接入武器威力/范围查询点、UI 预览、攻击选择快照、范围预检——全部入口统一，禁用牌面 1/1）
- `apply_weapon_mode_modifier(card_instance_id, stats)`——流星钢锤 extended 模式 might-5/range+2
- `get_weapon_might_by_self_damage(card_instance_id, printed_might)`——26/27 每损伤威力-2（统计本牌承受损伤，非区域总损伤）
- `get_energy_conversion_weapon_stats(card_instance_id)`——40 威力=max(0,mech.armor*2)、范围=max(0,mech.current_power)

### 5.4 attack record 字段扩展
- `energy_target_weapon_instance_id`（聚能 effect_fire payload 写入）
- `damage_placement_log` / `single_damage_slot_id`（damage_change 放置后回写父 attack，供 ATTACK_SETTLE 同区判定）
- attack scoped variables（`weapon_011_bonus_used`/`weapon_012_bonus_used`/`weapon_024_power_drain_used`）
- `weapon_instance_id`（攻击武器实例；effect_087 已写，确认通用化）

---

## 6. 落码顺序（建议分阶段，每阶段跑一次全量测试）

**Phase 1 · 基础设施**：先实现 5.1-5.4 的新增件与 record 字段。先 grep 验证既有件，已存在只扩展。这一层不碰 effect 定义。
**Phase 2 · 47 个 effect 定义**：在 `GeneratedEquipmentEffects.gd` 写 093-139。按机制族分批（A 聚能→B 被名响应→C 命中后额外损伤→D 自损伤→E 形态→F 弃目标牌→G 锁定→H 动力→I 冷却→J 直攻→K 盾牌→L 维修→M 随机弃牌→N 质能→O 攻击次数）。共用 effect_id 只定义一次。
**Phase 3 · JSON 同步**：重写 `data/cards/equipment_weapons.json` 全部 40 张（数值/文本/effect_ids/count 按第 7 节表）。同步 `data/new_cards/equipment_weapons.json`（若被加载）。
**Phase 4 · UI 接线**：DIRECT 发动入口（流星钢锤/直攻免牌/维修臂/推进器/机雷/双子机雷/多功能机械臂）暴露到装备面板/skill_bar；AVAILABILITY 被名响应进 ATTACK_AT 窗口；CHOOSE_MANY_MAP_CELLS 选格 UI；盾牌 OFFER_DAMAGE_REDIRECT 汇总窗；派生值装备面板显示。PvP 路由用 `_effect_popup_owner_pid`，不硬编码玩家序号。
**Phase 5 · 测试**：按拆解文件每张牌的测试场景写 `tests/test_weapon_xxx.gd`，加入 `run_tests.gd` 固定列表。逐张 + 全量回归。

---

## 7. 武器牌权威数值表（TXT；落码 JSON 以此为准）

| id | name | type | might | range | dur | cost | count | effect_ids |
|----|------|------|-------|-------|-----|------|-------|-----------|
| 01 | 光束军刀 | 近战 | 12 | 2 | 3 | 3 | 1 | 093,094 |
| 02 | 热能战斧 | 近战 | 12 | 2 | 3 | 3 | 1 | 095,096 |
| 03 | 破甲狼爪 | 近战 | 15 | 1 | 3 | 3 | 1 | 097 |
| 04 | 流星钢锤 | 近战 | 18 | 1 | 3 | 3 | 1 | 098,099 |
| 05 | 扭转钢鞭 | 近战 | 10 | 3 | 3 | 3 | 1 | 100 |
| 06 | 光束战戟 | 近战 | 15 | 3 | 3 | 5 | 2 | 101 |
| 07 | 热能战镰 | 近战 | 15 | 3 | 3 | 5 | 2 | 101 |
| 08 | 断甲长刀 | 近战 | 15 | 3 | 4 | 5 | 1 | 102 |
| 09 | 重型锤矛 | 近战 | 18 | 3 | 5 | 5 | 1 | 097,103 |
| 10 | 拘束钩爪 | 近战 | 10 | 5 | 3 | 5 | 1 | 104 |
| 11 | 光束斩舰刀 | 近战 | 20 | 3 | 5 | 7 | 2 | 105,106,107 |
| 12 | 热能双刃斧 | 近战 | 20 | 3 | 5 | 7 | 2 | 105,108,109 |
| 13 | 闪回激光剑 | 近战 | 20 | 3 | 4 | 7 | 1 | 110,111 |
| 14 | 等离子螺旋矛 | 近战 | **25** | 4 | 5 | 10 | 1 | 112,113,114 |
| 15 | 高灼能双翼斧 | 近战 | **25** | 4 | 5 | 10 | 1 | 112,113,114 |
| 16 | 光束步枪 | 远程 | 8 | 4 | 3 | 3 | 1 | 095,094 |
| 17 | 热能机枪 | 远程 | 8 | 4 | 3 | 3 | 1 | 093,096 |
| 18 | 光束霰弹枪 | 远程 | 10 | 3 | 3 | 3 | 1 | 115 |
| 19 | 热能爆弹枪 | 远程 | 10 | 3 | 3 | 3 | 1 | 115 |
| 20 | 火箭筒 | 远程 | 8 | 4 | 3 | 3 | 1 | 116 |
| 21 | 光束狙击枪 | 远程 | 10 | 5 | 3 | 5 | 2 | 101 |
| 22 | 穿甲热能枪 | 远程 | 10 | 5 | 3 | 5 | 2 | 101 |
| 23 | 扩散轨道炮 | 远程 | 12 | 4 | 3 | 5 | 1 | 115 |
| 24 | 密集导弹炮 | 远程 | 9 | 5 | 3 | 5 | 1 | 117,118 |
| 25 | 超级火箭筒 | 远程 | 10 | 5 | 3 | 5 | 1 | 119 |
| 26 | 大型光束炮 | 远程 | 14 | 6 | 4 | 7 | 2 | 120,121 |
| 27 | 热能加特林 | 远程 | 15 | 5 | 4 | 7 | 2 | 120,122 |
| 28 | 雷爆磁轨炮 | 远程 | 14 | 6 | 4 | 7 | 1 | 123,124 |
| 29 | 超米伽荣光炮 | 远程 | 18 | 7 | 5 | 10 | 1 | 125,126 |
| 30 | 核聚变神火炮 | 远程 | 18 | 7 | 5 | 10 | 1 | 125,126 |
| 31 | 合金盾牌 | 特殊 | 6 | 1 | 4 | 4 | 2 | 127 |
| 32 | 投掷式飞弹 | 特殊 | 7 | 4 | 6 | 3 | 2 | 128,129 |
| 33 | 维修机械臂 | 特殊 | 4 | 3 | 4 | 4 | 2 | 130 |
| 34 | 手持推进器 | 特殊 | 6 | 1 | 4 | 3 | 2 | 131,132 |
| 35 | 强合金盾牌 | 特殊 | 8 | 2 | 5 | 5 | 2 | 133 |
| 36 | 投掷式机雷 | 特殊 | 12 | 4 | 6 | 5 | 2 | 128,129,134 |
| 37 | 多功能机械臂 | 特殊 | 6 | 3 | 5 | 5 | 1 | 135 |
| 38 | 月神合金盾牌 | 特殊 | 10 | 3 | 6 | 6 | 1 | 136 |
| 39 | 投掷式双子机雷 | 特殊 | 14 | 4 | 6 | 6 | 1 | 128,129,137 |
| 40 | 质能全转换剑炮 | 特殊 | 1 | 1 | 5 | 8 | 1 | 138,139 |

JSON 字段名保持既有：`id`(weapon_XXX_名)/`category`="weapon"/`name`/`weapon_type`(近战/远程/特殊)/`slot`="武器"/`rarity`(按 cost 分档见下)/`count`/`effect_text`(TXT 原文)/`damage`/`range`/`durability`/`cost`/`effect_ids`(全写 equipment_effect_XXX)。
rarity 分档（参考既有）：cost3=N，cost5=R，cost7=SR，cost10=SSR；特殊：31(cost4)=N，33/34(cost4/3)=N，35(cost5)=R，37/36(cost5/5)=R，38/39(cost6/6)=SR，40(cost8)=SSR。与拆解文件牌头 rarity 一致；若不一致以拆解文件牌头 rarity 为准。

---

## 8. 关键坑（必须正确处理）

- **武器威力修改三路径避双计**：①改本次攻击 `MODIFY_ATTACK_MIGHT`/`MODIFY_ATTACK_RANGE`（写 extra_might/extra_range，仅本次）；②改武器基础 `MODIFY_WEAPON_POWER`/`SET_WEAPON_STATS`（跨回合持久）；③派生值实时重算。同一加成只走一条。参考神莺虚拟武器教训（虚拟 range 不在 `_get_weapon_stats` 预加，由 `_step_select_weapon` 统一加）。
- **ATTACK_AFTER 在主损伤放置前**：用 `MODIFY_ATTACK_MARKERS` 并入统一放置；需读放置结果的（06/07/21/22/25）在 ATTACK_SETTLE 读 `damage_placement_log`。
- **派生值覆盖所有查询入口**：武器威力/范围查询、UI 预览、攻击选择快照、范围预检、最大范围预估——统一调 helper，禁用牌面值（尤其 40 的 1/1）。
- **冷却/锁定拦截所有攻击入口**：武器选择过滤 + 直攻免牌 + 反击/闪击复用武器路径，统一调同一校验，不能绕过。
- **自损伤耐尽走标准破损弃置**：equipped_card=null、zone=equipment_discard、注销 listener/skill 按钮、区域损伤保留。
- **effect actions 入队后来源离场不取消已启动 effect**：如 08 自损致本牌破损后 +2 仍保留；27 自损 2 破损后 +3 仍执行；11 effect_105 命中自损致破损后 effect_107 跳过（牌已离场）。需在攻击开始时为 11/40 捕获一次性 settle follow-up，确保“本牌仍存在”规则明确。
- **PvP 路由**：所有弹窗/选择器 owner_pid 取当前效果执行者/响应者，不硬编码玩家序号；同优先级装备监听按座次。
- **GDScript 坑**：StringName 用 `&"..."`；`MechState` 是 RefCounted 不支持 `get(k,default)` 两参；`restore_power` 的 int 与 `&"full"` 比较需先 `String()` 转；`:=` 推断需显式类型。
- **测试基建**：`-s` 模式不 autoload 单例，日志走 `SLog` preload；`run_tests.gd` 帧驱动 flush deferred；测试方法 `test_` 前缀返回 true/错误串。

---

## 9. 约束

1. **先 PvP 人类玩家 + UI**：逻辑/UI 对任意数量人类玩家可复用；AI 逻辑暂不管。
2. **全面弃 hook**：只用 Action+时点体系，不碰 `scripts/effect_core/` 旧 hook。
3. **测试**：用 `"F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd`，**每次用 timeout 包裹并及时关闭 Godot**，否则爆内存。基线 07f4a29 全量 PASS。
4. **不臆断**：拆解文件每处 `▶ 回答：____________________` 留空 = 同意智能体选择，按其执行。遇到拆解文件与 TXT/逻辑文档冲突或真卡住的歧义，**过程中集中问用户**（多问少错），不要停止后再问。
5. **不质疑**已列问题；需要看日志时用户会给。
6. **不用 Agent；不用 python3，用 python**。
7. **数据层手工维护**：effect_ids 数组手写，不重新生成。

---

## 10. 完成标准

- 47 个 effect 定义全部落码（093-139），共用 id 只定义一次。
- `data/cards/equipment_weapons.json` 40 张全量按第 7 节表同步（数值/文本/effect_ids/count/rarity）。
- 新增件全部登记（条件 op / 原子动作 / helper / record 字段），先验证已存在再扩展。
- DIRECT 效果的 UI 发动入口、AVAILABILITY 响应窗口、选格/损伤转移 UI 全部接线，PvP 路由通用。
- 每张牌至少 3 类测试（正常/取消/条件不满足）+ 复合/新机制牌的边界场景，全量加入 run_tests.gd。
- **全量测试 PASS 无引入回归**（基线 07f4a29）。
- 落码完成后更新记忆 `weapon-effects-task-start-2026-08-02`（标注完成度/实装难点/待实机项），并视情况提交。

---

## 11. 参考文件清单

- `new_logic/Battle-GEAR-S_武器装备牌效果逻辑拆解_40张全量.txt`（效果逻辑权威 + 总览表 + 新增件清单 + 测试场景）
- `new_logic/装备牌武器_全部装备牌信息.txt`（数值/文本权威）
- `new_logic/装备牌武器效果拆解_外部模型提示词.md`（机制族目录 A-O + 既有件清单 + 武器关键坑，参考）
- `new_logic/各动作的生命周期与时点.txt`（时点权威，尤其 attack 链）
- `new_logic/行动牌的效果与逻辑.txt`（聚能/维修/迎击 action 拆解参照）
- `new_logic/机斗战甲规则书.txt`（裁定权威）
- 记忆：`weapon-effects-task-start-2026-08-02`、`lark-torso-virtual-weapon-2026-08-02`（武器威力修改三路径教训）等

开工。
