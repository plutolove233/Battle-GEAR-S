## GameFlowService.gd — 游戏流程编排服务
##
## 负责：
## - 游戏启动流程（初始化 + 首回合开始）
## - 命令路由（将玩家操作分发到对应服务）
class_name GameFlowService
extends RefCounted

var context = null  # type: GameContext


## 启动游戏
## 调用 GameSetupService 初始化状态 → 调用 TurnService 开始玩家首回合
func start_game(data_registry: DataRegistry) -> Dictionary:
	# ── 1. 初始化游戏状态 ──
	var setup_result: Dictionary = context.game_setup_service.setup_tutorial_battle(data_registry)
	if not setup_result.get("ok", false):
		return {"ok": false, "message": "游戏初始化失败: %s" % setup_result.get("message", "未知错误")}

	# ── 2. 开始玩家首回合 ──
	var turn_result: Dictionary = context.turn_service.start_turn(&"player")
	if not turn_result.get("ok", false):
		return {"ok": false, "message": "首回合启动失败: %s" % turn_result.get("message", "未知错误")}

	context.game_state.write_log(&"game_started", {})
	return {"ok": true, "message": "游戏已启动", "turn": turn_result}


## 执行命令
## 根据命令类型路由到对应服务处理
func execute_command(player_id: StringName, command: StringName, params: Dictionary = {}) -> Dictionary:
	var gs: GameState = context.game_state

	# ── 验证当前活跃玩家 ──
	if gs.active_player_id != player_id:
		return {"ok": false, "message": "不是当前行动玩家"}

	match command:
		# ── 移动机甲 ──
		&"MOVE":
			var mech: MechState = gs.get_mech_for_player(player_id)
			if mech == null:
				return {"ok": false, "message": "未找到玩家机甲"}
			var target: Dictionary = params.get("target", {})
			if target.is_empty():
				return {"ok": false, "message": "缺少移动目标"}
			return context.map_service.move_mech_to_hex(mech.mech_id, target)

		# ── 打出行动牌 ──
		&"PLAY_ACTION":
			var card_id: StringName = params.get("card_id", &"")
			if card_id == &"":
				return {"ok": false, "message": "缺少卡牌ID"}
			var payload: Dictionary = params.get("payload", {})
			return context.card_play_service.play_action_card(player_id, card_id, payload)

		# ── 设置装备 ──
		&"SET_EQUIPMENT":
			var card_id: StringName = params.get("card_id", &"")
			var slot_id: StringName = params.get("slot_id", &"")
			if card_id == &"" or slot_id == &"":
				return {"ok": false, "message": "缺少卡牌ID或槽位ID"}
			return context.card_set_service.set_equipment(player_id, card_id, slot_id)

		# ── 出售装备 ──
		&"SELL":
			var card_id: StringName = params.get("card_id", &"")
			if card_id == &"":
				return {"ok": false, "message": "缺少卡牌ID"}
			return context.card_set_service.sell_equipment(player_id, card_id)

		# ── 结束回合 ──
		&"END_TURN":
			var end_result: Dictionary = context.turn_service.end_turn(player_id)
			if not end_result.get("ok", false):
				return end_result

			# 检查游戏是否结束
			var victory: Dictionary = end_result.get("victory", {})
			if victory.get("state", "active") != "active":
				return end_result

			# 切换到对方回合
			var opponent_id: StringName = gs.get_opponent_player_id(player_id)
			if opponent_id != &"":
				return context.turn_service.start_turn(opponent_id)

			return end_result

		_:
			return {"ok": false, "message": "未知命令: %s" % String(command)}
