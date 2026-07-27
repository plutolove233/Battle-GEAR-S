## thrust_test_helper.gd - 推进 effect2 测试辅助
##
## 推进 effect2（thrust_effect2）在持有者使用迎击牌时弹多选窗。迎击牌相关测试
## （防御/回避/疾行/反击/识破/强袭）若玩家手牌里恰好有推进（教程抽牌 RNG），
## 会被多选窗挂起干扰。本辅助清掉玩家手牌中的推进（移回行动牌堆+注销监听器），
## 让这些测试专注验证迎击牌自身逻辑。
extends RefCounted


static func clear_thrust_from_hand(battle) -> void:
	if battle == null or battle.context == null or battle.context.game_state == null:
		return
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	if player == null:
		return
	var to_remove: Array = []
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == &"action_015_推进":
			to_remove.append(cid)
	for cid in to_remove:
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"
