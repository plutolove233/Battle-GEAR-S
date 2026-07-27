## VictoryService.gd — 胜利条件检查服务
##
## 负责：
## - 检查机甲HP判定胜负
## - 检查回合数上限
## - 返回游戏状态：active / victory / defeat
class_name VictoryService
extends RefCounted

var context = null  # type: GameContext

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


## 检查胜利条件
## 检查所有机甲HP → 检查回合上限 → 返回游戏状态
## 达到胜利/失败条件时发出 VICTORY_REACHED 时点（文档第148-149行）
func check_victory() -> Dictionary:
	var gs: GameState = context.game_state

	# 已结束：直接返回缓存结果，不重复 fire VICTORY_REACHED（A3：此前死循环重复触发）
	if gs.phase == &"battle_over":
		var cached: Dictionary = gs.temp_values.get("victory_result", {})
		if not cached.is_empty():
			return cached
		return {"state": "defeat", "reason": "battle_over"}

	var player_mech: MechState = gs.get_mech_for_player(&"player")
	var enemy_mech: MechState = gs.get_mech_for_player(&"enemy")

	# ── 检查玩家机甲被摧毁 → 失败 ──
	if player_mech != null and player_mech.destroyed:
		var result := {"state": "defeat", "reason": "玩家机甲被摧毁"}
		_fire_victory_reached(result, &"enemy")
		gs.write_log(&"game_over", {"state": "defeat", "reason": "player_mech_destroyed"})
		return result

	# ── 检查敌方机甲被摧毁 → 胜利 ──
	if enemy_mech != null and enemy_mech.destroyed:
		var result := {"state": "victory", "reason": "敌方机甲被摧毁"}
		_fire_victory_reached(result, &"player")
		gs.write_log(&"game_over", {"state": "victory", "reason": "enemy_mech_destroyed"})
		return result

	# ── 检查HP归零（双重保险） ──
	if player_mech != null and player_mech.current_hp <= 0:
		var result := {"state": "defeat", "reason": "玩家HP归零"}
		_fire_victory_reached(result, &"enemy")
		gs.write_log(&"game_over", {"state": "defeat", "reason": "player_hp_zero"})
		return result

	if enemy_mech != null and enemy_mech.current_hp <= 0:
		var result := {"state": "victory", "reason": "敌方HP归零"}
		_fire_victory_reached(result, &"player")
		gs.write_log(&"game_over", {"state": "victory", "reason": "enemy_hp_zero"})
		return result

	# ── 检查回合数上限 ──
	var turn_limit: int = int(gs.temp_values.get("turn_limit", 12))
	if gs.turn_number >= turn_limit:
		# 回合数达到上限，比较HP判定胜负
		var player_hp: int = player_mech.current_hp if player_mech else 0
		var enemy_hp: int = enemy_mech.current_hp if enemy_mech else 0

		if player_hp > enemy_hp:
			var result := {"state": "victory", "reason": "回合上限，HP优势获胜"}
			_fire_victory_reached(result, &"player")
			gs.write_log(&"game_over", {"state": "victory", "reason": "turn_limit_hp_advantage"})
			return result
		elif player_hp < enemy_hp:
			var result := {"state": "defeat", "reason": "回合上限，HP劣势失败"}
			_fire_victory_reached(result, &"enemy")
			gs.write_log(&"game_over", {"state": "defeat", "reason": "turn_limit_hp_disadvantage"})
			return result
		else:
			# HP相同，判定失败（进攻方不利原则）
			var result := {"state": "defeat", "reason": "回合上限，HP平局判定失败"}
			_fire_victory_reached(result, &"enemy")
			gs.write_log(&"game_over", {"state": "defeat", "reason": "turn_limit_tie"})
			return result

	# ── 游戏继续 ──
	return {"state": "active", "reason": ""}


## 发出 VICTORY_REACHED 时点（文档第148-149行：记录胜利方式、胜利者）
## result: {state, reason}；winner: 胜利方 player_id（"player" 或 "enemy"）
## 首次达到时设 gs.phase="battle_over"、缓存结果、停止动作链（A3 修复）
func _fire_victory_reached(result: Dictionary, winner: StringName) -> void:
	if context == null or context.timing_engine == null:
		return
	var gs: GameState = context.game_state
	gs.phase = &"battle_over"
	gs.temp_values["victory_result"] = result
	var virtual_action = _Action.new()
	virtual_action.action_type = &"victory"
	virtual_action.record = {
		"state": result.get("state", ""),
		"reason": result.get("reason", ""),
		"winner": String(winner),
	}
	virtual_action.state = &"running"
	virtual_action.context = context
	context.timing_engine.fire_timing(_TimingConst.VICTORY_REACHED, virtual_action)
	# 停止当前动作链：取消所有活跃动作，防止胜利后继续结算/重复 fire
	if context.action_engine != null:
		context.action_engine.cancel_all_actions()
