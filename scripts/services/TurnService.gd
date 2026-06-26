## TurnService.gd — 回合管理服务
##
## 负责回合开始/结束的完整流程：
## 资源恢复、抽牌、阶段切换、效果触发、清理
class_name TurnService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")


## 开始回合
## 流程：设置活跃玩家 → 回合开始阶段 → 抽牌 → 资源恢复 → 主阶段
func start_turn(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 1. 设置活跃玩家和阶段 ──
	gs.active_player_id = player_id
	gs.phase = &"TURN_START"

	# 先手玩家回合数递增
	if player_id == &"player":
		gs.turn_number += 1

	# ── 2. 重置每回合一次性标记和计数器 ──
	player.once_per_turn_used.clear()
	player.turn_counters.clear()

	# 重置机甲回合攻击计数
	var mech: MechState = gs.get_mech_for_player(player_id)
	if mech:
		mech.attack_count_this_turn = 0

	# ── 3. 触发回合开始钩子 ──
	_fire_hook(_EffectConst.HOOK_TURN_START, {"player_id": player_id})

	# ── 4. 抽2张行动牌 ──
	var drawn_actions: Array[StringName] = context.deck_service.draw_from_deck(&"action_deck", 2)
	for card_id: StringName in drawn_actions:
		player.action_hand.append(card_id)

	# ── 5. 抽1张装备牌 ──
	var drawn_equipment: Array[StringName] = context.deck_service.draw_from_deck(&"equipment_deck", 1)
	for card_id: StringName in drawn_equipment:
		player.equipment_hand.append(card_id)

	# ── 6. 获得2金币 ──
	if context.game_actions:
		context.game_actions.gain_gold({"player_id": player_id, "amount": 2})

	# ── 7. 恢复动力到最大值 ──
	if mech and context.game_actions:
		context.game_actions.restore_power({"mech_id": mech.mech_id, "amount": "full"})

	# ── 8. 切换到主阶段 ──
	gs.phase = &"MAIN"

	# ── 9. 触发主阶段开始钩子 ──
	_fire_hook(_EffectConst.HOOK_MAIN_PHASE_START, {"player_id": player_id})

	gs.write_log(&"turn_start", {"player_id": String(player_id), "turn_number": gs.turn_number})
	return {"ok": true, "player_id": player_id, "turn_number": gs.turn_number, "phase": String(gs.phase)}


## 结束回合
## 流程：回合结束阶段 → 事件计时 → 弃牌 → 清理 → 胜利检查
func end_turn(player_id: StringName) -> Dictionary:
	var gs: GameState = context.game_state
	var player: PlayerState = gs.players.get(player_id)
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 1. 切换到回合结束阶段 ──
	gs.phase = &"TURN_END"

	# ── 2. 触发回合结束钩子 ──
	_fire_hook(_EffectConst.HOOK_TURN_END, {"player_id": player_id})

	# ── 3. 推进事件计时器 ──
	var mech: MechState = gs.get_mech_for_player(player_id)
	if mech:
		context.event_timer_service.tick_on_turn_end(mech.mech_id)

	# ── 4. 弃掉超出手牌上限的行动牌 ──
	while player.action_hand.size() > player.action_card_limit:
		var excess_card: StringName = player.action_hand.pop_back()
		context.deck_service.discard_card(excess_card, &"hand_limit")

	# ── 5. 弃掉未设置的装备牌 ──
	while player.equipment_hand.size() > 0:
		var unset_card: StringName = player.equipment_hand.pop_back()
		context.deck_service.discard_card(unset_card, &"end_turn_unset")

	# ── 6. 清理 THIS_TURN 持续时间的效果 ──
	_clean_this_turn_durations()

	# ── 7. 检查胜利条件 ──
	var victory_result: Dictionary = context.victory_service.check_victory()

	gs.write_log(&"turn_end", {"player_id": String(player_id), "turn_number": gs.turn_number})
	return {"ok": true, "victory": victory_result}


## ── 内部方法 ──


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)


## 清理持续时间为 THIS_TURN 的效果
func _clean_this_turn_durations() -> void:
	if context.effect_registry == null:
		return
	# 遍历所有机甲，移除 THIS_TURN 持续时间的状态
	var gs: GameState = context.game_state
	for mech_id: StringName in gs.mechs:
		var mech: MechState = gs.mechs[mech_id]
		mech.statuses = mech.statuses.filter(func(s: Dictionary) -> bool:
			return s.get("duration", &"") != &"THIS_TURN"
		)
