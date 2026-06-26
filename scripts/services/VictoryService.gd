## VictoryService.gd — 胜利条件检查服务
##
## 负责：
## - 检查机甲HP判定胜负
## - 检查回合数上限
## - 返回游戏状态：active / victory / defeat
class_name VictoryService
extends RefCounted

var context = null  # type: GameContext


## 检查胜利条件
## 检查所有机甲HP → 检查回合上限 → 返回游戏状态
func check_victory() -> Dictionary:
	var gs: GameState = context.game_state

	var player_mech: MechState = gs.get_mech_for_player(&"player")
	var enemy_mech: MechState = gs.get_mech_for_player(&"enemy")

	# ── 检查玩家机甲被摧毁 → 失败 ──
	if player_mech != null and player_mech.destroyed:
		gs.write_log(&"game_over", {"state": "defeat", "reason": "player_mech_destroyed"})
		return {"state": "defeat", "reason": "玩家机甲被摧毁"}

	# ── 检查敌方机甲被摧毁 → 胜利 ──
	if enemy_mech != null and enemy_mech.destroyed:
		gs.write_log(&"game_over", {"state": "victory", "reason": "enemy_mech_destroyed"})
		return {"state": "victory", "reason": "敌方机甲被摧毁"}

	# ── 检查HP归零（双重保险） ──
	if player_mech != null and player_mech.current_hp <= 0:
		gs.write_log(&"game_over", {"state": "defeat", "reason": "player_hp_zero"})
		return {"state": "defeat", "reason": "玩家HP归零"}

	if enemy_mech != null and enemy_mech.current_hp <= 0:
		gs.write_log(&"game_over", {"state": "victory", "reason": "enemy_hp_zero"})
		return {"state": "victory", "reason": "敌方HP归零"}

	# ── 检查回合数上限 ──
	var turn_limit: int = int(gs.temp_values.get("turn_limit", 12))
	if gs.turn_number >= turn_limit:
		# 回合数达到上限，比较HP判定胜负
		var player_hp: int = player_mech.current_hp if player_mech else 0
		var enemy_hp: int = enemy_mech.current_hp if enemy_mech else 0

		if player_hp > enemy_hp:
			gs.write_log(&"game_over", {"state": "victory", "reason": "turn_limit_hp_advantage"})
			return {"state": "victory", "reason": "回合上限，HP优势获胜"}
		elif player_hp < enemy_hp:
			gs.write_log(&"game_over", {"state": "defeat", "reason": "turn_limit_hp_disadvantage"})
			return {"state": "defeat", "reason": "回合上限，HP劣势失败"}
		else:
			# HP相同，判定失败（进攻方不利原则）
			gs.write_log(&"game_over", {"state": "defeat", "reason": "turn_limit_tie"})
			return {"state": "defeat", "reason": "回合上限，HP平局判定失败"}

	# ── 游戏继续 ──
	return {"state": "active", "reason": ""}
