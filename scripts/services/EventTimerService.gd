## EventTimerService.gd - 事件牌计时引擎
##
## 事件牌计时方式（EventCardDef.timer_mode）：
##   instant              设置时即刻结算（set_event_card 动作内处理，本服务不参与计时）
##   every_turn_end       从当前回合开始，每个回合结束后-1（双方回合都 tick）
##   own_turn_end         从当前回合开始，只在我方回合结束后-1
##   next_own_turn_end    从下一个我方回合开始，我方回合结束后-1
##                        （设置总在我方回合中：armed 标志跳过设置当回合的结束）
##   next_own_turn_start  从下一个我方回合开始，我方回合开始时-1
##                        （设置在回合中，首个我方回合开始的 tick 天然是下回合，无需 armed）
##
## 到期流程：EVENT_TIMER_TICK（每-1一次）-> 归零 EVENT_TIMER_EXPIRE（先于弃置：
## 陷落到期抽新牌 e007 / 任务奖励 e022 此时结算）-> 事件牌弃置（永久离场，
## 弃置动作注销监听器/状态/派生）。时点经 TimingEngine 虚拟 action fire（同 TurnService 模式）。
class_name EventTimerService
extends RefCounted

var context = null  # type: GameContext

## 回合结束 tick 队列（分段挂起用）：{mech_ids: Array, active_player_id: StringName, on_done: Callable}
var _pending_tick: Dictionary = {}

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _SLog = preload("res://scripts/services/slog.gd")
const _GenEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")


## 回合结束时推进计时器（TurnService.end_turn 第4步调用）
## active_player_id：当前结束回合的玩家。遍历全部机甲（PVP3 多机甲通用）：
## every_turn_end 总是 tick；own_turn_end / next_own_turn_end 仅 owner==active_player 时 tick。
## on_done：全部机甲 tick 完成后调用（TurnService 续跑 end_turn 第5步）。
## 返回 true=有计时器到期效果挂起（EXPIRE 弹窗等待玩家），流程暂停，玩家交互完成后
## 自动续跑剩余机甲并经 on_done 续跑；false=全部同步完成（调用方【自行】续跑后续步骤，
## on_done 不在本路径调用——若此处再同步调 on_done 又返回 true，调用方会误判 suspended，
## net 路径 end_turn_flow_completed 信号先于 _pending_turn_flow 置位发出致轮转丢失）。
func tick_on_turn_end(active_player_id: StringName, on_done: Callable = Callable()) -> bool:
	if context == null or context.game_state == null:
		return false  # 无可 tick 机甲：调用方自行续跑
	# 新一轮：构建剩余机甲队列（续跑路径 _pending_tick 非空直接消费）
	if _pending_tick.is_empty():
		var ids: Array = []
		for mech_id: StringName in context.game_state.mechs:
			ids.append(mech_id)
		_pending_tick = {"mech_ids": ids, "active_player_id": active_player_id, "on_done": on_done}
	return _drain_pending_tick()


## 逐机甲消费 _pending_tick 队列；到期效果挂起时写 _flow_resume_call（_resume_tick_after_expire）
## 并返回 true。全部消费完：from_resume=true（挂起恢复路径，调用方已 suspended 返回，
## 无人续跑）时同步调用 on_done 并返回 true；from_resume=false（首轮直调）时返回 false，
## 调用方依据返回值自行同步续跑——两条路径互斥，保证 step5-9 恰好执行一次。
func _drain_pending_tick(from_resume: bool = false) -> bool:
	while not _pending_tick.mech_ids.is_empty():
		var mech_id: StringName = _pending_tick.mech_ids.pop_front()
		var mech = context.game_state.mechs.get(mech_id)
		if mech == null or mech.destroyed:
			continue
		var slot = mech.slots.get(&"event")
		if slot == null or slot.equipped_card == null:
			continue
		var card = slot.equipped_card
		var mode: StringName = _card_timer_mode(card)
		var owner_is_active: bool = String(mech.owner_player_id) == String(_pending_tick.active_player_id)
		var should_tick: bool = false
		match mode:
			_GenEventEffects.TIMER_MODE_EVERY_TURN_END:
				should_tick = true
			_GenEventEffects.TIMER_MODE_OWN_TURN_END:
				should_tick = owner_is_active
			_GenEventEffects.TIMER_MODE_NEXT_OWN_TURN_END:
				if owner_is_active:
					if bool(card.counters.get("timer_armed_pending", false)):
						# 设置当回合结束：跳过本次 tick，从下一个我方回合开始
						card.counters.erase("timer_armed_pending")
						_SLog.log_raw("[EVENT] %s next_own_turn_end 设置当回合，跳过 tick" % String(card.instance_id))
					else:
						should_tick = true
		if not should_tick:
			continue
		if _tick_event_card(card, mech_id):
			return true  # 到期效果挂起，续跑见 _resume_tick_after_expire
	var on_done: Callable = _pending_tick.get("on_done", Callable())
	_pending_tick = {}
	if on_done.is_valid() and from_resume:
		on_done.call()
		return true
	return false


## 到期效果挂起恢复（_flow_resume_call 出口）：到期即离场已改在 _tick_event_card 内完成，
## 此处补弃置对空槽/被顶掉幂等跳过，随后续跑剩余机甲队列
func _resume_tick_after_expire(card_instance_id: StringName, mech_id: StringName) -> void:
	if _pending_tick.is_empty():
		return
	var card = context.game_state.get_card(card_instance_id) if context.game_state != null else null
	if card != null:
		_expire_discard_if_in_slot(card, mech_id)
	_drain_pending_tick(true)


## 回合开始时推进计时器（TurnService.start_turn 在 TURN_START fire 后调用）
## next_own_turn_start 模式：设置在回合中，本回合 TURN_START 已过，
## 首个我方回合开始的 tick 天然是下回合，无需 armed 标志。
func tick_on_turn_start(active_player_id: StringName) -> void:
	if context == null or context.game_state == null:
		return
	for mech_id: StringName in context.game_state.mechs:
		var mech = context.game_state.mechs[mech_id]
		if mech == null or mech.destroyed:
			continue
		if String(mech.owner_player_id) != String(active_player_id):
			continue
		var slot = mech.slots.get(&"event")
		if slot == null or slot.equipped_card == null:
			continue
		var card = slot.equipped_card
		if _card_timer_mode(card) == _GenEventEffects.TIMER_MODE_NEXT_OWN_TURN_START:
			_tick_event_card(card, mech_id)


## 单张事件牌计时-1 + 到期结算
## 返回 true=到期效果挂起（EXPIRE 弹窗等待玩家）；false=同步完成。
## 到期即离场：EVENT_TIMER_EXPIRE 的同步段先结算，随后**无论是否挂起**立即弃置本牌
## （永久离场、清状态/派生/监听）--陷落归零即刻解除限制；挂起的弹窗（e007 到期抽新）
## 恢复后往空槽设新牌即可，_resume_tick_after_expire 的补弃置对空槽幂等跳过。
func _tick_event_card(card, mech_id: StringName) -> bool:
	if context == null or context.deck_service == null:
		return false
	var before: int = int(card.timer)
	card.timer = before - 1
	_fire_timing(_TimingConst.EVENT_TIMER_TICK, {
		"player_id": String(_mech_owner(mech_id)),
		"event_card_id": String(card.instance_id),
		"mech_id": String(mech_id),
		"timer": card.timer,
		"before": before,
	})
	context.game_state.write_log(&"event_timer_ticked", {
		"mech_id": String(mech_id),
		"card_id": String(card.instance_id),
		"remaining": card.timer,
	})
	_SLog.log_raw("[EVENT] %s 计时 %d -> %d（%s）" % [String(card.instance_id), before, card.timer, String(mech_id)])
	if card.timer > 0:
		return false
	# 到期：EVENT_TIMER_EXPIRE 先于弃置（e007 到期抽新牌 / 任务奖励此时结算）。
	# 同步段效果立即跑（条件读牌面计数器等仍有效）；随后立即弃置（挂起与否都离场）。
	var va_expire = _fire_timing(_TimingConst.EVENT_TIMER_EXPIRE, {
		"player_id": String(_mech_owner(mech_id)),
		"event_card_id": String(card.instance_id),
		"mech_id": String(mech_id),
	})
	_expire_discard_if_in_slot(card, mech_id)
	if va_expire != null:
		var st: StringName = va_expire.state
		if st == &"waiting_timing" or st == &"waiting_input" or st == &"waiting_effect_action":
			va_expire.record["_flow_resume_call"] = Callable(self, "_resume_tick_after_expire").bind(card.instance_id, mech_id)
			return true
	return false


## 到期结算后：若牌仍在事件槽（未被"到期抽新牌"顶掉）-> 弃置（永久离场）
func _expire_discard_if_in_slot(card, mech_id: StringName) -> void:
	if context == null or context.deck_service == null or context.game_state == null:
		return
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		return
	var slot = mech.slots.get(&"event")
	if slot == null or slot.equipped_card != card:
		_SLog.log_raw("[EVENT] %s 到期时已被顶掉/移除，跳过弃置" % String(card.instance_id))
		return
	slot.equipped_card = null
	context.deck_service.discard_card(card.instance_id, &"event_expired")
	context.game_state.write_log(&"event_timer_expired", {
		"mech_id": String(mech_id),
		"card_id": String(card.instance_id),
	})
	_SLog.log_raw("[EVENT] %s 计时到期弃置（永久离场）" % String(card.instance_id))


## ── 内部方法 ──


func _card_timer_mode(card) -> StringName:
	if card == null or card.def == null or not ("timer_mode" in card.def):
		return &""
	return card.def.timer_mode


func _mech_owner(mech_id: StringName) -> StringName:
	var mech = context.game_state.mechs.get(mech_id) if context.game_state != null else null
	return mech.owner_player_id if mech != null else &""


## 触发时点（通过 TimingEngine，虚拟 action 注册 registry 模式，同 TurnService._fire 模式）
## 返回虚拟 action（供调用方检查挂起态/挂续跑回调）
func _fire_timing(timing: StringName, payload: Dictionary = {}) -> Action:
	if context == null or context.timing_engine == null:
		return null
	var virtual_action = Action.new()
	virtual_action.action_type = &"event_timer"
	virtual_action.record = payload.duplicate()
	virtual_action.state = &"running"
	virtual_action.context = context
	var player_id: StringName = payload.get("player_id", &"")
	virtual_action.source = {
		"player_id": player_id,
		"mech_id": payload.get("mech_id", &""),
	}
	if context.action_registry != null:
		context.action_registry.register(virtual_action)
	context.timing_engine.fire_timing(timing, virtual_action)
	# fire 完成后：未挂起的虚拟 action 立即清理避免泄漏；挂起的（玩家弹窗确认）保留，
	# 待 resume 后 continue_action 跑空 step 自动 completed -> cleanup。
	if context.action_registry != null and virtual_action.state != &"waiting_timing" and virtual_action.state != &"waiting_input" and virtual_action.state != &"waiting_effect_action":
		context.action_registry.cleanup_action(virtual_action.action_id)
	return virtual_action
