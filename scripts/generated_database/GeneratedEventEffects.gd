## GeneratedEventEffects.gd - 20张事件牌效果定义 + 事件派生加成 registry
##
## 按 new_logic/事件牌信息.txt 定义全部20张事件牌（event_001~020）共27个效果
## （event_effect_001~027；任务牌计数 017~021 各配对一个 DIRECT 主动奖励效果
##  022机动10/024歼灭1/025赏金8/026执行4/027整备3，参数化 builder 生成）。
## 与装备/机师效果同一 ActionEffect 体系，效果只绑 effect_id 不绑卡：
##   - DIRECT 模式：事件牌主动效果（招募花2金抽机师、悬赏弃牌获金），事件槽行「触发」按钮
##   - LISTEN 模式：监听时点（设置时结算/回合结束/被攻击命中/计时到期等）
##   - AVAILABILITY 模式：本批无
##
## 注册方式：事件牌被 set_event_card 动作设置到事件区域后，由 set_event_card_action.
## _register_event_effects 查本表 get_effects_for_card 并 register_permanent_listener。
## 弃置/被顶掉时注销（discard_card_action event 分支）。效果只在牌设置到事件区域后生效。
##
## 派生型效果（陷落限制/强化数值）不注册监听器：
##   - 陷落限制：get_status_grants_for_effect 声明状态表，set_event_card activate 时施加
##     （带 source_card_id），弃置时按来源清除。
##   - 强化数值：get_derived_bonus_for_effect 声明数值表，set_event_card activate 时聚合
##     存入 _derived_registry（按 mech_id），MechState.get_armor/get_total_power 与武器统计
##     查询点实时读取，牌离场 unregister 自动失效。
## 复用：任何牌的 effect_ids 含这些 effect_id 即生效；复制效果定义 + 数值/状态表条目即可复用。
class_name GeneratedEventEffects
extends RefCounted

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")

## ── 计时方式枚举（EventCardDef.timer_mode） ──
const TIMER_MODE_INSTANT := &"instant"                ## 设置时即刻生效并结算
const TIMER_MODE_EVERY_TURN_END := &"every_turn_end"  ## 从当前回合开始，每个回合结束后-1
const TIMER_MODE_OWN_TURN_END := &"own_turn_end"      ## 从当前回合开始，只在我方回合结束后-1
const TIMER_MODE_NEXT_OWN_TURN_END := &"next_own_turn_end"   ## 从下一个我方回合开始，只在我方回合结束后-1
const TIMER_MODE_NEXT_OWN_TURN_START := &"next_own_turn_start" ## 从下一个我方回合开始，我方回合开始时-1

## card_def_id -> effect_id 列表 映射（由 CardDatabaseLoader effect_ids 提供）
static var _card_effect_map: Dictionary = {}
static var _initialized: bool = false

## 事件派生加成 registry：mech_id -> {armor, power, weapon_might, weapon_range}
## 由 set_event_card_action activate 注册 / discard 注销；查询点实时读取。
static var _derived_registry: Dictionary = {}


## 获取牌的效果ID列表（用于 set_event_card_action 注册）
static func get_effects_for_card(card_def_id: StringName, context = null) -> Array:
	if not _initialized and context != null:
		_try_load_map_from_context(context)
	return _card_effect_map.get(card_def_id, [])


## 从 context 尝试加载 effect_ids（懒加载，同 GeneratedEquipmentEffects 模式）。
## CardDatabaseLoader 的通用 get_effect_ids_map() 已包含事件牌（_load_event_card 也走
## _record_effect_ids），直接复用，card_id 命名空间（event_*）不与装备/机师冲突。
static func _try_load_map_from_context(context) -> void:
	if context == null:
		return
	var cdb = context.get("card_database") if context is Dictionary else context.card_database
	if cdb == null:
		return
	if cdb.get("loader") != null:
		var ev_map: Dictionary = cdb.loader.get_effect_ids_map()
		for k in ev_map:
			_card_effect_map[k] = ev_map[k]
	elif cdb.has_method("get_effect_ids_map"):
		var ev_map2: Dictionary = cdb.get_effect_ids_map()
		for k in ev_map2:
			_card_effect_map[k] = ev_map2[k]
	_initialized = true


## 按 effect_id 取效果定义（事件槽 tooltip / 注册用）
static func get_effect_by_id(effect_id: StringName):
	return build_event_effects().get(effect_id, null)


# ═══════════════════════════════════════════
# 派生型效果数据表（设置期间持续，离场失效）
# ═══════════════════════════════════════════

## 状态授予表：effect_id -> [status_type, ...]
## 设置期间持续施加（带 source_card_id=牌实例id），弃置/顶掉时按来源清除。
## 陷落 effect_006：不能移动/攻击/被选为目标。
static func get_status_grants_for_effect(effect_id: StringName) -> Array:
	match effect_id:
		&"event_effect_006":
			return [&"cannot_move", &"cannot_attack", &"cannot_be_targeted"]
		_:
			return []


## 数值加成表：effect_id -> {armor / power / weapon_might / weapon_range}
## 强化 effect_013~016（护甲+5/动力+4/威力+4/范围+2，全部武器生效）。
static func get_derived_bonus_for_effect(effect_id: StringName) -> Dictionary:
	match effect_id:
		&"event_effect_013":
			return {"armor": 5}
		&"event_effect_014":
			return {"power": 4}
		&"event_effect_015":
			return {"weapon_might": 4}
		&"event_effect_016":
			return {"weapon_range": 2}
		_:
			return {}


## 派生型效果集合（不注册监听器：数值实时重算 / 状态随设置-离场管理）
static func is_derived_effect(effect_id: StringName) -> bool:
	return get_derived_bonus_for_effect(effect_id).size() > 0 \
		or get_status_grants_for_effect(effect_id).size() > 0


# ═══════════════════════════════════════════
# 派生 registry 注册/注销/查询（set_event_card_action 与 discard_card_action 调用）
# ═══════════════════════════════════════════

## 注册一张事件牌的全部派生数值加成到 mech（activate 步骤调用）
static func register_derived_bonuses(card, mech_id: StringName) -> void:
	if card == null or card.def == null or mech_id == &"":
		return
	var effect_ids: Array = get_effects_for_card(card.def.card_id, null)
	var total: Dictionary = _derived_registry.get(mech_id, {})
	for eid_raw in effect_ids:
		var bonus: Dictionary = get_derived_bonus_for_effect(StringName(eid_raw))
		for k in bonus:
			total[k] = int(total.get(k, 0)) + int(bonus[k])
	_derived_registry[mech_id] = total


## 注销机甲的事件派生加成（事件牌弃置/顶掉时调用）
static func unregister_derived_bonuses(mech_id: StringName) -> void:
	_derived_registry.erase(mech_id)


static func get_armor_bonus(mech_id: StringName) -> int:
	return int(_derived_registry.get(mech_id, {}).get("armor", 0))


static func get_power_bonus(mech_id: StringName) -> int:
	return int(_derived_registry.get(mech_id, {}).get("power", 0))


static func get_weapon_might_bonus(mech_id: StringName) -> int:
	return int(_derived_registry.get(mech_id, {}).get("weapon_might", 0))


static func get_weapon_range_bonus(mech_id: StringName) -> int:
	return int(_derived_registry.get(mech_id, {}).get("weapon_range", 0))


## 施加事件牌声明的状态（activate 步骤调用；带 source_card_id 供离场清除）
static func apply_status_grants(context, card, mech_id: StringName) -> void:
	if context == null or context.game_actions == null or card == null or card.def == null:
		return
	if not context.game_state.mechs.has(mech_id):
		return
	var effect_ids: Array = get_effects_for_card(card.def.card_id, context)
	for eid_raw in effect_ids:
		for st_type in get_status_grants_for_effect(StringName(eid_raw)):
			# GameActions.add_status 期望 {mech_id, status:{type,...}}；
			# source_card_id 放 status 内（remove_status_by_source_card 读 s.source_card_id）
			context.game_actions.add_status({
				"mech_id": mech_id,
				"status": {"type": st_type, "source_card_id": card.instance_id},
			})


## 按来源牌清除事件状态（弃置/顶掉时调用；清所有机甲上以该牌为来源的状态）
static func remove_status_by_source_card(context, card_instance_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	for mech_id: StringName in context.game_state.mechs:
		var mech = context.game_state.mechs[mech_id]
		if mech == null or not "statuses" in mech:
			continue
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return s.get("source_card_id", &"") != card_instance_id)


# ═══════════════════════════════════════════
# 效果定义
# ═══════════════════════════════════════════

## 构建所有事件牌效果定义，返回 { effect_id: ActionEffect }
static func build_event_effects() -> Dictionary:
	var effects: Dictionary = {}

	# ═══════════════════════════════════════════
	# 001 增援：设置时抽2行动+1装备；我方回合外抽到的装备不立即设置则直接弃置
	# （我方回合内抽到则留装备手牌，回合结束统一弃未设置装备）
	# ═══════════════════════════════════════════
	var e001 := _ActionEffect.new()
	e001.effect_id = &"event_effect_001"
	e001.display_name = "增援"
	e001.mode = _TC.MODE_LISTEN
	e001.priority = 10
	e001.listen_timing = _TC.EVENT_RESOLVE
	e001.set_conditions([{"op": &"PAYLOAD_EVENT_CARD_IS_SELF"}])
	e001.set_target_rules([{"rule": &"NO_TARGET"}])
	e001.set_costs([])
	e001.set_actions([
		{"type": &"EXECUTE_GAIN_CARD", "params": {
			"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
			"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
			"reason": &"event_001_reinforce"}},
		# 抽1装备 + 弹"立即设置"窗：取消=直接弃置（不设置则弃置的规则语义）。
		# only_off_turn=true：我方回合内抽到的装备牌留手牌不弹窗（回合结束统一弃未设置装备）。
		{"type": &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET", "params": {
			"only_off_turn": true, "reason": &"event_001_reinforce"}},
	])
	e001.description = "抽2张行动牌与1张装备牌（我方回合外抽取装备牌时，若不立即设置则需要直接弃置）。"
	effects[e001.effect_id] = e001

	# ═══════════════════════════════════════════
	# 002 敌袭：设置时选择 弃2行动牌 或 我方机甲区域设置2损伤（位置自选）
	# ═══════════════════════════════════════════
	var e002 := _ActionEffect.new()
	e002.effect_id = &"event_effect_002"
	e002.display_name = "敌袭"
	e002.mode = _TC.MODE_LISTEN
	e002.priority = 10
	e002.listen_timing = _TC.EVENT_RESOLVE
	e002.set_conditions([{"op": &"PAYLOAD_EVENT_CARD_IS_SELF"}])
	e002.set_target_rules([{"rule": &"NO_TARGET"}])
	e002.set_costs([])
	e002.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"options": [
			{"label": "弃置2张行动牌",
				"condition": [{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}}],
				"actions": [
					{"type": &"CHOOSE_MANY_CARDS", "params": {
						"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2,
						"store_result_key": "event_002_discard", "discard_selected": false,
						"owner_from_binding": true, "no_cancel": true,
						"label": "选择要弃置的2张行动牌", "confirm_verb": "弃置"}},
					{"type": &"EXECUTE_DISCARD", "params": {
						"card_ids": "$runtime.event_002_discard", "reason": &"event_002_raid"}},
				]},
			{"label": "我方机甲区域设置2损伤（位置自选）",
				"actions": [{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
					"mech_ids": ["$binding_context.mech_id"], "value": 2, "method": &"increase",
					"executor": "$binding_context.player_id", "reason": &"event_002_raid",
					"source_label": "敌袭：设置2损伤"}}]},
		]}},
	])
	e002.description = "选择弃置2张行动牌或我方机甲区域设置2损伤（位置由我方指定）。"
	effects[e002.effect_id] = e002

	# ═══════════════════════════════════════════
	# 003 遭遇·联邦 / 004 遭遇·帝国：设置时按阵营分支（缺阵营=惩罚分支/有阵营=奖励分支）
	# 同一 builder 参数化（faction 复用时改参数即可）
	# ═══════════════════════════════════════════
	effects[&"event_effect_003"] = _build_encounter_effect(&"event_effect_003", &"联邦")
	effects[&"event_effect_004"] = _build_encounter_effect(&"event_effect_004", &"帝国")

	# ═══════════════════════════════════════════
	# 005 拾荒：每当回合即将结束，可弃1行动牌抽1装备并立即设置（不设置则弃置）
	# ═══════════════════════════════════════════
	var e005 := _ActionEffect.new()
	e005.effect_id = &"event_effect_005"
	e005.display_name = "拾荒"
	e005.mode = _TC.MODE_LISTEN
	e005.priority = 10
	e005.listen_timing = _TC.TURN_BEFORE_END
	e005.set_conditions([{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}}])
	e005.set_target_rules([{"rule": &"NO_TARGET"}])
	e005.set_costs([])
	e005.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": 1,
			"store_result_key": "event_005_discard", "discard_selected": false,
			"owner_from_binding": true,
			"label": "弃置1张行动牌以捡拾装备", "confirm_verb": "弃置", "cancel_label": "不弃置"}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.event_005_discard", "reason": &"event_005_scavenge"}},
		# 抽1装备 + 弹"立即设置"窗：取消=直接弃置（不设置则弃置的规则语义）。
		# 回合结束弹此窗：无论是否我方回合，不立即设置的装备牌都要弃置，语义一致。
		{"type": &"DRAW_EQUIPMENT_AND_IMMEDIATELY_SET", "params": {
			"reason": &"event_005_scavenge"}},
	])
	e005.description = "每当回合即将结束，可以弃置1张行动牌，抽1张装备牌，并设置到区域上（若不立即设置则需要直接弃置）。"
	effects[e005.effect_id] = e005

	# ═══════════════════════════════════════════
	# 006 陷落·限制：派生型（状态表声明 cannot_move/cannot_attack/cannot_be_targeted，
	# 设置期间持续，离场按 source_card_id 清除）。DIRECT 占位无 actions：不注册不建按钮，
	# 仅 tooltip 查询用。
	# ═══════════════════════════════════════════
	var e006 := _ActionEffect.new()
	e006.effect_id = &"event_effect_006"
	e006.display_name = "陷落·限制"
	e006.mode = _TC.MODE_DIRECT
	e006.priority = 10
	e006.set_conditions([])
	e006.set_target_rules([{"rule": &"NO_TARGET"}])
	e006.set_costs([])
	e006.set_actions([])
	e006.description = "机甲不能再移动和发动攻击，也不能被选为攻击目标。"
	effects[e006.effect_id] = e006

	# ═══════════════════════════════════════════
	# 007 陷落·到期抽新：计时结束时可抽1张新事件牌设置（EXECUTE_SET_EVENT_CARD 会顶掉本牌）
	# ═══════════════════════════════════════════
	var e007 := _ActionEffect.new()
	e007.effect_id = &"event_effect_007"
	e007.display_name = "陷落·到期抽新"
	e007.mode = _TC.MODE_LISTEN
	e007.priority = 10
	e007.listen_timing = _TC.EVENT_TIMER_EXPIRE
	e007.set_conditions([{"op": &"PAYLOAD_EVENT_CARD_IS_SELF"}])
	e007.set_target_rules([{"rule": &"NO_TARGET"}])
	e007.set_costs([])
	e007.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "抽1张新事件牌设置到区域上",
				"actions": [{"type": &"EXECUTE_SET_EVENT_CARD", "params": {
					"mech_id": "$binding_context.mech_id"}}]},
		]}},
	])
	e007.description = "此牌计时结束时，可以抽1张新的事件牌设置在区域上。"
	effects[e007.effect_id] = e007

	# ═══════════════════════════════════════════
	# 008 招募·主动：我方回合1次，花2金币从机师牌堆抽1张并设置（不设置则放牌堆底）
	# ═══════════════════════════════════════════
	var e008 := _ActionEffect.new()
	e008.effect_id = &"event_effect_008"
	e008.display_name = "招募机师"
	e008.mode = _TC.MODE_DIRECT
	e008.priority = 10
	e008.once_per_turn_key = &"event_effect_008"
	e008.once_per_turn_max = 1
	e008.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"GOLD_ABOVE", "threshold": 1},
	])
	e008.set_target_rules([{"rule": &"NO_TARGET"}])
	e008.set_costs([{"cost_type": &"SPEND_GOLD", "amount": 2}])
	e008.set_actions([
		{"type": &"DRAW_PILOT_SET_TO_SLOT_OR_DECK_BOTTOM", "params": {}},
	])
	e008.description = "我方回合1次，可以花费2金币，从机师牌堆中抽1张牌，并设置到区域上（若不立即设置则放入牌堆底）。"
	effects[e008.effect_id] = e008

	# ═══════════════════════════════════════════
	# 009 悬赏·主动：我方回合1次，弃1行动牌获2金币
	# ═══════════════════════════════════════════
	var e009 := _ActionEffect.new()
	e009.effect_id = &"event_effect_009"
	e009.display_name = "悬赏"
	e009.mode = _TC.MODE_DIRECT
	e009.priority = 10
	e009.once_per_turn_key = &"event_effect_009"
	e009.once_per_turn_max = 1
	e009.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}},
	])
	e009.set_target_rules([{"rule": &"NO_TARGET"}])
	e009.set_costs([])
	e009.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": 1,
			"store_result_key": "event_009_discard", "discard_selected": false,
			"owner_from_binding": true,
			"label": "弃置1张行动牌换取2金币", "confirm_verb": "弃置", "cancel_label": "取消"}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.event_009_discard", "reason": &"event_009_bounty"}},
		{"type": &"GAIN_GOLD", "params": {
			"player_id": "$binding_context.player_id", "amount": 2, "reason": &"event_009_bounty"}},
	])
	e009.description = "我方回合1次，可以弃置1张行动牌，获得2金币。"
	effects[e009.effect_id] = e009

	# ═══════════════════════════════════════════
	# 010 悬赏·被命中：我方被攻击命中时，攻击方获得2金币
	# ═══════════════════════════════════════════
	var e010 := _ActionEffect.new()
	e010.effect_id = &"event_effect_010"
	e010.display_name = "悬赏·被命中"
	e010.mode = _TC.MODE_LISTEN
	e010.priority = 10
	e010.listen_timing = _TC.ATTACK_AFTER
	e010.set_conditions([
		{"op": &"SELF_MECH_IS_ATTACK_TARGET"},
		{"op": &"PAYLOAD_ATTACK_HIT"},
	])
	e010.set_target_rules([{"rule": &"NO_TARGET"}])
	e010.set_costs([])
	e010.set_actions([
		{"type": &"GAIN_GOLD", "params": {
			"mech_id": "$payload.attacker_id", "amount": 2, "reason": &"event_009_bounty_hit"}},
	])
	e010.description = "我方被攻击命中时，攻击方获得2金币。"
	effects[e010.effect_id] = e010

	# ═══════════════════════════════════════════
	# 011 宝藏：每当回合即将结束，可弃1行动牌投1骰子获金（1~3=3金 / 4~5=4金 / 6=6金）
	# ═══════════════════════════════════════════
	var e011 := _ActionEffect.new()
	e011.effect_id = &"event_effect_011"
	e011.display_name = "宝藏"
	e011.mode = _TC.MODE_LISTEN
	e011.priority = 10
	e011.listen_timing = _TC.TURN_BEFORE_END
	e011.set_conditions([{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 1}}])
	e011.set_target_rules([{"rule": &"NO_TARGET"}])
	e011.set_costs([])
	e011.set_actions([
		{"type": &"CHOOSE_MANY_CARDS", "params": {
			"source": &"OWNER_ACTION_HAND", "min_count": 1, "max_count": 1,
			"store_result_key": "event_011_discard", "discard_selected": false,
			"owner_from_binding": true,
			"label": "弃置1张行动牌寻宝（投1骰子）", "confirm_verb": "弃置", "cancel_label": "不弃置"}},
		{"type": &"EXECUTE_DISCARD", "params": {
			"card_ids": "$runtime.event_011_discard", "reason": &"event_011_treasure"}},
		{"type": &"GAIN_GOLD_BY_DIE", "params": {
			"player_id": "$binding_context.player_id", "reason": &"event_011_treasure",
			"branches": [[1, 3, 3], [4, 5, 4], [6, 6, 6]],
			"source_label": "宝藏寻宝"}},
	])
	e011.description = "每当回合即将结束，可以弃置1张行动牌，投掷1骰子：点数1~3获得3金币，4~5获得4金币，6获得6金币。"
	effects[e011.effect_id] = e011

	# ═══════════════════════════════════════════
	# 012 修整：我方回合结束时，若本回合没有移动，可回复机甲5生命或移除3损伤
	# ═══════════════════════════════════════════
	var e012 := _ActionEffect.new()
	e012.effect_id = &"event_effect_012"
	e012.display_name = "修整"
	e012.mode = _TC.MODE_LISTEN
	e012.priority = 10
	e012.listen_timing = _TC.TURN_END
	e012.set_conditions([
		{"op": &"IS_OWNER_TURN"},
		{"op": &"MOVED_DISTANCE_THIS_TURN_BELOW", "threshold": 1},
	])
	e012.set_target_rules([{"rule": &"NO_TARGET"}])
	e012.set_costs([])
	e012.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "回复机甲5生命",
				"actions": [{"type": &"EXECUTE_HP_CHANGE", "params": {
					"mech_ids": ["$binding_context.mech_id"], "value": 5, "method": &"restore",
					"source_mech_id": "$binding_context.mech_id", "reason": &"event_012_rest"}}]},
			{"label": "移除3损伤",
				"condition": [{"op": &"TARGET_HAS_DAMAGE"}],
				"actions": [{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
					"mech_ids": ["$binding_context.mech_id"], "value": 3, "method": &"decrease",
					"executor": "$binding_context.player_id", "reason": &"event_012_rest",
					"allow_cancel": true, "max_mode": true,
					"source_label": "修整：移除3损伤"}}]},
		]}},
	])
	e012.description = "我方回合结束时，若本回合没有移动，则可以回复机甲5生命或移除3损伤。"
	effects[e012.effect_id] = e012

	# ═══════════════════════════════════════════
	# 013~016 强化（护甲+5/动力+4/威力+4/范围+2）：派生型占位（数值表声明，
	# 查询点实时重算）。DIRECT 占位无 actions：不注册不建按钮。
	# ═══════════════════════════════════════════
	effects[&"event_effect_013"] = _build_reinforce_placeholder(&"event_effect_013",
		"强化·护甲+5", "机甲护甲+5。")
	effects[&"event_effect_014"] = _build_reinforce_placeholder(&"event_effect_014",
		"强化·动力+4", "机甲动力+4。")
	effects[&"event_effect_015"] = _build_reinforce_placeholder(&"event_effect_015",
		"强化·威力+4", "我方武器威力+4。")
	effects[&"event_effect_016"] = _build_reinforce_placeholder(&"event_effect_016",
		"强化·范围+2", "我方武器范围+2。")

	# ═══════════════════════════════════════════
	# 017~021 任务·计数：LISTEN 各时点 + TRACK_EVENT_PROGRESS 累积 task_progress
	# （single_move 逐格分解 BASIC_MOVE 全覆盖；金币任务按获金量累积）
	# ═══════════════════════════════════════════
	effects[&"event_effect_017"] = _build_task_counter_effect(&"event_effect_017",
		_TC.BASIC_MOVE_AFTER,
		[{"op": &"SELF_MECH_IS_MOVE_SUBJECT"}], 1, 10,
		"任务·移动：每移动1格累积1点")
	effects[&"event_effect_018"] = _build_task_counter_effect(&"event_effect_018",
		_TC.ATTACK_AFTER,
		[{"op": &"SELF_MECH_IS_ATTACKER"}, {"op": &"PAYLOAD_ATTACK_HIT"}], 1, 1,
		"任务·命中：攻击命中累积1点")
	effects[&"event_effect_019"] = _build_task_counter_effect(&"event_effect_019",
		_TC.GAIN_GOLD_AFTER,
		[{"op": &"PAYLOAD_PLAYER_IS_OWNER", "key": "gainer_player_id"}], 0, 8,
		"任务·金币：每获得1金币累积1点")
	effects[&"event_effect_020"] = _build_task_counter_effect(&"event_effect_020",
		_TC.USE_ACTION_AFTER,
		[{"op": &"USED_CARD_EXECUTOR_IS_SELF"}, {"op": &"PAYLOAD_IS_PHYSICAL_ACTION_CARD"}], 1, 4,
		"任务·使用：每使用1张行动牌累积1点")
	effects[&"event_effect_021"] = _build_task_counter_effect(&"event_effect_021",
		_TC.SET_EQUIP_AFTER,
		[{"op": &"PAYLOAD_MECH_IS_BINDING"}, {"op": &"PAYLOAD_SLOT_NOT_RESERVE"}], 1, 3,
		"任务·设置：每正面设置1张装备牌累积1点")

	# ═══════════════════════════════════════════
	# 022/024~027 任务·奖励：DIRECT 主动按钮（017~021 各自配对一个阈值）
	# 满足 task_progress >= 阈值才能点；领取一次后写 var_task_claimed=1 按钮永久置灰；
	# 选择窗可取消（取消不写标记不消耗）；领取后留槽继续计时，到期正常弃置。
	# ═══════════════════════════════════════════
	effects[&"event_effect_022"] = _build_task_reward_effect(&"event_effect_022", 10, "任务·机动")
	effects[&"event_effect_024"] = _build_task_reward_effect(&"event_effect_024", 1, "任务·歼灭")
	effects[&"event_effect_025"] = _build_task_reward_effect(&"event_effect_025", 8, "任务·赏金")
	effects[&"event_effect_026"] = _build_task_reward_effect(&"event_effect_026", 4, "任务·执行")
	effects[&"event_effect_027"] = _build_task_reward_effect(&"event_effect_027", 3, "任务·整备")

	# ═══════════════════════════════════════════
	# 023 修悟：每当回合即将结束，抽2行动 或 弃2行动回复此牌1计时再抽1行动
	# ═══════════════════════════════════════════
	var e023 := _ActionEffect.new()
	e023.effect_id = &"event_effect_023"
	e023.display_name = "修悟"
	e023.mode = _TC.MODE_LISTEN
	e023.priority = 10
	e023.listen_timing = _TC.TURN_BEFORE_END
	e023.set_conditions([])
	e023.set_target_rules([{"rule": &"NO_TARGET"}])
	e023.set_costs([])
	e023.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "抽2张行动牌",
				"actions": [{"type": &"EXECUTE_GAIN_CARD", "params": {
					"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
					"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
					"reason": &"event_023_enlighten"}}]},
			{"label": "弃置2张行动牌，回复此牌1计时，之后抽1张行动牌",
				"condition": [{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}}],
				"actions": [
					{"type": &"CHOOSE_MANY_CARDS", "params": {
						"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2,
						"store_result_key": "event_023_discard", "discard_selected": false,
						"owner_from_binding": true,
						"label": "弃置2张行动牌回复此牌计时", "confirm_verb": "弃置"}},
					{"type": &"EXECUTE_DISCARD", "params": {
						"card_ids": "$runtime.event_023_discard", "reason": &"event_023_enlighten"}},
					{"type": &"SET_EVENT_TIMER", "params": {
						"event_card_id": "$binding_context.card_instance_id", "delta": 1}},
					{"type": &"EXECUTE_GAIN_CARD", "params": {
						"from_zone": &"action_deck", "card_kind": &"action", "count": 1,
						"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
						"reason": &"event_023_enlighten"}},
				]},
		]}},
	])
	e023.description = "每当回合即将结束，可以选择：1、抽2张行动牌；2、弃置2张行动牌回复此牌1计时，之后抽1张行动牌。"
	effects[e023.effect_id] = e023

	return effects


## 遭遇（003/004）builder：按阵营分支四选项
static func _build_encounter_effect(effect_id: StringName, faction: String) -> _ActionEffect:
	var eff := _ActionEffect.new()
	eff.effect_id = effect_id
	eff.display_name = "遭遇·%s" % faction
	eff.mode = _TC.MODE_LISTEN
	eff.priority = 10
	eff.listen_timing = _TC.EVENT_RESOLVE
	eff.set_conditions([{"op": &"PAYLOAD_EVENT_CARD_IS_SELF"}])
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	eff.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"options": [
			# 缺阵营：惩罚分支（弃2行动 / 设2损伤）
			{"label": "弃置2张行动牌",
				"condition": [
					{"op": &"OWNER_PILOT_OR_FRAME_LACKS_FACTION", "faction": faction},
					{"op": &"HAS_ACTION_CARD_IN_HAND", "params": {"count": 2}}],
				"actions": [
					{"type": &"CHOOSE_MANY_CARDS", "params": {
						"source": &"OWNER_ACTION_HAND", "min_count": 2, "max_count": 2,
						"store_result_key": "event_encounter_discard", "discard_selected": false,
						"owner_from_binding": true, "no_cancel": true,
						"label": "选择要弃置的2张行动牌", "confirm_verb": "弃置"}},
					{"type": &"EXECUTE_DISCARD", "params": {
						"card_ids": "$runtime.event_encounter_discard", "reason": &"event_encounter"}},
				]},
			{"label": "我方机甲区域设置2损伤（位置自选）",
				"condition": [{"op": &"OWNER_PILOT_OR_FRAME_LACKS_FACTION", "faction": faction}],
				"actions": [{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
					"mech_ids": ["$binding_context.mech_id"], "value": 2, "method": &"increase",
					"executor": "$binding_context.player_id", "reason": &"event_encounter",
					"source_label": "遭遇：设置2损伤"}}]},
			# 有阵营：奖励分支（抽2行动 / 移除2损伤）
			{"label": "抽2张行动牌",
				"condition": [{"op": &"OWNER_PILOT_OR_FRAME_HAS_FACTION", "faction": faction}],
				"actions": [{"type": &"EXECUTE_GAIN_CARD", "params": {
					"from_zone": &"action_deck", "card_kind": &"action", "count": 2,
					"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
					"reason": &"event_encounter"}}]},
			{"label": "移除2损伤",
				"condition": [
					{"op": &"OWNER_PILOT_OR_FRAME_HAS_FACTION", "faction": faction},
					{"op": &"TARGET_HAS_DAMAGE"}],
				"actions": [{"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
					"mech_ids": ["$binding_context.mech_id"], "value": 2, "method": &"decrease",
					"executor": "$binding_context.player_id", "reason": &"event_encounter",
					"allow_cancel": true, "max_mode": true,
					"source_label": "遭遇：移除2损伤"}}]},
		]}},
	])
	eff.description = "若我方的机师牌、机甲框架的所属阵营里没有%s，则选择弃置2张行动牌或我方机甲区域设置2损伤（位置由我方指定），否则选择抽2张行动牌或移除2损伤。" % faction
	return eff


## 强化（013~016）派生型占位 builder
static func _build_reinforce_placeholder(effect_id: StringName, display: String, desc: String) -> _ActionEffect:
	var eff := _ActionEffect.new()
	eff.effect_id = effect_id
	eff.display_name = display
	eff.mode = _TC.MODE_DIRECT
	eff.priority = 10
	eff.set_conditions([])
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	eff.set_actions([])
	eff.description = desc
	return eff


## 任务计数（017~021）builder：LISTEN 时点 + 条件 + TRACK_EVENT_PROGRESS
## delta=0 表示按 $payload.amount 动态累积（金币任务）
## progress_threshold：任务目标阈值（progress_display 元数据，UI 悬停显示进度 X/阈值）
static func _build_task_counter_effect(effect_id: StringName, listen_timing: StringName,
		conditions: Array, delta: int, progress_threshold: int, desc: String) -> _ActionEffect:
	var eff := _ActionEffect.new()
	eff.effect_id = effect_id
	eff.display_name = desc
	eff.mode = _TC.MODE_LISTEN
	eff.priority = 10
	eff.listen_timing = listen_timing
	eff.set_conditions(conditions)
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	var track_params: Dictionary = {
		"event_card_id": "$binding_context.card_instance_id",
		"metric": &"task_progress",
	}
	if delta > 0:
		track_params["delta"] = delta
	else:
		track_params["delta"] = "$payload.amount"
	eff.set_actions([
		{"type": &"TRACK_EVENT_PROGRESS", "params": track_params},
	])
	eff.description = desc
	eff.progress_display = {"counter_key": &"task_progress", "threshold": progress_threshold}
	return eff


## 任务奖励（022/024~027）builder：DIRECT 主动按钮。
## - 我方主阶段 + task_progress 达标 + 未领取（var_task_claimed < 1）才可点；
## - 选择窗 optional 可取消（取消分支不执行 -> 标记不写 -> 不消耗领取次数）；
## - 确认分支尾 INCREMENT_VARIABLE 写 var_task_claimed=1（挂来源牌实例，复制改阈值即复用）；
## - 领取后留槽继续计时（不弃置、不注销），到期由 EventTimerService 正常弃置。
static func _build_task_reward_effect(effect_id: StringName, threshold: int, task_name: String) -> _ActionEffect:
	var eff := _ActionEffect.new()
	eff.effect_id = effect_id
	eff.display_name = "%s·奖励" % task_name
	eff.mode = _TC.MODE_DIRECT
	eff.priority = 10
	eff.set_conditions([
		{"op": &"IS_OWNER_MAIN_PHASE"},
		{"op": &"BINDING_CARD_COUNTER_AT_LEAST", "params": {"counter_key": &"task_progress", "threshold": threshold}},
		{"op": &"BINDING_CARD_COUNTER_BELOW", "params": {"counter_key": &"task_claimed", "threshold": 1}},
	])
	eff.set_target_rules([{"rule": &"NO_TARGET"}])
	eff.set_costs([])
	# 领取标记：确认分支尾写牌实例计数器（INCREMENT_VARIABLE 从 payload.binding_context 取来源牌）
	var claim_action: Dictionary = {"type": &"INCREMENT_VARIABLE", "params": {
		"source_card_instance_id": "$binding_context.card_instance_id",
		"variable_name": &"task_claimed", "delta": 1, "max_value": 1}}
	eff.set_actions([
		{"type": &"CHOOSE_ONE", "params": {"optional": true, "options": [
			{"label": "抽4张行动牌",
				"actions": [
					{"type": &"EXECUTE_GAIN_CARD", "params": {
						"from_zone": &"action_deck", "card_kind": &"action", "count": 4,
						"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
						"reason": &"event_task_reward"}},
					claim_action.duplicate(true),
				]},
			{"label": "抽2张装备牌",
				"actions": [
					{"type": &"EXECUTE_GAIN_CARD", "params": {
						"from_zone": &"equipment_deck", "card_kind": &"equipment", "count": 2,
						"player_id": "$binding_context.player_id", "mech_ids": ["$binding_context.mech_id"],
						"reason": &"event_task_reward"}},
					claim_action.duplicate(true),
				]},
		]}},
	])
	eff.description = "完成%s（进度%d）后，我方回合可领取一次奖励：抽4张行动牌或2张装备牌。领取后留槽继续计时。" % [task_name, threshold]
	eff.progress_display = {"counter_key": &"task_progress", "threshold": threshold,
		"claimed_counter_key": &"task_claimed"}
	return eff
