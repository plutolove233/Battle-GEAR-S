## CardPlayService.gd — 行动牌打出服务
##
## 负责验证和执行行动牌的打出：
## 验证手牌/阶段 → 触发钩子 → 弃牌
class_name CardPlayService
extends RefCounted

var context = null  # type: GameContext

const _EffectConst = preload("res://scripts/effect_core/EffectConst.gd")


## 打出行动牌
## 验证牌在手中且处于主阶段 → 触发打出钩子 → 弃牌
func play_action_card(player_id: StringName, card_id: StringName, payload: Dictionary = {}) -> Dictionary:
	var gs = context.game_state
	var player = gs.players.get(player_id)

	# ── 验证玩家存在 ──
	if player == null:
		return {"ok": false, "message": "玩家不存在: %s" % String(player_id)}

	# ── 验证牌在手牌中 ──
	if not player.action_hand.has(card_id):
		return {"ok": false, "message": "行动牌不在手牌中"}

	# ── 验证当前阶段为主阶段 ──
	if gs.phase != &"MAIN":
		return {"ok": false, "message": "当前阶段不能打出行动牌: %s" % String(gs.phase)}

	# ── 触发行动牌打出钩子 ──
	_fire_hook(_EffectConst.HOOK_CARD_PLAYED, {
		"player_id": player_id,
		"card_id": card_id,
		"card_kind": &"action",
		"payload": payload,
	})

	# ── 弃掉该牌 ──
	player.action_hand.erase(card_id)
	context.deck_service.discard_card(card_id, &"played")

	gs.write_log(&"action_card_played", {
		"player_id": String(player_id),
		"card_id": String(card_id),
	})
	return {"ok": true, "card_id": card_id}


## ── 内部方法 ──


## 触发效果钩子
func _fire_hook(hook_name: StringName, payload: Dictionary = {}) -> void:
	if context.effect_engine:
		context.effect_engine.fire_hook(hook_name, payload)
