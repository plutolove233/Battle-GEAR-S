## set_event_card_action.gd - 设置事件牌动作
##
## 事件标记被玩家拾取后（MarkerService）或事件牌效果要求抽新事件牌时执行：
##   ① 解析事件牌（给定 card_id 或抽事件牌堆顶1张；堆空记日志取消）
##   ② EVENT_SET_BEFORE：顶掉旧事件牌（旧牌完整弃置，效果随之失效）+ 新牌入事件区域
##      （timer=timer_count 初始化；next_own_turn_end 模式置 armed 跳过设置当回合）
##   ③ EVENT_SET_AT：注册事件牌效果（LISTEN 监听时点 / DIRECT 主动按钮）+ 状态授予 + 派生数值
##   ④ EVENT_SET_AFTER：instant 模式标记（设置完成，效果已注册）
##   ⑤ EVENT_RESOLVE：设置时结算时点（instant 牌的效果此时触发；带 PAYLOAD_EVENT_CARD_IS_SELF 过滤）
##   ⑥ EVENT_SET_SETTLE：instant 模式效果结算完成后弃置（永久离场）
##
## 事件牌效果定义在 GeneratedEventEffects（效果只绑 effect_id 不绑卡，同装备/机师框架）。
extends Action
class_name SetEventCardAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _GeneratedEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")


func _init() -> void:
	action_type = &"set_event_card"


func setup_steps() -> void:
	steps = [
		{step_name = &"resolve_card",     timing_point = &"",                             handler = _step_resolve_card},
		{step_name = &"replace_place",    timing_point = _TimingConst.EVENT_SET_BEFORE,  handler = _step_replace_place},
		{step_name = &"activate",         timing_point = _TimingConst.EVENT_SET_AT,      handler = _step_activate},
		{step_name = &"mark_instant",     timing_point = _TimingConst.EVENT_SET_AFTER,   handler = _step_mark_instant},
		{step_name = &"instant_resolve",  timing_point = _TimingConst.EVENT_RESOLVE,     handler = _step_instant_resolve},
		{step_name = &"settle",           timing_point = _TimingConst.EVENT_SET_SETTLE,  handler = _step_settle},
	]


func get_display_name() -> String:
	return "设置事件牌"


## ① 解析事件牌：record.event_card_id 已给（测试/特定路径）则直接用；
## 否则抽事件牌堆顶1张（事件牌堆耗尽拾标记仅记日志：永久离场不重洗）。
func _step_resolve_card(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	if mech_id == &"" or not context.game_state.mechs.has(mech_id):
		return {"error": "设置事件牌失败：机甲不存在 %s" % String(mech_id)}
	var card_id: StringName = action.record.get("event_card_id", action.record.get("card_id", &""))
	if card_id == &"":
		if context.deck_service == null:
			return {"error": "设置事件牌失败：deck_service 不可用"}
		var drawn: Array = context.deck_service.draw_from_deck(&"event_deck", 1)
		if drawn.is_empty():
			context.game_state.write_log(&"event_deck_empty", {
				"mech_id": String(mech_id),
			})
			return {"error": "事件牌堆已耗尽，无法设置事件牌"}
		card_id = drawn[0]
		result["drawn_from_deck"] = true
	var card = context.game_state.get_card(card_id)
	if card == null or card.def == null or String(card.def.card_kind) != "event":
		return {"error": "设置事件牌失败：%s 不是事件牌" % String(card_id)}
	result["event_card_id"] = card_id
	return result


## ② 顶掉旧事件牌（旧牌完整弃置：监听器/状态/派生随弃置动作注销）+ 新牌入事件区域。
## 顺序保证：旧牌弃置先于新牌注册 -> 派生 registry 先清后注册，数值不叠加。
func _step_replace_place(action: Action) -> Dictionary:
	var result: Dictionary = {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var card_id: StringName = action.record.get("event_card_id", &"")
	var mech = context.game_state.mechs.get(mech_id)
	var card = context.game_state.get_card(card_id)
	if mech == null or card == null:
		return {"error": "设置事件牌失败：机甲或牌不存在"}
	var slot = mech.slots.get(&"event")
	if slot == null:
		return {"error": "设置事件牌失败：机甲无事件区域"}

	# 旧事件牌作为本动作的子动作完整弃置（其效果监听器/状态/派生随弃置注销）
	if slot.equipped_card != null:
		var old_card_id: StringName = slot.equipped_card.instance_id
		slot.equipped_card = null
		context.action_service.execute_sub_action({
			"type": &"EXECUTE_DISCARD",
			"params": {"card_ids": [old_card_id], "count": 1, "executor": &"system_default", "reason": &"event_replaced"},
		}, action.record.duplicate(), action)
		result["replaced_card_id"] = old_card_id
		if not action.pending_effect_action_ids.is_empty():
			result["effect_action_created"] = true

	# 新牌入事件区域：计时初始化 + 归属设置
	var player_id: StringName = mech.owner_player_id
	slot.equipped_card = card
	card.zone = &"event_slot"
	card.slot_id = &"event"
	card.mech_id = mech_id
	card.owner_player_id = player_id
	var timer_count: int = int(card.def.timer_count) if "timer_count" in card.def else 0
	card.timer = timer_count
	# next_own_turn_end：设置当回合的结束不 tick（armed 标志，EventTimerService 消费后清除）
	if "timer_mode" in card.def and card.def.timer_mode == _GeneratedEventEffects.TIMER_MODE_NEXT_OWN_TURN_END:
		card.counters["timer_armed_pending"] = true

	result["timer"] = card.timer
	result["player_id"] = player_id
	context.game_state.write_log(&"event_card_set", {
		"mech_id": String(mech_id),
		"card_id": String(card.def.card_id),
		"timer": card.timer,
	})
	return result


## ③ 注册事件牌效果（与 set_equipment 的 _register_equipment_effects 同模式）
## LISTEN -> register_permanent_listener(listen_timing)；DIRECT 无 listen_timing ->
## 注册到 effect_id 虚拟时点（equipment_panel 扫描建按钮）；派生型（强化/陷落限制）
## 跳过监听器（数值实时重算 / 状态由 apply_status_grants 施加）。
## 李 pilot_051 e2 在 EVENT_SET_BEFORE 拦截取消时写 record.event_set_cancelled=true
## 并自行摘牌（弃置/转设我方区域），此后本动作剩余步骤全部空跑（不注册/不结算/不弃置）。
func _step_activate(action: Action) -> Dictionary:
	if bool(action.record.get("event_set_cancelled", false)):
		return {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var card_id: StringName = action.record.get("event_card_id", &"")
	var card = context.game_state.get_card(card_id)
	var mech = context.game_state.mechs.get(mech_id)
	if card == null or mech == null:
		return {"error": "事件牌激活失败"}
	_register_event_effects(card, mech_id)
	# 状态授予（陷落限制：带 source_card_id，离场按来源清除）
	_GeneratedEventEffects.apply_status_grants(context, card, mech_id)
	# 派生数值注册（强化：护甲/动力/威力/范围，查询点实时读取）
	_GeneratedEventEffects.register_derived_bonuses(card, mech_id)
	# 派生可能含动力上限 -> 重算
	var old_max_power: int = mech.max_power
	mech.max_power = mech.get_total_power()
	mech.sync_own_power_after_max_change(old_max_power)
	return {}


## ④ 标记 instant 模式（EVENT_SET_AFTER 时点 fire：设置完成，效果已注册）。
## instant 牌的"设置时结算"在步骤⑤ EVENT_RESOLVE 时点触发。
func _step_mark_instant(action: Action) -> Dictionary:
	if bool(action.record.get("event_set_cancelled", false)):
		return {}
	var card_id: StringName = action.record.get("event_card_id", &"")
	var card = context.game_state.get_card(card_id)
	if card != null and card.def != null and "timer_mode" in card.def:
		if card.def.timer_mode == _GeneratedEventEffects.TIMER_MODE_INSTANT:
			action.record["instant_resolve"] = true
	return {}


## ⑤ instant 模式设置时结算：步骤级时点 EVENT_RESOLVE 无条件 fire。
## 监听 EVENT_RESOLVE 的效果（增援/敌袭/遭遇）带 PAYLOAD_EVENT_CARD_IS_SELF 条件，
## 只有本动作的事件牌效果触发（payload.event_card_id 匹配），其他机甲同时设置的事件牌不受扰。
func _step_instant_resolve(_action: Action) -> Dictionary:
	return {}


## ⑤ instant 模式结算完成后弃置（永久离场）。弃置动作注销监听器/状态/派生。
## EVENT_RESOLVE 效果挂起时本步骤在其完成后才执行（时点 fire 挂起 -> 恢复后推进）。
func _step_settle(action: Action) -> Dictionary:
	if not action.record.get("instant_resolve", false):
		return {}
	if bool(action.record.get("event_set_cancelled", false)):
		return {}
	var mech_id: StringName = action.record.get("mech_id", &"")
	var card_id: StringName = action.record.get("event_card_id", &"")
	var card = context.game_state.get_card(card_id)
	if card == null:
		return {}
	var mech = context.game_state.mechs.get(mech_id)
	if mech != null:
		var slot = mech.slots.get(&"event")
		if slot != null and slot.equipped_card == card:
			slot.equipped_card = null
	context.deck_service.discard_card(card_id, &"event_resolved")
	return {}


## 注册事件牌效果到 TimingEngine（GeneratedEventEffects 查表，效果只绑 effect_id）
func _register_event_effects(card, mech_id: StringName) -> void:
	if context == null or context.timing_engine == null:
		return
	if card == null or card.def == null:
		return
	var effect_ids: Array = _GeneratedEventEffects.get_effects_for_card(card.def.card_id, context)
	if effect_ids.is_empty():
		return
	var all_effects: Dictionary = _GeneratedEventEffects.build_event_effects()
	var binding_ctx: Dictionary = {
		"card_instance_id": card.instance_id,
		"mech_id": mech_id,
		"player_id": card.owner_player_id,
		"card_def_id": card.def.card_id,
		"slot_id": &"event",
	}
	for effect_id: StringName in effect_ids:
		var effect: ActionEffect = all_effects.get(effect_id)
		if effect == null:
			continue
		# 派生型效果（强化数值/陷落限制）不注册监听器：数值实时重算 / 状态已由 apply_status_grants 施加
		if _GeneratedEventEffects.is_derived_effect(effect_id):
			continue
		# DIRECT 主动效果：无 listen_timing 时注册到 effect_id 虚拟时点（equipment_panel 扫描建按钮）
		if effect.mode == _TimingConst.MODE_DIRECT and effect.listen_timing == &"":
			context.timing_engine.register_permanent_listener(effect_id, effect, binding_ctx)
			continue
		# LISTEN / AVAILABILITY 模式：注册到 effect.listen_timing
		if effect.listen_timing != &"":
			context.timing_engine.register_permanent_listener(effect.listen_timing, effect, binding_ctx)
