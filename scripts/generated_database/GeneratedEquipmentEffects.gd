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

## 全场光环查询所需的 game_state（由 BattleState 建局时注入；effect_080/086 全场光环用）
static var _aura_game_state = null


## 注入 game_state 供全场光环 helper 查询所有机甲（建局时调用）
static func set_aura_game_state(gs) -> void:
	_aura_game_state = gs


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
	# 动作：可取消选择；确认后移除原区域全部损伤（"可移除"=optional CHOOSE_ONE）
	fed_torso.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移除原区域全部损伤", "actions": [
				{"type": &"REMOVE_DAMAGE_TOKENS_FROM_DISCARD_ORIGIN_SLOT", "params": {"amount": -1}}  # -1 = 全部
			]}],
		},
	}])
	fed_torso.description = "此牌从区域中弃置时可移除原先所在区域内的所有损伤。"
	effects[fed_torso.effect_id] = fed_torso

	# ═══════════════════════════════════════════
	# 004 联邦普装·右臂：其他装备牌即将设置损伤时，可转移至此牌区域
	# 损伤位置替代型：监听 DAMAGE_REDIRECT_WINDOW 时点
	# ═══════════════════════════════════════════
	var fed_rarm := _ActionEffect.new()
	fed_rarm.effect_id = &"equipment_effect_004"
	fed_rarm.display_name = "联邦普装·右臂·损伤转移"
	fed_rarm.mode = _TC.MODE_LISTEN
	fed_rarm.priority = 20  # 损伤位置替代优先级20
	fed_rarm.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	# 每次即将设置损伤到我方机甲(右臂所在机甲)时，最多2损伤移至此牌区域。
	# 允许转移致本牌损坏（效果转移，非正常逐点攻击损伤）。fixed_slot 不触发转移窗。
	fed_rarm.set_conditions([
		{"op": &"TARGET_IS_OWN_MECH"},  # 损伤目标==本牌所在机甲(我方机甲)
	])
	fed_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_rarm.set_costs([])
	fed_rarm.set_actions([{
		"type": &"OFFER_DAMAGE_REDIRECT",
		"params": {"max_points": 2}  # 最多转移2点
	}])
	fed_rarm.description = "每次即将设置损伤到我方机甲时，可以将最多2损伤移至此牌所在区域。"
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
	# 可取消选择；确认后弃置自身 + 自动减少攻击 markers（"可以弃置"=optional CHOOSE_ONE）
	fed_lleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃置此牌，最多减少2损伤", "actions": [
				{"type": &"DISCARD_SELF_AND_REDUCE_ATTACK_MARKERS", "params": {"max_reduce": 2}}
			]}],
		},
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
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": -2, "method": &"add", "duration": &"THIS_TURN"}},
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
	imp_rarm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	])
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
	imp_larm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	])
	imp_larm.description = "机甲发动攻击结算后，回复1动力。"
	effects[imp_larm.effect_id] = imp_larm

	# ═══════════════════════════════════════════
	# 012 帝国普装·右腿：每回合1次，累计移动8格后可回复2动力
	# 诱发型 —— 监听 BASIC_MOVE_AFTER，每回合1次
	# ═══════════════════════════════════════════
	var imp_rleg := _ActionEffect.new()
	imp_rleg.effect_id = &"equipment_effect_012"
	imp_rleg.display_name = "帝国普装·右腿·移动8格回复2动力"
	imp_rleg.mode = _TC.MODE_DIRECT
	imp_rleg.priority = 10
	imp_rleg.once_per_turn_key = &"equipment_effect_012"
	imp_rleg.set_conditions([
		{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8},
	])
	imp_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_rleg.set_costs([])
	imp_rleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	])
	imp_rleg.description = "每回合1次，机甲在当前回合内累积移动过8个格子，可回复2动力。"
	effects[imp_rleg.effect_id] = imp_rleg

	# ═══════════════════════════════════════════
	# 013 帝国普装·左腿：每回合1次，累计移动8格后可回复1动力
	# ═══════════════════════════════════════════
	var imp_lleg := _ActionEffect.new()
	imp_lleg.effect_id = &"equipment_effect_013"
	imp_lleg.display_name = "帝国普装·左腿·移动8格回复1动力"
	imp_lleg.mode = _TC.MODE_DIRECT
	imp_lleg.priority = 10
	imp_lleg.once_per_turn_key = &"equipment_effect_013"
	imp_lleg.set_conditions([
		{"op": &"MOVED_DISTANCE_THIS_TURN_ABOVE", "threshold": 8},
	])
	imp_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	imp_lleg.set_costs([])
	imp_lleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	])
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
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	heavy_torso.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": 4, "method": &"add", "duration": &"THIS_TURN"}},
	])
	heavy_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合护甲+4。"
	effects[heavy_torso.effect_id] = heavy_torso

	# ═══════════════════════════════════════════
	# 016 重甲装·右臂：此牌上损伤≥1时，动力+1（机动腿改 effect_021 逐损伤+1）
	# 派生值实时重算型 —— 由 MechState.get_total_power 调用 slot_damage_threshold_power_bonus
	# ═══════════════════════════════════════════
	var heavy_rarm := _ActionEffect.new()
	heavy_rarm.effect_id = &"equipment_effect_016"
	heavy_rarm.display_name = "重甲装·右臂·损伤≥1动力+1"
	heavy_rarm.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_rarm.priority = 10
	heavy_rarm.set_conditions([{"op": &"ALWAYS"}])
	heavy_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_rarm.set_costs([])
	heavy_rarm.set_actions([])
	heavy_rarm.description = "此牌上设置的损伤≥1时，动力+1（实时重算）。"
	effects[heavy_rarm.effect_id] = heavy_rarm

	# ═══════════════════════════════════════════
	# 017 机动装·头部：每回合1次，消耗动力后若动力为0，可回复2动力并用当前动力移动
	# 诱发型：监听 basic_move.BASIC_MOVE_AFTER（落位后触发，避免额外移动被原移动落位覆盖）
	# ═══════════════════════════════════════════
	var mob_head := _ActionEffect.new()
	mob_head.effect_id = &"equipment_effect_017"
	mob_head.display_name = "机动装·头部·耗尽动力回复并移动"
	mob_head.mode = _TC.MODE_LISTEN
	mob_head.priority = 10
	mob_head.listen_timing = _TC.BASIC_MOVE_AFTER
	mob_head.listen_action_type = &"basic_move"
	mob_head.once_per_turn_key = &"equipment_effect_017"
	mob_head.once_per_turn_max = 1
	mob_head.set_conditions([
		{"op": &"SELF_MECH_IS_MOVE_SUBJECT"},
		{"op": &"OWNER_POWER_EQUALS", "value": 0},
	])
	mob_head.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_head.set_costs([])
	# 可取消：确认后先回复2动力，再以当时当前动力循环移动（到取消或无动力）
	mob_head.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复2动力并用当前动力移动", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 2}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
			]}],
		},
	}])
	mob_head.description = "每回合1次，消耗动力后若没有动力剩余，可回复2动力并用当前动力移动。"
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
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	mob_torso.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
	])
	mob_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合动力+5。"
	effects[mob_torso.effect_id] = mob_torso

	# ═══════════════════════════════════════════
	# 019 机动装·右臂：我方主阶段可弃置此牌，本回合动力+4（DIRECT 主动效果）
	# "使用迎击牌时"路径由 effect_032 处理；二者共享同一牌实例，无每回合限次
	# ═══════════════════════════════════════════
	var mob_rarm := _ActionEffect.new()
	mob_rarm.effect_id = &"equipment_effect_019"
	mob_rarm.display_name = "机动装·右臂·弃置动力+4(主动)"
	mob_rarm.mode = _TC.MODE_DIRECT
	mob_rarm.priority = 10
	mob_rarm.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	mob_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_rarm.set_costs([])
	# 我方主阶段可弃置此牌换本回合动力+4；"使用迎击牌时"路径由 effect_032 处理
	mob_rarm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃置此牌，本回合动力+4", "actions": [
				{"type": &"DISCARD_SELF_FROM_SLOT", "params": {"reason": &"effect_self_discard"}},
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 4, "method": &"add", "duration": &"THIS_TURN"}},
			]}],
		},
	}])
	mob_rarm.description = "我方回合或使用迎击牌时，可以弃置此牌，使机甲本回合动力+4。"
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
	# 自动回复（"命中后回复"非"可以"，无 CHOOSE_ONE）；回复攻击者动力
	mob_larm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 3, "mech_id": "$binding_context.mech_id"}},
	])
	mob_larm.description = "机甲发动的攻击命中后，回复3动力。"
	effects[mob_larm.effect_id] = mob_larm

	# ═══════════════════════════════════════════
	# 021 机动装·左腿：此牌上损伤≥2时，动力+1
	# 派生值实时重算型 —— 阈值2，由 slot_damage_threshold_power_bonus 判定
	# ═══════════════════════════════════════════
	var mob_lleg := _ActionEffect.new()
	mob_lleg.effect_id = &"equipment_effect_021"
	mob_lleg.display_name = "机动装·腿·每损伤动力+1"
	mob_lleg.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	mob_lleg.priority = 10
	mob_lleg.set_conditions([{"op": &"ALWAYS"}])
	mob_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_lleg.set_costs([])
	mob_lleg.set_actions([])
	mob_lleg.description = "此牌上每设置有1损伤，动力+1（实时重算）。"
	effects[mob_lleg.effect_id] = mob_lleg

	# ═══════════════════════════════════════════
	# 022 狙击装·头部：使用远程武器发动攻击时，该攻击范围+1
	# 派生值实时重算型 —— 不注册监听器，由 app_root._get_weapon_range /
	# attack_action._step_select_weapon 调用 get_passive_weapon_range_bonus
	# ═══════════════════════════════════════════
	var snip_head := _ActionEffect.new()
	snip_head.effect_id = &"equipment_effect_022"
	snip_head.display_name = "狙击装·头部·远程武器范围+1"
	snip_head.mode = _TC.MODE_DIRECT  # 占位模式，实际不注册监听（实时重算）
	snip_head.priority = 10
	snip_head.set_conditions([{"op": &"ALWAYS"}])
	snip_head.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_head.set_costs([])
	snip_head.set_actions([])
	snip_head.description = "使用远程武器发动攻击时，该攻击范围+1。"
	effects[snip_head.effect_id] = snip_head

	# ═══════════════════════════════════════════
	# 023 狙击装·躯干：无效果
	# ═══════════════════════════════════════════
	var snip_torso := _ActionEffect.new()
	snip_torso.effect_id = &"equipment_effect_023"
	snip_torso.display_name = "狙击装·躯干·被远程攻击弃牌减威力"
	snip_torso.mode = _TC.MODE_LISTEN
	snip_torso.priority = 10
	snip_torso.listen_timing = _TC.ATTACK_PRE
	snip_torso.listen_action_type = &"attack"
	snip_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
	])
	snip_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_torso.set_costs([])
	snip_torso.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃此牌，攻击威力-4", "actions": [
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -4}},
				{"type": &"DISCARD_SELF_FROM_SLOT", "params": {}},
			]}],
		},
	}])
	snip_torso.description = "被远程武器攻击时，可以弃置此牌，使此次攻击威力-4。"
	effects[snip_torso.effect_id] = snip_torso

	# ═══════════════════════════════════════════
	# 024 狙击装·右臂：我方回合1次，可弃1行动牌，回复2动力
	# DIRECT 主动效果：装备面板发动按钮触发，每我方回合1次
	# 弃牌为 optional 费用 -> 走 _request_optional_discard 弹选牌框让玩家自选弃哪张（取消=不发动，不消耗本回合次数）
	# ═══════════════════════════════════════════
	var snip_rarm := _ActionEffect.new()
	snip_rarm.effect_id = &"equipment_effect_024"
	snip_rarm.display_name = "狙击装·右臂·弃1牌回复2动力"
	snip_rarm.mode = _TC.MODE_DIRECT
	snip_rarm.priority = 10
	snip_rarm.once_per_turn_key = &"equipment_effect_024"
	snip_rarm.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	snip_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	snip_rarm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	snip_rarm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	])
	snip_rarm.description = "我方回合1次，可以弃置1张行动牌，回复2动力。"
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
	# 026 狙击装·右腿：使用攻击牌时，可立即免费移动到相邻1格（free_move 不消耗动力，adjacent_only 仅相邻）
	# 诱发型 —— 监听 USE_ACTION_AT（使用攻击牌时）
	# ═══════════════════════════════════════════
	var snip_rleg := _ActionEffect.new()
	snip_rleg.effect_id = &"equipment_effect_026"
	snip_rleg.display_name = "狙击装·右腿·使用攻击牌移动1格"
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
	snip_rleg.set_actions([
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1, "free_move": true, "adjacent_only": true, "use_current_power": false, "loop_until_cancel": false}},
	])
	snip_rleg.description = "使用攻击牌时，可立即移动到相邻的1个格子上。"
	effects[snip_rleg.effect_id] = snip_rleg

	# ═══════════════════════════════════════════
	# 027 狙击装·左腿：使用迎击牌时，可立即免费移动到相邻1格（free_move 不消耗动力，adjacent_only 仅相邻）
	# 诱发型 —— 监听 USE_ACTION_AT（使用迎击牌时）
	# ═══════════════════════════════════════════
	var snip_lleg := _ActionEffect.new()
	snip_lleg.effect_id = &"equipment_effect_027"
	snip_lleg.display_name = "狙击装·左腿·使用迎击牌移动1格"
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
	snip_lleg.set_actions([
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1, "free_move": true, "adjacent_only": true, "use_current_power": false, "loop_until_cancel": false}},
	])
	snip_lleg.description = "使用迎击牌时，可立即移动到相邻的1个格子上。"
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
	# 029 近战装·躯干：使用迎击牌时，当前回合护甲+2
	# 诱发型 —— 监听 USE_ACTION_AT（使用迎击牌时）
	# ═══════════════════════════════════════════
	var melee_torso := _ActionEffect.new()
	melee_torso.effect_id = &"equipment_effect_029"
	melee_torso.display_name = "近战装·躯干·使用迎击牌护甲+2"
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
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": 2, "method": &"add", "duration": &"THIS_TURN"}},
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 2, "method": &"add", "duration": &"THIS_TURN"}},
	])
	melee_torso.description = "使用迎击牌时，当前回合护甲+2，动力+2。"
	effects[melee_torso.effect_id] = melee_torso

	# ═══════════════════════════════════════════
	# 030 近战装·右臂 / 左臂：使用近战武器攻击时，可弃1行动牌，使威力+2
	# 诱发型 —— 监听 ATTACK_BEFORE，读 effective_weapon_type，priority 10（晚于028转换）
	# ═══════════════════════════════════════════
	var melee_arm := _ActionEffect.new()
	melee_arm.effect_id = &"equipment_effect_030"
	melee_arm.display_name = "近战装·臂·近战弃1牌威力+2"
	melee_arm.mode = _TC.MODE_LISTEN
	melee_arm.priority = 30  # 晚于 priority 20 的近战类型转换；与063/078臂效果统一为30，先于目标躯干效果
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
	melee_rleg.listen_action_type = &"discard_card"
	# 条件：弃置的牌是本牌，且从设置区域弃置，且原因是因损伤，且机甲其他区域有损伤可移除
	melee_rleg.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
		{"op": &"DISCARD_REASON_IS", "reason": &"damage_durability"},
		{"op": &"TARGET_HAS_DAMAGE"},
	])
	melee_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	melee_rleg.set_costs([])
	melee_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移除其他区域最多2损伤", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "value": 2, "method": &"decrease", "executor": "$binding_context.mech_id", "exclude_slot_id": "$binding_context.slot_id", "max_value": 2, "reason": &"equipment_leave_remove_damage"}}
			]}],
		},
	}])
	melee_rleg.description = "此牌因损伤而从区域中弃置时可移除机甲其他区域内最多2损伤。"
	effects[melee_rleg.effect_id] = melee_rleg

	# ═══════════════════════════════════════════
	# 032 机动装·右臂：使用迎击牌时，可弃置此牌，本回合动力+4
	# 诱发型 -- 监听 use_action_card.USE_ACTION_AT（迎击牌进入临时区时）
	# 与 effect_019 共享同一牌实例（part_027 effect_ids=[019,032]）；无每回合限次
	# 加动力发生在迎击牌效果执行前（USE_ACTION_AT 时点，迎击移动/反击尚未执行）
	# ═══════════════════════════════════════════
	var mob_rarm_counter := _ActionEffect.new()
	mob_rarm_counter.effect_id = &"equipment_effect_032"
	mob_rarm_counter.display_name = "机动装·右臂·使用迎击牌弃置动力+4"
	mob_rarm_counter.mode = _TC.MODE_LISTEN
	mob_rarm_counter.priority = 10
	mob_rarm_counter.listen_timing = _TC.USE_ACTION_AT
	mob_rarm_counter.listen_action_type = &"use_action_card"
	mob_rarm_counter.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
	])
	mob_rarm_counter.set_target_rules([{"rule": &"NO_TARGET"}])
	mob_rarm_counter.set_costs([])
	mob_rarm_counter.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃置机动装·右臂，本回合动力+4", "actions": [
				{"type": &"DISCARD_SELF_FROM_SLOT", "params": {"reason": &"effect_self_discard"}},
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 4, "method": &"add", "duration": &"THIS_TURN"}},
			]}],
		},
	}])
	mob_rarm_counter.description = "使用迎击牌时，可以弃置此牌，使机甲本回合动力+4。"
	effects[mob_rarm_counter.effect_id] = mob_rarm_counter

	# ═══════════════════════════════════════════
	# 033 精英装·头部/右腿/左腿：此牌设置到区域中时可以抽1张行动牌
	# 诱发型 -- 监听 set_equipment.SET_EQUIP_AFTER（_step_activate_equip 先注册 listener 再 fire）
	# 条件 SET_EQUIP_IS_SELF 只在本次设置的是本牌时触发（替换同名卡是新实例，分别触发）
	# ═══════════════════════════════════════════
	var elite_set_draw := _ActionEffect.new()
	elite_set_draw.effect_id = &"equipment_effect_033"
	elite_set_draw.display_name = "精英装·设置时抽1行动牌"
	elite_set_draw.mode = _TC.MODE_LISTEN
	elite_set_draw.priority = 10
	elite_set_draw.listen_timing = _TC.SET_EQUIP_AFTER
	elite_set_draw.listen_action_type = &"set_equipment"
	elite_set_draw.set_conditions([{"op": &"SET_EQUIP_IS_SELF"}])
	elite_set_draw.set_target_rules([{"rule": &"NO_TARGET"}])
	elite_set_draw.set_costs([])
	elite_set_draw.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "抽1张行动牌", "actions": [
				{"type": &"DRAW_ACTION", "params": {"count": 1, "player_id": "$binding_context.player_id"}},
			]}],
		},
	}])
	elite_set_draw.description = "此牌设置到区域中时可以抽1张行动牌。"
	effects[elite_set_draw.effect_id] = elite_set_draw

	# ═══════════════════════════════════════════
	# 034 精英装·躯干/右臂/左臂：此牌因损伤而从区域中弃置时可以抽2张行动牌
	# 诱发型 -- 监听 discard.DISCARD_AFTER（牌在 tmp_zone）；仅 damage_durability 原因触发
	# ═══════════════════════════════════════════
	var elite_discard_draw := _ActionEffect.new()
	elite_discard_draw.effect_id = &"equipment_effect_034"
	elite_discard_draw.display_name = "精英装·因损伤弃置抽2行动牌"
	elite_discard_draw.mode = _TC.MODE_LISTEN
	elite_discard_draw.priority = 10
	elite_discard_draw.listen_timing = _TC.DISCARD_AFTER
	elite_discard_draw.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
		{"op": &"DISCARD_REASON_IS", "reason": &"damage_durability"},
	])
	elite_discard_draw.set_target_rules([{"rule": &"NO_TARGET"}])
	elite_discard_draw.set_costs([])
	elite_discard_draw.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "抽2张行动牌", "actions": [
				{"type": &"DRAW_ACTION", "params": {"count": 2, "player_id": "$binding_context.player_id"}},
			]}],
		},
	}])
	elite_discard_draw.description = "此牌因损伤而从区域中弃置时可以抽2张行动牌。"
	effects[elite_discard_draw.effect_id] = elite_discard_draw

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

	# ═══════════════════════════════════════════
	# 035 联邦白马·躯干：使用迎击牌响应攻击时，可置1损伤在此牌上，之后该攻击威力-4
	# 诱发型 -- 监听 use_action_card.USE_ACTION_AT（迎击牌响应，payload.attack_action_id 绑定原攻击）
	# ═══════════════════════════════════════════
	var fed_wm_torso := _ActionEffect.new()
	fed_wm_torso.effect_id = &"equipment_effect_035"
	fed_wm_torso.display_name = "联邦白马·躯干·迎击置损伤减威力4"
	fed_wm_torso.mode = _TC.MODE_LISTEN
	fed_wm_torso.priority = 10
	fed_wm_torso.listen_timing = _TC.USE_ACTION_AT
	fed_wm_torso.listen_action_type = &"use_action_card"
	fed_wm_torso.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
		{"op": &"USED_ACTION_HAS_LINKED_ATTACK"},
	])
	fed_wm_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_wm_torso.set_costs([])
	# 可取消：确认后先置1损伤到此牌(fixed_slot 不开转移窗)，再减绑定攻击威力4。
	# MODIFY_ATTACK_MIGHT 在 use_action_card 上下文执行，经 payload.attack_action_id 定位原 attack。
	# Q3：若置1损伤致本牌弃置，减威力不执行（_source_equipment_discarded 守卫）。
	fed_wm_torso.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "置1损伤在此牌上，攻击威力-4", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 1, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -4}},
			]}],
		},
	}])
	fed_wm_torso.description = "使用迎击牌响应攻击时，可以设置1损伤在此牌上，之后使该攻击威力-4。"
	effects[fed_wm_torso.effect_id] = fed_wm_torso

	# ═══════════════════════════════════════════
	# 036 联邦白马·右臂：使用名称带光束的近战武器攻击时，威力+3
	# 诱发型 -- 监听 ATTACK_BEFORE，读 effective_weapon_type + WEAPON_NAME_CONTAINS
	# ═══════════════════════════════════════════
	var fed_wm_rarm := _ActionEffect.new()
	fed_wm_rarm.effect_id = &"equipment_effect_036"
	fed_wm_rarm.display_name = "联邦白马·右臂·光束近战威力+3"
	fed_wm_rarm.mode = _TC.MODE_LISTEN
	fed_wm_rarm.priority = 10
	fed_wm_rarm.listen_timing = _TC.ATTACK_BEFORE
	fed_wm_rarm.listen_action_type = &"attack"
	fed_wm_rarm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "光束"},
	])
	fed_wm_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_wm_rarm.set_costs([])
	fed_wm_rarm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	fed_wm_rarm.description = "使用名称带有光束的近战武器攻击时，威力+3。"
	effects[fed_wm_rarm.effect_id] = fed_wm_rarm

	# ═══════════════════════════════════════════
	# 037 联邦白马·左臂：使用名称带光束的远程武器攻击时，威力+3
	# ═══════════════════════════════════════════
	var fed_wm_larm := _ActionEffect.new()
	fed_wm_larm.effect_id = &"equipment_effect_037"
	fed_wm_larm.display_name = "联邦白马·左臂·光束远程威力+3"
	fed_wm_larm.mode = _TC.MODE_LISTEN
	fed_wm_larm.priority = 10
	fed_wm_larm.listen_timing = _TC.ATTACK_BEFORE
	fed_wm_larm.listen_action_type = &"attack"
	fed_wm_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "光束"},
	])
	fed_wm_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_wm_larm.set_costs([])
	fed_wm_larm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	fed_wm_larm.description = "使用名称带有光束的远程武器攻击时，威力+3。"
	effects[fed_wm_larm.effect_id] = fed_wm_larm

	# ═══════════════════════════════════════════
	# 038 联邦白马·右腿：机甲被指定为攻击目标时，可当前回合动力+3
	# 诱发型 -- 监听 ATTACK_PRE（仿 effect_006，value 2->3）
	# ═══════════════════════════════════════════
	var fed_wm_rleg := _ActionEffect.new()
	fed_wm_rleg.effect_id = &"equipment_effect_038"
	fed_wm_rleg.display_name = "联邦白马·右腿·被攻击目标时动力+3"
	fed_wm_rleg.mode = _TC.MODE_LISTEN
	fed_wm_rleg.priority = 10
	fed_wm_rleg.listen_timing = _TC.ATTACK_PRE
	fed_wm_rleg.listen_action_type = &"attack"
	fed_wm_rleg.set_conditions([{"op": &"SELF_MECH_IS_ATTACK_TARGET"}])
	fed_wm_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_wm_rleg.set_costs([])
	fed_wm_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "获得当前回合动力+3", "actions": [
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 3, "method": &"add", "duration": &"THIS_TURN"}}
			]}],
		},
	}])
	fed_wm_rleg.description = "机甲被指定为攻击目标时，可在当前回合动力+3。"
	effects[fed_wm_rleg.effect_id] = fed_wm_rleg

	# ═══════════════════════════════════════════
	# 039 联邦白马·左腿：被攻击命中时，可置2损伤在此牌上，之后最多减少3攻击损伤
	# 诱发型 -- 监听 ATTACK_AFTER（仿 effect_007，弃自身改 fixed_slot 置2损伤）
	# ═══════════════════════════════════════════
	var fed_wm_lleg := _ActionEffect.new()
	fed_wm_lleg.effect_id = &"equipment_effect_039"
	fed_wm_lleg.display_name = "联邦白马·左腿·被命中置2损伤减3攻击损伤"
	fed_wm_lleg.mode = _TC.MODE_LISTEN
	fed_wm_lleg.priority = 10
	fed_wm_lleg.listen_timing = _TC.ATTACK_AFTER
	fed_wm_lleg.listen_action_type = &"attack"
	fed_wm_lleg.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_HIT"},
		{"op": &"ATTACK_MARKERS_ABOVE", "threshold": 0},
	])
	fed_wm_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	fed_wm_lleg.set_costs([])
	# 可取消：确认后先置2损伤到此牌(fixed_slot)，再减攻击损伤3（MODIFY_ATTACK_MARKERS delta:-3，
	# 最终最低0，自动等效 min(3,损伤)）。Q3：若置2损伤致本牌弃置，减损伤不执行。
	fed_wm_lleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "置2损伤在此牌上，最多减少3攻击损伤", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 2, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -3}},
			]}],
		},
	}])
	fed_wm_lleg.description = "机甲被攻击命中时，可以设置2损伤在此牌上，之后可最多减少此次攻击产生的3损伤。"
	effects[fed_wm_lleg.effect_id] = fed_wm_lleg

	# ═══════════════════════════════════════════
	# 042 帝国赤枭·右臂：使用名称带热能的远程武器攻击时，威力+3
	# 诱发型 -- 监听 ATTACK_BEFORE（仿 effect_037 光束远程，substring=热能）
	# ═══════════════════════════════════════════
	var red_owl_rarm := _ActionEffect.new()
	red_owl_rarm.effect_id = &"equipment_effect_042"
	red_owl_rarm.display_name = "帝国赤枭·右臂·热能远程威力+3"
	red_owl_rarm.mode = _TC.MODE_LISTEN
	red_owl_rarm.priority = 10
	red_owl_rarm.listen_timing = _TC.ATTACK_BEFORE
	red_owl_rarm.listen_action_type = &"attack"
	red_owl_rarm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "热能"},
	])
	red_owl_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_rarm.set_costs([])
	red_owl_rarm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	red_owl_rarm.description = "使用名称带有热能的远程武器攻击时，威力+3。"
	effects[red_owl_rarm.effect_id] = red_owl_rarm

	# ═══════════════════════════════════════════
	# 043 帝国赤枭·左臂：使用名称带热能的近战武器攻击时，威力+3
	# ═══════════════════════════════════════════
	var red_owl_larm := _ActionEffect.new()
	red_owl_larm.effect_id = &"equipment_effect_043"
	red_owl_larm.display_name = "帝国赤枭·左臂·热能近战威力+3"
	red_owl_larm.mode = _TC.MODE_LISTEN
	red_owl_larm.priority = 10
	red_owl_larm.listen_timing = _TC.ATTACK_BEFORE
	red_owl_larm.listen_action_type = &"attack"
	red_owl_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "热能"},
	])
	red_owl_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_larm.set_costs([])
	red_owl_larm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	red_owl_larm.description = "使用名称带有热能的近战武器攻击时，威力+3。"
	effects[red_owl_larm.effect_id] = red_owl_larm

	# ═══════════════════════════════════════════
	# 044 帝国赤枭·右腿：每回合1次，累计消耗8动力后可回复2动力
	# 诱发型 -- 监听 BASIC_MOVE_AFTER（动力消耗走 spend_power 不发 STAT_MOD_SETTLE，仿 effect_012）
	# ═══════════════════════════════════════════
	var red_owl_rleg := _ActionEffect.new()
	red_owl_rleg.effect_id = &"equipment_effect_044"
	red_owl_rleg.display_name = "帝国赤枭·右腿·消耗8动力回复2"
	red_owl_rleg.mode = _TC.MODE_DIRECT
	red_owl_rleg.priority = 10
	red_owl_rleg.once_per_turn_key = &"equipment_effect_044"
	red_owl_rleg.set_conditions([
		{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8},
	])
	red_owl_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_rleg.set_costs([])
	red_owl_rleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
	])
	red_owl_rleg.description = "每回合1次，机甲在当前回合内消耗了8动力，可回复2动力。"
	effects[red_owl_rleg.effect_id] = red_owl_rleg

	# ═══════════════════════════════════════════
	# 045 帝国赤枭·左腿：每回合1次，累计消耗8动力后可回复1动力
	# ═══════════════════════════════════════════
	var red_owl_lleg := _ActionEffect.new()
	red_owl_lleg.effect_id = &"equipment_effect_045"
	red_owl_lleg.display_name = "帝国赤枭·左腿·消耗8动力回复1"
	red_owl_lleg.mode = _TC.MODE_DIRECT
	red_owl_lleg.priority = 10
	red_owl_lleg.once_per_turn_key = &"equipment_effect_045"
	red_owl_lleg.set_conditions([
		{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8},
	])
	red_owl_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_lleg.set_costs([])
	red_owl_lleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 1}},
	])
	red_owl_lleg.description = "每回合1次，机甲在当前回合内消耗了8动力，可回复1动力。"
	effects[red_owl_lleg.effect_id] = red_owl_lleg

	# ═══════════════════════════════════════════
	# 040 帝国赤枭·躯干：每回合1次，主阶段可弃置X张行动牌（X可0），本回合动力+2X
	# CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND：列出持有者全部行动牌供多选（全选/部分/全不选）。
	# 确认=弃置选中牌+每张+2本回合动力（选0张=弃0+0动力，仍消耗每回合1次）；取消=不发动不消耗。
	# 与 effect_041 共享 once_per_turn_key。per_card_actions 用原子 MODIFY_MECH_POWER（_resolve_atomic_params 解析 $binding_context）。
	# ═══════════════════════════════════════════
	var red_owl_torso_direct := _ActionEffect.new()
	red_owl_torso_direct.effect_id = &"equipment_effect_040"
	red_owl_torso_direct.display_name = "帝国赤枭·躯干·弃牌换动力(主阶段)"
	red_owl_torso_direct.mode = _TC.MODE_DIRECT
	red_owl_torso_direct.priority = 10
	red_owl_torso_direct.once_per_turn_key = &"red_owl_torso_card_power"
	red_owl_torso_direct.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	red_owl_torso_direct.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_torso_direct.set_costs([])
	red_owl_torso_direct.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 0,
			"max_count": 0,
			"discard_selected": true,
			"discard_reason": &"effect_discard",
			"label": "选择要弃置的行动牌（每张+2本回合动力）",
			"confirm_verb": "弃置",
			"cancel_label": "不弃置",
			"per_card_actions": [
				{"type": &"MODIFY_MECH_POWER", "params": {"mech_id": "$binding_context.mech_id", "delta": 2, "duration": &"THIS_TURN"}},
			],
		},
	}])
	red_owl_torso_direct.description = "每回合1次，可以弃置X数量的行动牌（X最低为1），当前回合动力+2倍X。"
	effects[red_owl_torso_direct.effect_id] = red_owl_torso_direct

	# ═══════════════════════════════════════════
	# 041 帝国赤枭·躯干：使用迎击牌时可弃置X张行动牌本回合动力+2X（与040共享once）
	# LISTEN USE_ACTION_AT，CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND。与主阶段共享每回合1次。
	# ═══════════════════════════════════════════
	var red_owl_torso_counter := _ActionEffect.new()
	red_owl_torso_counter.effect_id = &"equipment_effect_041"
	red_owl_torso_counter.display_name = "帝国赤枭·躯干·弃牌换动力(迎击)"
	red_owl_torso_counter.mode = _TC.MODE_LISTEN
	red_owl_torso_counter.priority = 10
	red_owl_torso_counter.listen_timing = _TC.USE_ACTION_AT
	red_owl_torso_counter.listen_action_type = &"use_action_card"
	red_owl_torso_counter.once_per_turn_key = &"red_owl_torso_card_power"
	red_owl_torso_counter.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	red_owl_torso_counter.set_target_rules([{"rule": &"NO_TARGET"}])
	red_owl_torso_counter.set_costs([])
	red_owl_torso_counter.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 0,
			"max_count": 0,
			"discard_selected": true,
			"discard_reason": &"effect_discard",
			"label": "选择要弃置的行动牌（每张+2本回合动力）",
			"confirm_verb": "弃置",
			"cancel_label": "不弃置",
			"per_card_actions": [
				{"type": &"MODIFY_MECH_POWER", "params": {"mech_id": "$binding_context.mech_id", "delta": 2, "duration": &"THIS_TURN"}},
			],
		},
	}])
	red_owl_torso_counter.description = "使用迎击牌时，可弃置X张行动牌当前回合动力+2X（与主阶段共享每回合1次）。"
	effects[red_owl_torso_counter.effect_id] = red_owl_torso_counter

	# ═══════════════════════════════════════════
	# 046 超重甲·头部：总损伤<4免疫（派生值，card_damage_immune_armor_amount 扩展）
	# ═══════════════════════════════════════════
	var heavy_head_total4 := _ActionEffect.new()
	heavy_head_total4.effect_id = &"equipment_effect_046"
	heavy_head_total4.display_name = "超重甲·头部·总损伤<4免疫"
	heavy_head_total4.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_head_total4.priority = 10
	heavy_head_total4.set_conditions([{"op": &"ALWAYS"}])
	heavy_head_total4.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_head_total4.set_costs([])
	heavy_head_total4.set_actions([])
	heavy_head_total4.description = "损伤不会影响机甲区域提供的护甲，除非机甲部件装备区域总损伤数≥4（实时重算）。"
	effects[heavy_head_total4.effect_id] = heavy_head_total4

	# ═══════════════════════════════════════════
	# 047 超重甲·躯干：被指定为攻击目标时，可弃2行动牌，当前回合护甲+5
	# 诱发型 -- 监听 ATTACK_PRE，弃2牌成本 + 临时护甲（仿 effect_015，value 4->5）
	# ═══════════════════════════════════════════
	var heavy_torso5 := _ActionEffect.new()
	heavy_torso5.effect_id = &"equipment_effect_047"
	heavy_torso5.display_name = "超重甲·躯干·被攻击弃2牌护甲+5"
	heavy_torso5.mode = _TC.MODE_LISTEN
	heavy_torso5.priority = 10
	heavy_torso5.listen_timing = _TC.ATTACK_PRE
	heavy_torso5.listen_action_type = &"attack"
	heavy_torso5.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	heavy_torso5.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_torso5.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	heavy_torso5.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
	])
	heavy_torso5.description = "机甲被指定为攻击目标时，可弃置2张行动牌，当前回合护甲+5。"
	effects[heavy_torso5.effect_id] = heavy_torso5

	# ═══════════════════════════════════════════
	# 048 超重甲·右臂：此牌损伤≥2时动力+2（派生值，slot_damage_threshold_power_bonus 扩展）
	# ═══════════════════════════════════════════
	var heavy_rarm2 := _ActionEffect.new()
	heavy_rarm2.effect_id = &"equipment_effect_048"
	heavy_rarm2.display_name = "超重甲·右臂·损伤≥2动力+2"
	heavy_rarm2.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_rarm2.priority = 10
	heavy_rarm2.set_conditions([{"op": &"ALWAYS"}])
	heavy_rarm2.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_rarm2.set_costs([])
	heavy_rarm2.set_actions([])
	heavy_rarm2.description = "此牌上设置有损伤≥2时，动力+2（实时重算）。"
	effects[heavy_rarm2.effect_id] = heavy_rarm2

	# ═══════════════════════════════════════════
	# 092 轰雷装·右臂：此牌上设置有损伤≥2时，此牌动力+3（派生值，仿 effect_048 但 +3）
	# 轰雷右臂原 effect_ids=[048,019,032]（+2 + 主动弃牌+4 + 迎击弃牌+4），用户裁定改为仅 +3，
	# 去除"弃置此牌加动力"效果。effect_048（超重甲右臂）仍为 +2，故另立 effect_092。
	# ═══════════════════════════════════════════
	var thunder_rarm := _ActionEffect.new()
	thunder_rarm.effect_id = &"equipment_effect_092"
	thunder_rarm.display_name = "轰雷装·右臂·损伤≥2动力+3"
	thunder_rarm.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	thunder_rarm.priority = 10
	thunder_rarm.set_conditions([{"op": &"ALWAYS"}])
	thunder_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	thunder_rarm.set_costs([])
	thunder_rarm.set_actions([])
	thunder_rarm.description = "此牌上设置有损伤≥2时，动力+3（实时重算）。"
	effects[thunder_rarm.effect_id] = thunder_rarm

	# ═══════════════════════════════════════════
	# 049 超重甲·臂/腿：此牌损伤<2免疫，≥2才扣甲（派生值，card_damage_immune_armor_amount 扩展）
	# ═══════════════════════════════════════════
	var heavy_limb_immune2 := _ActionEffect.new()
	heavy_limb_immune2.effect_id = &"equipment_effect_049"
	heavy_limb_immune2.display_name = "超重甲·臂腿·此牌损伤<2免疫"
	heavy_limb_immune2.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_limb_immune2.priority = 10
	heavy_limb_immune2.set_conditions([{"op": &"ALWAYS"}])
	heavy_limb_immune2.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_limb_immune2.set_costs([])
	heavy_limb_immune2.set_actions([])
	heavy_limb_immune2.description = "损伤不会影响此牌所在区域提供的护甲，除非此牌上设置的损伤≥2（实时重算）。"
	effects[heavy_limb_immune2.effect_id] = heavy_limb_immune2

	# ═══════════════════════════════════════════
	# 089 重甲装·头部：损伤不影响护甲，除非机甲部件装备区域总损伤数≥3
	# 派生值实时重算型 -- 由 MechSlotState.get_effective_armor 调用 card_damage_immune_armor_amount
	# （总损伤<3时免疫；≥3时损伤正常减护甲。与 effect_014 无条件免疫区分）
	# ═══════════════════════════════════════════
	var heavy_head_total := _ActionEffect.new()
	heavy_head_total.effect_id = &"equipment_effect_089"
	heavy_head_total.display_name = "重甲装·头部·总损伤<3免疫"
	heavy_head_total.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	heavy_head_total.priority = 10
	heavy_head_total.set_conditions([{"op": &"ALWAYS"}])
	heavy_head_total.set_target_rules([{"rule": &"NO_TARGET"}])
	heavy_head_total.set_costs([])
	heavy_head_total.set_actions([])
	heavy_head_total.description = "损伤不会影响机甲区域提供的护甲，除非机甲部件装备区域总损伤数≥3（实时重算）。"
	effects[heavy_head_total.effect_id] = heavy_head_total

	# ═══════════════════════════════════════════
	# 050 高机动装·头部：每回合1次，消耗动力后若动力为0，可回复3动力并用当前动力移动
	# 诱发型：监听 basic_move.BASIC_MOVE_AFTER（仿 effect_017；spend_power 不发 STAT_MOD_SETTLE）
	# ═══════════════════════════════════════════
	var hm_head := _ActionEffect.new()
	hm_head.effect_id = &"equipment_effect_050"
	hm_head.display_name = "高机动装·头部·耗尽动力回复3并移动"
	hm_head.mode = _TC.MODE_LISTEN
	hm_head.priority = 10
	hm_head.listen_timing = _TC.BASIC_MOVE_AFTER
	hm_head.listen_action_type = &"basic_move"
	hm_head.once_per_turn_key = &"equipment_effect_050"
	hm_head.once_per_turn_max = 1
	hm_head.set_conditions([
		{"op": &"SELF_MECH_IS_MOVE_SUBJECT"},
		{"op": &"OWNER_POWER_EQUALS", "value": 0},
	])
	hm_head.set_target_rules([{"rule": &"NO_TARGET"}])
	hm_head.set_costs([])
	hm_head.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复3动力并用当前动力移动", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 3}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
			]}],
		},
	}])
	hm_head.description = "每回合1次，消耗动力后若没有动力剩余，可回复3动力并用当前动力移动。"
	effects[hm_head.effect_id] = hm_head

	# ═══════════════════════════════════════════
	# 051 高机动装·躯干：被指定为攻击目标时，可弃2行动牌，当前回合动力+6
	# 诱发型 -- 监听 ATTACK_PRE（仿 effect_018，value 5->6）
	# ═══════════════════════════════════════════
	var hm_torso := _ActionEffect.new()
	hm_torso.effect_id = &"equipment_effect_051"
	hm_torso.display_name = "高机动装·躯干·被攻击弃2牌动力+6"
	hm_torso.mode = _TC.MODE_LISTEN
	hm_torso.priority = 10
	hm_torso.listen_timing = _TC.ATTACK_PRE
	hm_torso.listen_action_type = &"attack"
	hm_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	hm_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	hm_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	hm_torso.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 6, "method": &"add", "duration": &"THIS_TURN"}},
	])
	hm_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合动力+6。"
	effects[hm_torso.effect_id] = hm_torso

	# ═══════════════════════════════════════════
	# 052 高机动装·右臂：我方主阶段可弃置此牌，本回合动力+5（DIRECT 主动）
	# "使用迎击牌时"路径由 effect_053 处理；二者共享同一牌实例
	# ═══════════════════════════════════════════
	var hm_rarm := _ActionEffect.new()
	hm_rarm.effect_id = &"equipment_effect_052"
	hm_rarm.display_name = "高机动装·右臂·弃置动力+5(主动)"
	hm_rarm.mode = _TC.MODE_DIRECT
	hm_rarm.priority = 10
	hm_rarm.set_conditions([
		{"op": &"IS_OWNER_TURN"},
	])
	hm_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	hm_rarm.set_costs([])
	hm_rarm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃置此牌，本回合动力+5", "actions": [
				{"type": &"DISCARD_SELF_FROM_SLOT", "params": {"reason": &"effect_self_discard"}},
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
			]}],
		},
	}])
	hm_rarm.description = "我方回合或使用迎击牌时，可以弃置此牌，使机甲本回合动力+5。"
	effects[hm_rarm.effect_id] = hm_rarm

	# ═══════════════════════════════════════════
	# 053 高机动装·右臂：使用迎击牌时，可弃置此牌，本回合动力+5
	# 诱发型 -- 监听 use_action_card.USE_ACTION_AT（仿 effect_032，value 4->5）
	# ═══════════════════════════════════════════
	var hm_rarm_counter := _ActionEffect.new()
	hm_rarm_counter.effect_id = &"equipment_effect_053"
	hm_rarm_counter.display_name = "高机动装·右臂·使用迎击牌弃置动力+5"
	hm_rarm_counter.mode = _TC.MODE_LISTEN
	hm_rarm_counter.priority = 10
	hm_rarm_counter.listen_timing = _TC.USE_ACTION_AT
	hm_rarm_counter.listen_action_type = &"use_action_card"
	hm_rarm_counter.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
	])
	hm_rarm_counter.set_target_rules([{"rule": &"NO_TARGET"}])
	hm_rarm_counter.set_costs([])
	hm_rarm_counter.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "弃置高机动装·右臂，本回合动力+5", "actions": [
				{"type": &"DISCARD_SELF_FROM_SLOT", "params": {"reason": &"effect_self_discard"}},
				{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
			]}],
		},
	}])
	hm_rarm_counter.description = "使用迎击牌时，可以弃置此牌，使机甲本回合动力+5。"
	effects[hm_rarm_counter.effect_id] = hm_rarm_counter

	# ═══════════════════════════════════════════
	# 054 高机动装·左臂：机甲发动的攻击命中后，回复4动力
	# 诱发型 -- 监听 ATTACK_AFTER（仿 effect_020，amount 3->4）
	# ═══════════════════════════════════════════
	var hm_larm := _ActionEffect.new()
	hm_larm.effect_id = &"equipment_effect_054"
	hm_larm.display_name = "高机动装·左臂·攻击命中后回复4动力"
	hm_larm.mode = _TC.MODE_LISTEN
	hm_larm.priority = 10
	hm_larm.listen_timing = _TC.ATTACK_AFTER
	hm_larm.listen_action_type = &"attack"
	hm_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
	])
	hm_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	hm_larm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 4, "mech_id": "$binding_context.mech_id"}},
	])
	hm_larm.description = "机甲发动的攻击命中后，回复4动力。"
	effects[hm_larm.effect_id] = hm_larm

	# ═══════════════════════════════════════════
	# 055 狙击影装·头部：我方远程武器攻击范围+2（仿 effect_022，delta 1->2）
	# 派生值实时重算型 -- 不注册监听器，由 get_passive_weapon_range_bonus 实时重算
	# ═══════════════════════════════════════════
	var snipshadow_head := _ActionEffect.new()
	snipshadow_head.effect_id = &"equipment_effect_055"
	snipshadow_head.display_name = "狙击影装·头部·远程武器范围+2"
	snipshadow_head.mode = _TC.MODE_DIRECT  # 占位模式，实际不注册监听（实时重算）
	snipshadow_head.priority = 10
	snipshadow_head.set_conditions([{"op": &"ALWAYS"}])
	snipshadow_head.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_head.set_costs([])
	snipshadow_head.set_actions([])
	snipshadow_head.description = "我方远程武器攻击范围+2。"
	effects[snipshadow_head.effect_id] = snipshadow_head

	# ═══════════════════════════════════════════
	# 056 狙击影装·躯干/王牌装·头腿：此牌从区域中弃置时可获得2金币
	# 诱发型 -- 监听 DISCARD_AFTER（任意从设置区域弃置原因均触发）
	# ═══════════════════════════════════════════
	var snipshadow_leave_gold := _ActionEffect.new()
	snipshadow_leave_gold.effect_id = &"equipment_effect_056"
	snipshadow_leave_gold.display_name = "狙击影装·躯干·离场获2金币"
	snipshadow_leave_gold.mode = _TC.MODE_LISTEN
	snipshadow_leave_gold.priority = 10
	snipshadow_leave_gold.listen_timing = _TC.DISCARD_AFTER
	snipshadow_leave_gold.listen_action_type = &"discard_card"
	snipshadow_leave_gold.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
	])
	snipshadow_leave_gold.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_leave_gold.set_costs([])
	snipshadow_leave_gold.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "获得2金币", "actions": [
				{"type": &"GAIN_GOLD", "params": {"amount": 2, "player_id": "$binding_context.player_id"}},
			]}],
		},
	}])
	snipshadow_leave_gold.description = "此牌从区域中弃置时可获得2金币。"
	effects[snipshadow_leave_gold.effect_id] = snipshadow_leave_gold

	# ═══════════════════════════════════════════
	# 057 狙击影装·右臂：我方回合1次，可弃1行动牌，回复3动力（仿 effect_024，amount 2->3）
	# DIRECT 主动效果；optional 弃牌 -> 弹选牌框让玩家自选弃哪张
	# ═══════════════════════════════════════════
	var snipshadow_rarm := _ActionEffect.new()
	snipshadow_rarm.effect_id = &"equipment_effect_057"
	snipshadow_rarm.display_name = "狙击影装·右臂·弃1牌回复3动力"
	snipshadow_rarm.mode = _TC.MODE_DIRECT
	snipshadow_rarm.priority = 10
	snipshadow_rarm.once_per_turn_key = &"equipment_effect_057"
	snipshadow_rarm.once_per_turn_max = 1
	snipshadow_rarm.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	snipshadow_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_rarm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	snipshadow_rarm.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 3}},
	])
	snipshadow_rarm.description = "我方回合1次，可以弃置1张行动牌，回复3动力。"
	effects[snipshadow_rarm.effect_id] = snipshadow_rarm

	# ═══════════════════════════════════════════
	# 058 狙击影装·左臂：使用远程武器攻击时，可弃1行动牌，使威力+3（仿 effect_025，delta 2->3）
	# 诱发型 -- 监听 ATTACK_BEFORE
	# ═══════════════════════════════════════════
	var snipshadow_larm := _ActionEffect.new()
	snipshadow_larm.effect_id = &"equipment_effect_058"
	snipshadow_larm.display_name = "狙击影装·左臂·远程弃1牌威力+3"
	snipshadow_larm.mode = _TC.MODE_LISTEN
	snipshadow_larm.priority = 10
	snipshadow_larm.listen_timing = _TC.ATTACK_BEFORE
	snipshadow_larm.listen_action_type = &"attack"
	snipshadow_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	snipshadow_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_larm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	snipshadow_larm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	snipshadow_larm.description = "使用远程武器发动攻击时，可以弃置1张行动牌，使威力+3。"
	effects[snipshadow_larm.effect_id] = snipshadow_larm

	# ═══════════════════════════════════════════
	# 059 狙击影装·右腿：使用攻击牌时，立即回复2动力，之后可移动到相邻1格（移动消耗正常动力）
	# 诱发型 -- 监听 USE_ACTION_AT（使用攻击牌时）；回复强制，移动可取消
	# ═══════════════════════════════════════════
	var snipshadow_rleg := _ActionEffect.new()
	snipshadow_rleg.effect_id = &"equipment_effect_059"
	snipshadow_rleg.display_name = "狙击影装·右腿·使用攻击牌回复2并移动1格"
	snipshadow_rleg.mode = _TC.MODE_LISTEN
	snipshadow_rleg.priority = 10
	snipshadow_rleg.listen_timing = _TC.USE_ACTION_AT
	snipshadow_rleg.listen_action_type = &"use_action_card"
	snipshadow_rleg.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_CARD_TYPE_IS", "card_type": "攻击"},
	])
	snipshadow_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_rleg.set_costs([])
	snipshadow_rleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1, "use_current_power": true, "loop_until_cancel": false}},
	])
	snipshadow_rleg.description = "使用攻击牌时，立即回复2动力，之后可立即移动到相邻的1个格子上。"
	effects[snipshadow_rleg.effect_id] = snipshadow_rleg

	# ═══════════════════════════════════════════
	# 060 狙击影装·左腿：使用迎击牌时，立即回复2动力，之后可移动到相邻1格（移动消耗正常动力）
	# 诱发型 -- 监听 USE_ACTION_AT（使用迎击牌时）
	# ═══════════════════════════════════════════
	var snipshadow_lleg := _ActionEffect.new()
	snipshadow_lleg.effect_id = &"equipment_effect_060"
	snipshadow_lleg.display_name = "狙击影装·左腿·使用迎击牌回复2并移动1格"
	snipshadow_lleg.mode = _TC.MODE_LISTEN
	snipshadow_lleg.priority = 10
	snipshadow_lleg.listen_timing = _TC.USE_ACTION_AT
	snipshadow_lleg.listen_action_type = &"use_action_card"
	snipshadow_lleg.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
	])
	snipshadow_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	snipshadow_lleg.set_costs([])
	snipshadow_lleg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 1, "use_current_power": true, "loop_until_cancel": false}},
	])
	snipshadow_lleg.description = "使用迎击牌时，立即回复2动力，之后可立即移动到相邻的1个格子上。"
	effects[snipshadow_lleg.effect_id] = snipshadow_lleg

	# ═══════════════════════════════════════════
	# 061 近战特装·头部：范围-2(最低1)+威力+4+转近战（不适用于近战武器）
	# 类型转换型 -- 监听 ATTACK_BEFORE，priority 20（仿 effect_028，might 3->4）
	# ═══════════════════════════════════════════
	var meleesp_head := _ActionEffect.new()
	meleesp_head.effect_id = &"equipment_effect_061"
	meleesp_head.display_name = "近战特装·头部·非近战转近战范围-2威力+4"
	meleesp_head.mode = _TC.MODE_LISTEN
	meleesp_head.priority = 20
	meleesp_head.listen_timing = _TC.ATTACK_BEFORE
	meleesp_head.listen_action_type = &"attack"
	meleesp_head.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT", "weapon_kind": &"近战"},
	])
	meleesp_head.set_target_rules([{"rule": &"NO_TARGET"}])
	meleesp_head.set_costs([])
	meleesp_head.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "范围-2(最低1)+威力+4+转近战", "actions": [
				{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min_value": 1}},
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 4}},
				{"type": &"SET_ATTACK_EFFECTIVE_WEAPON_KIND", "params": {"weapon_kind": &"近战"}},
			]}],
		},
	}])
	meleesp_head.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器(不适用于近战武器)。"
	effects[meleesp_head.effect_id] = meleesp_head

	# ═══════════════════════════════════════════
	# 062 近战特装·躯干：使用迎击牌时，当前回合护甲+3，动力+3（仿 effect_029，2->3）
	# 诱发型 -- 监听 USE_ACTION_AT
	# ═══════════════════════════════════════════
	var meleesp_torso := _ActionEffect.new()
	meleesp_torso.effect_id = &"equipment_effect_062"
	meleesp_torso.display_name = "近战特装·躯干·使用迎击牌护甲+3动力+3"
	meleesp_torso.mode = _TC.MODE_LISTEN
	meleesp_torso.priority = 10
	meleesp_torso.listen_timing = _TC.USE_ACTION_AT
	meleesp_torso.listen_action_type = &"use_action_card"
	meleesp_torso.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
	])
	meleesp_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	meleesp_torso.set_costs([])
	meleesp_torso.set_actions([
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": 3, "method": &"add", "duration": &"THIS_TURN"}},
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"power", "value": 3, "method": &"add", "duration": &"THIS_TURN"}},
	])
	meleesp_torso.description = "使用迎击牌时，当前回合护甲+3，动力+3。"
	effects[meleesp_torso.effect_id] = meleesp_torso

	# ═══════════════════════════════════════════
	# 063 近战特装·臂：近战攻击弃1牌威力+2，之后选目标区域最多1张装备效果无效至本回合结束
	# 诱发型 -- 监听 ATTACK_PRE；CHOOSE_MANY_CARDS source=ATTACK_TARGET_EQUIPMENT + NEGATE_EQUIPMENT_EFFECT
	# ═══════════════════════════════════════════
	var meleesp_arm := _ActionEffect.new()
	meleesp_arm.effect_id = &"equipment_effect_063"
	meleesp_arm.display_name = "近战特装·臂·近战弃1牌威力+2并无效目标装备"
	meleesp_arm.mode = _TC.MODE_LISTEN
	meleesp_arm.priority = 30  # 先于目标躯干效果(ATTACK_PRE)：无效目标装备须先于躯干效果触发
	meleesp_arm.listen_timing = _TC.ATTACK_PRE
	meleesp_arm.listen_action_type = &"attack"
	meleesp_arm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	meleesp_arm.set_target_rules([{"rule": &"NO_TARGET"}])
	meleesp_arm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	meleesp_arm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 2}},
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"ATTACK_TARGET_EQUIPMENT",
				"max_count": 1,
				"min_count": 0,
				"discard_selected": false,
				"label": "选择至多1张装备，使其效果无效至本回合结束",
				"confirm_verb": "无效",
				"cancel_label": "不选择",
				"per_card_actions": [
					{"type": &"NEGATE_EQUIPMENT_EFFECT", "params": {"target_card_id": "$chosen_card.card_instance_id", "duration": "UNTIL_TURN_END"}}
				],
			},
		},
	])
	meleesp_arm.description = "使用近战武器发动攻击时，可以弃置1张行动牌，使威力+2，之后可以选择攻击目标区域最多1张牌效果无效直到本回合结束。"
	effects[meleesp_arm.effect_id] = meleesp_arm

	# ═══════════════════════════════════════════
	# 064 近战特装·右腿：此牌从区域中弃置时回复3动力并用当前动力移动
	# 诱发型 -- 监听 DISCARD_AFTER（任意从设置区域弃置原因均触发）
	# ═══════════════════════════════════════════
	var meleesp_rleg := _ActionEffect.new()
	meleesp_rleg.effect_id = &"equipment_effect_064"
	meleesp_rleg.display_name = "近战特装·右腿·离场回复3并移动"
	meleesp_rleg.mode = _TC.MODE_LISTEN
	meleesp_rleg.priority = 10
	meleesp_rleg.listen_timing = _TC.DISCARD_AFTER
	meleesp_rleg.listen_action_type = &"discard_card"
	meleesp_rleg.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
	])
	meleesp_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	meleesp_rleg.set_costs([])
	meleesp_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "回复3动力并用当前所有动力移动", "actions": [
				{"type": &"RESTORE_POWER", "params": {"amount": 3}},
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"use_current_power": true, "loop_until_cancel": true}},
			]}],
		},
	}])
	meleesp_rleg.description = "此牌从区域中弃置时可使机甲回复3动力，之后可以用当前所有动力进行移动。"
	effects[meleesp_rleg.effect_id] = meleesp_rleg

	# ═══════════════════════════════════════════
	# 065 王牌装·臂：此牌因损伤而从区域中弃置时，可抽1装备牌立即设置或卖出
	# 诱发型 -- 监听 DISCARD_AFTER + DISCARD_REASON_IS damage_durability
	# 新复杂交互 DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL（仿 DRAW_EQUIPMENT_AND_IMMEDIATELY_SET 加卖出分支）
	# ═══════════════════════════════════════════
	var ace_arm_damage_draw := _ActionEffect.new()
	ace_arm_damage_draw.effect_id = &"equipment_effect_065"
	ace_arm_damage_draw.display_name = "王牌装·臂·损伤弃置抽装备设置或卖出"
	ace_arm_damage_draw.mode = _TC.MODE_LISTEN
	ace_arm_damage_draw.priority = 10
	ace_arm_damage_draw.listen_timing = _TC.DISCARD_AFTER
	ace_arm_damage_draw.listen_action_type = &"discard_card"
	ace_arm_damage_draw.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
		{"op": &"DISCARD_REASON_IS", "reason": &"damage_durability"},
	])
	ace_arm_damage_draw.set_target_rules([{"rule": &"NO_TARGET"}])
	ace_arm_damage_draw.set_costs([])
	ace_arm_damage_draw.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "抽1张装备牌，立即设置或卖出", "actions": [
				{"type": &"DRAW_EQUIPMENT_AND_CHOOSE_SET_OR_SELL", "params": {"target_id": "$binding_context.mech_id", "count": 1, "sell_uses_turn_limit": true}},
			]}],
		},
	}])
	ace_arm_damage_draw.description = "此牌因损伤而从区域中弃置时可以抽1张装备牌，立即设置或者卖出。"
	effects[ace_arm_damage_draw.effect_id] = ace_arm_damage_draw

	# ═══════════════════════════════════════════
	# 066 联邦的圣牛·头部：机甲每设置1张名称带联邦的装备牌(含自身)则此牌护甲+1
	# 派生值实时重算型 -- 由 compute_head_faction_armor_bonus 判定（含自身）
	# ═══════════════════════════════════════════
	var holyox_head := _ActionEffect.new()
	holyox_head.effect_id = &"equipment_effect_066"
	holyox_head.display_name = "联邦的圣牛·头部·每联邦装备护甲+1(含自身)"
	holyox_head.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	holyox_head.priority = 10
	holyox_head.set_conditions([{"op": &"ALWAYS"}])
	holyox_head.set_target_rules([{"rule": &"NO_TARGET"}])
	holyox_head.set_costs([])
	holyox_head.set_actions([])
	holyox_head.description = "机甲每设置有1张名称带有联邦的装备牌则此牌护甲+1。"
	effects[holyox_head.effect_id] = holyox_head

	# ═══════════════════════════════════════════
	# 067 联邦的圣牛·躯干：被指定为攻击目标时，可弃2行动牌，使该攻击威力-4
	# 诱发型 -- 监听 ATTACK_PRE（仿 effect_023 但成本是弃2牌且本牌不离场）
	# ═══════════════════════════════════════════
	var holyox_torso := _ActionEffect.new()
	holyox_torso.effect_id = &"equipment_effect_067"
	holyox_torso.display_name = "联邦的圣牛·躯干·被攻击弃2牌威力-4"
	holyox_torso.mode = _TC.MODE_LISTEN
	holyox_torso.priority = 10
	holyox_torso.listen_timing = _TC.ATTACK_PRE
	holyox_torso.listen_action_type = &"attack"
	holyox_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	holyox_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	holyox_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	holyox_torso.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -4}},
	])
	holyox_torso.description = "机甲被指定为攻击目标时，可以弃置2张行动牌，使该攻击威力-4。"
	effects[holyox_torso.effect_id] = holyox_torso

	# ═══════════════════════════════════════════
	# 068 联邦的圣牛·臂：使用名称带光束的武器攻击时，可弃1行动牌，使威力+3
	# 诱发型 -- 监听 ATTACK_BEFORE（仿 effect_036/037，substring=光束，无类型限制）
	# ═══════════════════════════════════════════
	var holyox_arm := _ActionEffect.new()
	holyox_arm.effect_id = &"equipment_effect_068"
	holyox_arm.display_name = "联邦的圣牛·臂·光束弃1牌威力+3"
	holyox_arm.mode = _TC.MODE_LISTEN
	holyox_arm.priority = 10
	holyox_arm.listen_timing = _TC.ATTACK_BEFORE
	holyox_arm.listen_action_type = &"attack"
	holyox_arm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "光束"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	holyox_arm.set_target_rules([{"rule": &"NO_TARGET"}])
	holyox_arm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	holyox_arm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	holyox_arm.description = "使用名称带有光束的武器攻击时，可以弃置1张行动牌，使威力+3。"
	effects[holyox_arm.effect_id] = holyox_arm

	# ═══════════════════════════════════════════
	# 069 联邦的圣牛·右腿：每我方回合1次，可弃1行动牌，之后抽1行动牌或回复2动力
	# DIRECT 主动效果；CHOOSE_ONE 二选一（不可取消，避免已付成本后无收益）
	# ═══════════════════════════════════════════
	var holyox_rleg := _ActionEffect.new()
	holyox_rleg.effect_id = &"equipment_effect_069"
	holyox_rleg.display_name = "联邦的圣牛·右腿·弃1牌抽1或回复2"
	holyox_rleg.mode = _TC.MODE_DIRECT
	holyox_rleg.priority = 10
	holyox_rleg.once_per_turn_key = &"equipment_effect_069"
	holyox_rleg.once_per_turn_max = 1
	holyox_rleg.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"HAS_ACTION_CARD_IN_HAND"},
	])
	holyox_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	holyox_rleg.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	holyox_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": false,
			"options": [
				{"label": "抽1张行动牌", "actions": [
					{"type": &"DRAW_ACTION", "params": {"count": 1, "player_id": "$binding_context.player_id"}},
				]},
				{"label": "回复2动力", "actions": [
					{"type": &"RESTORE_POWER", "params": {"amount": 2}},
				]},
			],
		},
	}])
	holyox_rleg.description = "我方回合1次，可以弃置1张行动牌，之后抽1张行动牌或回复2动力。"
	effects[holyox_rleg.effect_id] = holyox_rleg

	# ═══════════════════════════════════════════
	# 070 帝国的雄鹰·头部：机甲每设置1张名称带帝国的装备牌(含自身)则此牌动力+1
	# 派生值实时重算型 -- 由 compute_head_faction_power_bonus 判定（含自身）
	# ═══════════════════════════════════════════
	var eagle_head := _ActionEffect.new()
	eagle_head.effect_id = &"equipment_effect_070"
	eagle_head.display_name = "帝国雄鹰·头部·每帝国装备动力+1(含自身)"
	eagle_head.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	eagle_head.priority = 10
	eagle_head.set_conditions([{"op": &"ALWAYS"}])
	eagle_head.set_target_rules([{"rule": &"NO_TARGET"}])
	eagle_head.set_costs([])
	eagle_head.set_actions([])
	eagle_head.description = "机甲每设置有1张名称带有帝国的装备牌则此牌动力+1。"
	effects[eagle_head.effect_id] = eagle_head

	# ═══════════════════════════════════════════
	# 071 帝国的雄鹰·躯干：每回合1次，主阶段可弃置X张行动牌移动X格(无视动力)（DIRECT）
	# CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND：多选弃牌，post_actions 按弃牌数($choice.count)免费移动。
	# 确认=弃置选中牌+移动等量格（选0张=弃0+不移动，仍消耗每回合1次）；取消=不发动不消耗。与072共享once。
	# ═══════════════════════════════════════════
	var eagle_torso_direct := _ActionEffect.new()
	eagle_torso_direct.effect_id = &"equipment_effect_071"
	eagle_torso_direct.display_name = "帝国雄鹰·躯干·弃牌换移动(主阶段)"
	eagle_torso_direct.mode = _TC.MODE_DIRECT
	eagle_torso_direct.priority = 10
	eagle_torso_direct.once_per_turn_key = &"eagle_torso_card_move"
	eagle_torso_direct.once_per_turn_max = 1
	eagle_torso_direct.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	eagle_torso_direct.set_target_rules([{"rule": &"NO_TARGET"}])
	eagle_torso_direct.set_costs([])
	eagle_torso_direct.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 0,
			"max_count": 0,
			"discard_selected": true,
			"discard_reason": &"effect_discard",
			"label": "选择要弃置的行动牌（每张弃置可无视动力移动1格）",
			"confirm_verb": "弃置并移动",
			"cancel_label": "不弃置",
			"per_card_actions": [],
			"post_actions": [
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"mech_id": "$binding_context.mech_id", "max_cells_expr": "$choice.count", "free_move": true, "loop_until_cancel": false}},
			],
		},
	}])
	eagle_torso_direct.description = "每回合1次，可以弃置n数量的行动牌(n为整数)，之后移动n个格子(无视动力)。"
	effects[eagle_torso_direct.effect_id] = eagle_torso_direct

	# ═══════════════════════════════════════════
	# 072 帝国的雄鹰·躯干：使用迎击牌时可弃置X张行动牌移动X格(无视动力)（与071共享once）
	# LISTEN USE_ACTION_AT，CHOOSE_MANY_CARDS source=OWNER_ACTION_HAND + post_actions 移动。
	# ═══════════════════════════════════════════
	var eagle_torso_counter := _ActionEffect.new()
	eagle_torso_counter.effect_id = &"equipment_effect_072"
	eagle_torso_counter.display_name = "帝国雄鹰·躯干·弃牌换移动(迎击)"
	eagle_torso_counter.mode = _TC.MODE_LISTEN
	eagle_torso_counter.priority = 10
	eagle_torso_counter.listen_timing = _TC.USE_ACTION_AT
	eagle_torso_counter.listen_action_type = &"use_action_card"
	eagle_torso_counter.once_per_turn_key = &"eagle_torso_card_move"
	eagle_torso_counter.once_per_turn_max = 1
	eagle_torso_counter.set_conditions([
		{"op": &"USED_CARD_OWNER_IS_SELF"},
		{"op": &"USED_COUNTER_CARD"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	eagle_torso_counter.set_target_rules([{"rule": &"NO_TARGET"}])
	eagle_torso_counter.set_costs([])
	eagle_torso_counter.set_actions([{
		"type": &"CHOOSE_MANY_CARDS",
		"params": {
			"source": &"OWNER_ACTION_HAND",
			"min_count": 0,
			"max_count": 0,
			"discard_selected": true,
			"discard_reason": &"effect_discard",
			"label": "选择要弃置的行动牌（每张弃置可无视动力移动1格）",
			"confirm_verb": "弃置并移动",
			"cancel_label": "不弃置",
			"per_card_actions": [],
			"post_actions": [
				{"type": &"EXECUTE_SINGLE_MOVE", "params": {"mech_id": "$binding_context.mech_id", "max_cells_expr": "$choice.count", "free_move": true, "loop_until_cancel": false}},
			],
		},
	}])
	eagle_torso_counter.description = "每回合1次，可以弃置n数量的行动牌(n为整数)，之后移动n个格子(无视动力)。此效果也可以在使用迎击牌时使用。"
	effects[eagle_torso_counter.effect_id] = eagle_torso_counter

	# ═══════════════════════════════════════════
	# 073 帝国的雄鹰·臂：使用名称带热能的武器攻击时，可弃1行动牌，使威力+3
	# 诱发型 -- 监听 ATTACK_BEFORE（仿 effect_068，substring=热能）
	# ═══════════════════════════════════════════
	var eagle_arm := _ActionEffect.new()
	eagle_arm.effect_id = &"equipment_effect_073"
	eagle_arm.display_name = "帝国雄鹰·臂·热能弃1牌威力+3"
	eagle_arm.mode = _TC.MODE_LISTEN
	eagle_arm.priority = 10
	eagle_arm.listen_timing = _TC.ATTACK_BEFORE
	eagle_arm.listen_action_type = &"attack"
	eagle_arm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "热能"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 1},
	])
	eagle_arm.set_target_rules([{"rule": &"NO_TARGET"}])
	eagle_arm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": true},
	])
	eagle_arm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	])
	eagle_arm.description = "使用名称带有热能的武器攻击时，可以弃置1张行动牌，使威力+3。"
	effects[eagle_arm.effect_id] = eagle_arm

	# ═══════════════════════════════════════════
	# 074 轰雷装：损伤不影响此牌所在区域护甲，除非此牌上损伤≥3（派生值，仿 effect_049 阈值3）
	# ═══════════════════════════════════════════
	var thunder_immune := _ActionEffect.new()
	thunder_immune.effect_id = &"equipment_effect_074"
	thunder_immune.display_name = "轰雷装·此牌损伤<3免疫护甲"
	thunder_immune.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	thunder_immune.priority = 10
	thunder_immune.set_conditions([{"op": &"ALWAYS"}])
	thunder_immune.set_target_rules([{"rule": &"NO_TARGET"}])
	thunder_immune.set_costs([])
	thunder_immune.set_actions([])
	thunder_immune.description = "损伤不会影响此牌所在区域提供的护甲，除非此牌上设置的损伤≥3（实时重算）。"
	effects[thunder_immune.effect_id] = thunder_immune

	# ═══════════════════════════════════════════
	# 075 轰雷装·躯干：被指定为攻击目标时，可弃2行动牌，本回合护甲+5；若远程攻击则威力-3
	# 诱发型 -- 监听 ATTACK_PRE；内层 CHOOSE_ONE 非可选 + 互斥条件 -> 自动选（不弹窗）
	# ═══════════════════════════════════════════
	var thunder_torso := _ActionEffect.new()
	thunder_torso.effect_id = &"equipment_effect_075"
	thunder_torso.display_name = "轰雷装·躯干·被攻击弃2牌护甲+5远程威力-3"
	thunder_torso.mode = _TC.MODE_LISTEN
	thunder_torso.priority = 10
	thunder_torso.listen_timing = _TC.ATTACK_PRE
	thunder_torso.listen_action_type = &"attack"
	thunder_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	thunder_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	thunder_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	thunder_torso.set_actions([
		# 护甲+5：不指定 target_id，由 _extract_stat_mod_params 默认取 payload.target_id（攻击目标=自身）。
		# 此前误用 "target_id":"$binding_context.mech_id" 未被解析（_extract_stat_mod_params 直接取字面字符串），
		# 致 modify_armor 收到无效 mech_id -> 护甲未加。与 effect_047 超重甲躯干同形式（无 target_id）。
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"stat_type": &"armor", "value": 5, "method": &"add", "duration": &"THIS_TURN"}},
		{
			"type": &"CHOOSE_ONE",
			"params": {
				"optional": false,
				"options": [
					{"label": "远程攻击威力-3", "condition": [{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"远程"}], "actions": [
						{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -3}},
					]},
					{"label": "非远程：无额外修正", "condition": [{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND_NOT", "weapon_kind": &"远程"}], "actions": []},
				],
			},
		},
	])
	thunder_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，使当前回合护甲+5，并且若此攻击是远程武器发出的，则其威力-3。"
	effects[thunder_torso.effect_id] = thunder_torso

	# ═══════════════════════════════════════════
	# 076 极电装·头部：范围-2(最低1)+威力+4+转近战+回复2动力（适用近战武器，无近战限制）
	# 类型转换型 -- 监听 ATTACK_BEFORE，priority 20（仿 effect_061 但去掉 NOT近战 限制 + 回复2）
	# ═══════════════════════════════════════════
	var polar_head := _ActionEffect.new()
	polar_head.effect_id = &"equipment_effect_076"
	polar_head.display_name = "极电装·头部·范围-2威力+4转近战回复2(适用近战)"
	polar_head.mode = _TC.MODE_LISTEN
	polar_head.priority = 20
	polar_head.listen_timing = _TC.ATTACK_BEFORE
	polar_head.listen_action_type = &"attack"
	polar_head.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	polar_head.set_target_rules([{"rule": &"NO_TARGET"}])
	polar_head.set_costs([])
	polar_head.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "范围-2(最低1)+威力+4+转近战+回复2动力", "actions": [
				{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": -2, "min_value": 1}},
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 4}},
				{"type": &"SET_ATTACK_EFFECTIVE_WEAPON_KIND", "params": {"weapon_kind": &"近战"}},
				{"type": &"RESTORE_POWER", "params": {"amount": 2}},
			]}],
		},
	}])
	polar_head.description = "可以将发动攻击武器的范围-2(不会低于1)，然后威力+4，类型变为近战武器，之后回复2动力。"
	effects[polar_head.effect_id] = polar_head

	# ═══════════════════════════════════════════
	# 077 极电装·躯干：被攻击时弃2牌抽1行动牌并本回合动力+3
	# （即时迎击"若抽到迎击牌可立即响应"需 bind_result_to + OPEN_OR_USE_RESPONSE 完整流程，暂简化为弃2抽1动力+3，待实机/F3 补）
	# 诱发型 -- 监听 ATTACK_PRE
	# ═══════════════════════════════════════════
	var polar_torso := _ActionEffect.new()
	polar_torso.effect_id = &"equipment_effect_077"
	polar_torso.display_name = "极电装·躯干·被攻击弃2牌抽1动力+3"
	polar_torso.mode = _TC.MODE_LISTEN
	polar_torso.priority = 10
	polar_torso.listen_timing = _TC.ATTACK_PRE
	polar_torso.listen_action_type = &"attack"
	polar_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	polar_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	polar_torso.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	polar_torso.set_actions([
		{"type": &"DRAW_ACTION", "params": {"count": 1, "player_id": "$binding_context.player_id"}},
		{"type": &"EXECUTE_STAT_MODIFY", "params": {"target_id": "$binding_context.mech_id", "stat_type": &"power", "value": 3, "method": &"add", "duration": &"THIS_TURN"}},
	])
	polar_torso.description = "机甲被指定为攻击目标时，可弃置2张行动牌，立即抽1张行动牌(若是迎击牌可以立即响应该攻击)，并使当前回合动力+3。"
	effects[polar_torso.effect_id] = polar_torso

	# ═══════════════════════════════════════════
	# 078 极电装·臂：近战攻击弃2牌威力+3，之后选目标区域最多2张装备效果无效至本回合结束
	# 诱发型 -- 监听 ATTACK_PRE（仿 effect_063，威力 2->3 / cost 1->2 / max_count 1->2）
	# ═══════════════════════════════════════════
	var polar_arm := _ActionEffect.new()
	polar_arm.effect_id = &"equipment_effect_078"
	polar_arm.display_name = "极电装·臂·近战弃2牌威力+3并无效2张目标装备"
	polar_arm.mode = _TC.MODE_LISTEN
	polar_arm.priority = 30  # 先于目标躯干效果(ATTACK_PRE)：无效目标装备须先于躯干效果触发
	polar_arm.listen_timing = _TC.ATTACK_PRE
	polar_arm.listen_action_type = &"attack"
	polar_arm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_EFFECTIVE_WEAPON_KIND", "weapon_kind": &"近战"},
		{"op": &"OWNER_ACTION_HAND_ABOVE", "threshold": 2},
	])
	polar_arm.set_target_rules([{"rule": &"NO_TARGET"}])
	polar_arm.set_costs([
		{"cost_type": &"DISCARD_ACTION_CARD", "count": 2, "optional": true},
	])
	polar_arm.set_actions([
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
		{
			"type": &"CHOOSE_MANY_CARDS",
			"params": {
				"source": &"ATTACK_TARGET_EQUIPMENT",
				"max_count": 2,
				"min_count": 0,
				"discard_selected": false,
				"label": "选择至多2张装备，使其效果无效至本回合结束",
				"confirm_verb": "无效",
				"cancel_label": "不选择",
				"per_card_actions": [
					{"type": &"NEGATE_EQUIPMENT_EFFECT", "params": {"target_card_id": "$chosen_card.card_instance_id", "duration": "UNTIL_TURN_END"}}
				],
			},
		},
	])
	polar_arm.description = "使用近战武器发动攻击时，可以弃置2张行动牌，使威力+3，之后可以选择攻击目标区域最多2张牌效果无效直到本回合结束。"
	effects[polar_arm.effect_id] = polar_arm

	# ═══════════════════════════════════════════
	# 079 极电装·右腿：此牌从区域中弃置时可移除机甲其他区域内最多2损伤
	# 诱发型 -- 监听 DISCARD_AFTER；EXECUTE_DAMAGE_CHANGE decrease 复用维修移除损伤UI
	# （exclude_slot_id=$binding_context.slot_id 排除来源槽，由 damage_change_action decrease 路径
	#  透传到 damage_placement_panel.removal，valid_slots 跳过来源槽）
	# ═══════════════════════════════════════════
	var polar_rleg := _ActionEffect.new()
	polar_rleg.effect_id = &"equipment_effect_079"
	polar_rleg.display_name = "极电装·右腿·离场移除其他区域最多2损伤"
	polar_rleg.mode = _TC.MODE_LISTEN
	polar_rleg.priority = 10
	polar_rleg.listen_timing = _TC.DISCARD_AFTER
	polar_rleg.listen_action_type = &"discard_card"
	polar_rleg.set_conditions([
		{"op": &"DISCARD_IS_SELF_FROM_SLOT"},
		{"op": &"TARGET_HAS_DAMAGE"},
	])
	polar_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	polar_rleg.set_costs([])
	polar_rleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "移除其他区域最多2损伤", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "value": 2, "method": &"decrease", "executor": "$binding_context.mech_id", "exclude_slot_id": "$binding_context.slot_id", "max_value": 2, "reason": &"equipment_leave_remove_damage"}},
			]}],
		},
	}])
	polar_rleg.description = "此牌从区域中弃置时可移除机甲其他区域内最多2损伤。"
	effects[polar_rleg.effect_id] = polar_rleg

	# ═══════════════════════════════════════════
	# 080 联邦的一角兽·头部：场上所有机甲名称带联邦的装备牌额外+1护甲（全场光环派生值）
	# 派生值实时重算型 -- 由 get_global_faction_equipment_aura_bonus 判定
	# ═══════════════════════════════════════════
	var unicorn_head := _ActionEffect.new()
	unicorn_head.effect_id = &"equipment_effect_080"
	unicorn_head.display_name = "联邦的一角兽·头部·全场联邦装备+1护甲"
	unicorn_head.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	unicorn_head.priority = 10
	unicorn_head.set_conditions([{"op": &"ALWAYS"}])
	unicorn_head.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_head.set_costs([])
	unicorn_head.set_actions([])
	unicorn_head.description = "场上所有机甲的所有区域中名称带有联邦的装备牌将额外提供1护甲。"
	effects[unicorn_head.effect_id] = unicorn_head

	# ═══════════════════════════════════════════
	# 081 联邦的一角兽·躯干：被指定为目标时可置4损伤到此牌并直接无效该攻击
	# 诱发型 -- 监听 ATTACK_PRE priority 30；ATTACK_CAN_BE_NEGATED + fixed_slot置4 + NEGATE_ATTACK
	# ═══════════════════════════════════════════
	var unicorn_torso := _ActionEffect.new()
	unicorn_torso.effect_id = &"equipment_effect_081"
	unicorn_torso.display_name = "联邦的一角兽·躯干·置4损伤无效攻击"
	unicorn_torso.mode = _TC.MODE_LISTEN
	unicorn_torso.priority = 30
	unicorn_torso.listen_timing = _TC.ATTACK_PRE
	unicorn_torso.listen_action_type = &"attack"
	unicorn_torso.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_CAN_BE_NEGATED"},
		{"op": &"SELF_DAMAGE_TOKENS_BELOW", "threshold": 6},
	])
	unicorn_torso.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_torso.set_costs([])
	unicorn_torso.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "在此牌上设置4损伤，直接无效该攻击", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 4, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"NEGATE_ATTACK", "params": {}},
			]}],
		},
	}])
	unicorn_torso.description = "机甲被指定为攻击目标时，可以设置4损伤到此牌上，之后直接无效该攻击。"
	effects[unicorn_torso.effect_id] = unicorn_torso

	# ═══════════════════════════════════════════
	# 082 联邦的一角兽·右臂：发动攻击时可置2损伤到此牌使本次攻击威力+4
	# 诱发型 -- 监听 ATTACK_BEFORE；fixed_slot置2 + MODIFY_ATTACK_MIGHT +4
	# ═══════════════════════════════════════════
	var unicorn_rarm := _ActionEffect.new()
	unicorn_rarm.effect_id = &"equipment_effect_082"
	unicorn_rarm.display_name = "联邦的一角兽·右臂·置2损伤威力+4"
	unicorn_rarm.mode = _TC.MODE_LISTEN
	unicorn_rarm.priority = 10
	unicorn_rarm.listen_timing = _TC.ATTACK_BEFORE
	unicorn_rarm.listen_action_type = &"attack"
	unicorn_rarm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
	])
	unicorn_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_rarm.set_costs([])
	unicorn_rarm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "在此牌上设置2损伤，本次攻击威力+4", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 2, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 4}},
			]}],
		},
	}])
	unicorn_rarm.description = "发动攻击时，可以设置2损伤到此牌上，使本次攻击威力+4。"
	effects[unicorn_rarm.effect_id] = unicorn_rarm

	# ═══════════════════════════════════════════
	# 083 联邦的一角兽·左臂：攻击命中时可置3损伤到此牌使本回合可攻击次数+1
	# 诱发型 -- 监听 ATTACK_AFTER；fixed_slot置3 + MODIFY_ATTACK_COUNT +1 THIS_TURN
	# ═══════════════════════════════════════════
	var unicorn_larm := _ActionEffect.new()
	unicorn_larm.effect_id = &"equipment_effect_083"
	unicorn_larm.display_name = "联邦的一角兽·左臂·置3损伤攻击次数+1"
	unicorn_larm.mode = _TC.MODE_LISTEN
	unicorn_larm.priority = 10
	unicorn_larm.listen_timing = _TC.ATTACK_AFTER
	unicorn_larm.listen_action_type = &"attack"
	unicorn_larm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
	])
	unicorn_larm.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_larm.set_costs([])
	unicorn_larm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "在此牌上设置3损伤，本回合可攻击次数+1", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 3, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"MODIFY_ATTACK_COUNT", "params": {"target_id": "$binding_context.mech_id", "delta": 1, "duration": &"THIS_TURN"}},
			]}],
		},
	}])
	unicorn_larm.description = "发动攻击命中时，可以设置3损伤到此牌上，之后本回合的可攻击次数+1。"
	effects[unicorn_larm.effect_id] = unicorn_larm

	# ═══════════════════════════════════════════
	# 084 联邦的一角兽·右腿：响应对我方攻击，可置2损伤到此牌并立即移动2格，发动后可继续发动
	# AVAILABILITY 响应攻击；RESPOND_ATTACK + REPEAT_SELF_DAMAGE_AND_FREE_MOVE（新复杂交互循环）
	# ═══════════════════════════════════════════
	var unicorn_rleg := _ActionEffect.new()
	unicorn_rleg.effect_id = &"equipment_effect_084"
	unicorn_rleg.display_name = "联邦的一角兽·右腿·响应自损2移动2格循环"
	unicorn_rleg.mode = _TC.MODE_AVAILABILITY
	unicorn_rleg.priority = 10
	unicorn_rleg.availability_condition = _TC.AVAIL_RESPOND_ATTACK
	unicorn_rleg.availability_priority = 10
	unicorn_rleg.listen_timing = _TC.ATTACK_AT
	unicorn_rleg.listen_action_type = &"attack"
	unicorn_rleg.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"SELF_DAMAGE_TOKENS_BELOW", "threshold": 5},
	])
	unicorn_rleg.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_rleg.set_costs([])
	unicorn_rleg.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {"attack_id": "$payload.action_id", "source_card_id": "$binding_context.card_instance_id", "is_counter_card": false}},
		{"type": &"REPEAT_SELF_DAMAGE_AND_FREE_MOVE", "params": {
			"source_card_id": "$binding_context.card_instance_id",
			"target_mech_id": "$binding_context.mech_id",
			"target_slot_id": "$binding_context.slot_id",
			"damage_per_loop": 2,
			"move_cells_per_loop": 2,
			"ignore_power": true,
			"allow_continue": true,
			"stop_if_source_leaves_slot": true,
			"stop_damage_threshold": 5,
			"damage_reason": &"equipment_effect_cost",
		}},
	])
	unicorn_rleg.description = "响应对我方的攻击，可以设置2损伤到此牌上，机甲可立即无视动力移动2格。发动此效果后，可以立即继续发动此效果。"
	effects[unicorn_rleg.effect_id] = unicorn_rleg

	# ═══════════════════════════════════════════
	# 085 联邦的一角兽·左腿：被攻击命中时可置3损伤到此牌，之后最多减少5攻击损伤
	# 诱发型 -- 监听 ATTACK_AFTER；fixed_slot置3 + MODIFY_ATTACK_MARKERS -5（自动夹到0=min(5,markers)）
	# ═══════════════════════════════════════════
	var unicorn_lleg := _ActionEffect.new()
	unicorn_lleg.effect_id = &"equipment_effect_085"
	unicorn_lleg.display_name = "联邦的一角兽·左腿·置3损伤最多减5攻击损伤"
	unicorn_lleg.mode = _TC.MODE_LISTEN
	unicorn_lleg.priority = 10
	unicorn_lleg.listen_timing = _TC.ATTACK_AFTER
	unicorn_lleg.listen_action_type = &"attack"
	unicorn_lleg.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"ATTACK_HIT"},
		{"op": &"ATTACK_MARKERS_ABOVE", "threshold": 0},
	])
	unicorn_lleg.set_target_rules([{"rule": &"NO_TARGET"}])
	unicorn_lleg.set_costs([])
	unicorn_lleg.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "在此牌上设置3损伤，最多减少5攻击损伤", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 3, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -5}},
			]}],
		},
	}])
	unicorn_lleg.description = "机甲被攻击命中时，可以设置3损伤到此牌上，之后可最多减少此次攻击产生的5损伤。"
	effects[unicorn_lleg.effect_id] = unicorn_lleg

	# ═══════════════════════════════════════════
	# 086 帝国的神莺·头部：场上所有机甲名称带帝国的装备牌额外+1动力（全场光环派生值）
	# 派生值实时重算型 -- 由 get_global_faction_equipment_aura_bonus(帝国) 判定
	# ═══════════════════════════════════════════
	var lark_head := _ActionEffect.new()
	lark_head.effect_id = &"equipment_effect_086"
	lark_head.display_name = "帝国的神莺·头部·全场帝国装备+1动力"
	lark_head.mode = _TC.MODE_DIRECT  # 占位，实际实时重算
	lark_head.priority = 10
	lark_head.set_conditions([{"op": &"ALWAYS"}])
	lark_head.set_target_rules([{"rule": &"NO_TARGET"}])
	lark_head.set_costs([])
	lark_head.set_actions([])
	lark_head.description = "场上所有机甲的所有区域中名称带有帝国的装备牌将额外提供1动力。"
	effects[lark_head.effect_id] = lark_head

	# ═══════════════════════════════════════════
	# 090 帝国的神莺·右臂：攻击命中时可置2损伤到此牌，抽3行动牌并回复3动力
	# 诱发型 -- 监听 ATTACK_AFTER；fixed_slot置2 + DRAW_ACTION 3 + RESTORE_POWER 3
	# ═══════════════════════════════════════════
	var lark_rarm := _ActionEffect.new()
	lark_rarm.effect_id = &"equipment_effect_090"
	lark_rarm.display_name = "帝国的神莺·右臂·置2损伤抽3回复3"
	lark_rarm.mode = _TC.MODE_LISTEN
	lark_rarm.priority = 10
	lark_rarm.listen_timing = _TC.ATTACK_AFTER
	lark_rarm.listen_action_type = &"attack"
	lark_rarm.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_HIT"},
	])
	lark_rarm.set_target_rules([{"rule": &"NO_TARGET"}])
	lark_rarm.set_costs([])
	lark_rarm.set_actions([{
		"type": &"CHOOSE_ONE",
		"params": {
			"optional": true,
			"options": [{"label": "在此牌上设置2损伤，抽3行动牌并回复3动力", "actions": [
				{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {"target_mech_id": "$binding_context.mech_id", "target_slot_id": "$binding_context.slot_id", "value": 2, "method": &"increase", "executor": &"SYSTEM_DEFAULT", "reason": &"equipment_effect_cost", "fixed_slot": true}},
				{"type": &"DRAW_ACTION", "params": {"count": 3, "player_id": "$binding_context.player_id"}},
				{"type": &"RESTORE_POWER", "params": {"amount": 3}},
			]}],
		},
	}])
	lark_rarm.description = "发动攻击命中时，可以设置2损伤到此牌上，之后抽3张行动牌，回复3动力。"
	effects[lark_rarm.effect_id] = lark_rarm

	# ═══════════════════════════════════════════
	# 091 帝国的神莺·腿：每回合1次，当前回合消耗8动力后可无视动力移动2格
	# 诱发型 -- 监听 BASIC_MOVE_AFTER（仿 effect_044，收益改免费移动2格）
	# ═══════════════════════════════════════════
	var lark_leg := _ActionEffect.new()
	lark_leg.effect_id = &"equipment_effect_091"
	lark_leg.display_name = "帝国的神莺·腿·消耗8动力免费移动2格"
	lark_leg.mode = _TC.MODE_DIRECT
	lark_leg.priority = 10
	lark_leg.once_per_turn_key = &"equipment_effect_091"
	lark_leg.once_per_turn_max = 1
	lark_leg.set_conditions([
		{"op": &"POWER_SPENT_THIS_TURN_ABOVE", "threshold": 8},
	])
	lark_leg.set_target_rules([{"rule": &"NO_TARGET"}])
	lark_leg.set_costs([])
	lark_leg.set_actions([
		{"type": &"RESTORE_POWER", "params": {"amount": 2}},
		{"type": &"EXECUTE_SINGLE_MOVE", "params": {"max_cells": 2, "free_move": true, "loop_until_cancel": false}},
	])
	lark_leg.description = "每回合1次，机甲在当前回合内消耗了8动力，可无视动力移动2格，并回复2动力。"
	effects[lark_leg.effect_id] = lark_leg

	# ═══════════════════════════════════════════
	# 087 帝国的神莺·躯干：此牌也可当作威力20范围6的远程武器使用（权限型/派生武器型）
	# 不注册 timing listener；由武器选择面板/攻击可用性识别（get_virtual_weapon_from_equipment）。
	# 使用此虚拟武器需 current_power>0；配套 effect_088 处理耗尽动力+禁回。
	# ═══════════════════════════════════════════
	var lark_torso_weapon := _ActionEffect.new()
	lark_torso_weapon.effect_id = &"equipment_effect_087"
	lark_torso_weapon.display_name = "帝国的神莺·躯干·虚拟远程武器(威力20范围6)"
	lark_torso_weapon.mode = _TC.MODE_DIRECT  # 占位，权限型由武器查询接口识别
	lark_torso_weapon.priority = 10
	lark_torso_weapon.set_conditions([{"op": &"ALWAYS"}])
	lark_torso_weapon.set_target_rules([{"rule": &"NO_TARGET"}])
	lark_torso_weapon.set_costs([])
	lark_torso_weapon.set_actions([])
	lark_torso_weapon.description = "此牌也可以当作威力20，范围6的远程武器使用。使用此牌发动攻击需要消耗当前所有动力(不为0)，且直到下个我方回合开始无法回复。"
	effects[lark_torso_weapon.effect_id] = lark_torso_weapon

	# ═══════════════════════════════════════════
	# 088 帝国的神莺·躯干：使用本牌虚拟武器攻击时，强制消耗全部当前动力+施加禁回状态
	# 诱发型 -- 监听 ATTACK_BEFORE priority 30；ATTACK_SOURCE_IS_SELF + SPEND_POWER(ALL_CURRENT) + ADD_STATUS CANNOT_RESTORE_POWER
	# ═══════════════════════════════════════════
	var lark_torso_cost := _ActionEffect.new()
	lark_torso_cost.effect_id = &"equipment_effect_088"
	lark_torso_cost.display_name = "帝国的神莺·躯干·虚拟武器耗尽动力+禁回"
	lark_torso_cost.mode = _TC.MODE_LISTEN
	lark_torso_cost.priority = 30
	lark_torso_cost.listen_timing = _TC.ATTACK_BEFORE
	lark_torso_cost.listen_action_type = &"attack"
	lark_torso_cost.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACKER"},
		{"op": &"ATTACK_SOURCE_IS_SELF"},
		{"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "threshold": 1},
	])
	lark_torso_cost.set_target_rules([{"rule": &"NO_TARGET"}])
	lark_torso_cost.set_costs([
		{"cost_type": &"SPEND_POWER", "amount": &"ALL_CURRENT", "optional": false},
	])
	lark_torso_cost.set_actions([
		{"type": &"ADD_STATUS", "params": {"status_type": &"CANNOT_RESTORE_POWER", "target_id": "$binding_context.mech_id", "duration": &"UNTIL_OWNER_TURN_START", "source_card_id": "$binding_context.card_instance_id"}},
	])
	lark_torso_cost.description = "使用此牌发动攻击需要消耗当前所有动力(不为0)，且直到下个我方回合开始无法回复。"
	effects[lark_torso_cost.effect_id] = lark_torso_cost

	# ═══════════════════════════════════════════════════════════════
	# 武器装备牌效果（equipment_effect_093 ~ 139，共47个定义）
	# 权威拆解：new_logic/Battle-GEAR-S_武器装备牌效果逻辑拆解_40张全量.txt
	# 武器仅正面设置到 WEAPON 槽时注册 permanent listener；备用区不注册；离场注销。
	# ATTACK_AFTER 在主损伤放置前：简单额外损伤用 MODIFY_ATTACK_MARKERS；需读放置结果的
	# （101/119）在 ATTACK_SETTLE 读 damage_placement_log。
	# ═══════════════════════════════════════════════════════════════

	# 093 聚能后本回合范围+2（01光束军刀/17热能机枪）
	var w093 := _ActionEffect.new()
	w093.effect_id = &"equipment_effect_093"
	w093.display_name = "聚能后本回合范围+2"
	w093.mode = _TC.MODE_LISTEN
	w093.priority = 10
	w093.listen_timing = _TC.EFFECT_FIRE_AFTER
	w093.listen_action_type = &""  # 聚能联动：APPLY_ENERGY_TO_WEAPON 特判 fire EFFECT_FIRE_AFTER
	w093.set_conditions([{"op": &"ENERGY_TARGET_IS_SELF"}])
	w093.set_target_rules([{"rule": &"NO_TARGET"}])
	w093.set_costs([])
	w093.set_actions([{"type": &"SET_WEAPON_STATS", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "might_delta": 0, "range_delta": 2, "duration": &"THIS_OWNER_TURN", "stack": true}}])
	w093.description = "对此牌使用聚能时，本回合额外使此牌范围+2。"
	effects[w093.effect_id] = w093

	# 094 被光束名武器攻击时弃行动牌响应，威力-5（01光束军刀/16光束步枪）
	var w094 := _ActionEffect.new()
	w094.effect_id = &"equipment_effect_094"
	w094.display_name = "被光束名武器攻击时弃行动牌响应，威力-5"
	w094.mode = _TC.MODE_AVAILABILITY
	w094.priority = 10
	w094.availability_priority = 5
	w094.listen_timing = _TC.ATTACK_AT
	w094.listen_action_type = &"attack"
	w094.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "光束"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	w094.set_target_rules([{"rule": &"NO_TARGET"}])
	w094.set_costs([{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": false, "params": {"reason": &"weapon_named_response"}}])
	w094.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {"source_type": &"equipment", "source_card_instance_id": "$binding_context.card_instance_id", "is_counter_card": false}},
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -5}},
	])
	w094.description = "机甲被名称带有光束的武器攻击时，可弃1张行动牌响应，使该攻击威力-5。"
	effects[w094.effect_id] = w094

	# 095 聚能后本回合威力+4（02热能战斧/16光束步枪）
	var w095 := _ActionEffect.new()
	w095.effect_id = &"equipment_effect_095"
	w095.display_name = "聚能后本回合威力+4"
	w095.mode = _TC.MODE_LISTEN
	w095.priority = 10
	w095.listen_timing = _TC.EFFECT_FIRE_AFTER
	w095.listen_action_type = &""  # 聚能联动
	w095.set_conditions([{"op": &"ENERGY_TARGET_IS_SELF"}])
	w095.set_target_rules([{"rule": &"NO_TARGET"}])
	w095.set_costs([])
	w095.set_actions([{"type": &"SET_WEAPON_STATS", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "might_delta": 4, "range_delta": 0, "duration": &"THIS_OWNER_TURN", "stack": true}}])
	w095.description = "对此牌使用聚能时，本回合额外使此牌威力+4。"
	effects[w095.effect_id] = w095

	# 096 被热能名武器攻击时弃行动牌响应，威力-5（02热能战斧/17热能机枪）
	var w096 := _ActionEffect.new()
	w096.effect_id = &"equipment_effect_096"
	w096.display_name = "被热能名武器攻击时弃行动牌响应，威力-5"
	w096.mode = _TC.MODE_AVAILABILITY
	w096.priority = 10
	w096.availability_priority = 5
	w096.listen_timing = _TC.ATTACK_AT
	w096.listen_action_type = &"attack"
	w096.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"WEAPON_NAME_CONTAINS", "substring": "热能"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	w096.set_target_rules([{"rule": &"NO_TARGET"}])
	w096.set_costs([{"cost_type": &"DISCARD_ACTION_CARD", "count": 1, "optional": false, "params": {"reason": &"weapon_named_response"}}])
	w096.set_actions([
		{"type": &"RESPOND_ATTACK", "params": {"source_type": &"equipment", "source_card_instance_id": "$binding_context.card_instance_id", "is_counter_card": false}},
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": -5}},
	])
	w096.description = "机甲被名称带有热能的武器攻击时，可弃1张行动牌响应，使该攻击威力-5。"
	effects[w096.effect_id] = w096

	# 097 命中后可使本次攻击损伤标记+2（03破甲狼爪/09重型锤矛）
	var w097 := _ActionEffect.new()
	w097.effect_id = &"equipment_effect_097"
	w097.display_name = "命中后可使本次攻击损伤标记+2"
	w097.mode = _TC.MODE_LISTEN
	w097.priority = 10
	w097.listen_timing = _TC.ATTACK_AFTER
	w097.listen_action_type = &"attack"
	w097.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}])
	w097.set_target_rules([{"rule": &"NO_TARGET"}])
	w097.set_costs([])
	w097.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "额外设置2损伤", "actions": [{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 2}}]}]}}])
	w097.description = "此牌发动的攻击命中后可额外设置2损伤。"
	effects[w097.effect_id] = w097

	# 098 流星钢锤主阶段切换形态（04）
	var w098 := _ActionEffect.new()
	w098.effect_id = &"equipment_effect_098"
	w098.display_name = "流星钢锤主阶段切换形态"
	w098.mode = _TC.MODE_DIRECT
	w098.priority = 10
	w098.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}])
	w098.set_target_rules([{"rule": &"NO_TARGET"}])
	w098.set_costs([])
	w098.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
		{"label": "威力-5，范围+2", "condition": {"op": &"WEAPON_MODE_NOT_EQUALS", "params": {"mode": &"extended"}}, "actions": [{"type": &"SET_WEAPON_MODE", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "mode": &"extended"}}]},
		{"label": "恢复原本数值", "condition": {"op": &"WEAPON_MODE_EQUALS", "params": {"mode": &"extended"}}, "actions": [{"type": &"SET_WEAPON_MODE", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "mode": &"normal"}}]},
	]}}])
	w098.description = "我方回合中可以使此牌威力-5范围+2，或恢复原本数值。"
	effects[w098.effect_id] = w098

	# 099 流星钢锤攻击被响应后切换形态（04）
	var w099 := _ActionEffect.new()
	w099.effect_id = &"equipment_effect_099"
	w099.display_name = "流星钢锤攻击被响应后切换形态"
	w099.mode = _TC.MODE_LISTEN
	w099.priority = 10
	w099.listen_timing = _TC.ATTACK_AT
	w099.listen_action_type = &"attack"
	w099.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"ATTACK_WAS_RESPONDED"}])
	w099.set_target_rules([{"rule": &"NO_TARGET"}])
	w099.set_costs([])
	w099.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
		{"label": "威力-5，范围+2", "actions": [{"type": &"SET_WEAPON_MODE", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "mode": &"extended", "refresh_parent_attack": true}}]},
		{"label": "恢复原本数值", "actions": [{"type": &"SET_WEAPON_MODE", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "mode": &"normal", "refresh_parent_attack": true}}]},
	]}}])
	w099.description = "此牌发动的攻击被响应后，可切换形态。"
	effects[w099.effect_id] = w099

	# 100 命中后可弃目标2张行动牌（05扭转钢鞭）
	var w100 := _ActionEffect.new()
	w100.effect_id = &"equipment_effect_100"
	w100.display_name = "命中后可弃目标2张行动牌"
	w100.mode = _TC.MODE_LISTEN
	w100.priority = 10
	w100.listen_timing = _TC.ATTACK_AFTER
	w100.listen_action_type = &"attack"
	w100.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"TARGET_HAS_ACTION_CARDS", "params": {"minimum": 1}}])
	w100.set_target_rules([{"rule": &"NO_TARGET"}])
	w100.set_costs([])
	w100.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "弃置目标2张行动牌", "actions": [{"type": &"EXECUTE_DISCARD", "params": {"from_target": "$payload.target_id", "zone": &"action_hand", "count": 2, "count_mode": &"up_to", "choose": true, "chooser_id": "$binding_context.mech_id", "face_up": false, "reason": &"weapon_effect"}}]}]}}])
	w100.description = "此牌发动的攻击命中后可弃置攻击目标2张行动牌。"
	effects[w100.effect_id] = w100

	# 101 同区额外2损伤（06光束战戟/07热能战镰/21光束狙击枪/22穿甲热能枪）
	var w101 := _ActionEffect.new()
	w101.effect_id = &"equipment_effect_101"
	w101.display_name = "本次攻击损伤全在同一区域后，可在该区域额外放2损伤"
	w101.mode = _TC.MODE_LISTEN
	w101.priority = 10
	w101.listen_timing = _TC.ATTACK_SETTLE
	w101.listen_action_type = &"attack"
	w101.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"ATTACK_MARKERS_ABOVE", "params": {"threshold": 1}}, {"op": &"DAMAGE_TOKENS_ALL_IN_SAME_SLOT"}])
	w101.set_target_rules([{"rule": &"NO_TARGET"}])
	w101.set_costs([])
	w101.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "在同一区域额外设置2损伤", "actions": [{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$payload.target_id", "target_slot": "$payload.single_damage_slot_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_extra_damage"}}]}]}}])
	w101.description = "此牌发动的攻击产生的损伤如果全部设置于同一区域，则可以额外设置2损伤在该区域上。"
	effects[w101.effect_id] = w101

	# 102 命中后可额外2损伤，之后本牌自损1（08断甲长刀）
	var w102 := _ActionEffect.new()
	w102.effect_id = &"equipment_effect_102"
	w102.display_name = "命中后可额外2损伤，之后本牌自损1"
	w102.mode = _TC.MODE_LISTEN
	w102.priority = 10
	w102.listen_timing = _TC.ATTACK_AFTER
	w102.listen_action_type = &"attack"
	w102.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}])
	w102.set_target_rules([{"rule": &"NO_TARGET"}])
	w102.set_costs([])
	w102.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "额外2损伤并使此牌受1损伤", "actions": [
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 2}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_self_damage"}},
	]}]}}])
	w102.description = "此牌发动的攻击命中后可额外设置2损伤，之后在此牌上设置1损伤。"
	effects[w102.effect_id] = w102

	# 103 本牌攻击未命中时自损2（09重型锤矛）
	var w103 := _ActionEffect.new()
	w103.effect_id = &"equipment_effect_103"
	w103.display_name = "本牌攻击未命中时自损2"
	w103.mode = _TC.MODE_LISTEN
	w103.priority = 10
	w103.listen_timing = _TC.ATTACK_AFTER
	w103.listen_action_type = &"attack"
	w103.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_MISS"}])
	w103.set_target_rules([{"rule": &"NO_TARGET"}])
	w103.set_costs([])
	w103.set_actions([{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_miss_self_damage"}}])
	w103.description = "此牌发动的攻击没有命中，则设置2损伤在此牌上。"
	effects[w103.effect_id] = w103

	# 104 命中后施加锁定；锁定期间本牌不能攻击（10拘束钩爪）
	var w104 := _ActionEffect.new()
	w104.effect_id = &"equipment_effect_104"
	w104.display_name = "命中后施加锁定；锁定期间本牌不能攻击"
	w104.mode = _TC.MODE_LISTEN
	w104.priority = 10
	w104.listen_timing = _TC.ATTACK_AFTER
	w104.listen_action_type = &"attack"
	w104.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"ATTACK_TARGET_ALIVE"}])
	w104.set_target_rules([{"rule": &"NO_TARGET"}])
	w104.set_costs([])
	w104.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "施加锁定", "actions": [{"type": &"SET_WEAPON_LOCK", "params": {"weapon_id": "$binding_context.card_instance_id", "target_id": "$payload.target_id", "mode": &"apply"}}]}]}}])
	w104.description = "命中后可施加锁定，持续到目标下一次被攻击命中，期间此牌不能攻击。"
	effects[w104.effect_id] = w104

	# 105 本牌攻击命中后自损1（11光束斩舰刀/12热能双刃斧）
	var w105 := _ActionEffect.new()
	w105.effect_id = &"equipment_effect_105"
	w105.display_name = "本牌攻击命中后自损1"
	w105.mode = _TC.MODE_LISTEN
	w105.priority = 10
	w105.listen_timing = _TC.ATTACK_AFTER
	w105.listen_action_type = &"attack"
	w105.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}])
	w105.set_target_rules([{"rule": &"NO_TARGET"}])
	w105.set_costs([])
	w105.set_actions([{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_hit_self_damage"}}])
	w105.description = "此牌发动的攻击命中后，在此牌上设置1损伤。"
	effects[w105.effect_id] = w105

	# 106 光束斩舰刀攻击时可威力+3并记录后续自损（11）
	var w106 := _ActionEffect.new()
	w106.effect_id = &"equipment_effect_106"
	w106.display_name = "光束斩舰刀攻击时可威力+3并记录后续自损"
	w106.mode = _TC.MODE_LISTEN
	w106.priority = 10
	w106.listen_timing = _TC.ATTACK_BEFORE
	w106.listen_action_type = &"attack"
	w106.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w106.set_target_rules([{"rule": &"NO_TARGET"}])
	w106.set_costs([])
	w106.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "威力+3（结算后此牌受1损伤）", "actions": [
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
		{"type": &"INCREMENT_VARIABLE", "params": {"scope": &"attack", "variable_name": &"weapon_011_bonus_used", "delta": 1}},
	]}]}}])
	w106.description = "此牌攻击时，可以使威力+3，攻击结算后在此牌上设置1损伤。"
	effects[w106.effect_id] = w106

	# 107 光束斩舰刀加成攻击结算后自损1（11）
	var w107 := _ActionEffect.new()
	w107.effect_id = &"equipment_effect_107"
	w107.display_name = "光束斩舰刀加成攻击结算后自损1"
	w107.mode = _TC.MODE_LISTEN
	w107.priority = 10
	w107.listen_timing = _TC.ATTACK_SETTLE
	w107.listen_action_type = &"attack"
	w107.requires_effect = &"equipment_effect_106"
	w107.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"VARIABLE_ABOVE", "params": {"scope": &"attack", "variable_name": &"weapon_011_bonus_used", "threshold": 0}}])
	w107.set_target_rules([{"rule": &"NO_TARGET"}])
	w107.set_costs([])
	w107.set_actions([{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_bonus_settle_self_damage"}}])
	w107.description = "攻击结算后在此牌上设置1损伤（仅选过威力+3时）。"
	effects[w107.effect_id] = w107

	# 108 热能双刃斧攻击时可范围+2并记录后续自损（12）
	var w108 := _ActionEffect.new()
	w108.effect_id = &"equipment_effect_108"
	w108.display_name = "热能双刃斧攻击时可范围+2并记录后续自损"
	w108.mode = _TC.MODE_LISTEN
	w108.priority = 10
	w108.listen_timing = _TC.ATTACK_BEFORE
	w108.listen_action_type = &"attack"
	w108.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w108.set_target_rules([{"rule": &"NO_TARGET"}])
	w108.set_costs([])
	w108.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "范围+2（结算后此牌受1损伤）", "actions": [
		{"type": &"MODIFY_ATTACK_RANGE", "params": {"delta": 2, "min_value": 0}},
		{"type": &"INCREMENT_VARIABLE", "params": {"scope": &"attack", "variable_name": &"weapon_012_bonus_used", "delta": 1}},
	]}]}}])
	w108.description = "此牌攻击时，可以使范围+2，攻击结算后在此牌上设置1损伤。"
	effects[w108.effect_id] = w108

	# 109 热能双刃斧加成攻击结算后自损1（12）
	var w109 := _ActionEffect.new()
	w109.effect_id = &"equipment_effect_109"
	w109.display_name = "热能双刃斧加成攻击结算后自损1"
	w109.mode = _TC.MODE_LISTEN
	w109.priority = 10
	w109.listen_timing = _TC.ATTACK_SETTLE
	w109.listen_action_type = &"attack"
	w109.requires_effect = &"equipment_effect_108"
	w109.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"VARIABLE_ABOVE", "params": {"scope": &"attack", "variable_name": &"weapon_012_bonus_used", "threshold": 0}}])
	w109.set_target_rules([{"rule": &"NO_TARGET"}])
	w109.set_costs([])
	w109.set_actions([{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_bonus_settle_self_damage"}}])
	w109.description = "攻击结算后在此牌上设置1损伤（仅选过范围+2时）。"
	effects[w109.effect_id] = w109

	# 110 使用闪回激光剑攻击必须额外消耗2动力（13）
	var w110 := _ActionEffect.new()
	w110.effect_id = &"equipment_effect_110"
	w110.display_name = "使用闪回激光剑攻击必须额外消耗2动力"
	w110.mode = _TC.MODE_LISTEN
	w110.priority = 20
	w110.listen_timing = _TC.ATTACK_BEFORE
	w110.listen_action_type = &"attack"
	w110.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 2}}])
	w110.set_target_rules([{"rule": &"NO_TARGET"}])
	w110.set_costs([{"cost_type": &"SPEND_POWER", "amount": 2, "optional": false}])
	w110.set_actions([])
	w110.description = "需要额外消耗2动力才能使用此牌攻击。"
	effects[w110.effect_id] = w110

	# 111 闪回激光剑攻击时可再耗4动力使威力+3（13）
	var w111 := _ActionEffect.new()
	w111.effect_id = &"equipment_effect_111"
	w111.display_name = "闪回激光剑攻击时可再耗4动力使威力+3"
	w111.mode = _TC.MODE_LISTEN
	w111.priority = 10
	w111.listen_timing = _TC.ATTACK_BEFORE
	w111.listen_action_type = &"attack"
	w111.requires_effect = &"equipment_effect_110"
	w111.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"OWNER_POWER_ABOVE_OR_EQUAL", "params": {"threshold": 4}}])
	w111.set_target_rules([{"rule": &"NO_TARGET"}])
	w111.set_costs([])
	w111.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "再消耗4动力，威力+3", "actions": [
		{"type": &"SPEND_POWER", "params": {"amount": 4}},
		{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}},
	]}]}}])
	w111.description = "此牌攻击时，可以再消耗4动力使此次攻击威力+3。"
	effects[w111.effect_id] = w111

	# 112 每次攻击结算后武器威力永久-4并标记本回合已用（14/15）
	var w112 := _ActionEffect.new()
	w112.effect_id = &"equipment_effect_112"
	w112.display_name = "每次攻击结算后武器威力永久-4并标记本回合已用"
	w112.mode = _TC.MODE_LISTEN
	w112.priority = 10
	w112.listen_timing = _TC.ATTACK_SETTLE
	w112.listen_action_type = &"attack"
	w112.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w112.set_target_rules([{"rule": &"NO_TARGET"}])
	w112.set_costs([])
	w112.set_actions([
		{"type": &"MODIFY_WEAPON_POWER", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "delta": -4, "mode": &"increase", "duration": &"PERMANENT", "bucket": "weapon_decay"}},
		{"type": &"ADD_STATUS", "params": {"status_type": &"weapon_used_this_turn", "target_card_instance_id": "$binding_context.card_instance_id", "duration": &"UNTIL_OWNER_TURN_AFTER_END", "refresh": true}},
	])
	w112.description = "此牌每发动过1次攻击，威力-4。"
	effects[w112.effect_id] = w112

	# 113 我方回合未用本牌攻击则回合结束回复4威力（14/15）
	var w113 := _ActionEffect.new()
	w113.effect_id = &"equipment_effect_113"
	w113.display_name = "我方回合未用本牌攻击则回合结束回复4威力"
	w113.mode = _TC.MODE_LISTEN
	w113.priority = 10
	w113.listen_timing = _TC.TURN_END
	w113.listen_action_type = &"turn"
	w113.set_conditions([{"op": &"SOURCE_OWNER_IS_TURN_PLAYER"}, {"op": &"WEAPON_STATUS_ABSENT", "params": {"status_type": &"weapon_used_this_turn"}}])
	w113.set_target_rules([{"rule": &"NO_TARGET"}])
	w113.set_costs([])
	w113.set_actions([{"type": &"MODIFY_WEAPON_POWER", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "delta": 4, "mode": &"restore", "clamp_max": &"printed_might", "duration": &"PERMANENT", "bucket": "weapon_decay"}}])
	w113.description = "我方回合未使用此牌攻击则在回合结束时回复4威力。"
	effects[w113.effect_id] = w113

	# 114 对此牌使用聚能时回复4威力（14/15）
	var w114 := _ActionEffect.new()
	w114.effect_id = &"equipment_effect_114"
	w114.display_name = "对此牌使用聚能时回复4威力"
	w114.mode = _TC.MODE_LISTEN
	w114.priority = 10
	w114.listen_timing = _TC.EFFECT_FIRE_AFTER
	w114.listen_action_type = &""  # 聚能联动
	w114.set_conditions([{"op": &"ENERGY_TARGET_IS_SELF"}])
	w114.set_target_rules([{"rule": &"NO_TARGET"}])
	w114.set_costs([])
	w114.set_actions([{"type": &"MODIFY_WEAPON_POWER", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "delta": 4, "mode": &"restore", "clamp_max": &"printed_might", "duration": &"PERMANENT", "bucket": "weapon_decay"}}])
	w114.description = "对此牌使用聚能时也可回复4威力。"
	effects[w114.effect_id] = w114

	# 115 命中且目标与攻击方相邻时可额外2损伤（18/19/23）
	var w115 := _ActionEffect.new()
	w115.effect_id = &"equipment_effect_115"
	w115.display_name = "命中且目标与攻击方相邻时可额外2损伤"
	w115.mode = _TC.MODE_LISTEN
	w115.priority = 10
	w115.listen_timing = _TC.ATTACK_AFTER
	w115.listen_action_type = &"attack"
	w115.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"TARGET_IS_ADJACENT"}])
	w115.set_target_rules([{"rule": &"NO_TARGET"}])
	w115.set_costs([])
	w115.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "相邻：额外设置2损伤", "actions": [{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 2}}]}]}}])
	w115.description = "命中且目标与机甲当前位置相邻，则可额外设置2损伤。"
	effects[w115.effect_id] = w115

	# 116 命中后可额外1损伤（20火箭筒）
	var w116 := _ActionEffect.new()
	w116.effect_id = &"equipment_effect_116"
	w116.display_name = "命中后可额外1损伤"
	w116.mode = _TC.MODE_LISTEN
	w116.priority = 10
	w116.listen_timing = _TC.ATTACK_AFTER
	w116.listen_action_type = &"attack"
	w116.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}])
	w116.set_target_rules([{"rule": &"NO_TARGET"}])
	w116.set_costs([])
	w116.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "额外设置1损伤", "actions": [{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 1}}]}]}}])
	w116.description = "此牌发动的攻击命中后可额外设置1损伤。"
	effects[w116.effect_id] = w116

	# 117 指定目标时可使目标当前动力-2并记录已发动（24密集导弹炮）
	var w117 := _ActionEffect.new()
	w117.effect_id = &"equipment_effect_117"
	w117.display_name = "指定目标时可使目标当前动力-2并记录已发动"
	w117.mode = _TC.MODE_LISTEN
	w117.priority = 20
	w117.listen_timing = _TC.ATTACK_PRE
	w117.listen_action_type = &"attack"
	w117.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"ATTACK_TARGET_ALIVE"}])
	w117.set_target_rules([{"rule": &"NO_TARGET"}])
	w117.set_costs([])
	w117.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "使目标当前动力-2", "actions": [
		{"type": &"MODIFY_MECH_POWER", "params": {"target_id": "$payload.target_id", "delta": -2, "mode": &"current_only", "min_value": 0, "duration": &"PERMANENT"}},
		{"type": &"INCREMENT_VARIABLE", "params": {"scope": &"attack", "variable_name": &"weapon_024_power_drain_used", "delta": 1}},
	]}]}}])
	w117.description = "此牌发动攻击指定目标时，可以使目标当前动力-2。"
	effects[w117.effect_id] = w117

	# 118 已减动力且命中时，若目标动力为0则额外2损伤（24）
	var w118 := _ActionEffect.new()
	w118.effect_id = &"equipment_effect_118"
	w118.display_name = "已减动力且命中时，若目标动力为0则额外2损伤"
	w118.mode = _TC.MODE_LISTEN
	w118.priority = 10
	w118.listen_timing = _TC.ATTACK_AFTER
	w118.listen_action_type = &"attack"
	w118.requires_effect = &"equipment_effect_117"
	w118.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"VARIABLE_ABOVE", "params": {"scope": &"attack", "variable_name": &"weapon_024_power_drain_used", "threshold": 0}}, {"op": &"TARGET_POWER_EQUALS", "params": {"value": 0}}])
	w118.set_target_rules([{"rule": &"NO_TARGET"}])
	w118.set_costs([])
	w118.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "目标动力为0：额外设置2损伤", "actions": [{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 2}}]}]}}])
	w118.description = "若目标机甲动力为0，则攻击命中可额外设置2损伤。"
	effects[w118.effect_id] = w118

	# 119 本次攻击损伤未全在同一区域后，可额外2损伤（25超级火箭筒）
	var w119 := _ActionEffect.new()
	w119.effect_id = &"equipment_effect_119"
	w119.display_name = "本次攻击损伤未全在同一区域后，可额外2损伤"
	w119.mode = _TC.MODE_LISTEN
	w119.priority = 10
	w119.listen_timing = _TC.ATTACK_SETTLE
	w119.listen_action_type = &"attack"
	w119.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}, {"op": &"ATTACK_MARKERS_ABOVE", "params": {"threshold": 1}}, {"op": &"DAMAGE_TOKENS_NOT_ALL_IN_SAME_SLOT"}])
	w119.set_target_rules([{"rule": &"NO_TARGET"}])
	w119.set_costs([])
	w119.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "损伤分散：额外设置2损伤", "actions": [{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$payload.target_id", "target_slot": &"choose_by_executor", "executor_id": "$binding_context.mech_id", "reason": &"weapon_extra_damage"}}]}]}}])
	w119.description = "此牌发动的攻击产生的损伤如果未设置于同一区域，则可额外再设置2损伤。"
	effects[w119.effect_id] = w119

	# 120 每有1损伤，武器有效威力-2（26/27）派生值型——不注册监听器
	var w120 := _ActionEffect.new()
	w120.effect_id = &"equipment_effect_120"
	w120.display_name = "每有1损伤，武器有效威力-2"
	w120.mode = _TC.MODE_DIRECT
	w120.priority = 10
	w120.set_conditions([{"op": &"ALWAYS"}])
	w120.set_target_rules([{"rule": &"NO_TARGET"}])
	w120.set_costs([])
	w120.set_actions([])
	w120.description = "此牌每设置有1损伤，则威力-2（实时重算）。"
	effects[w120.effect_id] = w120

	# 121 大型光束炮攻击时可自损1并将本次威力回复至全值+2（26）
	var w121 := _ActionEffect.new()
	w121.effect_id = &"equipment_effect_121"
	w121.display_name = "大型光束炮攻击时可自损1并将本次威力回复至全值+2"
	w121.mode = _TC.MODE_LISTEN
	w121.priority = 10
	w121.listen_timing = _TC.ATTACK_BEFORE
	w121.listen_action_type = &"attack"
	w121.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w121.set_target_rules([{"rule": &"NO_TARGET"}])
	w121.set_costs([])
	w121.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "此牌受1损伤，回复全部威力并威力+2", "actions": [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_self_damage"}},
		{"type": &"SET_ATTACK_MIGHT_FROM_PRINTED_WEAPON", "params": {"weapon_instance_id": "$binding_context.card_instance_id", "bonus": 2, "ignore_self_damage_penalty": true, "preserve_external_extra_might": true}},
	]}]}}])
	w121.description = "此牌攻击时，可以在此牌上设置1损伤，回复全部威力，并使威力+2。"
	effects[w121.effect_id] = w121

	# 122 热能加特林命中时可自损2，之后额外3损伤（27）
	var w122 := _ActionEffect.new()
	w122.effect_id = &"equipment_effect_122"
	w122.display_name = "热能加特林命中时可自损2，之后额外3损伤"
	w122.mode = _TC.MODE_LISTEN
	w122.priority = 10
	w122.listen_timing = _TC.ATTACK_AFTER
	w122.listen_action_type = &"attack"
	w122.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"PAYLOAD_ATTACK_HIT"}])
	w122.set_target_rules([{"rule": &"NO_TARGET"}])
	w122.set_costs([])
	w122.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "此牌受2损伤，额外设置3损伤", "actions": [
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_self_damage"}},
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": 3}},
	]}]}}])
	w122.description = "此牌攻击命中时，可以在此牌上设置2损伤，之后可额外设置3损伤。"
	effects[w122.effect_id] = w122

	# 123 攻击时随机弃我方1张行动牌（28雷爆磁轨炮）
	var w123 := _ActionEffect.new()
	w123.effect_id = &"equipment_effect_123"
	w123.display_name = "攻击时随机弃我方1张行动牌"
	w123.mode = _TC.MODE_LISTEN
	w123.priority = 20
	w123.listen_timing = _TC.ATTACK_BEFORE
	w123.listen_action_type = &"attack"
	w123.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}}])
	w123.set_target_rules([{"rule": &"NO_TARGET"}])
	w123.set_costs([])
	w123.set_actions([{"type": &"RANDOM_DISCARD_ACTION_CARD", "params": {"owner_id": "$binding_context.mech_id", "count": 1, "reason": &"weapon_028_random_cost", "parent_attack_id": "$payload.action_id"}}])
	w123.description = "此牌发动攻击时，随机弃置我方1张行动牌。"
	effects[w123.effect_id] = w123

	# 124 随机弃牌若为最后一张，则本次攻击威力+3（28）
	var w124 := _ActionEffect.new()
	w124.effect_id = &"equipment_effect_124"
	w124.display_name = "随机弃牌若为最后一张，则本次攻击威力+3"
	w124.mode = _TC.MODE_LISTEN
	w124.priority = 10
	w124.listen_timing = _TC.ATTACK_AFTER
	w124.listen_action_type = &"attack"
	w124.requires_effect = &"equipment_effect_123"
	w124.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}, {"op": &"VARIABLE_ABOVE", "params": {"scope": &"attack", "variable_name": &"weapon_028_was_last", "threshold": 0}}])
	w124.set_target_rules([{"rule": &"NO_TARGET"}])
	w124.set_costs([])
	w124.set_actions([{"type": &"MODIFY_ATTACK_MIGHT", "params": {"delta": 3}}])
	w124.description = "若被弃置的牌是我方的最后一张牌，则此次攻击威力+3。"
	effects[w124.effect_id] = w124

	# 125 攻击结算后设置武器冷却至下个我方回合结束（29/30）
	var w125 := _ActionEffect.new()
	w125.effect_id = &"equipment_effect_125"
	w125.display_name = "攻击结算后设置武器冷却至下个我方回合结束"
	w125.mode = _TC.MODE_LISTEN
	w125.priority = 10
	w125.listen_timing = _TC.ATTACK_SETTLE
	w125.listen_action_type = &"attack"
	w125.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w125.set_target_rules([{"rule": &"NO_TARGET"}])
	w125.set_costs([])
	w125.set_actions([{"type": &"SET_WEAPON_COOLDOWN", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "clear_timing": &"NEXT_OWNER_TURN_AFTER_END", "refresh": true}}])
	w125.description = "此牌发动攻击后，直到下个我方回合结束不能再使用此牌发动攻击。"
	effects[w125.effect_id] = w125

	# 126 对此牌使用聚能后清除冷却（29/30）
	var w126 := _ActionEffect.new()
	w126.effect_id = &"equipment_effect_126"
	w126.display_name = "对此牌使用聚能后清除冷却"
	w126.mode = _TC.MODE_LISTEN
	w126.priority = 20
	w126.listen_timing = _TC.EFFECT_FIRE_AFTER
	w126.listen_action_type = &""  # 聚能联动
	w126.set_conditions([{"op": &"ENERGY_TARGET_IS_SELF"}, {"op": &"WEAPON_IS_ON_COOLDOWN"}])
	w126.set_target_rules([{"rule": &"NO_TARGET"}])
	w126.set_costs([])
	w126.set_actions([{"type": &"SET_WEAPON_COOLDOWN", "params": {"target_card_instance_id": "$binding_context.card_instance_id", "clear": true}}])
	w126.description = "对此牌使用聚能后允许再次发动攻击。"
	effects[w126.effect_id] = w126

	# 127 盾牌将攻击/陷阱全部损伤转移到自身，减伤0（31合金盾牌）
	var w127 := _ActionEffect.new()
	w127.effect_id = &"equipment_effect_127"
	w127.display_name = "盾牌将攻击/陷阱全部损伤转移到自身，减伤0"
	w127.mode = _TC.MODE_LISTEN
	w127.priority = 20
	w127.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	w127.listen_action_type = &"damage_change"
	w127.set_conditions([{"op": &"SELF_MECH_IS_DAMAGE_TARGET"}, {"op": &"DAMAGE_SOURCE_IS_ATTACK_OR_TRAP"}, {"op": &"PAYLOAD_DAMAGE_TOKENS_ABOVE", "params": {"threshold": 0}}])
	w127.set_target_rules([{"rule": &"NO_TARGET"}])
	w127.set_costs([])
	w127.set_actions([{"type": &"OFFER_DAMAGE_REDIRECT", "params": {"max_points": -1, "mode": &"all_or_nothing", "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "reduction": 0, "min_points": 0, "optional": true}}])
	w127.description = "可以将每次攻击或陷阱产生的全部损伤设置到此牌上。"
	effects[w127.effect_id] = w127

	# 128 直接使用本牌发动不需要攻击牌的攻击（32/36/39）
	var w128 := _ActionEffect.new()
	w128.effect_id = &"equipment_effect_128"
	w128.display_name = "直接使用本牌发动不需要攻击牌的攻击"
	w128.mode = _TC.MODE_DIRECT
	w128.priority = 10
	w128.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}, {"op": &"ATTACK_COUNT_ABOVE", "params": {"threshold": 0}}, {"op": &"WEAPON_CAN_ATTACK_AGAIN"}, {"op": &"WEAPON_HAS_ATTACKABLE_TARGET_IN_RANGE"}])
	w128.set_target_rules([{"rule": &"NO_TARGET"}])
	w128.set_costs([])
	w128.set_actions([{"type": &"EXECUTE_ATTACK", "params": {"attacker_id": "$binding_context.mech_id", "weapon_instance_id": "$binding_context.card_instance_id", "target_count": 1, "skip_weapon_select": true, "choose_new_target": true, "source_action_card": null, "cardless_weapon_attack": true, "consume_turn_attack_count": true}}])
	w128.description = "可直接使用此牌发动攻击(不需要攻击牌)。"
	effects[w128.effect_id] = w128

	# 129 本牌攻击结算后自损1（32/36/39）
	var w129 := _ActionEffect.new()
	w129.effect_id = &"equipment_effect_129"
	w129.display_name = "本牌攻击结算后自损1"
	w129.mode = _TC.MODE_LISTEN
	w129.priority = 10
	w129.listen_timing = _TC.ATTACK_SETTLE
	w129.listen_action_type = &"attack"
	w129.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w129.set_target_rules([{"rule": &"NO_TARGET"}])
	w129.set_costs([])
	w129.set_actions([{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_attack_settle_self_damage"}}])
	w129.description = "此牌发动攻击结算后会被设置1损伤。"
	effects[w129.effect_id] = w129

	# 130 每回合1次，将1张行动牌当维修打出，之后本牌自损2（33维修机械臂）
	var w130 := _ActionEffect.new()
	w130.effect_id = &"equipment_effect_130"
	w130.display_name = "每回合1次，将1张行动牌当维修打出，之后本牌自损2"
	w130.mode = _TC.MODE_DIRECT
	w130.priority = 10
	w130.once_per_turn_key = &"weapon_033_use"
	w130.once_per_turn_max = 1
	w130.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}, {"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}}, {"op": &"REPAIR_HAS_VALID_TARGET", "params": {"range": 1}}])
	w130.set_target_rules([{"rule": &"NO_TARGET"}])
	w130.set_costs([])
	w130.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {"filter": {"zone": &"action_hand", "owner_id": "$binding_context.mech_id"}, "min_count": 1, "max_count": 1, "label": "选择1张行动牌当作维修打出", "confirm_verb": "当作维修", "cancel_label": "取消", "per_card_actions": [
			{"type": &"DECLARE_CARD_TYPE", "params": {"card_instance_id": "$selected_card_instance_id", "declared_card_def_id": &"action_013_维修", "duration": &"UNTIL_USE_ACTION_SETTLE"}},
			{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"card_instance_id": "$selected_card_instance_id", "acting_mech_id": "$binding_context.mech_id", "as_card_def_id": &"action_013_维修", "consume_original_card": true}},
		]}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_repair_self_damage"}},
	])
	w130.description = "我方回合1次，可以将1张行动牌当作维修打出，之后在此牌上设置2损伤。"
	effects[w130.effect_id] = w130

	# 131 我方回合主动：本回合动力+4，之后本牌自损1（34手持推进器）
	var w131 := _ActionEffect.new()
	w131.effect_id = &"equipment_effect_131"
	w131.display_name = "我方回合主动：本回合动力+4，之后本牌自损1"
	w131.mode = _TC.MODE_DIRECT
	w131.priority = 10
	w131.once_per_turn_key = &"weapon_034_boost"
	w131.once_per_turn_max = 1
	w131.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}])
	w131.set_target_rules([{"rule": &"NO_TARGET"}])
	w131.set_costs([])
	w131.set_actions([
		{"type": &"MODIFY_MECH_POWER", "params": {"target_id": "$binding_context.mech_id", "delta": 4, "mode": &"current_and_temporary_max", "duration": &"THIS_TURN"}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_power_boost_self_damage"}},
	])
	w131.description = "我方回合可以使机甲在本回合动力+4，之后在此牌上设置1损伤。"
	effects[w131.effect_id] = w131

	# 132 打出迎击牌时可使本回合动力+4并自损1（34）
	var w132 := _ActionEffect.new()
	w132.effect_id = &"equipment_effect_132"
	w132.display_name = "打出迎击牌时可使本回合动力+4并自损1"
	w132.mode = _TC.MODE_LISTEN
	w132.priority = 10
	w132.listen_timing = _TC.USE_ACTION_AT
	w132.listen_action_type = &"use_action_card"
	w132.once_per_turn_key = &"weapon_034_boost"
	w132.once_per_turn_max = 1
	w132.set_conditions([{"op": &"USED_CARD_OWNER_IS_SELF"}, {"op": &"USED_COUNTER_CARD"}])
	w132.set_target_rules([{"rule": &"NO_TARGET"}])
	w132.set_costs([])
	w132.set_actions([{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [{"label": "手持推进器：本回合动力+4并受1损伤", "actions": [
		{"type": &"MODIFY_MECH_POWER", "params": {"target_id": "$binding_context.mech_id", "delta": 4, "mode": &"current_and_temporary_max", "duration": &"THIS_TURN"}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_power_boost_self_damage"}},
	]}]}}])
	w132.description = "打出迎击牌时，可以使机甲在本回合动力+4，之后在此牌上设置1损伤。"
	effects[w132.effect_id] = w132

	# 133 强合金盾牌全量吸收并使转移损伤-1（35）
	var w133 := _ActionEffect.new()
	w133.effect_id = &"equipment_effect_133"
	w133.display_name = "强合金盾牌全量吸收并使转移损伤-1"
	w133.mode = _TC.MODE_LISTEN
	w133.priority = 20
	w133.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	w133.listen_action_type = &"damage_change"
	w133.set_conditions([{"op": &"SELF_MECH_IS_DAMAGE_TARGET"}, {"op": &"DAMAGE_SOURCE_IS_ATTACK_OR_TRAP"}, {"op": &"PAYLOAD_DAMAGE_TOKENS_ABOVE", "params": {"threshold": 0}}])
	w133.set_target_rules([{"rule": &"NO_TARGET"}])
	w133.set_costs([])
	w133.set_actions([{"type": &"OFFER_DAMAGE_REDIRECT", "params": {"max_points": -1, "mode": &"all_or_nothing", "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "reduction": 1, "min_points": 0, "optional": true}}])
	w133.description = "可以将每次攻击或陷阱产生的全部损伤设置到此牌上，并使此次设置的损伤-1。"
	effects[w133.effect_id] = w133

	# 134 每回合1次在武器范围内设置1陷阱，之后本牌自损1（36投掷式机雷）
	var w134 := _ActionEffect.new()
	w134.effect_id = &"equipment_effect_134"
	w134.display_name = "每回合1次在武器范围内设置1陷阱，之后本牌自损1"
	w134.mode = _TC.MODE_DIRECT
	w134.priority = 10
	w134.once_per_turn_key = &"weapon_036_trap"
	w134.once_per_turn_max = 1
	w134.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}, {"op": &"WEAPON_HAS_VALID_TRAP_CELL"}])
	w134.set_target_rules([{"rule": &"CHOOSE_MAP_CELL_IN_WEAPON_RANGE"}, {"rule": &"TARGET_CELL_CAN_HOLD_TRAP"}])
	w134.set_costs([])
	w134.set_actions([
		{"type": &"PLACE_OR_TRIGGER_TRAP", "params": {"mode": &"place", "cell_id": "$selected_cell_id", "count": 1, "source_mech_id": "$binding_context.mech_id", "source_card_instance_id": "$binding_context.card_instance_id"}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_trap_self_damage"}},
	])
	w134.description = "我方回合1次，可以在此牌攻击范围内的格子上设置1陷阱，之后在此牌上设置1损伤。"
	effects[w134.effect_id] = w134

	# 135 每回合1次：行动牌当维修，或弃2抽2；之后本牌自损2（37多功能机械臂）
	var w135 := _ActionEffect.new()
	w135.effect_id = &"equipment_effect_135"
	w135.display_name = "每回合1次：行动牌当维修，或弃2抽2；之后本牌自损2"
	w135.mode = _TC.MODE_DIRECT
	w135.priority = 10
	w135.once_per_turn_key = &"weapon_037_use"
	w135.once_per_turn_max = 1
	w135.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}, {"op": &"MULTI_ARM_HAS_AVAILABLE_OPTION"}])
	w135.set_target_rules([{"rule": &"NO_TARGET"}])
	w135.set_costs([])
	w135.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "将1张行动牌当作维修打出", "condition": {"op": &"REPAIR_BRANCH_AVAILABLE"}, "actions": [{"type": &"CHOOSE_MANY_CARDS", "params": {"filter": {"zone": &"action_hand", "owner_id": "$binding_context.mech_id"}, "min_count": 1, "max_count": 1, "label": "选择维修素材", "confirm_verb": "打出", "cancel_label": "返回", "per_card_actions": [
				{"type": &"DECLARE_CARD_TYPE", "params": {"card_instance_id": "$selected_card_instance_id", "declared_card_def_id": &"action_013_维修", "duration": &"UNTIL_USE_ACTION_SETTLE"}},
				{"type": &"EXECUTE_USE_ACTION_CARD", "params": {"card_instance_id": "$selected_card_instance_id", "acting_mech_id": "$binding_context.mech_id", "as_card_def_id": &"action_013_维修", "consume_original_card": true}},
			]}}]},
			{"label": "弃置2张行动牌，再抽2张", "condition": {"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}}, "actions": [
				{"type": &"EXECUTE_DISCARD", "params": {"from_target": "$binding_context.mech_id", "zone": &"action_hand", "count": 2, "choose": true, "chooser_id": "$binding_context.mech_id", "face_up": true, "reason": &"weapon_cycle"}},
				{"type": &"DRAW_ACTION", "params": {"target_id": "$binding_context.mech_id", "count": 2, "reason": &"weapon_cycle"}},
			]},
		]}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 2, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_multi_arm_self_damage"}},
	])
	w135.description = "我方回合1次，可以将1张行动牌当作维修打出或是弃置2张行动牌再抽2张，之后在此牌上设置2损伤。"
	effects[w135.effect_id] = w135

	# 136 月神合金盾牌全量吸收并使转移损伤-2（38）
	var w136 := _ActionEffect.new()
	w136.effect_id = &"equipment_effect_136"
	w136.display_name = "月神合金盾牌全量吸收并使转移损伤-2"
	w136.mode = _TC.MODE_LISTEN
	w136.priority = 20
	w136.listen_timing = &"DAMAGE_REDIRECT_WINDOW"
	w136.listen_action_type = &"damage_change"
	w136.set_conditions([{"op": &"SELF_MECH_IS_DAMAGE_TARGET"}, {"op": &"DAMAGE_SOURCE_IS_ATTACK_OR_TRAP"}, {"op": &"PAYLOAD_DAMAGE_TOKENS_ABOVE", "params": {"threshold": 0}}])
	w136.set_target_rules([{"rule": &"NO_TARGET"}])
	w136.set_costs([])
	w136.set_actions([{"type": &"OFFER_DAMAGE_REDIRECT", "params": {"max_points": -1, "mode": &"all_or_nothing", "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "reduction": 2, "min_points": 0, "optional": true}}])
	w136.description = "可以将每次攻击或陷阱产生的全部损伤设置到此牌上，并使此次设置的损伤-2。"
	effects[w136.effect_id] = w136

	# 137 每回合1次在范围内2个格子各放1陷阱，之后本牌自损1（39投掷式双子机雷）
	var w137 := _ActionEffect.new()
	w137.effect_id = &"equipment_effect_137"
	w137.display_name = "每回合1次在范围内2个格子各放1陷阱，之后本牌自损1"
	w137.mode = _TC.MODE_DIRECT
	w137.priority = 10
	w137.once_per_turn_key = &"weapon_039_trap"
	w137.once_per_turn_max = 1
	w137.set_conditions([{"op": &"IS_OWNER_MAIN_PHASE"}, {"op": &"WEAPON_HAS_VALID_TRAP_CELLS", "params": {"count": 2}}])
	w137.set_target_rules([{"rule": &"CHOOSE_TWO_DISTINCT_MAP_CELLS_IN_WEAPON_RANGE"}, {"rule": &"TARGET_CELL_CAN_HOLD_TRAP"}])
	w137.set_costs([])
	w137.set_actions([
		{"type": &"CHOOSE_MANY_MAP_CELLS", "params": {"count": 2, "distinct": true, "range_source_weapon_instance_id": "$binding_context.card_instance_id", "cell_rule": &"TARGET_CELL_CAN_HOLD_TRAP", "label": "选择2个格子设置陷阱"}},
		{"type": &"PLACE_OR_TRIGGER_TRAP", "params": {"mode": &"place_each", "cell_ids": "$selected_cell_ids", "count_each": 1, "source_mech_id": "$binding_context.mech_id", "source_card_instance_id": "$binding_context.card_instance_id"}},
		{"type": &"PLACE_DAMAGE_TOKENS", "params": {"count": 1, "target_mech_id": "$binding_context.mech_id", "target_slot": "$binding_context.slot_id", "target_card_instance_id": "$binding_context.card_instance_id", "executor_id": "$binding_context.mech_id", "reason": &"weapon_trap_self_damage"}},
	])
	w137.description = "我方回合1次，可以在此牌范围内的2个格子上各设置1陷阱，之后在此牌上设置1损伤。"
	effects[w137.effect_id] = w137

	# 138 威力实时变为当前护甲×2，范围实时变为当前动力（40）派生值型——不注册监听器
	var w138 := _ActionEffect.new()
	w138.effect_id = &"equipment_effect_138"
	w138.display_name = "威力实时变为当前护甲×2，范围实时变为当前动力"
	w138.mode = _TC.MODE_DIRECT
	w138.priority = 10
	w138.set_conditions([{"op": &"ALWAYS"}])
	w138.set_target_rules([{"rule": &"NO_TARGET"}])
	w138.set_costs([])
	w138.set_actions([])
	w138.description = "可以将此牌的威力变为机甲当前护甲数值*2，范围变为当前动力数值。"
	effects[w138.effect_id] = w138

	# 139 本牌攻击结算后弃置所有正面部件装备牌（40）
	var w139 := _ActionEffect.new()
	w139.effect_id = &"equipment_effect_139"
	w139.display_name = "本牌攻击结算后弃置所有正面部件装备牌"
	w139.mode = _TC.MODE_LISTEN
	w139.priority = 10
	w139.listen_timing = _TC.ATTACK_SETTLE
	w139.listen_action_type = &"attack"
	w139.set_conditions([{"op": &"ATTACK_SOURCE_IS_SELF"}])
	w139.set_target_rules([{"rule": &"NO_TARGET"}])
	w139.set_costs([])
	w139.set_actions([{"type": &"DISCARD_ALL_FACE_UP_PARTS", "params": {"target_mech_id": "$binding_context.mech_id", "slot_kinds": [&"HEAD", &"TORSO", &"RIGHT_ARM", &"LEFT_ARM", &"RIGHT_LEG", &"LEFT_LEG"], "reason": &"weapon_040_conversion_cost", "preserve_slot_damage": true}}])
	w139.description = "此牌发动攻击结算完成后，弃置机甲所有正面朝上的部件装备牌。"
	effects[w139.effect_id] = w139

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
		# 排除备用区（用户裁定：联邦/帝国头部计数只含部件区+武器区，排除整个备用区）
		if String(sid).begins_with("reserve"):
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


## 头部阵营护甲加成（get_armor 调用，门控 by 头部 effect_id）：
## effect_002（联邦普装头）：其他区域联邦装备数（排除自身）
## effect_066（联邦圣牛头）：机甲所有联邦装备数（含自身）
static func compute_head_faction_armor_bonus(mech) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var head_slot = mech.slots.get(&"头部")
	if head_slot == null:
		return 0
	var head_card = head_slot.get("equipped_card")
	if not is_equipment_active(head_card):
		return 0
	if _card_has_effect_id(head_card, &"equipment_effect_066"):
		return count_faction_equipment(mech, &"", "联邦")  # 含自身（exclude=&"" 不排除任何槽）
	if _card_has_effect_id(head_card, &"equipment_effect_002"):
		return count_faction_equipment(mech, &"头部", "联邦")  # 其他区域
	return 0


## 头部阵营动力上限加成（get_total_power 调用，门控 by 头部 effect_id）：
## effect_008（帝国普装头）：其他区域帝国装备数（排除自身）
## effect_070（帝国雄鹰头）：机甲所有帝国装备数（含自身）
static func compute_head_faction_power_bonus(mech) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var head_slot = mech.slots.get(&"头部")
	if head_slot == null:
		return 0
	var head_card = head_slot.get("equipped_card")
	if not is_equipment_active(head_card):
		return 0
	if _card_has_effect_id(head_card, &"equipment_effect_070"):
		return count_faction_equipment(mech, &"", "帝国")  # 含自身
	if _card_has_effect_id(head_card, &"equipment_effect_008"):
		return count_faction_equipment(mech, &"头部", "帝国")  # 其他区域
	return 0


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


## 返回某 slot 装备因"损伤不影响护甲"效果而应扣减的 region_damage 数量（0=免疫，region_damage=正常扣减）
## 由 MechSlotState.get_effective_armor(mech) 调用：
##   effect_014（重甲左臂/右腿/左腿）：无条件免疫 -> 0
##   effect_089（重甲头部）：机甲部件总损伤 < 3 时免疫 -> 0；≥3 时正常扣减
##   无以上效果：正常扣减 region_damage
## Phase 2 将扩展：总损伤≥4（超重甲头部）、此牌损伤≥2/≥3（超重甲臂腿/轰雷）等阈值变体。
static func card_damage_immune_armor_amount(card, mech, region_damage: int) -> int:
	if not is_equipment_active(card):
		return region_damage
	if _card_has_effect_id(card, &"equipment_effect_014"):
		return 0  # 此牌所在区域无条件免疫（重甲左臂/右腿/左腿）
	# 机甲头部光环：重甲头部(089)/超重甲头部(046)保护机甲【所有】部件区域，
	# 总损伤 < 阈值时全域免疫（文档"机甲区域提供的护甲"= 全部 6 个部件区域，非仅头部）。
	# 头部自身也由此光环覆盖；mech==null（UI 未传）时跳过光环走下方 per-card 退路。
	if mech != null:
		if _mech_head_has_effect(mech, &"equipment_effect_089") and _mech_total_part_damage(mech) < 3:
			return 0
		if _mech_head_has_effect(mech, &"equipment_effect_046") and _mech_total_part_damage(mech) < 4:
			return 0
	if _card_has_effect_id(card, &"equipment_effect_089"):
		# 头部自身：mech!=null 已被上方光环覆盖；mech==null 保守按正常扣减
		if mech != null and _mech_total_part_damage(mech) < 3:
			return 0
		return region_damage
	if _card_has_effect_id(card, &"equipment_effect_046"):
		# 超重甲头部：机甲部件总损伤 < 4 时免疫；≥4 失效（一次性计入全部已有损伤）
		if mech != null and _mech_total_part_damage(mech) < 4:
			return 0
		return region_damage
	if _card_has_effect_id(card, &"equipment_effect_049"):
		# 超重甲臂/腿：此牌上损伤 < 2 时免疫；≥2 时保护失效，扣该槽全部 region_damage
		var _d049: int = int(card.damage_tokens) if (card != null and card.get("damage_tokens")) else 0
		if _d049 < 2:
			return 0
		return region_damage
	if _card_has_effect_id(card, &"equipment_effect_074"):
		# 轰雷装：此牌上损伤 < 3 时免疫；≥3 时保护失效，扣该槽全部 region_damage（仿 effect_049 阈值3）
		var _d074: int = int(card.damage_tokens) if (card != null and card.get("damage_tokens")) else 0
		if _d074 < 3:
			return 0
		return region_damage
	return region_damage


## 机甲头部是否装备了指定效果（重甲头部 089 / 超重甲头部 046 光环判定用）
static func _mech_head_has_effect(mech, effect_id: StringName) -> bool:
	if mech == null or mech.get("slots") == null:
		return false
	var head = mech.slots.get(&"头部")
	if head == null:
		return false
	var c = head.get("equipped_card")
	return is_equipment_active(c) and _card_has_effect_id(c, effect_id)


## 机甲 6 个部件槽的【区域】损伤总数，用于重甲头部"总损伤≥3"/超重甲头部"<4"判定。
## 损伤放置为 region+card 双计：region_damage_tokens 代表区域真实损伤标记数，
## card.damage_tokens 是装备牌归属/耐久判定用的镜像。"机甲部件总损伤数"指区域级
## 损伤总数，故只统计 region_damage_tokens；若再累加 card 会双计翻倍（放1个算成2），
## 致重甲头部 <3 阈值在 2 个损伤时（算成4）误判失效。
static func _mech_total_part_damage(mech) -> int:
	if mech == null or mech.get("slots") == null:
		return 0
	var total: int = 0
	for sid: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		var slot = mech.slots.get(sid)
		if slot == null:
			continue
		total += int(slot.region_damage_tokens) if "region_damage_tokens" in slot else 0
	return total


## 全场阵营装备光环（effect_080 联邦护甲 / effect_086 帝国动力）：
## 场上每有1张正面设置的来源头（effect_080/effect_086），所有名称含该阵营的正面装备牌额外+1。
## queried_card 为被查询的装备牌实例；faction=联邦->effect_080护甲, 帝国->effect_086动力。
## 由 MechSlotState.get_effective_armor(联邦)/get_effective_power(帝国) 调用。避免递归：只查 effect_id 不查护甲。
static func get_global_faction_equipment_aura_bonus(queried_card, faction: String) -> int:
	if not is_equipment_active(queried_card):
		return 0
	var qname: String = String(queried_card.def.get("display_name"))
	if qname.find(faction) < 0:
		return 0  # 只有名称含阵营的装备受益
	var aura_effect: StringName = &"equipment_effect_080" if faction == "联邦" else &"equipment_effect_086"
	if _aura_game_state == null:
		return 0
	var count: int = 0
	for mech_id in _aura_game_state.mechs:
		var mech = _aura_game_state.mechs[mech_id]
		if mech == null or mech.get("slots") == null:
			continue
		for sid in mech.slots:
			var slot = mech.slots[sid]
			if slot == null:
				continue
			var c = slot.get("equipped_card")
			if is_equipment_active(c) and _card_has_effect_id(c, aura_effect):
				count += 1
	return count


## 装备牌虚拟武器（effect_087 帝国的神莺·躯干）：本牌可当作威力20范围6的远程武器。
## 由武器选择面板/攻击可用性预检调用（current_power>0 才可选）。返回虚拟武器条目，非本牌返回 {}。
## 注意：武器选择面板与攻击武器解析的接入待实机/F3 补（当前 effect_087 为权限型占位）。
static func get_virtual_weapon_from_equipment(card) -> Dictionary:
	if not is_equipment_active(card):
		return {}
	if not _card_has_effect_id(card, &"equipment_effect_087"):
		return {}
	return {
		"source_card_id": card.instance_id,
		"display_name": String(card.def.get("display_name")),
		"weapon_kind": &"远程",
		"might": 20,
		"range_value": 6,
		"is_virtual": true,
	}


## 狙击装·头部被动远程武器范围加成（派生值实时重算）
## effect_022（狙击装·头部）远程武器范围+1 / effect_055（狙击影装·头部 / 轰雷装·头部）远程武器范围+2
## 由 app_root._get_weapon_range（攻击预检查）与 attack_action._step_select_weapon（存入
## record["weapon_range"]，命中/选目标校验/高亮自动含之）调用。仅远程武器生效。
## effect_022/055 已改为派生占位（mode=DIRECT，不注册 listener），与此 helper 配合，
## 避免与旧的 MODIFY_ATTACK_RANGE 路径双计。机甲仅1个头部，故用基础 weapon_kind 即可
## （无其他头部效果会改写远程武器类型）。
static func get_passive_weapon_range_bonus(mech, weapon_kind) -> int:
	if String(weapon_kind) != "远程":
		return 0
	if mech == null or mech.get("slots") == null:
		return 0
	var head = mech.slots.get(&"头部")
	if head == null:
		return 0
	var c = head.get("equipped_card")
	if not is_equipment_active(c):
		return 0
	if _card_has_effect_id(c, &"equipment_effect_055"):
		return 2
	if _card_has_effect_id(c, &"equipment_effect_022"):
		return 1
	return 0


## ── 武器装备牌统一威力/范围查询（effect_093+ 用）──
## 所有武器威力/范围查询入口（attack_action._get_weapon_stats / weapon_picker_panel /
## equipment_panel / 范围预检 / 最大范围预估）统一调用此函数，禁用牌面直读。
## 返回 {might, range_value, weapon_kind, weapon_name, is_virtual}。
## 不含狙击装·头部远程范围加成（由调用方 get_passive_weapon_range_bonus 单独加，避双计）。
static func get_effective_weapon_stats(card) -> Dictionary:
	if card == null or card.def == null:
		return {"might": 0, "range_value": 1, "weapon_kind": &"", "weapon_name": &"", "is_virtual": false}
	# 虚拟武器（神莺躯干 effect_087）基础值
	var vw = get_virtual_weapon_from_equipment(card)
	var base_might: int
	var base_range: int
	var wkind: StringName
	var wname: StringName
	var is_virt: bool = false
	if not vw.is_empty():
		base_might = int(vw.get("might", 20))
		base_range = int(vw.get("range_value", 6))
		wkind = vw.get("weapon_kind", &"远程")
		wname = StringName(vw.get("display_name", &""))
		is_virt = true
	else:
		base_might = int(card.def.might) if "might" in card.def else 0
		base_range = int(card.def.range_value) if "range_value" in card.def else 1
		wkind = card.def.weapon_kind if "weapon_kind" in card.def else &""
		wname = card.def.display_name if "display_name" in card.def else &""

	var might: int = base_might
	var range: int = base_range

	# 派生值型：effect_138 质能全转换（40）威力=max(0,armor*2) 范围=max(0,current_power)
	# 替代牌面 1/1，之后再叠加下方修正。
	if _card_has_effect_id(card, &"equipment_effect_138"):
		var ec_mech = _get_card_mech(card)
		if ec_mech != null:
			might = max(0, int(ec_mech.get_armor()) * 2)
			range = max(0, int(ec_mech.power))
		else:
			might = 0
			range = 0

	# 持久/临时修正（聚能 effect_093/095 临时 +3/+1、其他 might_modifiers/range_modifiers）
	might += _sum_weapon_modifiers(card, &"might")
	range += _sum_weapon_modifiers(card, &"range")

	# 派生值型：effect_120 每1自损威力-2（26/27 大型光束炮/热能加特林）
	if _card_has_effect_id(card, &"equipment_effect_120"):
		might += get_weapon_might_by_self_damage(card, 0)

	# 形态修正（流星钢锤 effect_098/099 extended: might-5, range+2）
	var mode: StringName = card.weapon_mode if "weapon_mode" in card else &""
	if mode == &"":
		mode = &"normal"
	if mode == &"extended":
		might -= 5
		range += 2

	might = max(0, might)
	range = max(0, range)
	return {"might": might, "range_value": range, "weapon_kind": wkind, "weapon_name": wname, "is_virtual": is_virt}


## 武器 might/range 修正列表求和（might_modifiers / range_modifiers）
## 每项 {delta, duration, bucket}。THIS_OWNER_TURN/THIS_TURN 项由 TurnService 回合结束清除，
## 故查询时列表中所有项均生效，直接求和。
static func _sum_weapon_modifiers(card, kind: StringName) -> int:
	if card == null:
		return 0
	var arr: Array = card.might_modifiers if (kind == &"might" and "might_modifiers" in card) else (card.range_modifiers if (kind == &"range" and "range_modifiers" in card) else [])
	var total: int = 0
	for m in arr:
		if m is Dictionary:
			total += int(m.get("delta", 0))
	return total


## 取卡牌所属机甲（经 _aura_game_state 查 card.mech_id）
static func _get_card_mech(card):
	if card == null or _aura_game_state == null:
		return null
	var mid: StringName = card.mech_id if "mech_id" in card else &""
	if mid == &"":
		return null
	return _aura_game_state.mechs.get(mid)


## effect_120（26/27）每1自损威力-2。统计本牌承受的损伤数（card.damage_tokens）。
## printed_might 参数仅用于兼容旧签名，实际返回 -2*damage_tokens（调用方加到 might）。
static func get_weapon_might_by_self_damage(card, printed_might: int) -> int:
	if card == null:
		return 0
	var tokens: int = int(card.damage_tokens) if card.get("damage_tokens") else 0
	return -2 * tokens


## effect_138（40 质能全转换）派生值：返回 {might, range}（已含 max(0,*) 钳制）
## 供 UI 预览等需要单独查询时使用；get_effective_weapon_stats 已内含此逻辑。
static func get_energy_conversion_weapon_stats(card) -> Dictionary:
	var mech = _get_card_mech(card)
	if mech == null:
		return {"might": 0, "range": 0}
	return {"might": max(0, int(mech.get_armor()) * 2), "range": max(0, int(mech.power))}


## 流星钢锤形态修正（extended: might-5, range+2）。get_effective_weapon_stats 已内含；
## 此函数供需要单独应用形态修正的场景（如刷新当前 attack 基础值）。
static func apply_weapon_mode_modifier(card, stats: Dictionary) -> Dictionary:
	if card == null:
		return stats
	var mode: StringName = card.weapon_mode if "weapon_mode" in card else &""
	if mode == &"":
		mode = &"normal"
	if mode == &"extended":
		stats["might"] = max(0, int(stats.get("might", 0)) - 5)
		stats["range_value"] = max(0, int(stats.get("range_value", 0)) + 2)
	return stats


## 判断某 slot 的装备是否有"损伤≥阈值时动力+1"或"每损伤+1动力"效果
## effect_016（重甲右臂，阈值≥1 +1）/ effect_021（机动右腿/左腿，每损伤 +1，逐点）
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
	# 牌上损伤（装备时损伤挂在 equipped_card.damage_tokens）
	var card_damage: int = int(card.damage_tokens) if (card != null and card.get("damage_tokens")) else 0
	var any_damage: int = max(region_damage, card_damage)
	# effect_016 重甲装·右臂：此牌损伤≥1时动力+1（阈值型，固定+1）
	if _card_has_effect_id(card, &"equipment_effect_016") and any_damage >= 1:
		return 1
	# effect_021 机动装·右腿/左腿：此牌上每设置1损伤动力+1（逐点型，=牌上损伤数）
	if _card_has_effect_id(card, &"equipment_effect_021"):
		return card_damage
	# effect_048 超重甲·右臂：此牌损伤≥2时动力+2（阈值型，固定+2）
	if _card_has_effect_id(card, &"equipment_effect_048") and any_damage >= 2:
		return 2
	# effect_092 轰雷·右臂：此牌损伤≥2时动力+3（阈值型，固定+3）
	if _card_has_effect_id(card, &"equipment_effect_092") and any_damage >= 2:
		return 3
	return 0


## 判断 card 的 def 是否绑定某 effect_id（查 _card_effect_map）
static func _card_has_effect_id(card, effect_id: StringName) -> bool:
	if card == null or card.def == null:
		return false
	# 效果被压制（NEGATE_EQUIPMENT_EFFECT）的装备：自身派生值/效果不生效（保留牌面 stats）
	if card.get("effect_negated") == true:
		return false
	if not _initialized:
		return false  # map 未加载，保守返回 false（效果不生效）
	var eids = _card_effect_map.get(card.def.card_id, [])
	return effect_id in eids
