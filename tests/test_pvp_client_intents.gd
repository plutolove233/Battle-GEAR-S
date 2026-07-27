## test_pvp_client_intents.gd - PvP 锁步输入交换（_apply_remote_input）单测
##
## Phase 3 锁步：client/host 对等跑引擎,交换输入。本测试模拟 host 收到 client 的 input
## （_apply_remote_input 即 _dispatch_input 本地执行,无广播），覆盖：
##   Bug 1：client 设置装备 / 卖出装备
##     - set_equipment op：以 enemy 身份调 card_set_service.set_equipment,
##       且从备用区重新设置时先把牌从备用区移回手牌再设置。
##     - sell_equipment op：以 enemy 身份调 card_set_service.sell_equipment。
##   Bug 2：client 迎击移动取消 -> 攻击结算
##     - ui_cancelled op 取消 single_move 循环,使父 use_action_card 与原攻击继续结算（不卡在 ATTACK_AT）。
##
## 用真实 app_root（PVP host 模式，无实际联网）直接调用 _apply_remote_input。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")


func _pump(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


## 建一个 PVP host 模式的 app_root + 教学战斗（无实际联网，直接调 _apply_remote_input）
func _make_pvp_app_root():
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		return null
	app_root.selected_equipment = {}
	app_root._start_tutorial_battle()
	await _pump(3)
	app_root.game_mode = &"PVP"
	app_root.local_player_id = &"player"
	app_root.is_network_client = false
	# PVP 下 enemy 为人类（client 控制），关闭 AI 自动响应/移动
	var enemy_player = app_root.battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	return app_root


func _free_app_root(app_root) -> void:
	if app_root != null:
		app_root.queue_free()
	await _pump(2)


## 给指定玩家加一张牌（复用 dev_edit 路径，会注册 availability）
func _dev_add_card(app_root, op: StringName, target: StringName, card_id: StringName) -> StringName:
	var gs = app_root.battle.context.game_state
	var player = gs.players.get(target)
	if player == null:
		return &""
	app_root._apply_dev_edit(op, {"target": target, "card_id": card_id})
	await _pump(2)
	# 返回刚加入的牌 instance_id（手牌末尾）
	var hand: Array = player.action_hand if String(op) == &"add_action_card" else player.equipment_hand
	if hand.is_empty():
		return &""
	return hand[hand.size() - 1]


## Bug 1a：client 设置装备 intent（手牌 -> 槽位）
func test_client_set_equipment_from_hand():
	var app_root = await _make_pvp_app_root()
	if app_root == null:
		return "app_root 初始化失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	# client 是 enemy，需在 enemy 回合才能设置装备（_handle_client_set_equipment 有 active 守卫）
	gs.active_player_id = &"enemy"

	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		await _free_app_root(app_root)
		return "enemy 机甲缺失"

	var cid: StringName = await _dev_add_card(app_root, &"add_equipment_card", &"enemy", "part_008_联邦普装_躯干")
	if cid == &"":
		await _free_app_root(app_root)
		return "加装备牌失败"
	var enemy_player = gs.players.get(&"enemy")
	if not enemy_player.equipment_hand.has(cid):
		await _free_app_root(app_root)
		return "装备牌未加入 enemy 手牌"

	# host 处理 client 的 set_equipment input：enemy -> 躯干槽
	app_root._apply_remote_input("set_equipment", {"player_id": &"enemy", "card_instance_id": cid, "slot_id": &"躯干"})
	await _pump(3)

	var torso_slot = enemy_mech.slots.get(&"躯干")
	if torso_slot == null or torso_slot.equipped_card == null:
		await _free_app_root(app_root)
		return "设置后躯干槽无装备"
	if torso_slot.equipped_card.instance_id != cid:
		await _free_app_root(app_root)
		return "躯干槽装备 instance_id 不匹配: %s" % String(torso_slot.equipped_card.instance_id)
	if enemy_player.equipment_hand.has(cid):
		await _free_app_root(app_root)
		return "设置后装备仍在手牌中（未移除）"

	await _free_app_root(app_root)
	return true


## Bug 1a-续：client 从备用区重新设置装备（reserve -> hand 迁移 -> 新槽位）
func test_client_set_equipment_from_reserve():
	var app_root = await _make_pvp_app_root()
	if app_root == null:
		return "app_root 初始化失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	gs.active_player_id = &"enemy"
	var enemy_mech = gs.get_mech_for_player(&"enemy")

	var cid: StringName = await _dev_add_card(app_root, &"add_equipment_card", &"enemy", "part_008_联邦普装_躯干")
	if cid == &"":
		await _free_app_root(app_root)
		return "加装备牌失败"

	# 先设置到 reserve_1
	app_root._apply_remote_input("set_equipment", {"player_id": &"enemy", "card_instance_id": cid, "slot_id": &"reserve_1"})
	await _pump(3)
	var r1 = enemy_mech.slots.get(&"reserve_1")
	if r1 == null or r1.equipped_card == null or r1.equipped_card.instance_id != cid:
		await _free_app_root(app_root)
		return "设置到 reserve_1 失败"

	# 再从 reserve_1 重新设置到 reserve_2（_net_set_equipment 先把牌从 reserve_1 移回手牌再 set_equipment）
	app_root._apply_remote_input("set_equipment", {"player_id": &"enemy", "card_instance_id": cid, "slot_id": &"reserve_2"})
	await _pump(3)
	var r2 = enemy_mech.slots.get(&"reserve_2")
	if r2 == null or r2.equipped_card == null or r2.equipped_card.instance_id != cid:
		await _free_app_root(app_root)
		return "reserve->reserve 迁移后 reserve_2 无目标装备"
	if r1.equipped_card != null and r1.equipped_card.instance_id == cid:
		await _free_app_root(app_root)
		return "迁移后 reserve_1 仍持有原装备（未迁出）"

	await _free_app_root(app_root)
	return true


## Bug 1b：client 卖出装备 intent（手牌 -> 卖出换金币 + 弃牌）
func test_client_sell_equipment_from_hand():
	var app_root = await _make_pvp_app_root()
	if app_root == null:
		return "app_root 初始化失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	gs.active_player_id = &"enemy"
	var enemy_player = gs.players.get(&"enemy")

	var cid: StringName = await _dev_add_card(app_root, &"add_equipment_card", &"enemy", "part_008_联邦普装_躯干")
	if cid == &"":
		await _free_app_root(app_root)
		return "加装备牌失败"
	var card = gs.get_card(cid)
	if card == null or card.def == null:
		await _free_app_root(app_root)
		return "装备牌实例/def 缺失"
	var expected_price: int = int(card.def.cost)
	var gold_before: int = enemy_player.gold
	var sell_count_before: int = enemy_player.sell_equipment_count_this_turn

	# 重置本回合卖出次数（dev 流程可能已用过），确保能卖
	enemy_player.sell_equipment_count_this_turn = 0

	app_root._apply_remote_input("sell_equipment", {"player_id": &"enemy", "card_instance_id": cid})
	await _pump(3)

	if enemy_player.equipment_hand.has(cid):
		await _free_app_root(app_root)
		return "卖出后装备仍在手牌中"
	if enemy_player.gold != gold_before + expected_price:
		await _free_app_root(app_root)
		return "卖出后金币未增加 %d：before=%d after=%d" % [expected_price, gold_before, enemy_player.gold]
	if enemy_player.sell_equipment_count_this_turn != sell_count_before + 1 and sell_count_before != 0:
		# sell_count_before 被 reset 为 0，应为 1
		if enemy_player.sell_equipment_count_this_turn != 1:
			await _free_app_root(app_root)
			return "卖出次数未+1：after=%d" % enemy_player.sell_equipment_count_this_turn
	if card.zone != &"discard":
		await _free_app_root(app_root)
		return "卖出后牌未进弃牌堆 zone=%s" % String(card.zone)

	await _free_app_root(app_root)
	return true


## Bug 2：client 取消迎击移动 -> 攻击继续结算
## player 攻击 enemy -> enemy(client) 用回避响应 -> single_move 循环等待选格 ->
## _handle_client_popup_cancel(move_target_select) -> on_ui_cancelled 取消 single_move ->
## 回避 use_action_card 完成 -> 攻击恢复结算（未命中，已移出范围）-> attack 完成。
func test_client_cancel_move_target_completes_attack():
	var app_root = await _make_pvp_app_root()
	if app_root == null:
		return "app_root 初始化失败"
	var battle = app_root.battle
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		await _free_app_root(app_root)
		return "机甲缺失"

	# 敌我相邻，玩家武器范围内；玩家动力充足（回避需消耗 1/2 动力移动）
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	enemy_mech.power = 6
	gs.active_player_id = &"player"

	var weapon_ids: Array[StringName] = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		await _free_app_root(app_root)
		return "玩家无机甲武器"
	var weapon_id: StringName = weapon_ids[0]

	var attack_cid: StringName = await _dev_add_card(app_root, &"add_action_card", &"player", "action_001_进攻")
	if attack_cid == &"":
		await _free_app_root(app_root)
		return "加进攻牌失败"
	var evade_cid: StringName = await _dev_add_card(app_root, &"add_action_card", &"enemy", "action_008_回避")
	if evade_cid == &"":
		await _free_app_root(app_root)
		return "加回避牌失败"

	battle.context.action_ui_bridge.context = battle.context

	# 玩家发起攻击敌方
	var atk_result: Dictionary = battle.execute_attack_action(&"player", &"enemy", weapon_id, attack_cid)
	var attack_action_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""

	# 攻击应暂停在 ATTACK_AT 等待响应
	var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if wait_info.is_empty():
		await _free_app_root(app_root)
		return "攻击未暂停等待响应"
	if String(wait_info.get("input_type", &"")) != &"respond_attack":
		await _free_app_root(app_root)
		return "等待的不是 respond_attack: %s" % String(wait_info.get("input_type", &""))

	# 模拟 client 在响应窗口选回避（走 respond_attack op -> handle_response_selection）
	var resp_action_id: StringName = wait_info.get("action_id", &"")
	app_root._apply_remote_input("respond_attack", {"action_id": resp_action_id, "card_instance_id": evade_cid, "pass": false})
	await _pump(4)

	# 回避发起 single_move 循环，应请求 select_move_target
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"select_move_target":
		await _free_app_root(app_root)
		return "回避响应后未请求 select_move_target: %s" % String(wait2.get("input_type", &""))

	# 模拟 client 点取消结束移动循环（Bug 2 核心：ui_cancelled op 取消 single_move）
	app_root._apply_remote_input("ui_cancelled", {})
	await _pump(8)

	# 处理可能的 place_damage_tokens（若攻击仍命中）
	for _i in 6:
		var w4: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if String(w4.get("input_type", &"")) == &"place_damage_tokens":
			battle.context.action_ui_bridge.on_ui_confirmed({"placed": true})
			await _pump(4)
		else:
			break
	await _pump(6)

	# 攻击动作应已完成并从 registry 移除
	var attack_action = battle.context.action_registry.get_action(attack_action_id)
	if attack_action != null:
		await _free_app_root(app_root)
		return "取消移动后攻击未完成，state=%s（Bug2：client 取消迎击移动后攻击卡在 ATTACK_AT）" % String(attack_action.state)
	var active_count: int = battle.context.action_registry.get_active_count()
	if active_count != 0:
		await _free_app_root(app_root)
		return "取消移动后仍有 %d 个活跃动作残留" % active_count

	await _free_app_root(app_root)
	return true
