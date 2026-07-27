## GeneratedEquipmentEffects.gd — 42张N品质部件装备牌的新效果定义
##
## 按 new_logic/装备牌-N_效果与逻辑详解.txt 定义全部42张N装备牌（part_001~042，7套×6部位）
## 共用31个 effect_id（equipment_effect_001~031）。同型效果共用同一 effect_id。
##
## 与行动牌效果（GeneratedActionEffects）一样走**新 ActionEffect 体系**：
##   - DIRECT 模式：装备主动效果（机动头部消耗4动力抽牌等），由装备面板按钮/skill_bar 触发
##   - LISTEN 模式：监听指定动作的指定时点（被攻击时+动力、攻击前+威力、弃置后离场诱发等）
##   - AVAILABILITY 模式：响应窗口（本批N装备牌无此模式）
##
## 注册方式：装备牌被 set_equipment 动作设置到区域后，由 set_equipment_action.
## _register_equipment_effects 查本表的 get_effects_for_card 并 register_permanent_listener。
## 装备弃置/替换时注销。装备效果只在牌正面正式设置到合法区域后生效。
##
## 派生值型效果（联邦/帝国头部按同名装备数、重甲头部损伤不影响护甲、重甲右臂&机动右腿
## 损伤≥阈值+动力上限）不注册监听器，而是在 MechState.get_armor/get_total_power 与
## MechSlotState.get_effective_armor 查询时实时重算（调用本文件 compute_* helper）。
class_name GeneratedEquipmentEffects
extends RefCounted

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")

## card_def_id → [effect_id, ...] 映射（由 CardDatabaseLoader._effect_ids_map 提供）
## set_equipment_action 注册时调用 get_effects_for_card 查询
static var _card_effect_map: Dictionary = {}

## 是否已初始化
static var _initialized: bool = false


## 初始化 card_def_id → effect_id 列表 映射
## 由 set_equipment_action 首次调用时注入 effect_ids_map（来自 CardDatabaseLoader）
static func _init_map(effect_ids_map: Dictionary = {}) -> void:
	if effect_ids_map.size() > 0:
		_card_effect_map = effect_ids_map.duplicate(true)
	_initialized = true


## 获取牌的效果ID列表（用于 set_equipment_action 注册）
## 若 _card_effect_map 为空，尝试从 context.card_database.loader.get_effect_ids_map() 取
static func get_effects_for_card(card_def_id: StringName, context = null) -> Array:
	if not _initialized and context != null:
		_try_load_map_from_context(context)
	return _card_effect_map.get(card_def_id, [])


## 从 context 尝试加载 effect_ids_map（懒加载）
static func _try_load_map_from_context(context) -> void:
	if context == null:
		return
	var cdb = context.get("card_database") if context is Dictionary else context.card_database
	if cdb == null:
		return
	# CardDatabaseLoader 在 load_all 后持有 _effect_ids_map，通过 loader 暴露
	if cdb.get("loader") != null:
		_init_map(cdb.loader.get_effect_ids_map())
	elif cdb.has_method("get_effect_ids_map"):
		_init_map(cdb.get_effect_ids_map())


## 构建所有装备效果定义，返回 { effect_id: ActionEffect }
static func build_equipment_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# 001 量产装·已设置装备仍可卖出（6张：part_001~006）
	# 权限型效果：不注册监听器，由 sell_equipment_panel 识别 effect_id 后列出可卖的已设置装备。
	# 这里仍提供一个占位 ActionEffect，便于查询与未来扩展。
	# ═══════════════════════════════════════════
	var sell_set := _ActionEffect.new()
	sell_set.effect_id = &"equipment_effect_001"
	sell_set.display_name = "已设置可卖出"
	sell_set.mode = _TC.MODE_DIRECT
	sell_set.priority = 20  # 作用于卖出合法性检查，先于"已设置装备不可卖出"否决
	sell_set.set_conditions([{"op": &"ALWAYS"}])
	sell_set.set_target_rules([{"rule": &"NO_TARGET"}])
	sell_set.set_costs([])
	sell_set.set_actions([])  # 实际卖出逻辑由 sell_equipment_panel + CardSetService 处理
	sell_set.description = "此牌设置在区域中依然可以卖出。"
	effects[sell_set.effect_id] = sell_set

	# ═══════════════════════════════════════════
	# 002 联邦普装·头部：其他区域每设置1张名称带"联邦"的装备牌则护甲+1
	# 派生值实时重算型 —— 不注册监听器，由 MechState.get_armor 调用 compute_faction_armor_bonus
	# ═══════════════════════════════════════════
	var fed_head := _ActionEffect.new()
	fed_head.effect_id = &"equipment_effect_002"
	fed_head.display_name = "联邦普装·头部·按联邦装备数+护甲"
	fed_head.mode = _TC.MODE_DIRECT  # 占位模式，实际不注册监听（实时重算）
	fed_head.priority = 10
	fed_head.set_conditions([{"op": &"ALWAYS"}])
	fed_head.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_head.set_costs([])
	fed_head.set_actions([])
	fed_head.description = "其他区域每设置有1张名称带有联邦的装备牌则此牌护甲+1（实时重算）。"
	effects[fed_head.effect_id] = fed_head

	# ═══════════════════════════════════════════
	# 003 联邦普装·躯干：从区域中弃置时可移除原区域内所有损伤
	# 离场诱发型 —— 监听 DISCARD_AFTER 时点，按快照 from_slot_id 移除该区域全部损伤
	# ═══════════════════════════════════════════
	var fed_torso := _ActionEffect.new()
	fed_torso.effect_id = &"equipment_effect_003"
	fed_torso.display_name = "联邦普装·躯干·弃置移除原区域损伤"
	fed_torso.mode = _TC.MODE_LISTEN
	fed_torso.priority = 10
	fed_torso.listen_timing = _TC.DISCARD_AFTER
	# 触发条件：弃置的牌是本牌（source_card_id == 弃置牌），且从设置区域弃置（非手牌/临时区）
	fed_torso.set_conditions([{"op": &"DISCARD_IS_SELF_FROM_SLOT"}])
	fed_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_torso.set_costs([])
	# 动作：移除原区域全部损伤（数量由执行时读取原区域当前损伤，上限为该损伤数）
	fed_torso.set_actions([{
		"type": &"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT",
		"params": {"amount": -1}  # -1 = 移除原区域全部损伤
	}])
	fed_torso.description = "此牌从区域中弃置时可移除原先所在区域内的所有损伤。"
	effects[fed_torso.effect_id] = fed_torso

	# ═══════════════════════════════════════════
	# 004 联邦普装·右臂：将要在其他名称带"联邦"的装备牌上设置损伤时，可转移至此牌区域
	# 损伤位置替代型 —— 监听 DAMAGE_REDIRECT_WINDOW 时点
	# ═══════════════════════════════════════════
	var fed_rarm := _ActionEffect.new()
	fed_rarm.effect_id = &"equipment_effect_004"
	fed_rarm.display_name = "联邦普装·右臂·损伤转移(联邦装备)"
	fed_rarm.mode = _TC.MODE_LISTEN
	fed_rarm.priority = 20  # 损伤位置替代优先级20
	fed_rarm.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	fed_rarm.set_conditions([{"op": &"REDIRECT_TARGET_HAS_FACTION_EQUIP", "faction_substring": "联邦"}])
	fed_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_rarm.set_costs([])
	fed_rarm.set_actions([{
		"type": &"OFFER_DAMAGE_REDIRECT",
		"params": {"max_points": -1}  # -1 = 不限点数（每点原目标含联邦装备即可转）
	}])
	fed_rarm.description = "将要在其他名称带有联邦的装备牌上设置损伤时，可将损伤移至此牌所在区域。"
	effects[fed_rarm.effect_id] = fed_rarm

	# ═══════════════════════════════════════════
	# 005 联邦普装·左臂 / 近战装·左腿：从区域弃置时可立即抽1张装备牌并设置，否则弃置
	# 离场诱发型 + 子动作链 —— 监听 DISCARD_AFTER
	# ═══════════════════════════════════════════
	var fed_larm := _ActionEffect.new()
	fed_larm.effect_id = &"equipment_effect_005"
	fed_larm.display_name = "弃置抽装备立即设置"
	fed_larm.mode = _TC.MODE_LISTEN
	fed_larm.priority = 10
	fed_larm.listen_timing = _TC.DISCARD_AFTER
	fed_larm.set_conditions([{"op": &"DISCARD_IS_SELF_FROM_SLOT"}])
	fed_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_larm.set_costs([])
	fed_larm.set_actions([{
		"type": &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET",
		"params": {}
	}])
	fed_larm.description = "此牌从区域中弃置时可立即抽1张装备牌并设置到区域上(若不立即设置则需要直接弃置)。"
	effects[fed_larm.effect_id] = fed_larm

	# ═══════════════════════════════════════════
	# 006 联邦普装·右腿：机甲被指定为攻击目标时，可当前回合动力+2
	# 诱发型 —— 监听 ATTACK_PRE（目标选择完成后）
	# ═══════════════════════════════════════════
	var fed_rleg := _ActionEffect.new()
	fed_rleg.effect_id = &"equipment_effect_006"
	fed_rleg.display_name = "联邦普装·右腿·被攻击目标时动力+2"
	fed_rleg.mode = _TC.MODE_LISTEN
	fed_rleg.priority = 10
	fed_rleg.listen_timing = _TC.ATTACK_PRE
	fed_rleg.listen_action_type = &"attack"
	fed_rleg.set_conditions([{"op": &"SELF_MECH_IS_ATTACK_TARGET"}])
	fed_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_rleg.set_costs([])
	# 可选效果：弹"是否发动"窗，选择发动则动力+2（THIS_TURN 临时动力，可超上限）
	fed_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "获得当前回合动力+2", "actions": [
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 2, "method": &"add", "duration": &"THIS_TURN"}}
			]}],
		},
	}])
	fed_rleg.description = "机甲被指定为攻击目标时，可在当前回合动力+2。"
	effects[fed_rleg.effect_id] = fed_rleg

	# ═══════════════════════════════════════════
	# 007 联邦普装·左腿：被攻击命中时，可弃置此牌，减少本次攻击最多2损伤
	# 诱发型 —— 监听 ATTACK_AFTER（命中后、设置损伤前）
	# ═══════════════════════════════════════════
	var fed_lleg := _ActionEffect.new()
	fed_lleg.effect_id = &"equipment_effect_007"
	fed_lleg.display_name = "联邦普装·左腿·被命中弃牌减损伤"
	fed_lleg.mode = _TC.MODE_LISTEN
	fed_lleg.priority = 10
	fed_lleg.listen_timing = _TC.ATTACK_AFTER
	fed_lleg.listen_action_type = &"attack"
	fed_lleg.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_HIT"},
		{"op": &"ATTACK_MARKERS_ABOVE", "threshold": 0},
	])
	fed_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_lleg.set_costs([])
	# 弃置自身 + 减少攻击 markers（玩家选减1或2）
	fed_lleg.set_actions([{
		"type": &"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS",
		"params": {"max_reduce": 2}
	}])
	fed_lleg.description = "机甲被攻击命中时，可以弃置此牌，之后可最多减少此次攻击产生的2损伤。"
	effects[fed_lleg.effect_id] = fed_lleg

	# ═══════════════════════════════════════════
	# 008 帝国普装·头部：其他区域每设置1张名称带"帝国"的装备牌则动力+1
	# 派生值实时重算型 —— 由 MechState.get_total_power 调用 compute_faction_power_bonus
	# ═══════════════════════════════════════════
	var imp_head := _ActionEffect.new()
	imp_head.effect_id = &"equipment_effect_008"
	imp_head.display_name = "帝国普装·头部·按帝国装备数+动力"
	imp_head.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	imp_head.priority = 10
	imp_head.set_conditions([{"op": &"ALWAYS"}])
	imp_head.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_head.set_costs([])
	imp_head.set_actions([])
	imp_head.description = "其他区域每设置有1张名称带有帝国的装备牌则此牌动力+1（实时重算）。"
	effects[imp_head.effect_id] = imp_head

	# ═══════════════════════════════════════════
	# 009 帝国普装·躯干：被指定为攻击目标时，可当前回合动力+3，之后护甲-2
	# 诱发型 —— 监听 ATTACK_PRE
	# ═══════════════════════════════════════════
	var imp_torso := _ActionEffect.new()
	imp_torso.effect_id = &"equipment_effect_009"
	imp_torso.display_name = "帝国普装·躯干·被攻击目标时动力+3后护甲-2"
	imp_torso.mode = _TC.MODE_LISTEN
	imp_torso.priority = 10
	imp_torso.listen_timing = _TC.ATTACK_PRE
	imp_torso.listen_action_type = &"attack"
	imp_torso.set_conditions([{"op": &"SELF_MECH_IS_ATTACK_TARGET"}])
	imp_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_torso.set_costs([])
	imp_torso.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "获得当前回合动力+3，之后护甲-2", "actions": [
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 3, "method": &"add", "duration": &"THIS_TURN"}},
				{"type": &"MODIFY_ARMOR", "params": {"delta": -2, "duration": &"PERMANENT"}},
			]}],
		},
	}])
	imp_torso.description = "机甲被指定为攻击目标时，可在当前回合动力+3，之后护甲-2。"
	effects[imp_torso.effect_id] = imp_torso

	# ═══════════════════════════════════════════
	# 010 帝国普装·右臂：机甲发动攻击结算后，回复2动力
	# 诱发型 —— 监听 ATTACK_SETTLE
	# ═══════════════════════════════════════════
	var imp_rarm := _ActionEffect.new()
	imp_rarm.effect_id = &"equipment_effect_010"
	imp_rarm.display_name = "帝国普装·右臂·攻击结算后回复2动力"
	imp_rarm.mode = _TC.MODE_LISTEN
	imp_rarm.priority = 10
	imp_rarm.listen_timing = _TC.ATTACK_SETTLE
	imp_rarm.listen_action_type = &"attack"
	imp_rarm.set_conditions([{"op": &"SELF_MECH_IS_ATTACKER"}])
	imp_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_rarm.set_costs([])
	imp_rarm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复2动力", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 2}}
			]}],
		},
	}])
	imp_rarm.description = "机甲发动攻击结算后，回复2动力。"
	effects[imp_rarm.effect_id] = imp_rarm

	# ═══════════════════════════════════════════
	# 011 帝国普装·左臂：机甲发动攻击结算后，回复1动力
	# ═══════════════════════════════════════════
	var imp_larm := _ActionEffect.new()
	imp_larm.effect_id = &"equipment_effect_011"
	imp_larm.display_name = "帝国普装·左臂·攻击结算后回复1动力"
	imp_larm.mode = _TC.MODE_LISTEN
	imp_larm.priority = 10
	imp_larm.listen_timing = _TC.ATTACK_SETTLE
	imp_larm.listen_action_type = &"attack"
	imp_larm.set_conditions([{"op": &"SELF_MECH_IS_ATTACKER"}])
	imp_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_larm.set_costs([])
	imp_larm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复1动力", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 1}}
			]}],
		},
	}])
	imp_larm.description = "机甲发动攻击结算后，回复1动力。"
	effects[imp_larm.effect_id] = imp_larm

	# ═══════════════════════════════════════════
	# 012 帝国普装·右腿：每回合1次，累计移动8格后可回复2动力
	# 诱发型 —— 监听 BASIC_MOVE_AFTER，每回合1次
	# ═══════════════════════════════════════════
	var imp_rleg := _ActionEffect.new()
	imp_rleg.effect_id = &"equipment_effect_012"
	imp_rleg.display_name = "帝国普装·右腿·移动8格回复2动力"
	imp_rleg.mode = _TC.MODE_LISTEN
	imp_rleg.priority = 10
	imp_rleg.listen_timing = _TC.BASIC_MOVE_AFTER
	imp_rleg.listen_action_type = &"basic_move"
	imp_rleg.once_per_turn_key = &"equipment_effect_012"
	imp_rleg.set_conditions([
		{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8},
		{"op": &"SELF_MECH_IS_MOVE_SUBJECT"},
	])
	imp_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_rleg.set_costs([])
	imp_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复2动力", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 2}}
			]}],
		},
	}])
	imp_rleg.description = "每回合1次，机甲在当前回合内累积移动过8个格子，可回复2动力。"
	effects[imp_rleg.effect_id] = imp_rleg

	# ═══════════════════════════════════════════
	# 013 帝国普装·左腿：每回合1次，累计移动8格后可回复1动力
	# ═══════════════════════════════════════════
	var imp_lleg := _ActionEffect.new()
	imp_lleg.effect_id = &"equipment_effect_013"
	imp_lleg.display_name = "帝国普装·左腿·移动8格回复1动力"
	imp_lleg.mode = _TC.MODE_LISTEN
	imp_lleg.priority = 10
	imp_lleg.listen_timing = _TC.BASIC_MOVE_AFTER
	imp_lleg.listen_action_type = &"basic_move"
	imp_lleg.once_per_turn_key = &"equipment_effect_013"
	imp_lleg.set_conditions([
		{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8},
		{"op": &"SELF_MECH_IS_MOVE_SUBJECT"},
	])
	imp_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_lleg.set_costs([])
	imp_lleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复1动力", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 1}}
			]}],
		},
	}])
	imp_lleg.description = "每回合1次，机甲在当前回合内累积移动过8个格子，可回复1动力。"
	effects[imp_lleg.effect_id] = imp_lleg

	# ═══════════════════════════════════════════
	# 014 重甲装·头部/左臂/右腿/左腿：损伤不影响此牌所在区域提供的护甲
	# 派生值实时重算型 —— 由 MechSlotState.get_effective_armor 调用 slot_has_damage_immune_armor
	# ═══════════════════════════════════════════
	var heavy_armor_immune := _ActionEffect.new()
	heavy_armor_immune.effect_id = &"equipment_effect_014"
	heavy_armor_immune.display_name = "重甲装·损伤不影响护甲"
	heavy_armor_immune.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_armor_immune.priority = 10
	heavy_armor_immune.set_conditions([{"op": &"ALWAYS"}])
	heavy_armor_immune.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_armor_immune.set_costs([])
	heavy_armor_immune.set_actions([])
	heavy_armor_immune.description = "损伤不会影响此牌所在区域提供的护甲（实时重算）。"
	effects[heavy_armor_immune.effect_id] = heavy_armor_immune

	# ═══════════════════════════════════════════
	# 015 重甲装·躯干：被指定为攻击目标时，可弃2行动牌，当前回合护甲+4
	# 诱发型 —— 监听 ATTACK_PRE，弃2牌成本 + 临时护甲
	# ═══════════════════════════════════════════
	var heavy_torso := _ActionEffect.new()
	heavy_torso.effect_id = &"equipment_effect_015"
	heavy_torso.display_name = "重甲装·躯干·被攻击弃2牌护甲+4"
	heavy_torso.mode = _TC.MODE_LISTEN
	heavy_torso.priority = 10
	heavy_torso.listen_timing = _TC.ATTACK_PRE
	heavy_torso.listen_action_type = &"attack"
	heavy_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	heavy_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	])
	heavy_torso.set_actions([{
		"type": &"MODIFY_ATTACK_TEMP_ARMOR", "params": {"delta": 4},
	}])
	heavy_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合护甲+4。"
	effects[heavy_torso.effect_id] = heavy_torso

	# ═══════════════════════════════════════════
	# 016 重甲装·右臂 / 机动装·右腿：此牌上损伤≥1时，动力+1
	# 派生值实时重算型 —— 由 MechState.get_total_power 调用 slot_damage_threshold_power_bonus
	# ═══════════════════════════════════════════
	var heavy_rarm := _ActionEffect.new()
	heavy_rarm.effect_id = &"equipment_effect_016"
	heavy_rarm.display_name = "损伤≥1时动力上限+1"
	heavy_rarm.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_rarm.priority = 10
	heavy_rarm.set_conditions([{"op": &"ALWAYS"}])
	heavy_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_rarm.set_costs([])
	heavy_rarm.set_actions([])
	heavy_rarm.description = "此牌上设置的损伤≥1时，动力+1（实时重算）。"
	effects[heavy_rarm.effect_id] = heavy_rarm

	# ═══════════════════════════════════════════
	# 017 机动装·头部：每我方回合1次，可消耗4动力抽1张行动牌
	# DIRECT 主动效果 —— 由装备面板按钮/skill_bar 触发，每我方回合1次
	# ═══════════════════════════════════════════
	var mob_head := _ActionEffect.new()
	mob_head.effect_id = &"equipment_effect_017"
	mob_head.display_name = "机动装·头部·消耗4动力抽1行动牌"
	mob_head.mode = _TC.MODE_DIRECT
	mob_head.priority = 10
	mob_head.once_per_turn_key = &"equipment_effect_017"
	mob_head.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "threshold": 4},
	])
	mob_head.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_head.set_costs([
		{"cost_type": &"SPEND_POWER", "amount": 4},
	])
	mob_head.set_actions([
		{"type": &"DRAW_ACTION", "params": {"count": 1}},
	])
	mob_head.description = "每我方回合1次，可以消耗4动力抽1张行动牌。"
	effects[mob_head.effect_id] = mob_head

	# ═══════════════════════════════════════════
	# 018 机动装·躯干：被指定为攻击目标时，可弃2行动牌，当前回合动力+5
	# 诱发型 —— 监听 ATTACK_PRE
	# ═══════════════════════════════════════════
	var mob_torso := _ActionEffect.new()
	mob_torso.effect_id = &"equipment_effect_018"
	mob_torso.display_name = "机动装·躯干·被攻击弃2牌动力+5"
	mob_torso.mode = _TC.MODE_LISTEN
	mob_torso.priority = 10
	mob_torso.listen_timing = _TC.ATTACK_PRE
	mob_torso.listen_action_type = &"attack"
	mob_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	mob_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2},
	])
	mob_torso.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
	])
	mob_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合动力+5。"
	effects[mob_torso.effect_id] = mob_torso

	# ═══════════════════════════════════════════
	# 019 机动装·右臂：其他装备将因新损伤弃置时，可把最多2点损伤转移到本区域
	# 损伤位置替代型 —— 监听 DAMAGE_REDIRECT_WINDOW，最多2点
	# ═══════════════════════════════════════════
	var mob_rarm := _ActionEffect.new()
	mob_rarm.effect_id = &"equipment_effect_019"
	mob_rarm.display_name = "机动装·右臂·损伤转移(最多2点)"
	mob_rarm.mode = _TC.MODE_LISTEN
	mob_rarm.priority = 20
	mob_rarm.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	mob_rarm.set_conditions([{"op": &"REDIRECT_HAS_DESTROYABLE_EQUIP"}])
	mob_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_rarm.set_costs([])
	mob_rarm.set_actions([{
		"type": &"OFFER_DAMAGE_REDIRECT",
		"params": {"max_points": 2}
	}])
	mob_rarm.description = "其他区域设置的装备牌会因即将设置的损伤而弃置时，可以将最多2损伤转移至此牌所在区域。"
	effects[mob_rarm.effect_id] = mob_rarm

	# ═══════════════════════════════════════════
	# 020 机动装·左臂：机甲发动的攻击命中后，回复3动力
	# 诱发型 —— 监听 ATTACK_AFTER（命中后）
	# ═══════════════════════════════════════════
	var mob_larm := _ActionEffect.new()
	mob_larm.effect_id = &"equipment_effect_020"
	mob_larm.display_name = "机动装·左臂·攻击命中后回复3动力"
	mob_larm.mode = _TC.MODE_LISTEN
	mob_larm.priority = 10
	mob_larm.listen_timing = _TC.ATTACK_AFTER
	mob_larm.listen_action_type = &"attack"
	mob_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
	])
	mob_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_larm.set_costs([])
	mob_larm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复3动力", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 3}}
			]}],
		},
	}])
	mob_larm.description = "机甲发动的攻击命中后，回复3动力。"
	effects[mob_larm.effect_id] = mob_larm

	# ═══════════════════════════════════════════
	# 021 机动装·左腿：此牌上损伤≥2时，动力+1
	# 派生值实时重算型 —— 阈值2，由 slot_damage_threshold_power_bonus 判定
	# ═══════════════════════════════════════════
	var mob_lleg := _ActionEffect.new()
	mob_lleg.effect_id = &"equipment_effect_021"
	mob_lleg.display_name = "损伤≥2时动力上限+1"
	mob_lleg.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	mob_lleg.priority = 10
	mob_lleg.set_conditions([{"op": &"ALWAYS"}])
	mob_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_lleg.set_costs([])
	mob_lleg.set_actions([])
	mob_lleg.description = "此牌上设置的损伤≥2时，动力+1（实时重算）。"
	effects[mob_lleg.effect_id] = mob_lleg

	# ═══════════════════════════════════════════
	# 022 狙击装·头部：使用远程武器发动攻击时，该攻击范围+1
	# 强制修正型 —— 监听 ATTACK_BEFORE，读 effective_weapon_type
	# ═══════════════════════════════════════════
	var snip_head := _ActionEffect.new()
	snip_head.effect_id = &"equipment_effect_022"
	snip_head.display_name = "狙击装·头部·远程武器范围+1"
	snip_head.mode = _TC.MODE_LISTEN
	snip_head.priority = 10
	snip_head.listen_timing = _TC.ATTACK_BEFORE
	snip_head.listen_action_type = &"attack"
	snip_head.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
	])
	snip_head.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_head.set_costs([])
	snip_head.set_actions([
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 1}},
	])
	snip_head.description = "使用远程武器发动攻击时，该攻击范围+1。"
	effects[snip_head.effect_id] = snip_head

	# ═══════════════════════════════════════════
	# 023 狙击装·躯干：无效果
	# ═══════════════════════════════════════════
	var snip_torso := _ActionEffect.new()
	snip_torso.effect_id = &"equipment_effect_023"
	snip_torso.display_name = "狙击装·躯干·无效果"
	snip_torso.mode = _TC.MODE_DIRECT
	snip_torso.priority = 10
	snip_torso.set_conditions([{"op": &"ALWAYS"}])
	snip_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_torso.set_costs([])
	snip_torso.set_actions([])
	snip_torso.description = "无额外卡牌效果。"
	effects[snip_torso.effect_id] = snip_torso

	# ═══════════════════════════════════════════
	# 024 狙击装·右臂：每我方回合1次，可弃1行动牌，回复1动力
	# DIRECT 主动效果 —— 由装备面板按钮/skill_bar 触发，每我方回合1次
	# ═══════════════════════════════════════════
	var snip_rarm := _ActionEffect.new()
	snip_rarm.effect_id = &"equipment_effect_024"
	snip_rarm.display_name = "狙击装·右臂·弃1牌回复1动力"
	snip_rarm.mode = _TC.MODE_DIRECT
	snip_rarm.priority = 10
	snip_rarm.once_per_turn_key = &"equipment_effect_024"
	snip_rarm.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	snip_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_rarm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1},
	])
	snip_rarm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	])
	snip_rarm.description = "每我方回合1次，可以弃置1张行动牌，回复1动力。"
	effects[snip_rarm.effect_id] = snip_rarm

	# ═══════════════════════════════════════════
	# 025 狙击装·左臂：使用远程武器攻击时，可弃1行动牌，使威力+2
	# 诱发型 —— 监听 ATTACK_BEFORE，读 effective_weapon_type
	# ═══════════════════════════════════════════
	var snip_larm := _ActionEffect.new()
	snip_larm.effect_id = &"equipment_effect_025"
	snip_larm.display_name = "狙击装·左臂·远程弃1牌威力+2"
	snip_larm.mode = _TC.MODE_LISTEN
	snip_larm.priority = 10
	snip_larm.listen_timing = _TC.ATTACK_BEFORE
	snip_larm.listen_action_type = &"attack"
	snip_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	snip_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_larm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	snip_larm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 2}},
	])
	snip_larm.description = "使用远程武器发动攻击时，可以弃置1张行动牌，使威力+2。"
	effects[snip_larm.effect_id] = snip_larm

	# ═══════════════════════════════════════════
	# 026 狙击装·右腿：打出攻击牌时，可立即移动到相邻1格
	# 诱发型 —— 监听 USE_ACTION_AT（打出攻击牌时）
	# ═══════════════════════════════════════════
	var snip_rleg := _ActionEffect.new()
	snip_rleg.effect_id = &"equipment_effect_026"
	snip_rleg.display_name = "狙击装·右腿·打出攻击牌移动1格"
	snip_rleg.mode = _TC.MODE_LISTEN
	snip_rleg.priority = 10
	snip_rleg.listen_timing = _TC.USE_ACTION_AT
	snip_rleg.listen_action_type = &"use_action_card"
	snip_rleg.set_conditions([
		{"op": &"USED_CARD_TYPE_IS", "card_type": "攻击"},
		{"op": &"USED_CARD_OWNER_IS_SELF"},  # 只有持有者本人打攻击牌才触发（敌方装同类牌不弹我方框）
	])
	snip_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_rleg.set_costs([])
	snip_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移动到相邻1格", "actions": [
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1}}
			]}],
		},
	}])
	snip_rleg.description = "打出攻击牌时，可立即移动到相邻的1个格子上。"
	effects[snip_rleg.effect_id] = snip_rleg

	# ═══════════════════════════════════════════
	# 027 狙击装·左腿：打出迎击牌时，可立即移动到相邻1格
	# 诱发型 —— 监听 USE_ACTION_AT（打出迎击牌时）
	# ═══════════════════════════════════════════
	var snip_lleg := _ActionEffect.new()
	snip_lleg.effect_id = &"equipment_effect_027"
	snip_lleg.display_name = "狙击装·左腿·打出迎击牌移动1格"
	snip_lleg.mode = _TC.MODE_LISTEN
	snip_lleg.priority = 10
	snip_lleg.listen_timing = _TC.USE_ACTION_AT
	snip_lleg.listen_action_type = &"use_action_card"
	snip_lleg.set_conditions([
		{"op": &"USED_CARD_TYPE_IS", "card_type": "迎击"},
		{"op": &"USED_CARD_OWNER_IS_SELF"},  # 只有持有者本人打迎击牌才触发
	])
	snip_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_lleg.set_costs([])
	snip_lleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移动到相邻1格", "actions": [
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1}}
			]}],
		},
	}])
	snip_lleg.description = "打出迎击牌时，可立即移动到相邻的1个格子上。"
	effects[snip_lleg.effect_id] = snip_lleg

	# ═══════════════════════════════════════════
	# 028 近战装·头部：可将攻击武器范围-2(最低1)，威力+3，类型变近战(不适用于近战武器)
	# 类型转换型 —— 监听 ATTACK_BEFORE，priority 20（先于近战威力+2效果）
	# ═══════════════════════════════════════════
	var melee_head := _ActionEffect.new()
	melee_head.effect_id = &"equipment_effect_028"
	melee_head.display_name = "近战装·头部·非近战转近战范围-2威力+3"
	melee_head.mode = _TC.MODE_LISTEN
	melee_head.priority = 20  # 先于 priority 10 的近战威力+2
	melee_head.listen_timing = _TC.ATTACK_BEFORE
	melee_head.listen_action_type = &"attack"
	melee_head.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT", "weapon_kind": &"近战"},
	])
	melee_head.set_target_rules([{"rule": &"NO_TARGET"}])
	melee_head.set_costs([])
	melee_head.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "范围-2(最低1)+威力+3+转近战", "actions": [
				{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min_value": 1}},
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
				{"type": &"SET_ATTACK_EFFECTIVE_WEAPON_KIND", "params": {"weapon_kind": &"近战"}},
			]}],
		},
	}])
	melee_head.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+3，类型变为近战武器(不适用于近战武器)。"
	effects[melee_head.effect_id] = melee_head

	# ═══════════════════════════════════════════
	# 029 近战装·躯干：打出迎击牌时，当前回合护甲+2
	# 诱发型 —— 监听 USE_ACTION_AT（打出迎击牌时）
	# ═══════════════════════════════════════════
	var melee_torso := _ActionEffect.new()
	melee_torso.effect_id = &"equipment_effect_029"
	melee_torso.display_name = "近战装·躯干·打出迎击牌护甲+2"
	melee_torso.mode = _TC.MODE_LISTEN
	melee_torso.priority = 10
	melee_torso.listen_timing = _TC.USE_ACTION_AT
	melee_torso.listen_action_type = &"use_action_card"
	melee_torso.set_conditions([
		{"op": &"USED_CARD_TYPE_IS", "card_type": "迎击"},
		{"op": &"USED_CARD_OWNER_IS_SELF"},  # 只有持有者本人打迎击牌才触发
	])
	melee_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	melee_torso.set_costs([])
	melee_torso.set_actions([
		{"type": &"MODIFY_ARMOR", "params": {"delta": 2, "duration": &"THIS_TURN"}},
	])
	melee_torso.description = "打出迎击牌时，当前回合护甲+2。"
	effects[melee_torso.effect_id] = melee_torso

	# ═══════════════════════════════════════════
	# 030 近战装·右臂 / 左臂：使用近战武器攻击时，可弃1行动牌，使威力+2
	# 诱发型 —— 监听 ATTACK_BEFORE，读 effective_weapon_type，priority 10（晚于028转换）
	# ═══════════════════════════════════════════
	var melee_arm := _ActionEffect.new()
	melee_arm.effect_id = &"equipment_effect_030"
	melee_arm.display_name = "近战装·臂·近战弃1牌威力+2"
	melee_arm.mode = _TC.MODE_LISTEN
	melee_arm.priority = 10  # 晚于 priority 20 的近战类型转换
	melee_arm.listen_timing = _TC.ATTACK_BEFORE
	melee_arm.listen_action_type = &"attack"
	melee_arm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	melee_arm.set_target_rules([{"rule": &"NO_TARGET"}])
	melee_arm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	melee_arm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 2}},
	])
	melee_arm.description = "使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2。"
	effects[melee_arm.effect_id] = melee_arm

	# ═══════════════════════════════════════════
	# 031 近战装·右腿：此牌因损伤而从区域中弃置时，可移除机甲其他区域最多2损伤
	# 离场诱发型 —— 监听 DISCARD_AFTER，只接受 reason=damage_durability
	# ═══════════════════════════════════════════
	var melee_rleg := _ActionEffect.new()
	melee_rleg.effect_id = &"equipment_effect_031"
	melee_rleg.display_name = "近战装·右腿·因损伤弃置移除其他区域2损伤"
	melee_rleg.mode = _TC.MODE_LISTEN
	melee_rleg.priority = 10
	melee_rleg.listen_timing = _TC.DISCARD_AFTER
	# 条件：弃置的牌是本牌，且从设置区域弃置，且原因是因损伤
	melee_rleg.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
		{"op": &"DISCARD_REASON_IS", "reason": &"damage_durability"},
	])
	melee_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	melee_rleg.set_costs([])
	melee_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移除其他区域最多2损伤", "actions": [
				{"type": &"REMOVE_DAMAGE_TOKENS_OTHER_SLOTS", "params": {"amount": 2}}
			]}],
		},
	}])
	melee_rleg.description = "此牌因损伤而从区域中弃置时可移除机甲其他区域内最多2损伤。"
	effects[melee_rleg.effect_id] = melee_rleg

	# ═══════════════════════════════════════════
	# 测试用：非迎击牌（装备牌）AVAILABILITY 响应效果
	# 验证强袭 effect2 在「非迎击牌响应」时也触发（规则：被任何效果响应都算）。
	# 装备牌设置到机甲后，该机甲被攻击时此效果进响应窗口；玩家选中后用当前动力移动1次。
	# ═══════════════════════════════════════════
	var test_respond := _ActionEffect.new()
	test_respond.effect_id = &"equipment_effect_test_respond"
	test_respond.display_name = "测试·响应移动"
	test_respond.mode = _TC.MODE_AVAILABILITY
	test_respond.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	test_respond.availability_priority = 10
	test_respond.listen_timing = _TC.ATTACK_AT
	test_respond.set_conditions([{"op": &"ALWAYS"}])
	test_respond.set_target_rules([{"rule": &"NO_TARGET"}])
	test_respond.set_costs([])
	test_respond.set_actions([{
		"type": &"EXECUTE_SINGLE_MOVE",
		"params": {"use_current_power": true, "loop_until_cancel": false},
	}])
	test_respond.description = "被攻击时可响应：用当前动力移动1次（测试非迎击牌响应触发强袭2）。"
	effects[test_respond.effect_id] = test_respond

	return effects


# ════════════════════════════════════════════════════════════════
# 派生值实时重算 helper（由 MechState / MechSlotState 调用）
# ════════════════════════════════════════════════════════════════

## 判断装备牌实例是否正面正式设置（在区域中、face_up、未 disabled）
static func is_equipment_active(card) -> bool:
	if card == null or card.def == null:
		return false
	if not (card.def is _EquipmentCardDef):
		return false
	if card.get("disabled") == true:
		return false
	if card.get("face_down") == true:
		return false
	# zone 必须是 equipment_slot / weapon_slot / reserve_slot（在区域中）
	var z = card.get("zone")
	return z == &"equipment_slot" or z == &"weapon_slot" or z == &"reserve_slot" or z == &"equipped"


## 计算某机甲上"名称包含 substring"的其他区域正式设置装备牌数量
## 用于联邦头部（substring=联邦）/帝国头部（substring=帝国）
static func count_faction_equipment(mech, exclude_slot_id: StringName, substring: String) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var count: int = 0
	for sid in mech.slots:
		if sid == exclude_slot_id:
			continue
		var slot = mech.slots[sid]
		if slot == null:
			continue
		var card = slot.get("equipped_card")
		if not is_equipment_active(card):
			continue
		var name: String = String(card.def.get("display_name"))
		if name.find(substring) >= 0:
			count += 1
	return count


## 联邦头部护甲加值 = 其他区域联邦装备数
static func compute_faction_armor_bonus(mech, slot_id: StringName) -> int:
	return count_faction_equipment(mech, slot_id, "联邦")


## 帝国头部动力上限加值 = 其他区域帝国装备数
static func compute_faction_power_bonus(mech, slot_id: StringName) -> int:
	return count_faction_equipment(mech, slot_id, "帝国")


## 判断某 slot 的装备是否有"损伤不影响护甲"效果（重甲头部/左臂/右腿/左腿，effect_014）
static func slot_has_damage_immune_armor(mech, slot_id: StringName) -> bool:
	if mech == null or mech.get("slots") == null:
		return false
	var slot = mech.slots.get(slot_id)
	if slot == null:
		return false
	var card = slot.get("equipped_card")
	if not is_equipment_active(card):
		return false
	return _card_has_effect_id(card, &"equipment_effect_014")


## 判断一张装备牌实例是否有"损伤不影响护甲"效果（供 MechSlotState.get_effective_armor 直接调用）
static func card_has_damage_immune_armor(card) -> bool:
	if not is_equipment_active(card):
		return false
	return _card_has_effect_id(card, &"equipment_effect_014")


## 判断某 slot 的装备是否有"损伤≥阈值时动力上限+1"效果
## effect_016（重甲右臂/机动右腿，阈值1）/ effect_021（机动左腿，阈值2）
static func slot_damage_threshold_power_bonus(mech, slot_id: StringName) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var slot = mech.slots.get(slot_id)
	if slot == null:
		return 0
	var card = slot.get("equipped_card")
	if not is_equipment_active(card):
		return 0
	# MechSlotState 是 RefCounted（非 Dictionary），用属性访问取 region_damage_tokens
	var region_damage: int = int(slot.region_damage_tokens) if "region_damage_tokens" in slot else 0
	# 同时计入牌上损伤（损伤在牌上时也算该区域有损伤）
	if card and card.get("damage_tokens"):
		region_damage = max(region_damage, int(card.damage_tokens))
	if _card_has_effect_id(card, &"equipment_effect_016") and region_damage >= 1:
		return 1
	if _card_has_effect_id(card, &"equipment_effect_021") and region_damage >= 2:
		return 1
	return 0


## 判断 card 的 def 是否绑定某 effect_id（查 _card_effect_map）
static func _card_has_effect_id(card, effect_id: StringName) -> bool:
	if card == null or card.def == null:
		return false
	if not _initialized:
		return false  # map 未加载，保守返回 false（效果不生效）
	var eids = _card_effect_map.get(card.def.card_id, [])
	return effect_id in eids
