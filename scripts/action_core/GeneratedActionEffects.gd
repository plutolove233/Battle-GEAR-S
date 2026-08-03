## GeneratedActionEffects.gd — 23张行动牌的新效果定义
##
## 按新规则文档（行动牌的效果与逻辑.docx）定义所有行动牌效果。
## 每张牌的效果遵循统一的 ActionEffect 格式：
##   - DIRECT 模式：使用行动牌时立即执行
##   - LISTEN 模式：监听指定动作的指定时点
##   - AVAILABILITY 模式：在响应窗口等场景中作为可选牌出现
##
## 所有效果通过 TimingEngine 注册和触发。
## 关键变化：
##   - LISTEN效果绑定到触发动作的action_id（如"攻击A"）
##   - AVAILABILITY效果与手牌中具体的card_instance_id关联
##   - 状态效果（聚能/联合/锁定/折扣）有独立的监听效果
class_name GeneratedActionEffects
extends RefCounted

const _TC = preload("res://scripts/action_core/TimingConst.gd")

## 牌定义ID到效果ID列表的映射（用于UseActionCardAction注册临时监听器）
static var _card_effect_map: Dictionary = {}

static func _ensure_card_map() -> void:
	if not _card_effect_map.is_empty():
		return
	# 构建card_def_id → [{effect_id, bind_to_sub_action}] 映射
	# bind_to_sub_action=true表示此LISTEN效果绑定到使用行动牌产生的子动作（如攻击A）
	_card_effect_map = {
			# 1 进攻
			&"action_001_进攻": [{"effect_id": &"attack_basic_direct", "bind_to_sub": false}],
			# 2 强袭
			&"action_002_强袭": [{"effect_id": &"assault_effect1", "bind_to_sub": false}, {"effect_id": &"assault_effect2", "bind_to_sub": true}],
			# 3 猛击
			&"action_003_猛击": [{"effect_id": &"smash_effect1", "bind_to_sub": false}, {"effect_id": &"smash_effect2", "bind_to_sub": true}],
			# 4 破甲
			&"action_004_破甲": [{"effect_id": &"armor_break_effect1", "bind_to_sub": false}, {"effect_id": &"armor_break_effect2", "bind_to_sub": true}],
			# 5 双连
			&"action_005_双连": [{"effect_id": &"dual_strike_direct", "bind_to_sub": false}],
			# 6 闪击
			&"action_006_闪击": [{"effect_id": &"flash_effect1", "bind_to_sub": false}, {"effect_id": &"flash_effect2", "bind_to_sub": true}],
			# 7 回避
			&"action_008_回避": [{"effect_id": &"evade_availability", "bind_to_sub": false}, {"effect_id": &"evade_effect1", "bind_to_sub": false}],
			# 8 疾行
			&"action_011_疾行": [{"effect_id": &"rush_availability", "bind_to_sub": false}, {"effect_id": &"rush_effect1", "bind_to_sub": false}],
			# 9 防御
			&"action_009_防御": [{"effect_id": &"defend_availability", "bind_to_sub": false}, {"effect_id": &"defend_effect1", "bind_to_sub": false}],
			# 10 反击
			&"action_010_反击": [{"effect_id": &"counter_availability", "bind_to_sub": false}, {"effect_id": &"counter_effect1", "bind_to_sub": false}, {"effect_id": &"counter_effect2", "bind_to_sub": false, "bind_to_attack_action": true}],
			# 11 维修
			&"action_013_维修": [{"effect_id": &"repair_direct", "bind_to_sub": false}],
			# 12 聚能
			&"action_014_聚能": [{"effect_id": &"energy_direct", "bind_to_sub": false}],
			# 13 推进
			&"action_015_推进": [{"effect_id": &"thrust_effect1", "bind_to_sub": false}, {"effect_id": &"thrust_effect2", "bind_to_sub": false}],
			# 14 掩护（LISTEN+permanent_while_in_hand，非响应牌；监听 ATTACK_AT 弹多选窗）
			&"action_016_掩护": [{"effect_id": &"cover_effect1", "bind_to_sub": false}],
			# 15 联合（效果2 弃牌抽牌改由 UI 点击时询问 + unite_discard_draw 网络op 实现，故仅留 effect1）
			&"action_018_联合": [{"effect_id": &"unite_effect1", "bind_to_sub": false}],
			# 16 回收
			&"action_019_回收": [{"effect_id": &"recycle_direct", "bind_to_sub": false}],
			# 17 回忆
			&"action_020_回忆": [{"effect_id": &"recall_direct", "bind_to_sub": false}],
			# 18 折扣
			&"action_021_折扣": [{"effect_id": &"discount_direct", "bind_to_sub": false}],
			# 19 补给
			&"action_022_补给": [{"effect_id": &"supply_direct", "bind_to_sub": false}],
			# 20 锁定
			&"action_023_锁定": [{"effect_id": &"lock_on_direct", "bind_to_sub": false}],
			# 21 预判
			&"action_007_预判": [{"effect_id": &"predict_effect1", "bind_to_sub": false}, {"effect_id": &"predict_effect2", "bind_to_sub": true}, {"effect_id": &"predict_effect3", "bind_to_sub": true}],
			# 22 识破
			&"action_012_识破": [{"effect_id": &"expose_availability", "bind_to_sub": false}, {"effect_id": &"expose_effect1", "bind_to_sub": false}, {"effect_id": &"expose_effect2", "bind_to_sub": false}],
			# 23 觉醒
			&"action_024_觉醒": [{"effect_id": &"awaken_direct", "bind_to_sub": false}],
		}


## 获取牌的效果映射
static func get_effects_for_card(card_def_id: StringName) -> Array:
	_ensure_card_map()
	return _card_effect_map.get(card_def_id, [])


## 状态类型到对应LISTEN效果ID列表的映射
## 状态施加时注册为临时监听器，状态移除时注销
static func get_effects_for_status(status_type: StringName) -> Array[StringName]:
	var _status_effect_map: Dictionary = {
		&"LOCKED": [&"lock_status_clear_on_hit", &"lock_status_duration_tick"],
		&"ENERGY_CHARGE": [&"energy_status_might", &"energy_status_clear_on_attack"],
		&"UNITE": [&"unite_status_attack", &"unite_status_clear"],
		&"DISCOUNT": [&"discount_clear_on_turn_end"],
	}
	var result: Array[StringName] = []
	for eid: StringName in _status_effect_map.get(status_type, []):
		result.append(eid)
	return result


## 构建所有效果定义，返回 { effect_id: ActionEffect }
static func build_all_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# 1、进攻
	# ═══════════════════════════════════════════
	var attack_basic := ActionEffect.new()
	attack_basic.effect_id = &"attack_basic_direct"
	attack_basic.display_name = "进攻"
	attack_basic.mode = _TC.MODE_DIRECT
	attack_basic.priority = 10
	attack_basic.set_conditions([{"op": &"ALWAYS"}])
	attack_basic.set_target_rules([{"rule": &"NO_TARGET"}])
	attack_basic.set_costs([])
	attack_basic.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	attack_basic.description = "执行攻击动作，可选择的攻击目标数为1。"
	effects[attack_basic.effect_id] = attack_basic

	# ═══════════════════════════════════════════
	# 2、强袭
	# ═══════════════════════════════════════════
	var assault_e1 := ActionEffect.new()
	assault_e1.effect_id = &"assault_effect1"
	assault_e1.display_name = "强袭·攻击"
	assault_e1.mode = _TC.MODE_DIRECT
	assault_e1.priority = 10
	assault_e1.set_conditions([{"op": &"ALWAYS"}])
	assault_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	assault_e1.set_costs([])
	assault_e1.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	assault_e1.description = "执行攻击动作A，可选择的攻击目标数为1。"
	effects[assault_e1.effect_id] = assault_e1

	var assault_e2 := ActionEffect.new()
	assault_e2.effect_id = &"assault_effect2"
	assault_e2.display_name = "强袭·被响应则移动"
	assault_e2.mode = _TC.MODE_LISTEN
	assault_e2.priority = -1  # 最低优先级
	# 监听 ATTACK_AT（文档原义）：翻转后 execute_attack handler 先跑初始化 responded=false，
	# 再 fire ATTACK_AT。若目标有迎击牌（AVAILABILITY 监听器）则开响应窗口并暂存 regular_listeners，
	# 窗口关闭、迎击子动作（RESPOND_ATTACK 写 responded=true）完成、attack 恢复后，
	# _execute_step 阶段3 补跑 regular listeners，effect2 此时读到 responded=true 触发移动。
	# （翻转前因「fire 在 handler 前」，ATTACK_AT fire 时 responded 未初始化，被迫改听 ATTACK_AFTER。）
	assault_e2.listen_timing = _TC.ATTACK_AT
	assault_e2.listen_action_type = &"attack"
	assault_e2.set_conditions([{"op": &"ATTACK_WAS_RESPONDED"}])
	assault_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	assault_e2.set_costs([])
	assault_e2.set_actions([{
		"type": &"EXECUTE_SINGLE_MOVE",
		"params": {"use_current_power": true, "loop_until_cancel": true},
	}])
	assault_e2.description = "监听攻击动作A的攻击时时点，如果被响应则循环执行单次移动。"
	effects[assault_e2.effect_id] = assault_e2

	# ═══════════════════════════════════════════
	# 3、猛击
	# ═══════════════════════════════════════════
	var smash_e1 := ActionEffect.new()
	smash_e1.effect_id = &"smash_effect1"
	smash_e1.display_name = "猛击·攻击"
	smash_e1.mode = _TC.MODE_DIRECT
	smash_e1.priority = 10
	smash_e1.set_conditions([{"op": &"ALWAYS"}])
	smash_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	smash_e1.set_costs([])
	smash_e1.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	smash_e1.description = "执行攻击动作A。"
	effects[smash_e1.effect_id] = smash_e1

	var smash_e2 := ActionEffect.new()
	smash_e2.effect_id = &"smash_effect2"
	smash_e2.display_name = "猛击·威力+4"
	smash_e2.mode = _TC.MODE_LISTEN
	smash_e2.priority = 10
	smash_e2.listen_timing = _TC.ATTACK_BEFORE
	smash_e2.listen_action_type = &"attack"
	smash_e2.set_conditions([{"op": &"ALWAYS"}])
	smash_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	smash_e2.set_costs([])
	smash_e2.set_actions([{
		"type": &"MODIFY_ATTACK_MIGHT",
		"params": {"delta": 4},
	}])
	smash_e2.description = "监听攻击A的攻击前时点，威力+4（写入 attack A 的 extra_might，结算时计入）。"
	effects[smash_e2.effect_id] = smash_e2

	# ═══════════════════════════════════════════
	# 4、破甲
	# ═══════════════════════════════════════════
	var armor_break_e1 := ActionEffect.new()
	armor_break_e1.effect_id = &"armor_break_effect1"
	armor_break_e1.display_name = "破甲·攻击"
	armor_break_e1.mode = _TC.MODE_DIRECT
	armor_break_e1.priority = 10
	armor_break_e1.set_conditions([{"op": &"ALWAYS"}])
	armor_break_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	armor_break_e1.set_costs([])
	armor_break_e1.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	armor_break_e1.description = "执行攻击动作A。"
	effects[armor_break_e1.effect_id] = armor_break_e1

	var armor_break_e2 := ActionEffect.new()
	armor_break_e2.effect_id = &"armor_break_effect2"
	armor_break_e2.display_name = "破甲·命中则损伤+2"
	armor_break_e2.mode = _TC.MODE_LISTEN
	armor_break_e2.priority = 10
	armor_break_e2.listen_timing = _TC.ATTACK_AFTER
	armor_break_e2.listen_action_type = &"attack"
	armor_break_e2.set_conditions([{"op": &"ATTACK_HIT"}])
	armor_break_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	armor_break_e2.set_costs([])
	armor_break_e2.set_actions([{
		"type": &"MODIFY_ATTACK_MARKERS",
		"params": {"delta": 2},
	}])
	armor_break_e2.description = "监听攻击A的攻击后时点，命中则使攻击A造成的损伤+2（写入A的extra_markers，由 _step_apply_damage 在 ATTACK_AFTER fire 之后合并入 markers 一次放置）。"
	effects[armor_break_e2.effect_id] = armor_break_e2

	# ═══════════════════════════════════════════
	# 5、双连
	# ═══════════════════════════════════════════
	var dual_strike := ActionEffect.new()
	dual_strike.effect_id = &"dual_strike_direct"
	dual_strike.display_name = "双连·攻击"
	dual_strike.mode = _TC.MODE_DIRECT
	dual_strike.priority = 10
	dual_strike.set_conditions([{"op": &"ALWAYS"}])
	dual_strike.set_target_rules([{"rule": &"NO_TARGET"}])
	dual_strike.set_costs([])
	dual_strike.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 2},
	}])
	dual_strike.description = "执行攻击动作，可选择的攻击目标数为2。"
	effects[dual_strike.effect_id] = dual_strike

	# ═══════════════════════════════════════════
	# 6、闪击
	# ═══════════════════════════════════════════
	var flash_e1 := ActionEffect.new()
	flash_e1.effect_id = &"flash_effect1"
	flash_e1.display_name = "闪击·攻击"
	flash_e1.mode = _TC.MODE_DIRECT
	flash_e1.priority = 10
	flash_e1.set_conditions([{"op": &"ALWAYS"}])
	flash_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	flash_e1.set_costs([])
	flash_e1.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	flash_e1.description = "执行攻击动作A。"
	effects[flash_e1.effect_id] = flash_e1

	var flash_e2 := ActionEffect.new()
	flash_e2.effect_id = &"flash_effect2"
	flash_e2.display_name = "闪击·再攻"
	flash_e2.mode = _TC.MODE_LISTEN
	flash_e2.priority = 10
	flash_e2.listen_timing = _TC.ATTACK_SETTLE
	flash_e2.listen_action_type = &"attack"
	# 条件：持有行动牌可弃 + 武器可再次攻击（攻击者存活且武器仍在）+ 武器攻击范围内存在可攻击目标。
	# 再攻不锁定攻击A的目标，玩家可在武器范围内任选目标，故不再检查 ATTACK_TARGET_ALIVE，
	# 改由 WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE 保证范围内有目标可打（弃牌弹窗前置）。
	flash_e2.set_conditions([
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
		{"op": &"WEAPON_CAN_ATTACK_AGAIN"},
		{"op": &"WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE"},
	])
	flash_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	flash_e2.set_costs([{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true}])
	# 用攻击A的武器（自动确认，跳过选武器），目标在武器攻击范围内由玩家任选（不跳过选目标）。
	flash_e2.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {
			"target_count": 1,
			"use_previous_weapon": true,
			"skip_weapon_select": true,
			"choose_new_target": true,
		},
	}])
	flash_e2.description = "监听攻击A的攻击结算时点，可弃1行动牌再发动一次攻击（用攻击A的武器，目标可在武器范围内任选）。"
	effects[flash_e2.effect_id] = flash_e2

	# ═══════════════════════════════════════════
	# 7、回避
	# ═══════════════════════════════════════════
	var evade_avail := ActionEffect.new()
	evade_avail.effect_id = &"evade_availability"
	evade_avail.display_name = "回避·可用条件"
	evade_avail.mode = _TC.MODE_AVAILABILITY
	evade_avail.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	evade_avail.availability_priority = 5
	evade_avail.description = "响应攻击：当被攻击时可使用。"
	effects[evade_avail.effect_id] = evade_avail

	var evade_e1 := ActionEffect.new()
	evade_e1.effect_id = &"evade_effect1"
	evade_e1.display_name = "回避·响应攻击+半动力移动"
	evade_e1.mode = _TC.MODE_DIRECT
	evade_e1.priority = 10
	evade_e1.set_conditions([{"op": &"ALWAYS"}])
	evade_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	evade_e1.set_costs([])
	evade_e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"power_fraction": 0.5, "loop_until_cancel": true}},
	])
	evade_e1.description = "响应攻击A（更新被响应记录），以1/2动力循环执行单次移动。"
	effects[evade_e1.effect_id] = evade_e1

	# ═══════════════════════════════════════════
	# 8、疾行
	# ═══════════════════════════════════════════
	var rush_avail := ActionEffect.new()
	rush_avail.effect_id = &"rush_availability"
	rush_avail.display_name = "疾行·可用条件"
	rush_avail.mode = _TC.MODE_AVAILABILITY
	rush_avail.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	rush_avail.availability_priority = 5
	rush_avail.description = "响应攻击：当被攻击时可使用。"
	effects[rush_avail.effect_id] = rush_avail

	var rush_e1 := ActionEffect.new()
	rush_e1.effect_id = &"rush_effect1"
	rush_e1.display_name = "疾行·响应攻击+全动力移动"
	rush_e1.mode = _TC.MODE_DIRECT
	rush_e1.priority = 10
	rush_e1.set_conditions([{"op": &"ALWAYS"}])
	rush_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	rush_e1.set_costs([])
	rush_e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
	])
	rush_e1.description = "响应攻击A（更新被响应记录），以全动力循环执行单次移动。"
	effects[rush_e1.effect_id] = rush_e1

	# ═══════════════════════════════════════════
	# 9、防御
	# ═══════════════════════════════════════════
	var defend_avail := ActionEffect.new()
	defend_avail.effect_id = &"defend_availability"
	defend_avail.display_name = "防御·可用条件"
	defend_avail.mode = _TC.MODE_AVAILABILITY
	defend_avail.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	defend_avail.availability_priority = 5
	defend_avail.description = "响应攻击：当被攻击时可使用。"
	effects[defend_avail.effect_id] = defend_avail

	var defend_e1 := ActionEffect.new()
	defend_e1.effect_id = &"defend_effect1"
	defend_e1.display_name = "防御·响应攻击+护甲+5损伤-1"
	defend_e1.mode = _TC.MODE_DIRECT
	defend_e1.priority = 10
	defend_e1.set_conditions([{"op": &"ALWAYS"}])
	defend_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	defend_e1.set_costs([])
	defend_e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"ADD_MECH_TEMP_ARMOR", "params": {"delta": 5}},
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1}},
	])
	defend_e1.description = "响应攻击A（更新被响应记录），被攻击方机甲护甲+5（面板可见，攻击结算后恢复），本次攻击损伤标记-1。"
	effects[defend_e1.effect_id] = defend_e1

	# ═══════════════════════════════════════════
	# 10、反击
	# ═══════════════════════════════════════════
	var counter_avail := ActionEffect.new()
	counter_avail.effect_id = &"counter_availability"
	counter_avail.display_name = "反击·可用条件"
	counter_avail.mode = _TC.MODE_AVAILABILITY
	counter_avail.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	counter_avail.availability_priority = 5
	counter_avail.description = "响应攻击：当被攻击时可使用。"
	effects[counter_avail.effect_id] = counter_avail

	var counter_e1 := ActionEffect.new()
	counter_e1.effect_id = &"counter_effect1"
	counter_e1.display_name = "反击·响应攻击+半动力移动"
	counter_e1.mode = _TC.MODE_DIRECT
	counter_e1.priority = 10
	counter_e1.set_conditions([{"op": &"ALWAYS"}])
	counter_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	counter_e1.set_costs([])
	counter_e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"power_fraction": 0.5, "loop_until_cancel": true}},
	])
	counter_e1.description = "响应攻击A（更新被响应记录），1/2动力循环移动。"
	effects[counter_e1.effect_id] = counter_e1

	var counter_e2 := ActionEffect.new()
	counter_e2.effect_id = &"counter_effect2"
	counter_e2.display_name = "反击·反击攻击"
	counter_e2.mode = _TC.MODE_LISTEN
	# 优先级20：反击的反击攻击须先于闪击 effect2（再攻）等同监听 ATTACK_SETTLE 的效果执行。
	# 原优先级10与闪击 effect2 相同，按注册序闪击 effect2 先触发，其 optional 弃牌弹窗
	# 会把 attack 置 waiting_timing 并在 fire_timing 首次循环 return，丢弃排在后面的
	# counter_effect2（反击2永不执行）。提至20后 counter_effect2 走 waiting_effect_action
	# 路径（创建反击攻击子动作并正确暂存剩余监听器），反击攻击结算后续跑闪击 effect2。
	counter_e2.priority = 20
	counter_e2.listen_timing = _TC.ATTACK_SETTLE
	counter_e2.listen_action_type = &"attack"
	counter_e2.requires_effect = &"counter_effect1"
	counter_e2.set_conditions([{"op": &"ALWAYS"}])
	counter_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	counter_e2.set_costs([])
	counter_e2.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1, "counter_strike": true},
	}])
	counter_e2.description = "效果1执行后，监听攻击1的攻击结算时点，发动攻击2。攻击2的发动方=迎击牌持有者，目标在所选武器攻击范围内任选（不限定原攻击者），武器由发动方重新选择。"
	effects[counter_e2.effect_id] = counter_e2

	# ═══════════════════════════════════════════
	# 11、维修
	# ═══════════════════════════════════════════
	var repair_direct := ActionEffect.new()
	repair_direct.effect_id = &"repair_direct"
	repair_direct.display_name = "维修"
	repair_direct.mode = _TC.MODE_DIRECT
	repair_direct.priority = 10
	repair_direct.set_conditions([{"op": &"ALWAYS"}])
	repair_direct.set_target_rules([{"rule": &"TARGET_IS_ADJACENT_OR_SELF"}])
	repair_direct.set_costs([])
	repair_direct.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"options": [
				{
					"label": "回复4生命",
					"condition": [{"op": &"TARGET_HP_NOT_FULL"}],
					"actions": [{"type": &"EXECUTE_HP_CHANGE", "params": {"value": 4, "method": &"restore"}}],
				},
				{
					"label": "移除2损伤",
					"condition": [{"op": &"TARGET_HAS_DAMAGE"}],
					"actions": [{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"value": 2, "method": &"decrease"}}],
				},
			],
		},
	}])
	repair_direct.description = "选择1台机甲（包含自身与周围1格），回复4生命或移除2损伤。"
	effects[repair_direct.effect_id] = repair_direct

	# ═══════════════════════════════════════════
	# 12、聚能
	# ═══════════════════════════════════════════
	var energy_direct := ActionEffect.new()
	energy_direct.effect_id = &"energy_direct"
	energy_direct.display_name = "聚能"
	energy_direct.mode = _TC.MODE_DIRECT
	energy_direct.priority = 10
	energy_direct.set_conditions([{"op": &"ALWAYS"}])
	energy_direct.set_target_rules([{"rule": &"CHOOSE_OWN_WEAPON"}])
	energy_direct.set_costs([])
	energy_direct.set_actions([{
		"type": &"APPLY_ENERGY_TO_WEAPON",
		"params": {"delta": 4},
	}])
	energy_direct.description = "选择自己区域内正面设置的1张武器装备牌，施加1层聚能状态。"
	effects[energy_direct.effect_id] = energy_direct

	# 聚能状态效果1：监听攻击前，威力+4*X
	var energy_status_e1 := ActionEffect.new()
	energy_status_e1.effect_id = &"energy_status_might"
	energy_status_e1.display_name = "聚能·威力+N"
	energy_status_e1.mode = _TC.MODE_LISTEN
	energy_status_e1.priority = 10
	energy_status_e1.listen_timing = _TC.ATTACK_BEFORE
	energy_status_e1.set_conditions([{"op": &"WEAPON_HAS_ENERGY_CHARGE"}])
	energy_status_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	energy_status_e1.set_costs([])
	energy_status_e1.set_actions([{
		"type": &"EXECUTE_STAT_MODIFY",
		"params": {"stat_type": &"might", "value_multiplier": 4, "value_multiplier_by_stacks": &"ENERGY_CHARGE"},
	}])
	energy_status_e1.description = "监听以聚能武器发动的攻击前时点，威力+4*N。"
	effects[energy_status_e1.effect_id] = energy_status_e1

	# 聚能状态效果2：攻击结算后清除
	var energy_status_e2 := ActionEffect.new()
	energy_status_e2.effect_id = &"energy_status_clear_on_attack"
	energy_status_e2.display_name = "聚能·攻击后清除"
	energy_status_e2.mode = _TC.MODE_LISTEN
	energy_status_e2.priority = 10
	energy_status_e2.listen_timing = _TC.ATTACK_SETTLE
	energy_status_e2.set_conditions([{"op": &"WEAPON_HAS_ENERGY_CHARGE"}])
	energy_status_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	energy_status_e2.set_costs([])
	energy_status_e2.requires_effect = &"energy_status_might"
	energy_status_e2.set_actions([{
		"type": &"REMOVE_STATUS",
		"params": {"status_id": "$binding_context.status_id", "target_id": "$binding_context.target_id"},
	}])
	energy_status_e2.description = "攻击结算后去除该武器（本状态）的聚能状态。"
	effects[energy_status_e2.effect_id] = energy_status_e2

	# 聚能状态效果3：回合结束清除
	var energy_status_e3 := ActionEffect.new()
	energy_status_e3.effect_id = &"energy_status_clear_on_turn_end"
	energy_status_e3.display_name = "聚能·回合结束清除"
	energy_status_e3.mode = _TC.MODE_LISTEN
	energy_status_e3.priority = 10
	energy_status_e3.listen_timing = _TC.TURN_AFTER_END
	energy_status_e3.set_conditions([{"op": &"WEAPON_HAS_ENERGY_CHARGE"}])
	energy_status_e3.set_target_rules([{"rule": &"NO_TARGET"}])
	energy_status_e3.set_costs([])
	energy_status_e3.set_actions([{
		"type": &"REMOVE_STATUS",
		"params": {"status_type": &"ENERGY_CHARGE", "remove_all": true, "target_id": "$binding_context.target_id"},
	}])
	energy_status_e3.description = "回合结束后去除Target所有的聚能状态。"
	effects[energy_status_e3.effect_id] = energy_status_e3

	# ═══════════════════════════════════════════
	# 13、推进
	# ═══════════════════════════════════════════
	var thrust_e1 := ActionEffect.new()
	thrust_e1.effect_id = &"thrust_effect1"
	thrust_e1.display_name = "推进·动力+4"
	thrust_e1.mode = _TC.MODE_DIRECT
	thrust_e1.priority = 10
	thrust_e1.set_conditions([{"op": &"ALWAYS"}])
	thrust_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	thrust_e1.set_costs([])
	thrust_e1.set_actions([{
		"type": &"EXECUTE_STAT_MODIFY",
		"params": {"stat_type": &"power", "value": 4, "method": &"add"},
	}])
	thrust_e1.description = "执行数值修正：动力+4。"
	effects[thrust_e1.effect_id] = thrust_e1

	var thrust_e2 := ActionEffect.new()
	thrust_e2.effect_id = &"thrust_effect2"
	thrust_e2.display_name = "推进·迎击时触发"
	thrust_e2.mode = _TC.MODE_LISTEN
	thrust_e2.priority = 10
	thrust_e2.listen_timing = _TC.USE_ACTION_AT
	thrust_e2.listen_action_type = &"use_action_card"
	# 手牌期间作为永久监听器监听他人使用迎击牌（register_hand_card_availability 注册），
	# 使用此推进时不绑到自身 use_action_card（_register_card_effects 跳过），避免自触发。
	thrust_e2.permanent_while_in_hand = true
	thrust_e2.set_conditions([{"op": &"USED_COUNTER_CARD"}])
	thrust_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	thrust_e2.set_costs([])
	# 多选弹窗：列出手中所有推进，玩家选任意数量，确认后逐张执行效果1(动力+4)并弃置，再继续迎击牌。
	thrust_e2.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"card_def_id": &"action_015_推进",
			"label": "选择要一起打出的推进（可多选）",
			"per_card_suffix": "·动力+4",
			"confirm_verb": "打出",
			"cancel_label": "不打出推进",
			"per_card_actions": [{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 4, "method": &"add"}}],
		},
	}])
	thrust_e2.description = "持有者使用迎击牌时弹出多选窗，选任意数量推进各动力+4并弃置，再执行迎击牌。"
	effects[thrust_e2.effect_id] = thrust_e2

	# ═══════════════════════════════════════════
	# 14、掩护
	# 文档：掩护不是响应牌，是 LISTEN 效果。持有者(机甲1)手牌期间作为永久监听器
	# 监听 ATTACK_AT：当攻击A的目标在机甲1最大武器范围内（且非机甲1自身）时触发。
	# 机甲1所有掩护共用一个效果执行（去重守卫 _choose_many_shown 保证只弹一次窗），
	# UI 列出机甲1所有掩护供多选任意数量（含0/取消），每张执行 MODIFY_ATTACK_MIGHT -5
	# （X张累加=5*X）并弃置。因 LISTEN 不受 _is_effect_suppressed 抑制，自动"不受锁定影响"。
	# ═══════════════════════════════════════════
	var cover_e1 := ActionEffect.new()
	cover_e1.effect_id = &"cover_effect1"
	cover_e1.display_name = "掩护·威力-5"
	cover_e1.mode = _TC.MODE_LISTEN
	cover_e1.priority = 10
	cover_e1.listen_timing = _TC.ATTACK_PRE
	cover_e1.listen_action_type = &"attack"
	cover_e1.permanent_while_in_hand = true
	cover_e1.set_conditions([{"op": &"TARGET_IN_COVER_RANGE"}])
	cover_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	cover_e1.set_costs([])
	cover_e1.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"card_def_id": &"action_016_掩护",
			"label": "选择要使用的掩护",
			"per_card_suffix": "·威力-5",
			"confirm_verb": "使用",
			"cancel_label": "不使用掩护",
			"per_card_actions": [{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -5}}],
		},
	}])
	cover_e1.description = "监听ATTACK_PRE(攻击时前)：holder自身或其范围内其他机甲被攻击时弹多选窗，选X张掩护各威力-5(累加5X)并弃置。非响应，不受锁定影响。"
	effects[cover_e1.effect_id] = cover_e1

	# ═══════════════════════════════════════════
	# 15、联合
	# ═══════════════════════════════════════════
	var unite_e1 := ActionEffect.new()
	unite_e1.effect_id = &"unite_effect1"
	unite_e1.display_name = "联合·施加联合状态"
	unite_e1.mode = _TC.MODE_DIRECT
	unite_e1.priority = 10
	unite_e1.set_conditions([{"op": &"ALWAYS"}])
	unite_e1.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	unite_e1.set_costs([])
	# unite 字段 = 出牌者机甲（机甲1），供联合状态效果1判断"unite机甲为发动攻击的机甲"。
	# $payload.source_mech_id = use_action_card record 中 _step_validate_card 写入的机甲1。
	# duration 不用 THIS_TURN：联合状态由效果2（unite_status_clear，监听 TURN_AFTER_END）主动移除，
	# 而非靠 _clean_this_turn_durations 回合结束清理。这样效果2是活跃机制（规范忠实），且
	# 状态移除走 remove_status -> _unregister_status_listeners，无孤儿监听器。
	unite_e1.set_actions([{
		"type": &"ADD_STATUS",
		"params": {"status_type": &"UNITE", "duration": &"UNTIL_TURN_END", "unite": "$payload.source_mech_id"},
	}])
	unite_e1.description = "选择1台其他机甲为Target，施加联合状态。"
	effects[unite_e1.effect_id] = unite_e1

	# 注：联合效果2（弃置此牌抽1张行动牌）原为 LISTEN 监听 USE_ACTION_BEFORE，
	# 但行动牌监听器在 card_to_temp_zone（step②）才注册，晚于 USE_ACTION_BEFORE（step①）fire，
	# 永不触发。改为点击联合时由 UI 先询问「使用联合效果 / 弃置抽1张 / 取消」
	# （app_root._on_action_card_clicked），选「弃置抽1张」走 unite_discard_draw 网络op，
	# 此时联合仍在手牌、未进临时区。故此处不再定义 unite_effect2。

	# 联合状态效果1：unite机甲攻击结算时可选择联合攻击
	# UNITE_ATTACK_OFFER 由 TimingEngine._execute_actions 拦截：列出 Target 手中所有攻击牌，
	# 无牌不弹窗；玩家选1张+确认 -> 作为子动作 use_action_card 打出（不消耗攻击次数，
	# 因 source_action_id=父attack 非空），结算后 REMOVE_STATUS 去除此联合状态；取消则无事发生。
	var unite_status_e1 := ActionEffect.new()
	unite_status_e1.effect_id = &"unite_status_attack"
	unite_status_e1.display_name = "联合·联合攻击"
	unite_status_e1.mode = _TC.MODE_LISTEN
	unite_status_e1.priority = 10
	unite_status_e1.listen_timing = _TC.ATTACK_SETTLE
	unite_status_e1.set_conditions([{"op": &"UNITE_ATTACKER_IS_UNITE_MECH"}])
	unite_status_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	unite_status_e1.set_costs([])
	unite_status_e1.set_actions([{
		"type": &"UNITE_ATTACK_OFFER",
		"params": {
			"card_action_type": "攻击",
			"label": "联合攻击：选择1张攻击牌使用",
		},
	}])
	unite_status_e1.description = "unite机甲攻击结算时，Target可选择立即使用1张持有的攻击牌，结算后去除此联合状态。"
	effects[unite_status_e1.effect_id] = unite_status_e1

	# 联合状态效果2：回合结束清除（活跃机制--状态 duration=UNTIL_TURN_END，不靠 _clean_this_turn_durations）
	# 每个 UNITE 状态注册自己的 unite_status_clear 监听器，TURN_AFTER_END 时各自移除自身（按 status_id 精确）。
	# 效果1确认使用攻击牌后，REMOVE_STATUS 移除状态时也会注销本监听器（幂等）。
	var unite_status_e2 := ActionEffect.new()
	unite_status_e2.effect_id = &"unite_status_clear"
	unite_status_e2.display_name = "联合·回合结束清除"
	unite_status_e2.mode = _TC.MODE_LISTEN
	unite_status_e2.priority = 10
	unite_status_e2.listen_timing = _TC.TURN_AFTER_END
	unite_status_e2.set_conditions([{"op": &"ALWAYS"}])
	unite_status_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	unite_status_e2.set_costs([])
	unite_status_e2.set_actions([{
		"type": &"REMOVE_STATUS",
		"params": {"status_type": &"UNITE", "remove_all": true},
	}])
	unite_status_e2.description = "回合结束后去除所有联合状态。"
	effects[unite_status_e2.effect_id] = unite_status_e2

	# ═══════════════════════════════════════════
	# 16-19：回收/回忆/折扣/补给
	# ═══════════════════════════════════════════
	var recycle := ActionEffect.new()
	recycle.effect_id = &"recycle_direct"
	recycle.display_name = "回收"
	recycle.mode = _TC.MODE_DIRECT
	recycle.priority = 10
	recycle.set_conditions([{"op": &"ALWAYS"}])
	recycle.set_target_rules([{"rule": &"NO_TARGET"}])
	recycle.set_costs([])
	recycle.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {"from_zone": &"equipment_discard", "count": 1, "random": true, "card_kind": &"equipment"},
	}])
	recycle.description = "从装备弃牌堆随机获取1张装备牌。"
	effects[recycle.effect_id] = recycle

	var recall := ActionEffect.new()
	recall.effect_id = &"recall_direct"
	recall.display_name = "回忆"
	recall.mode = _TC.MODE_DIRECT
	recall.priority = 10
	recall.set_conditions([{"op": &"ALWAYS"}])
	recall.set_target_rules([{"rule": &"NO_TARGET"}])
	recall.set_costs([])
	recall.set_actions([{
		"type": &"EXECUTE_GAIN_CARD",
		"params": {"from_zone": &"action_discard", "count": 2, "random": true, "card_kind": &"action"},
	}])
	recall.description = "从行动弃牌堆随机获取2张行动牌。"
	effects[recall.effect_id] = recall

	var discount := ActionEffect.new()
	discount.effect_id = &"discount_direct"
	discount.display_name = "折扣"
	discount.mode = _TC.MODE_DIRECT
	discount.priority = 10
	discount.set_conditions([{"op": &"ALWAYS"}])
	discount.set_target_rules([{"rule": &"NO_TARGET"}])
	discount.set_costs([])
	discount.set_actions([{
		"type": &"ADD_STATUS",
		"params": {"status_type": &"DISCOUNT", "stacks": 2},
	}])
	discount.description = "对自身施加2层折扣状态。"
	effects[discount.effect_id] = discount

	# 折扣状态回合结束清除
	var discount_status_clear := ActionEffect.new()
	discount_status_clear.effect_id = &"discount_clear_on_turn_end"
	discount_status_clear.display_name = "折扣·回合结束清除"
	discount_status_clear.mode = _TC.MODE_LISTEN
	discount_status_clear.priority = 10
	discount_status_clear.listen_timing = _TC.TURN_AFTER_END
	discount_status_clear.set_conditions([{"op": &"HAS_DISCOUNT_STATUS"}])
	discount_status_clear.set_target_rules([{"rule": &"NO_TARGET"}])
	discount_status_clear.set_costs([])
	discount_status_clear.set_actions([{
		"type": &"REMOVE_STATUS",
		"params": {"status_type": &"DISCOUNT", "remove_all": true},
	}])
	discount_status_clear.description = "回合结束后去除所有折扣状态。"
	effects[discount_status_clear.effect_id] = discount_status_clear

	var supply := ActionEffect.new()
	supply.effect_id = &"supply_direct"
	supply.display_name = "补给"
	supply.mode = _TC.MODE_DIRECT
	supply.priority = 10
	supply.set_conditions([{"op": &"ALWAYS"}])
	supply.set_target_rules([{"rule": &"NO_TARGET"}])
	supply.set_costs([])
	supply.set_actions([
		{"type": &"DRAW_ACTION", "params": {"count": 2}},
		{"type": &"DRAW_EQUIPMENT", "params": {"count": 1}},
	])
	supply.description = "从行动牌堆获取2张行动牌，从装备牌堆获取1张装备牌。"
	effects[supply.effect_id] = supply

	# ═══════════════════════════════════════════
	# 20、锁定
	# ═══════════════════════════════════════════
	var lock_direct := ActionEffect.new()
	lock_direct.effect_id = &"lock_on_direct"
	lock_direct.display_name = "锁定"
	lock_direct.mode = _TC.MODE_DIRECT
	lock_direct.priority = 10
	lock_direct.set_conditions([{"op": &"ALWAYS"}])
	lock_direct.set_target_rules([{"rule": &"CHOOSE_OTHER_MECH"}])
	lock_direct.set_costs([])
	lock_direct.set_actions([{
		"type": &"APPLY_OR_CHECK_LOCKED",
		"params": {"mode": &"apply", "duration": 1},
	}])
	lock_direct.description = "选择1台其他机甲施加锁定状态（持续1回合）。本回合我方对该目标发动的攻击，目标及其相邻机甲不能响应（识破除外）；该目标被命中后解除。"
	effects[lock_direct.effect_id] = lock_direct

	# 锁定状态效果2：命中后清除
	var lock_status_e2 := ActionEffect.new()
	lock_status_e2.effect_id = &"lock_status_clear_on_hit"
	lock_status_e2.display_name = "锁定·命中后清除"
	lock_status_e2.mode = _TC.MODE_LISTEN
	lock_status_e2.priority = 10
	lock_status_e2.listen_timing = _TC.ATTACK_AFTER
	lock_status_e2.set_conditions([{"op": &"ATTACK_HIT"}, {"op": &"TARGET_HAS_LOCK_FROM_ATTACKER"}])
	lock_status_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	lock_status_e2.set_costs([])
	lock_status_e2.set_actions([{
		"type": &"REMOVE_STATUS",
		"params": {"status_type": &"LOCKED"},
	}])
	lock_status_e2.description = "locker 的攻击命中该目标后，去除该目标身上此 locker 施加的锁定状态。"
	effects[lock_status_e2.effect_id] = lock_status_e2

	# 锁定状态效果3：回合-1
	var lock_status_e3 := ActionEffect.new()
	lock_status_e3.effect_id = &"lock_status_duration_tick"
	lock_status_e3.display_name = "锁定·持续回合-1"
	lock_status_e3.mode = _TC.MODE_LISTEN
	lock_status_e3.priority = 10
	lock_status_e3.listen_timing = _TC.TURN_AFTER_END
	lock_status_e3.set_conditions([{"op": &"ALWAYS"}])
	lock_status_e3.set_target_rules([{"rule": &"NO_TARGET"}])
	lock_status_e3.set_costs([])
	lock_status_e3.set_actions([{
		"type": &"DECREMENT_STATUS_DURATION",
		"params": {"status_type": &"LOCKED", "remove_if_zero": true},
	}])
	lock_status_e3.description = "回合结束后持续时间-1，为0则去除。"
	effects[lock_status_e3.effect_id] = lock_status_e3

	# ═══════════════════════════════════════════
	# 21、预判
	# ═══════════════════════════════════════════
	var predict_e1 := ActionEffect.new()
	predict_e1.effect_id = &"predict_effect1"
	predict_e1.display_name = "预判·攻击"
	predict_e1.mode = _TC.MODE_DIRECT
	predict_e1.priority = 10
	predict_e1.set_conditions([{"op": &"ALWAYS"}])
	predict_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	predict_e1.set_costs([])
	predict_e1.set_actions([{
		"type": &"EXECUTE_ATTACK",
		"params": {"target_count": 1},
	}])
	predict_e1.description = "执行攻击动作A。"
	effects[predict_e1.effect_id] = predict_e1

	var predict_e2 := ActionEffect.new()
	predict_e2.effect_id = &"predict_effect2"
	predict_e2.display_name = "预判·锁定+弃牌"
	predict_e2.mode = _TC.MODE_LISTEN
	# 优先级30（最高）：与掩护 effect1 同样监听 ATTACK_PRE，须保证预判的锁定+弃牌先于
	# 掩护的多选窗口执行--这样预判弃掉的掩护会离开手牌、不再出现在掩护窗口里（规则：
	# 行动牌离开手牌则其手牌效果不再触发）。普通行动牌效果优先级为10。
	predict_e2.priority = 30
	predict_e2.listen_timing = _TC.ATTACK_PRE
	predict_e2.listen_action_type = &"attack"
	predict_e2.set_conditions([{"op": &"ALWAYS"}])
	predict_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	predict_e2.set_costs([])
	predict_e2.set_actions([
		{"type": &"ADD_STATUS", "params": {"status_type": &"LOCKED", "duration": 1, "target_is_attack_target": true}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"from_target": true,
			"count": 1,
			"choose": true,
			"face_up": false,
			"reason": &"PREDICT_DISCARD",
		}},
	])
	predict_e2.description = "攻击时前时点，对目标施加锁定并弃置1张行动牌。"
	effects[predict_e2.effect_id] = predict_e2

	var predict_e3 := ActionEffect.new()
	predict_e3.effect_id = &"predict_effect3"
	predict_e3.display_name = "预判·不可否定"
	predict_e3.mode = _TC.MODE_LISTEN
	predict_e3.priority = 10
	# 监听 ATTACK_PRE（而非 ATTACK_AT）：ATTACK_AT 会开响应窗口，regular 监听器会被推迟到
	# 响应窗口关闭后才跑，那时识破的 NEGATE_ATTACK 已执行--预判的"不可无效"来不及阻断。
	# 改在 ATTACK_PRE（响应窗口之前）设置 unnegatable，确保识破 effect1 的 negate 被阻断。
	predict_e3.listen_timing = _TC.ATTACK_PRE
	predict_e3.listen_action_type = &"attack"
	predict_e3.set_conditions([{"op": &"ALWAYS"}])
	predict_e3.set_target_rules([{"rule": &"NO_TARGET"}])
	predict_e3.set_costs([])
	predict_e3.set_actions([{
		"type": &"SET_ATTACK_UNNEGATABLE",
		"params": {},
	}])
	predict_e3.description = "攻击A不会被无效攻击的效果影响。"
	effects[predict_e3.effect_id] = predict_e3

	# ═══════════════════════════════════════════
	# 22、识破
	# ═══════════════════════════════════════════
	var expose_avail := ActionEffect.new()
	expose_avail.effect_id = &"expose_availability"
	expose_avail.display_name = "识破·可用条件"
	expose_avail.mode = _TC.MODE_AVAILABILITY
	expose_avail.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	expose_avail.availability_priority = 30
	expose_avail.description = "响应攻击：优先级30。"
	effects[expose_avail.effect_id] = expose_avail

	var expose_e1 := ActionEffect.new()
	expose_e1.effect_id = &"expose_effect1"
	expose_e1.display_name = "识破·无效攻击"
	expose_e1.mode = _TC.MODE_DIRECT
	expose_e1.priority = 10
	expose_e1.set_conditions([{"op": &"ALWAYS"}])
	expose_e1.set_target_rules([{"rule": &"NO_TARGET"}])
	expose_e1.set_costs([])
	# 效果1：响应攻击A（写 responded/counter_attacked）+ 立即无效攻击（跳过到结算步）。
	# 均为原子动作，无需玩家输入，故同处一个效果内同步执行不会触发串行等待。
	# 预判 effect3 的 SET_ATTACK_UNNEGATABLE 会阻断 NEGATE_ATTACK（unnegatable 时 negated 不被置位）。
	expose_e1.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {}},
		{"type": &"NEGATE_ATTACK", "params": {}},
	])
	expose_e1.description = "响应攻击A（更新被响应记录），立即无效攻击（跳过到结算步，对预判无效）。"
	effects[expose_e1.effect_id] = expose_e1

	var expose_e2 := ActionEffect.new()
	expose_e2.effect_id = &"expose_effect2"
	expose_e2.display_name = "识破·偷牌+移动"
	expose_e2.mode = _TC.MODE_DIRECT
	expose_e2.priority = 10
	expose_e2.requires_effect = &"expose_effect1"
	expose_e2.set_conditions([{"op": &"ALWAYS"}])
	expose_e2.set_target_rules([{"rule": &"NO_TARGET"}])
	expose_e2.set_costs([])
	# 效果2：效果1结算后执行。偷牌（选攻击方1张暗牌，需输入）+ 循环移动（当前动力，需输入）。
	# 两个子动作都需玩家输入，依赖 _execute_actions 的串行机制：先创建偷牌子动作并等待其完成，
	# 再创建移动子动作（见 TimingEngine._execute_actions / ActionEngine.notify_effect_action_completed）。
	expose_e2.set_actions([
		{"type": &"EXECUTE_STEAL", "params": {"from_attacker": true, "count": 1, "choose": true}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
	])
	expose_e2.description = "效果1结算后执行：从攻击者手牌选1张行动牌获取，然后全动力循环移动。"
	effects[expose_e2.effect_id] = expose_e2

	# ═══════════════════════════════════════════
	# 23、觉醒
	# ═══════════════════════════════════════════
	var awaken_direct := ActionEffect.new()
	awaken_direct.effect_id = &"awaken_direct"
	awaken_direct.display_name = "觉醒"
	awaken_direct.mode = _TC.MODE_DIRECT
	awaken_direct.priority = 10
	awaken_direct.set_conditions([{"op": &"ALWAYS"}])
	awaken_direct.set_target_rules([{"rule": &"NO_TARGET"}])
	awaken_direct.set_costs([])
	awaken_direct.set_actions([{
		"type": &"AWAKEN_DRAW",
		"params": {},
	}])
	awaken_direct.description = "两轮：弃牌堆有预判/识破则取随机1张，否则选1种行动牌取弃牌堆1张+牌堆顶1张；最后获取牌。"
	effects[awaken_direct.effect_id] = awaken_direct

	return effects
