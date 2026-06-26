## EventTimerService.gd — 事件计时器服务
##
## 负责：
## - 回合结束时推进事件计时器
## - 触发事件到期钩子
class_name EventTimerService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 回合结束时推进事件计时器
## 遍历机甲的事件槽位，递减计时器，到期时触发效果
func tick_on_turn_end(mech_id: StringName) -> void:
	var gs: GameState = context.game_state
	var mech: MechState = gs.mechs.get(mech_id)
	if mech == null:
		return

	# ── 检查事件槽位 ──
	if not mech.slots.has(&"event"):
		return

	var event_slot: MechSlotState = mech.slots[&"event"]
	var event_card: CardInstance = event_slot.equipped_card
	if event_card == null:
		return

	# ── 递减计时器 ──
	# 事件卡牌使用 temp_values 存储剩余回合数
	var timer_key: String = "event_timer_%s" % String(event_card.instance_id)
	var remaining: int = int(gs.temp_values.get(timer_key, 0))

	if remaining <= 0:
		return  # 没有激活的计时器

	remaining -= 1
	gs.temp_values[timer_key] = remaining

	# ── 触发计时器递减钩子 ──
	_fire_hook(_EffectConst.HOOK_TURN_END, {
		"event": &"event_timer_ticked",
		"mech_id": String(mech_id),
		"card_id": String(event_card.instance_id),
		"remaining": remaining,
	})

	# ── 计时器到期 ──
	if remaining <= 0:
		_fire_hook(_EffectConst.HOOK_TURN_END, {
			"event": &"event_timer_expired",
			"mech_id": String(mech_id),
			"card_id": String(event_card.instance_id),
		})

		# 移除到期的事件卡
		if context.effect_registry:
			context.effect_registry.unregister_card(event_card)
		context.deck_service.discard_card(event_card.instance_id, &"event_expired")
		event_slot.equipped_card = null

		gs.write_log(&"event_timer_expired", {
			"mech_id": String(mech_id),
			"card_id": String(event_card.instance_id),
		})
	else:
		gs.write_log(&"event_timer_ticked", {
			"mech_id": String(mech_id),
			"card_id": String(event_card.instance_id),
			"remaining": remaining,
		})


## ── 内部方法 ──


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
