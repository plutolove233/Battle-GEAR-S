# 装备牌偏差修复 · 下一 Session 提示词（直接复制使用）

> 把下面整段复制给新 session 即可开始动手修复。本提示词自包含：含权威依据、根因、
> 精确文件位置、正确逻辑、改法、验证与坑点。

---

## 角色与硬约束（必须遵守）
- 项目：机斗战甲 Battle-GEAR-S（Godot 4.6）。工作目录 `f:/Battle-GEAR-S`。
- **唯一权威**：`new_logic/装备牌部件_全部装备牌信息.txt`（126 张装备牌）。冲突以它为准。
  另三份逻辑文档也是权威：`new_logic/机斗战甲规则书.txt`、`new_logic/行动牌的效果与逻辑.txt`、
  `new_logic/各动作的生命周期与时点.txt`。
- 完整审查报告：`new_logic/装备牌代码审查报告.txt`（含「零、紧急新增」节，本提示词的来源）。
- **不要用 Agent 子智能体**。**不要用 python3，用 `python`**。
- **先不用管 AI 玩家逻辑**，专注 PVP 人类玩家逻辑与 UI，要通用可复用（任意人数人类）。
- **保证既有测试全部通过、无引入回归**。测试命令（每次跑完即关 Godot 防爆内存）：
  ```bash
  timeout 300 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd
  ```
- 不确定的地方**边做边问用户**，多问少错。每完成一项跑一次测试。

## 前置必读（按顺序）
1. `new_logic/装备牌代码审查报告.txt` 的「零、紧急新增」节（CRITICAL-A/B + 动力模型）。
2. `scripts/generated_database/GeneratedEquipmentEffects.gd`（91 个 effect 定义 + 派生值 helper 区）。
3. `scripts/runtime/MechState.gd`（get_armor / get_total_power / max_power）、
   `scripts/runtime/MechSlotState.gd`（get_effective_armor / region_damage_tokens）。
4. `scripts/effect_core/GameActions.gd`（modify_armor L300 / modify_mech_power L349 / restore_power L445 / spend_power L405 / _get_max_power L2093）。
5. `scripts/action_defs/attack_action.gd`（步骤顺序：select_weapon→select_target→…，extra_range 读取处 L117/141/213）、`scripts/action_defs/stat_modify_action.gd`。
6. `scripts/app/app_root.gd`（_get_weapon_range L4007 / 攻击预检查 L1424 / attack_target_select 高亮 L2282 / select_attack_target 处理 L1303）。
7. `scripts/action_core/ActionService.gd`（MODIFY_ATTACK_RANGE L345 / CHOOSE_INTEGER / 各原子动作分发）、`scripts/action_core/ConditionChecker.gd`、`scripts/action_core/TimingEngine.gd`（_execute_actions 串行 / REPEAT_SELF_DAMAGE_AND_FREE_MOVE L2104）。

## 记忆要点与坑（必看，避免重蹈覆辙）
- **GDScript4 类型坑**：`int` 与 `StringName(&"full")` 直接比较会报 Invalid operands。`restore_power`/`_clean_this_turn_durations` 都要先 `str()` 转。任何新写的 duration/amount 判别都注意类型（int/String/StringName 混用）。
- **测试基建**：`-s` 模式不加载 autoload，`SessionLogger` 裸标识符不可解析 → 所有日志用 `preload("res://scripts/services/slog.gd")` 的 `SLog`。`run_tests.gd` 用帧驱动 flush `call_deferred`（每方法间 process_frame）。新增测试照此模式。
- **input_type vs popup_type 极易混淆**：一个走 `_on_battle_hex_clicked`/`_on_action_ui_input_requested`（input_type），一个走 `_on_action_ui_popup_requested`→`_show_popup`（popup_type）。resume 时按目标规则读的键注入（如 selected_weapon_id / target_id / chosen_card）。
- **时点翻转**：每个 step 是「handler 先执行 → 再 fire timing」。故读 extra_*/markers 必须放在 fire 之后的步骤（如破甲 extra_markers 在 _step_apply_damage 读，不在 _step_calculate_damage）。
- **弹窗暂停三路径**：waiting_timing / waiting_input / waiting_effect_action。fire_timing 首循环若 listener 创建子动作挂起，必须设 waiting_effect_action + 暂存剩余 listeners，否则后续 listener 被丢弃（曾致闪击/反击顺序 bug）。
- **派生值效果不注册 listener**：effect_002/008/014/016/021/046/048/049/066/070/074/080/086/089 是 mode=DIRECT 占位，由 MechState.get_armor/get_total_power/MechSlotState.get_effective_armor 实时调用 helper 重算。新增派生效果照此（不要注册 timing listener）。
- **binding_context 解析**：`_resolve_atomic_value` 支持 `$binding_context.xxx`（player_id/mech_id/slot_id/owner_gold 等）、`$choice.n`、`$chosen_card.card_instance_id`、`$payload.xxx`、`$variables.xxx`。状态挂 A 时点 fire、在 B 时点用时，target 须用 binding_context 非 payload。
- **CHOOSE_INTEGER**：用 Expression 解析 `max_value_expr`（如 `floor($binding_context.owner_gold / 2)`），AI 自动选 min，人类走 choice_panel 弹窗。需新增整数上下文时仿此。
- **discard_card_action 装备 listener 注销在 _settle**（不是 move_to_tmp），否则离场诱发效果（effect_003/005/031/034/079）永不触发。改离场相关逻辑注意别回退这点。
- **PvP 弹窗路由**：`_popup_owner` / `_effect_popup_owner_pid` 优先 binding_context.player_id（装备拥有者/操作人），回退 action.source.player_id。新增弹窗务必带 player_id 并在路由 match 里登记。
- **同优先级执行顺序**：行动牌按 seq，装备牌低 1 级按座次（TimingEngine._annotate_listener_meta）。改优先级注意 tiebreak。
- **损伤模型**：放损伤时 region_damage_tokens 与 equipped_card.damage_tokens 同步递增（DamageTokenService L36/40/82/86）；装备时二者相等，故派生值用 max(region,card) 或 card_damage 都对。
- **动力模型已正确**（勿改）：①「此牌动力+X」=派生 get_total_power 加上限；②「当前回合动力+X」=modify_mech_power(THIS_TURN) 可超上限、回末还原；③「回复X动力」=restore_power 夹 max_power、保留至下个我方回合开始 full 回复。max_power 在 set/break/sell 装备时同步为 get_total_power()。

---

## 修复任务清单（按优先级。每项改完跑测试再下一项）

### 【P0-A · CRITICAL】THIS_TURN 护甲+X 不生效（6 张牌：014/020/038/062/080/104）
- **根因**：`modify_armor`(GameActions.gd L300) 把 THIS_TURN 护甲写成 `ARMOR_MODIFIER` 状态存入 mech.statuses，但 `MechState.get_armor()`(L71-80) 不遍历 statuses，全工程无消费方。伤害计算 attack_action L243 用 get_armor() → 护甲没变 → 不减伤。
- **正确逻辑**：「当前回合护甲+X」应整回合提升 get_armor()，回合结束清除。
- **改法（最小）**：`MechState.get_armor()` 末尾 `return total` 前加：
  ```gdscript
  var am_bonus := 0
  for st in statuses:
      if st is Dictionary and st.get("type", &"") == &"ARMOR_MODIFIER" \
              and String(st.get("duration", &"")) != "THIS_ATTACK":
          am_bonus += int(st.get("delta", 0))
  total += am_bonus
  ```
  （排除 THIS_ATTACK：那条路由 attack record temporary_armor_bonus 处理，L246 已读，避免双计。）
  回合结束 `TurnService._clean_this_turn_durations`(L217) 已移除 THIS_TURN 的 ARMOR_MODIFIER 状态，移除后 get_armor 自动不再计入，无需显式还原。
- **验证**：新增行为测试 `tests/test_armor_this_turn_fix.gd`：造 attack 场景，目标装 020 重甲躯干，被攻击时发动 effect_015 弃 2 牌，同回合再挨打，断言伤害减少 4（或 get_armor() 增加 4）。全测试 PASS。
- **风险**：低。

### 【P0-B · CRITICAL】狙击装头部「远程武器范围+X」不生效（3 张牌：031/073/103，2 个 effect_id）
- **受影响牌**：031 狙击装·头部(+1，effect_022)、073 狙击影装·头部(+2，effect_055)、103 轰雷装·头部(+2，effect_055+effect_074)。073 与 103 **共用 effect_055**（同型效果共用同一 effect_id），103 另绑 effect_074(损伤免疫)。故 effect_id 2 个、牌 3 张，修 effect_022/055 一次全修。
- **根因**：effect_022/055 用 ATTACK_BEFORE→MODIFY_ATTACK_RANGE 写 attack record extra_range，但：①攻击预检查 app_root L1424-1446 用 `_get_weapon_range`(L4007，仅基础 range_value) 判「是否有可攻击目标」，唯一目标在 base+1 时直接拦截；②目标高亮 L2282-2292 用 input_params.weapon_range（attack_action L160 传的是基础 weapon_range，不含 extra_range），高亮只到基础射程，玩家选不到 +1 格。AI _auto_select L310 同样用基础值。
- **正确逻辑**：「我方远程武器范围+X」是被动常驻，所有远程武器有效射程（预检查/高亮/选目标/命中）始终 +X。
- **改法（把 effect_022/055 改派生值，仿 effect_002）**：
  1. `GeneratedEquipmentEffects.gd` 新增 helper：
     ```gdscript
     static func get_passive_weapon_range_bonus(mech, weapon_kind: StringName) -> int:
         if weapon_kind != &"远程" or mech == null or mech.get("slots") == null:
             return 0
         var head = mech.slots.get(&"头部")
         if head == null: return 0
         var c = head.get("equipped_card")
         if not is_equipment_active(c): return 0
         if _card_has_effect_id(c, &"equipment_effect_055"): return 2
         if _card_has_effect_id(c, &"equipment_effect_022"): return 1
         return 0
     ```
  2. `app_root._get_weapon_range`(L4007)：取基础 range_value 后 `+= GeneratedEquipmentEffects.get_passive_weapon_range_bonus(mech, <该武器kind>)`（修预检查①）。注意 frame_base_weapon 与实体武器都要取 weapon_kind。
  3. `attack_action._step_select_weapon`(L88-89)：`result["weapon_range"] = weapon_stats.range_value + GeneratedEquipmentEffects.get_passive_weapon_range_bonus(attacker, weapon_stats.weapon_kind)`（存进 record，命中 L213 / 选目标校验 L117 自动含之）。
  4. `attack_action._step_select_target` input_params(L160)：`"weapon_range": action.record.get("weapon_range",1) + int(action.record.get("extra_range",0))`（让高亮也反映 effect_028/061/076 可选范围-2 的 extra_range）。
  5. effect_022/055 改为派生占位：`mode=_TC.MODE_DIRECT`，`set_actions([])`，去掉 listen_timing/listen_action_type/conditions（仿 effect_002/008），不再注册 listener，防与派生值双计。
- **验证**：新增行为测试 `tests/test_sniper_range_fix.gd`：机甲装 031 狙击头 + base range=1 远程武器，2 格外有敌方机甲，断言能选中并命中（预检查通过 + 高亮含 2 格 + 命中）。全测试 PASS。
- **风险**：中（动 attack record 字段语义与高亮）。改完务必跑 attack 相关全测试。

### 【P1 · MAJOR】056 帝国赤枭·躯干 + 098 帝国雄鹰·躯干：金币→应为弃行动牌
- **根因**：effect_040/041（056）与 effect_071/072（098）用 CHOOSE_INTEGER + SPEND_GOLD(2n) + 动力+n(056)/移动n(098)。权威是「弃置 X 数量行动牌（X≥1）」，056 动力+2X、098 移动 X 格。资源错（金币→行动牌），056 倍率错（n→2n）。
- **改法**：两类同型，一起改。
  1. 新增 binding `$binding_context.owner_action_hand_count`：仿 `owner_gold` 的注入处（在 binding_context 构造/`_resolve_atomic_value` 支持 `$binding_context.xxx` 的地方），加入持有者行动手牌数。
  2. DISCARD_ACTION_CARD 支持 `count_expr`（变量张数）：仿 SPEND_GOLD 的 `amount_expr` 解析，在 ActionService 分发 DISCARD_ACTION_CARD 处读 count_expr→count。
  3. effect_040/041（056）actions：
     ```gdscript
     "max_value_expr": "$binding_context.owner_action_hand_count",
     "actions": [
       {"type": &"DISCARD_ACTION_CARD", "params": {"count_expr": "$choice.n", "player_id": "$binding_context.player_id"}},
       {"type": &"EXECUTE_STAT_MODIFY", "params": {"target_id": "$binding_context.mech_id", "stat_type": &"power", "value_expr": "2 * $choice.n", "method": &"add", "duration": &"THIS_TURN"}}
     ]
     ```
     条件 `GOLD_ABOVE threshold=2` 改 `OWNER_ACTION_HAND_ABOVE threshold=1`；label 改「弃置 n 张行动牌，本回合动力+2n」。
  4. effect_071/072（098）actions：max_value_expr 同上；actions 把 SPEND_GOLD 换成 DISCARD_ACTION_CARD count_expr=$choice.n，保留 EXECUTE_SINGLE_MOVE max_cells_expr=$choice.n free_move=true；条件 GOLD_ABOVE→OWNER_ACTION_HAND_ABOVE threshold=1。
  5. once_per_turn_key 保留（056 red_owl_torso_gold_power 可改名 red_owl_torso_card_power；098 eagle_torso_gold_move→eagle_torso_card_move）。同步 description/display_name。
- **验证**：更新 test_equipment_effects.gd 中 red_owl/eagle 结构断言文案；新增行为测试：056 弃 2 牌后动力+4；098 弃 2 牌后免费移动 2 格。全测试 PASS。
- **风险**：中（新 binding + count_expr）。注意 PvP 路由 CHOOSE_INTEGER 弹窗走 _effect_popup_owner_pid。

### 【P1 · MEDIUM-易】125/126 帝国神莺·腿（effect_091）缺「并回复2动力」
- **改法**：effect_091 option.actions 在 EXECUTE_SINGLE_MOVE 之前加 `{"type": &"RESTORE_POWER", "params": {"amount": 2}}`。description 末尾补「，并回复2动力」。
- **验证**：跑 test_equipment_effects.gd lark_suite21 结构断言；可加行为测试。全测试 PASS。风险极低。

### 【P2 · MEDIUM】119 联邦一角兽·右腿（effect_084）「可继续发动」循环未实现
- **根因**：REPEAT_SELF_DAMAGE_AND_FREE_MOVE 在 TimingEngine L2104 是单轮（注释明写「单轮…循环待补」）。
- **改法**：在该分支末尾，当 `allow_continue=true` 且来源牌仍在槽（stop_if_source_leaves_slot 校验）且 SELF_DAMAGE_TOKENS_BELOW 门槛仍成立时，挂起 need_input「是否继续发动？」（CHOOSE_ONE optional），玩家确认则再执行「自损2+免费移动2」，取消则结束。可挂计数/action.record 状态循环。复用 _source_equipment_discarded 守卫（自损致弃置则停）。
- **验证**：行为测试：119 装此牌被攻击响应，连续发动 2 次后自损达耐久弃置则停。全测试 PASS。风险中。

### 【P2 · MEDIUM】122 帝国神莺·躯干（effect_087/088）虚拟武器未接入武器选择
- **根因**：`get_virtual_weapon_from_equipment`(GeneratedEquipmentEffects L2659) 全工程无调用方。effect_088（耗尽动力+禁回）已写好但永不触发。
- **改法**：
  1. `weapon_picker_panel` 列武器时，遍历机甲 6 部件槽，对正面装备牌调 `GeneratedEquipmentEffects.get_virtual_weapon_from_equipment(card)`，非空则加入选项（可选条件 current_power>0）。
  2. attack 动作 / AttackRuleChecker：选中虚拟武器时，attack.record 标记 source 为该装备牌（让 effect_088 的 ATTACK_SOURCE_IS_SELF 命中），might/range 取虚拟武器条目；虚拟武器不占武器槽、不耗武器耐久。
  3. 验证 ConditionChecker.ATTACK_SOURCE_IS_SELF 能识别虚拟武器 source_card_id（可能需适配）。
- **验证**：F3 实机：装 122 后武器面板出现「帝国的神莺·躯干(威力20/范围6)」，选它攻击消耗全部动力+禁回。全测试 PASS。风险中高（UI+动作解析接线，建议配 F3）。

### 【P2 · PARTIAL】110 极电装·躯干（effect_077）「抽到迎击牌可立即响应」未实现
- **根因**：注释明写简化为弃2抽1动力+3，括号内「(若是迎击牌可以立即响应该攻击)」未做。
- **改法**：DRAW_ACTION 后加条件分支（需 bind_result_to 暴露抽到的牌 instance）：若抽到的是 action_type=="迎击"，挂起 CHOOSE_ONE optional「是否立即用此迎击牌响应攻击？」，确认→调 OPEN_OR_USE_RESPONSE（AtomicActionResolver L63 已有，attack_id=当前攻击, response_card_id=抽到的牌），取消→牌留手牌。
- **验证**：行为测试：110 被攻击时发动，抽到迎击牌可立即响应。全测试 PASS。风险中。

### 【P3 · MINOR】113 极电装·右腿（effect_079）exclude_slot_id 未消费
- **根因**：effect_079 传了 exclude_slot_id=$binding_context.slot_id，但 damage_change_action.gd 的 decrease 路径不读它（grep 无匹配），移除损伤 UI 可能选中来源槽。权威是「其他区域」。
- **改法**：damage_change_action.gd decrease 分支（复用维修移除损伤 UI 路径）读 params.exclude_slot_id，弹窗列出可选损伤槽位时跳过该 slot_id。effect_079 参数已传，只需下游消费。
- **验证**：行为测试：113 离场移除损伤时不能选来源槽。全测试 PASS。风险低。

### 【P3 · cosmetic】effect_004 注释
- GeneratedEquipmentEffects.gd L136 注释仍写「名称带联邦」，但代码已是不限（ConditionChecker L616 注释明写不限）。仅改注释，代码不动。

---

## 完成后
- 跑全测试：`timeout 300 "F:/Godot_4.6/Godot_v4.6-stable_win64.exe" --headless --path . -s res://tests/run_tests.gd` → 必须 TESTS PASSED。
- 更新 `new_logic/装备牌代码审查报告.txt`：把已修项标注「✅已修」。
- 存/更新记忆（`C:\Users\m1396\.claude\projects\f--Battle-GEAR-S\memory\`）：更新 `equipment-authoritative-sync-and-audit.md`，把已修 effect 移出待修列表；MEMORY.md 索引行同步。记录新坑（如 count_expr/binding 新增、虚拟武器接入点）。
- 每项改动遵循「先核实报告所述根因仍成立（代码可能已被改过）→ 改 → 测试」。
