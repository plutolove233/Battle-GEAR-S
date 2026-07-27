## test_energy_unite_fix.gd - 聚能选武器死循环 / 联合弃牌抽牌 修复测试
##
## 聚能：打出后应挂起 select_weapon_for_charge，on_ui_confirmed({selected_weapon_id})
##       续跑后对该武器施加 ENERGY_CHARGE 状态（修复前 _on_weapon_selected 匹配错 input_type
##       + resume 不注入 selected_weapon_id -> 选武器死循环）。
## 联合·使用效果：打出后挂起 select_mech_target（CHOOSE_OTHER_MECH），选目标后施加 UNITE 状态。
## 联合·弃牌抽牌：直接 discard_card + draw_action_cards（unite_discard_draw 网络op 的底层逻辑），
##                 联合牌从手牌进弃牌堆、抽1张行动牌、手牌数不变。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")


## 等一帧，flush call_deferred 排入的动作恢复（-s 模式靠 SceneTree 主循环）。
func _frame() -> void:
	var ml = Engine.get_main_loop()
	if ml and ml is SceneTree:
		await (ml as SceneTree).process_frame


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


func _ensure_card_in_hand(battle, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for cid: StringName in player.action_hand:
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			return cid
	for i in range(gs.deck_state.action_deck.size()):
		var cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_deck.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			return cid
	return &""


## 聚能：选武器后施加 ENERGY_CHARGE
func test_energy_applies_charge_to_selected_weapon() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null:
		return "找不到玩家机甲"

	var weapon_ids: Array[StringName] = pmech.get_weapon_ids()
	if weapon_ids.is_empty():
		return "玩家机甲无可用武器"
	var weapon_id: StringName = weapon_ids[0]

	var card_id := _ensure_card_in_hand(battle, "action_014_聚能")
	if card_id == &"":
		return "找不到聚能牌（action_014_聚能）"

	var res := battle.execute_use_action_card(&"player", card_id)
	print("[ENERGY] execute_use_action_card 返回 = ", res)
	var bridge = battle.context.action_ui_bridge

	# 1) 应挂起 select_weapon_for_charge（修复前 UI 匹配 weapon_charge_select 永不命中）
	var w1 = bridge.get_waiting_action_info() if bridge else {}
	print("[ENERGY] step1 waiting = ", w1.get("input_type", &"<none>"))
	if w1.get("input_type", &"") != &"select_weapon_for_charge":
		return "step1: 未挂起 select_weapon_for_charge，而是 %s" % w1.get("input_type", &"<none>")

	# 2) 注入 selected_weapon_id 续跑（CHOOSE_OWN_WEAPON 读此键）
	bridge.on_ui_confirmed({"selected_weapon_id": weapon_id})
	await _frame()

	# 3) 应对该武器施加 ENERGY_CHARGE 状态
	var found := false
	for s: Dictionary in pmech.statuses:
		if s.get("type", &"") == &"ENERGY_CHARGE" and s.get("weapon_id", &"") == weapon_id:
			found = true
			break
	if not found:
		return "step3: 聚能状态未施加到武器 %s（statuses=%s）" % [String(weapon_id), str(pmech.statuses)]
	return true


## 联合·使用效果：选其他机甲施加 UNITE 状态
func test_unite_use_effect_applies_status() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	gs.active_player_id = &"player"
	var emech = gs.get_mech_for_player(&"enemy")
	if emech == null:
		return "找不到敌方机甲"

	var card_id := _ensure_card_in_hand(battle, "action_018_联合")
	if card_id == &"":
		return "找不到联合牌（action_018_联合）"

	var res := battle.execute_use_action_card(&"player", card_id)
	print("[UNITE] execute_use_action_card 返回 = ", res)
	var bridge = battle.context.action_ui_bridge

	# 1) 应挂起 select_mech_target（CHOOSE_OTHER_MECH）
	var w1 = bridge.get_waiting_action_info() if bridge else {}
	print("[UNITE] step1 waiting = ", w1.get("input_type", &"<none>"))
	if w1.get("input_type", &"") != &"select_mech_target":
		return "step1: 未挂起 select_mech_target，而是 %s" % w1.get("input_type", &"<none>")

	# 2) 选敌方机甲续跑 -> ADD_STATUS UNITE
	bridge.on_ui_confirmed({"target_id": emech.mech_id})
	await _frame()

	if not emech.has_status(&"UNITE"):
		return "step2: 联合状态未施加到敌方机甲"
	return true


## 联合·弃牌抽牌：验证底层原子方法 discard_card + draw_action_cards（回合清理等路径仍用）。
## 注：联合效果2 网络op 已改走正式 discard_card + gain_card 动作（带时点），
## 见 test_unite_status_flow.gd::test_unite_effect2_discard_draw_via_actions。
func test_unite_discard_draw() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var ctx = battle.context
	var player = gs.players.get(&"player")
	if player == null:
		return "找不到玩家"

	var card_id := _ensure_card_in_hand(battle, "action_018_联合")
	if card_id == &"":
		return "找不到联合牌（action_018_联合）"
	if gs.deck_state.action_deck.is_empty():
		return "行动牌堆为空，无法验证抽牌"

	var hand_before: int = player.action_hand.size()
	var card = gs.get_card(card_id)

	# 模拟 unite_discard_draw 网络op 的双端执行（直接 GameActions）
	ctx.game_actions.discard_card({"card_id": card_id, "reason": &"UNITE_DISCARD"})
	ctx.game_actions.draw_action_cards({"player_id": &"player", "count": 1, "reason": &"UNITE_DRAW"})

	# 1) 联合牌应离开手牌、进入弃牌堆
	if player.action_hand.has(card_id):
		return "联合牌仍在手牌（应已弃置）"
	if card == null or String(card.zone) != &"discard":
		return "联合牌 zone 非 discard（实际 %s）" % (String(card.zone) if card else "<null>")
	# 2) 抽1张：手牌数应不变（弃1抽1）
	if player.action_hand.size() != hand_before:
		return "手牌数应不变（弃1抽1）：before=%d after=%d" % [hand_before, player.action_hand.size()]
	return true
