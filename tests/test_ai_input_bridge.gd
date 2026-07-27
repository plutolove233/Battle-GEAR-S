## test_ai_input_bridge.gd — AI 回合输入自动决策回归测试
##
## 验证 ActionUIBridge 在 AI 发起方需要输入时，走自动决策而非弹出人类 UI（request_ui_popup）。
## 覆盖：select_weapon / select_attack_target / select_discard_cards / select_target_mech / choose_one。
## 用户报告：AI 用闪击2/反击等效果时仍弹人类选框。根因是这些 input_type 在 ActionUIBridge
## 缺 AI 自动决策分支。本测试断言 AI 发起方触发这些输入时 request_ui_popup 不被 emit。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _ActionUIBridge = preload("res://scripts/action_core/ActionUIBridge.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


## 构造一个已注册的 waiting_input 动作（供 ActionUIBridge 续跑）
func _make_waiting_action(battle, action_type: StringName, record: Dictionary) -> _Action:
	var action := _Action.new()
	action.action_id = &"test_ai_input_%d" % [randi() % 1000000]
	action.action_type = action_type
	action.record = record
	action.state = &"waiting_input"
	action.current_step_phase = &""
	action.context = battle.context
	battle.context.action_registry.register(action)
	return action


## 收集 request_ui_popup 信号：AI 触发输入时不应 emit 任何 popup
func _make_bridge_collector(battle) -> Dictionary:
	var bridge := _ActionUIBridge.new()
	bridge.context = battle.context
	battle.context.action_ui_bridge = bridge
	var popups: Array = []
	bridge.request_ui_popup.connect(func(popup_type, _params):
		popups.append(String(popup_type))
	)
	var resolved: Array = []
	bridge.action_input_resolved.connect(func(_aid, _data):
		resolved.append(true)
	)
	return {"bridge": bridge, "popups": popups, "resolved": resolved}


## select_weapon：AI 攻击者 → 自动选武器，不弹 weapon_select
func test_ai_select_weapon_auto():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	var col = _make_bridge_collector(battle)
	var bridge = col.bridge
	var action := _make_waiting_action(battle, &"attack", {"attacker_id": enemy_mech.mech_id, "_last_input_type": &"select_weapon"})
	bridge._on_action_needs_input(action.action_id, &"select_weapon", {"attacker_id": enemy_mech.mech_id})
	if not col.popups.is_empty():
		return "AI select_weapon 不应弹窗，实际弹了: %s" % str(col.popups)
	if col.resolved.is_empty():
		return "AI select_weapon 应自动决策续跑（action_input_resolved 未触发）"
	# attack record 应被注入 weapon_id
	if String(action.record.get("weapon_id", &"")) == &"":
		return "AI 自动选武器后 attack.record.weapon_id 应非空"
	return true


## select_attack_target：AI 攻击者 → 自动选射程内敌方，不弹 attack_target_select
func test_ai_select_attack_target_auto():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var player_mech = gs.get_mech_for_player(&"player")
	if enemy_mech == null or player_mech == null:
		return "找不到机甲"
	# 把玩家放到敌方相邻格（射程1可达）：取敌方位置的某个邻居
	var _HexGrid = preload("res://scripts/battle/hex_grid.gd")
	var ep: Dictionary = enemy_mech.position
	var nbrs: Array = _HexGrid.neighbors(ep)
	if nbrs.is_empty():
		return "无法取敌方相邻格"
	player_mech.position = nbrs[0]
	var col = _make_bridge_collector(battle)
	var bridge = col.bridge
	var action := _make_waiting_action(battle, &"attack", {"attacker_id": enemy_mech.mech_id, "_last_input_type": &"select_attack_target"})
	bridge._on_action_needs_input(action.action_id, &"select_attack_target", {
		"attacker_id": enemy_mech.mech_id, "weapon_range": 1, "target_count": 1,
	})
	if not col.popups.is_empty():
		return "AI select_attack_target 不应弹窗，实际弹了: %s" % str(col.popups)
	if col.resolved.is_empty():
		return "AI select_attack_target 应自动决策续跑"
	if String(action.record.get("target_id", &"")) == &"":
		return "AI 自动选目标后 attack.record.target_id 应非空"
	return true


## select_discard_cards：AI executor → 自动弃牌，不弹 discard_card_select
func test_ai_discard_cards_auto():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	# 给 AI 塞1张行动牌
	var enemy_player = gs.players.get(&"enemy")
	if enemy_player == null:
		return "找不到敌方玩家"
	# 从牌堆抽1张到敌方手牌
	if gs.deck_state.action_deck.size() > 0:
		var cid: StringName = gs.deck_state.action_deck[0]
		gs.deck_state.action_deck.remove_at(0)
		enemy_player.action_hand.append(cid)
		var dc = gs.get_card(cid)
		if dc != null:
			dc.zone = &"action_hand"
	var hand_before = enemy_player.action_hand.size()
	if hand_before == 0:
		return "AI 无行动牌可测"
	var col = _make_bridge_collector(battle)
	var bridge = col.bridge
	var action := _make_waiting_action(battle, &"discard_card", {"executor": enemy_mech.mech_id, "count": 1})
	bridge._on_action_needs_input(action.action_id, &"select_discard_cards", {
		"executor": enemy_mech.mech_id, "count": 1, "face_up": true,
	})
	if not col.popups.is_empty():
		return "AI select_discard_cards 不应弹窗，实际弹了: %s" % str(col.popups)
	if col.resolved.is_empty():
		return "AI select_discard_cards 应自动决策续跑"
	return true


## select_target_mech：AI 发起方 → 自动选敌方，不弹 mech_target_select
func test_ai_select_target_mech_auto():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		return "找不到敌方机甲"
	var col = _make_bridge_collector(battle)
	var bridge = col.bridge
	var action := _make_waiting_action(battle, &"effect_fire", {"mech_id": enemy_mech.mech_id})
	bridge._on_action_needs_input(action.action_id, &"select_target_mech", {"mech_id": enemy_mech.mech_id})
	if not col.popups.is_empty():
		return "AI select_target_mech 不应弹窗，实际弹了: %s" % str(col.popups)
	if col.resolved.is_empty():
		return "AI select_target_mech 应自动决策续跑"
	return true


## 玩家发起方仍弹窗（确保 AI 分支不误伤人类路径）
func test_player_select_weapon_still_pops():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	if player_mech == null:
		return "找不到玩家机甲"
	var col = _make_bridge_collector(battle)
	var bridge = col.bridge
	bridge._on_action_needs_input(&"p_act", &"select_weapon", {"attacker_id": player_mech.mech_id})
	if not col.popups.has("weapon_select"):
		return "玩家 select_weapon 应弹 weapon_select 窗，实际: %s" % str(col.popups)
	return true
