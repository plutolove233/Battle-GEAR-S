## PlayerActionService.gd — 玩家主阶段操作分发服务
##
## 接收玩家操作命令，验证合法性，分发到对应 Service。
## 支持的命令：MOVE, PLAY_ACTION, SET_EQUIPMENT, SELL_EQUIPMENT,
## USE_ACTIVE_EFFECT, END_TURN, PAID_DRAW_ACTION
class_name PlayerActionService
extends RefCounted

const _GameConfig = preload("res://scripts/config/GameConfig.gd")

var context = null  # type: GameContext


## 执行玩家命令
## command: 命令类型（StringName）
## params: 命令参数（Dictionary）
## 返回: { ok: bool, message: String, ... }
func execute_command(player_id: StringName, command: StringName, params: Dictionary = {}) -> Dictionary:
	var gs = context.game_state

	# 验证是否当前玩家
	if gs.active_player_id != player_id:
		return {"ok": false, "message": "不是当前行动玩家"}

	# 验证是否主阶段
	if gs.phase != &"MAIN":
		return {"ok": false, "message": "当前不是主阶段（phase=%s）" % String(gs.phase)}

	match command:
		&"MOVE":
			return _cmd_move(player_id, params)
		&"PLAY_ACTION":
			return _cmd_play_action(player_id, params)
		&"SET_EQUIPMENT":
			return _cmd_set_equipment(player_id, params)
		&"SELL_EQUIPMENT":
			return _cmd_sell_equipment(player_id, params)
		&"USE_ACTIVE_EFFECT":
			return _cmd_use_active_effect(player_id, params)
		&"END_TURN":
			return _cmd_end_turn(player_id)
		&"PAID_DRAW_ACTION":
			return _cmd_paid_draw_action(player_id)
		_:
			return {"ok": false, "message": "未知命令: %s" % String(command)}


## ── 命令实现 ──


func _cmd_move(player_id: StringName, params: Dictionary) -> Dictionary:
	var target_q: int = int(params.get("q", 0))
	var target_r: int = int(params.get("r", 0))
	var mech = context.game_state.get_mech_for_player(player_id)
	if not mech:
		return {"ok": false, "message": "找不到机甲"}
	var result: Dictionary = context.map_service.move_mech_to_hex(
		mech.mech_id, {"q": target_q, "r": target_r}
	)
	return result


func _cmd_play_action(player_id: StringName, params: Dictionary) -> Dictionary:
	var card_id: StringName = params.get("card_id", &"")
	if card_id == &"":
		return {"ok": false, "message": "未指定行动牌"}
	return context.card_play_service.play_action_card(player_id, card_id)


func _cmd_set_equipment(player_id: StringName, params: Dictionary) -> Dictionary:
	var card_id: StringName = params.get("card_id", &"")
	var slot_id: StringName = params.get("slot_id", &"")
	if card_id == &"" or slot_id == &"":
		return {"ok": false, "message": "未指定装备或槽位"}
	return context.card_set_service.set_equipment(player_id, card_id, slot_id)


func _cmd_sell_equipment(player_id: StringName, params: Dictionary) -> Dictionary:
	var card_id: StringName = params.get("card_id", &"")
	if card_id == &"":
		return {"ok": false, "message": "未指定装备"}
	return context.card_set_service.sell_equipment(player_id, card_id)


func _cmd_use_active_effect(_player_id: StringName, params: Dictionary) -> Dictionary:
	var source_instance_id: StringName = params.get("source_instance_id", &"")
	var effect_id: StringName = params.get("effect_id", &"")
	var input_payload: Dictionary = params.get("payload", {})
	if source_instance_id == &"" or effect_id == &"":
		return {"ok": false, "message": "未指定效果来源或效果ID"}
	var success: bool = context.effect_engine.use_active_effect(
		source_instance_id, effect_id, input_payload
	)
	if success:
		return {"ok": true, "message": "效果已使用"}
	else:
		return {"ok": false, "message": "效果使用失败"}


func _cmd_end_turn(player_id: StringName) -> Dictionary:
	return context.turn_service.end_turn(player_id)


func _cmd_paid_draw_action(player_id: StringName) -> Dictionary:
	var player = context.game_state.players.get(player_id)
	if not player:
		return {"ok": false, "message": "玩家不存在"}
	if player.gold < _GameConfig.PAID_DRAW_ACTION_COST:
		return {"ok": false, "message": "金币不足（需要%d）" % _GameConfig.PAID_DRAW_ACTION_COST}
	# 扣除金币
	player.gold -= _GameConfig.PAID_DRAW_ACTION_COST
	# 抽牌
	var drawn: Array[StringName] = context.deck_service.draw_from_deck(
		&"action_deck", _GameConfig.PAID_DRAW_ACTION_COUNT
	)
	for card_id: StringName in drawn:
		player.action_hand.append(card_id)
	return {"ok": true, "message": "花费%d金币抽了%d张行动牌" % [_GameConfig.PAID_DRAW_ACTION_COST, drawn.size()]}
