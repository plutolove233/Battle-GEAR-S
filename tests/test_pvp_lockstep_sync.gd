## test_pvp_lockstep_sync.gd - PvP 锁步操作同步验证
##
## Phase 3 锁步：双端对等跑引擎，交换输入。本测试建两个 app_root 实例（同种子建局 =>
## 相同初始状态），host 调 _net_exec（本地执行+广播，测试中无网络故广播 no-op）发 input，
## 手动把同一 op/data 喂给 client 的 _apply_remote_input，断言双端 game_state 关键字段一致。
##
## 覆盖：初始确定性 / 移动 / 设装备 / 商店 / 结束回合 / 攻击全流程(选武器+选目标+迎击响应+损伤放置)。
##
## 另含回归测试 test_client_self_build_connects_popup_signals：复刻 client 真实启动路径
## （_start_pvp_client 临时 context + _show_battle -> _apply_pvp_seed_and_build 新建替换 context），
## 断言新 context 的 action_ui_bridge/timing_engine/action_engine 信号已重连。
## 未修复前 client 自建后 request_ui_popup 无人接收 => weapon_select/attack_target_select/
## response_window 弹窗不弹（client 用攻击牌不弹选择窗口、被攻击不弹响应窗口的根因）。
extends RefCounted

const _AppRootScript = preload("res://scripts/app/app_root.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _BattleState = preload("res://scripts/battle/battle_state.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")


func _pump(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _free_app_root(app_root) -> void:
	if app_root != null:
		app_root.queue_free()
	await _pump(2)


## 同种子建局（host 风格：start_tutorial -> start_turn -> _show_battle 连信号）。
## local_pid 决定本窗口视角（player=host / enemy=client）。双端用同 seed => 相同牌堆/初始状态。
func _build_pvp_app_root(seed_val: int, local_pid: StringName):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		return null
	app_root.game_mode = &"PVP"
	app_root.local_player_id = local_pid
	app_root.is_network_client = (String(local_pid) == &"enemy")
	app_root.battle = _BattleState.new()
	app_root.battle.rng_seed = seed_val
	var r = app_root.battle.start_tutorial(app_root.registry)
	if not app_root._status_ok(r):
		return null
	var ep = app_root.battle.context.game_state.players.get(&"enemy")
	if ep != null:
		ep.is_human = true
	app_root.battle.start_turn(&"player")
	app_root._show_battle()  # _connect_action_signals 连到真实 context
	await _pump(2)
	return app_root


## 复刻 client 真实启动路径（一段式：_start_pvp_client 连 host 占位 -> 收种子 _apply_pvp_seed_and_build
## 即 start_tutorial + _show_battle，与 host 一致，无临时 context 替换）。用于回归测试：
## 自建后真实 context 的弹窗信号已连。
func _make_pvp_client_app_root(seed_val: int):
	var tree := Engine.get_main_loop() as SceneTree
	var app_root = _AppRootScript.new()
	app_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	tree.root.add_child(app_root)
	await _pump(3)
	if app_root.registry == null:
		return null
	app_root.is_network_client = true
	app_root.game_mode = &"PVP"
	app_root.local_player_id = &"enemy"
	# 一段式：直接 _apply_pvp_seed_and_build（start_tutorial 建真实 context + _show_battle 连信号）
	app_root._apply_pvp_seed_and_build(seed_val)
	await _pump(2)
	return app_root


func _wait_input_type(app_root) -> StringName:
	if app_root.battle == null or app_root.battle.context == null or app_root.battle.context.action_ui_bridge == null:
		return &""
	var wi: Dictionary = app_root.battle.context.action_ui_bridge.get_waiting_action_info()
	return wi.get("input_type", &"")


func _wait_action_id(app_root) -> StringName:
	if app_root.battle == null or app_root.battle.context == null or app_root.battle.context.action_ui_bridge == null:
		return &""
	var wi: Dictionary = app_root.battle.context.action_ui_bridge.get_waiting_action_info()
	return wi.get("action_id", &"")


## 双端 dev_add 同一张牌，返回 instance_id（双端计数器同序 => 同 id）
func _dev_add_card_both(host, client, op: StringName, target: StringName, card_id: String) -> StringName:
	host._apply_dev_edit(op, {"target": target, "card_id": card_id})
	client._apply_dev_edit(op, {"target": target, "card_id": card_id})
	await _pump(2)
	var hplayer = host.battle.context.game_state.players.get(target)
	var cplayer = client.battle.context.game_state.players.get(target)
	if hplayer == null or cplayer == null:
		return &""
	var hhand: Array = hplayer.action_hand if String(op) == &"add_action_card" else hplayer.equipment_hand
	var chand: Array = cplayer.action_hand if String(op) == &"add_action_card" else cplayer.equipment_hand
	if hhand.is_empty() or chand.is_empty():
		return &""
	var hid: StringName = hhand[hhand.size() - 1]
	var cid: StringName = chand[chand.size() - 1]
	if hid != cid:
		return &""  # 双端 instance_id 不同，调用方会断言失败
	return hid


# ═══════════════════════════════════════════
# 回归测试：client 自建后弹窗信号重连（本次 bug 的核心）
# ═══════════════════════════════════════════

func test_client_self_build_connects_popup_signals() -> Variant:
	var app_root = await _make_pvp_client_app_root(12345)
	if app_root == null:
		return "client app_root 初始化失败"
	var ctx = app_root.battle.context
	if ctx == null or ctx.action_ui_bridge == null:
		await _free_app_root(app_root)
		return "自建后 context/action_ui_bridge 缺失"
	var pu := Callable(app_root, "_on_action_ui_popup_requested")
	if not ctx.action_ui_bridge.request_ui_popup.is_connected(pu):
		await _free_app_root(app_root)
		return "自建后 request_ui_popup 未连接到 _on_action_ui_popup_requested（client 弹窗不弹根因未修复）"
	var ir := Callable(app_root, "_on_action_input_resolved")
	if not ctx.action_ui_bridge.action_input_resolved.is_connected(ir):
		await _free_app_root(app_root)
		return "自建后 action_input_resolved 未连接"
	var tf := Callable(app_root, "_on_timing_fired")
	if not ctx.timing_engine.timing_fired.is_connected(tf):
		await _free_app_root(app_root)
		return "自建后 timing_fired 未连接"
	var ts := Callable(app_root, "_on_target_selection_requested")
	if not ctx.timing_engine.request_target_selection.is_connected(ts):
		await _free_app_root(app_root)
		return "自建后 request_target_selection 未连接"
	var ac := Callable(app_root, "_on_action_completed")
	if not ctx.action_engine.action_completed.is_connected(ac):
		await _free_app_root(app_root)
		return "自建后 action_completed 未连接"
	await _free_app_root(app_root)
	return true


# ═══════════════════════════════════════════
# 锁步同步：双端同种子 => 初始状态完全一致
# ═══════════════════════════════════════════

func test_lockstep_identical_initial_state() -> Variant:
	var seed_val := 777
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host)
		await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	var cg = client.battle.context.game_state
	var hpm = hg.get_mech_for_player(&"player")
	var cpm = cg.get_mech_for_player(&"player")
	if hpm.current_hp != cpm.current_hp:
		await _free_app_root(host); await _free_app_root(client)
		return "player 机甲 HP 不一致 host=%d client=%d" % [hpm.current_hp, cpm.current_hp]
	if hpm.position != cpm.position:
		await _free_app_root(host); await _free_app_root(client)
		return "player 机甲位置不一致"
	var hph: int = hg.players.get(&"player").action_hand.size()
	var cph: int = cg.players.get(&"player").action_hand.size()
	if hph != cph:
		await _free_app_root(host); await _free_app_root(client)
		return "player 行动牌数不一致 host=%d client=%d" % [hph, cph]
	# 同种子洗牌 => 行动牌堆顺序一致（instance_id 同序生成）
	if hg.deck_state.action_deck != cg.deck_state.action_deck:
		await _free_app_root(host); await _free_app_root(client)
		return "行动牌堆顺序不一致（种子确定性失败）"
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：move op 双端位置一致
# ═══════════════════════════════════════════

func test_lockstep_move_sync() -> Variant:
	var seed_val := 111
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	var player_mech = hg.get_mech_for_player(&"player")
	var pos: Dictionary = player_mech.position
	var cells: Dictionary = hg.map_state.cells if hg.map_state else {}
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(pos, player_mech.power, cells)
	if reachable.is_empty():
		await _free_app_root(host); await _free_app_root(client)
		return "无可达移动格（power=%d）" % player_mech.power
	var target: Dictionary = reachable[0]
	var tq := int(target.get("q", 0))
	var tr := int(target.get("r", 0))
	host._net_exec("move", {"player_id": &"player", "q": tq, "r": tr})
	await _pump(3)
	client._apply_remote_input("move", {"player_id": &"player", "q": tq, "r": tr})
	await _pump(3)
	var hpos: Dictionary = host.battle.context.game_state.get_mech_for_player(&"player").position
	var cpos: Dictionary = client.battle.context.game_state.get_mech_for_player(&"player").position
	if hpos != cpos:
		await _free_app_root(host); await _free_app_root(client)
		return "移动后 player 位置不一致 host=%s client=%s" % [str(hpos), str(cpos)]
	if int(hpos.get("q", -1)) == int(pos.get("q", -2)) and int(hpos.get("r", -1)) == int(pos.get("r", -2)):
		await _free_app_root(host); await _free_app_root(client)
		return "未实际移动"
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：cancel_move 按 mech_id 取消 + 强制同步位置/动力/格数
# 复现并验证问题2根因修复：移动取消时若按 action_id 取消（锁步计数器发散则空操作），
# 远端 single_move 会走到终点致位置不同步。现 cancel_move 带 mech_id+位置/动力/格数，
# 远端无论是否仍在移动都被强制拉回本方取消时的真实状态。
# ═══════════════════════════════════════════

func test_lockstep_cancel_move_syncs_position() -> Variant:
	var seed_val := 333
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	var player_mech = hg.get_mech_for_player(&"player")
	var mech_id: StringName = player_mech.mech_id
	var start_pos: Dictionary = player_mech.position.duplicate()
	var start_power: int = player_mech.power
	var cells: Dictionary = hg.map_state.cells if hg.map_state else {}
	var reachable: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(start_pos, player_mech.power, cells)
	if reachable.is_empty():
		await _free_app_root(host); await _free_app_root(client)
		return "无可达移动格"
	var target: Dictionary = reachable[0]
	# 模拟"远端走到终点/不同步"的发散：把 client 的 player 机甲强行挪到 target（动力也改），
	# 代表远端状态与本方（仍在起点）不一致。随后用本方实际状态构造 cancel_move，
	# 验证远端被强制同步回本方真实位置/动力/格数（不依赖 action_id 匹配）。
	var cplayer_mech = client.battle.context.game_state.get_mech_for_player(&"player")
	cplayer_mech.position = {"q": int(target.get("q", 0)), "r": int(target.get("r", 0))}
	cplayer_mech.power = start_power - 1
	cplayer_mech.power_spent_this_turn = 1
	cplayer_mech.cells_moved_this_turn = 1
	# 模拟"先前动作(设装备/打牌)致计数器发散"：把 client 的 action 计数器强行抬高，
	# 代表两端 ActionRegistry._id_counter 不一致（后续攻击 action_id 会不匹配）。cancel_move
	# 应把远端计数器拉回本方值。
	var host_counter: int = host.battle.context.action_registry._id_counter
	client.battle.context.action_registry._id_counter = host_counter + 7
	# 本方（host）仍在起点：用 host 实际状态构造 cancel_move 数据
	var cancel_data := {
		"mech_id": String(mech_id),
		"q": int(start_pos.get("q", 0)),
		"r": int(start_pos.get("r", 0)),
		"power": start_power,
		"power_spent": 0,
		"cells_moved": 0,
		"action_counter": host_counter,
	}
	host._net_exec("cancel_move", cancel_data)
	await _pump(2)
	client._apply_remote_input("cancel_move", cancel_data)
	await _pump(2)
	# 断言：client 被强制同步回起点（位置/动力/格数都与 host 一致）
	var hpos: Dictionary = host.battle.context.game_state.get_mech_for_player(&"player").position
	var cpos2: Dictionary = client.battle.context.game_state.get_mech_for_player(&"player").position
	if int(hpos.get("q", -1)) != int(start_pos.get("q", -2)) or int(hpos.get("r", -1)) != int(start_pos.get("r", -2)):
		await _free_app_root(host); await _free_app_root(client)
		return "host 位置被错误改动: %s want %s" % [str(hpos), str(start_pos)]
	if int(cpos2.get("q", -1)) != int(start_pos.get("q", -2)) or int(cpos2.get("r", -1)) != int(start_pos.get("r", -2)):
		await _free_app_root(host); await _free_app_root(client)
		return "client 未被 cancel_move 同步回起点: %s want %s" % [str(cpos2), str(start_pos)]
	var cpower: int = client.battle.context.game_state.get_mech_for_player(&"player").power
	var ccells: int = client.battle.context.game_state.get_mech_for_player(&"player").cells_moved_this_turn
	if cpower != start_power:
		await _free_app_root(host); await _free_app_root(client)
		return "client 动力未同步: %d want %d" % [cpower, start_power]
	if ccells != 0:
		await _free_app_root(host); await _free_app_root(client)
		return "client 移动格数未同步: %d want 0" % [ccells]
	# 计数器应被拉回本方值（纠正先前发散，保证后续动作 action_id 对齐）
	var ccounter: int = client.battle.context.action_registry._id_counter
	if ccounter != host_counter:
		await _free_app_root(host); await _free_app_root(client)
		return "client 计数器未同步: %d want %d" % [ccounter, host_counter]
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：set_equipment op 双端槽位装备一致
# ═══════════════════════════════════════════

func test_lockstep_set_equipment_sync() -> Variant:
	var seed_val := 222
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	hg.active_player_id = &"enemy"
	client.battle.context.game_state.active_player_id = &"enemy"
	var cid: StringName = await _dev_add_card_both(host, client, &"add_equipment_card", &"enemy", "part_008_联邦普装_躯干")
	if cid == &"":
		await _free_app_root(host); await _free_app_root(client)
		return "双端加装备牌失败或 instance_id 不同步"
	host._net_exec("set_equipment", {"player_id": &"enemy", "card_instance_id": cid, "slot_id": &"躯干"})
	await _pump(3)
	client._apply_remote_input("set_equipment", {"player_id": &"enemy", "card_instance_id": cid, "slot_id": &"躯干"})
	await _pump(3)
	var hslot = host.battle.context.game_state.get_mech_for_player(&"enemy").slots.get(&"躯干")
	var cslot = client.battle.context.game_state.get_mech_for_player(&"enemy").slots.get(&"躯干")
	if hslot == null or hslot.equipped_card == null or hslot.equipped_card.instance_id != cid:
		await _free_app_root(host); await _free_app_root(client)
		return "host 躯干槽未设置目标装备"
	if cslot == null or cslot.equipped_card == null or cslot.equipped_card.instance_id != cid:
		await _free_app_root(host); await _free_app_root(client)
		return "client 躯干槽未设置目标装备（set_equipment op 未同步）"
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：shop_buy op 双端金币/手牌一致
# ═══════════════════════════════════════════

func test_lockstep_shop_buy_sync() -> Variant:
	var seed_val := 333
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	hg.active_player_id = &"player"
	client.battle.context.game_state.active_player_id = &"player"
	var gold_before: int = hg.players.get(&"player").gold
	var hand_before: int = hg.players.get(&"player").equipment_hand.size()
	host._net_exec("shop_buy", {"player_id": &"player", "kind": "normal", "slot_index": 0, "discount": false})
	await _pump(3)
	client._apply_remote_input("shop_buy", {"player_id": &"player", "kind": "normal", "slot_index": 0, "discount": false})
	await _pump(3)
	var hp = host.battle.context.game_state.players.get(&"player")
	var cp = client.battle.context.game_state.players.get(&"player")
	if hp.gold != cp.gold:
		await _free_app_root(host); await _free_app_root(client)
		return "购买后金币不一致 host=%d client=%d" % [hp.gold, cp.gold]
	if hp.gold >= gold_before:
		await _free_app_root(host); await _free_app_root(client)
		return "购买未扣金币 before=%d after=%d" % [gold_before, hp.gold]
	if hp.equipment_hand.size() != cp.equipment_hand.size():
		await _free_app_root(host); await _free_app_root(client)
		return "购买后装备手牌数不一致 host=%d client=%d" % [hp.equipment_hand.size(), cp.equipment_hand.size()]
	if hp.equipment_hand.size() <= hand_before:
		await _free_app_root(host); await _free_app_root(client)
		return "购买后装备手牌未增加"
	# 买到的牌 instance_id 双端应一致
	if hp.equipment_hand[hp.equipment_hand.size() - 1] != cp.equipment_hand[cp.equipment_hand.size() - 1]:
		await _free_app_root(host); await _free_app_root(client)
		return "买到的装备 instance_id 不一致"
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：end_turn op 双端回合/行动方一致
# ═══════════════════════════════════════════

func test_lockstep_end_turn_sync() -> Variant:
	var seed_val := 444
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	hg.active_player_id = &"player"
	client.battle.context.game_state.active_player_id = &"player"
	host._net_exec("end_turn", {"player_id": &"player", "discarded_card_ids": []})
	await _pump(4)
	client._apply_remote_input("end_turn", {"player_id": &"player", "discarded_card_ids": []})
	await _pump(4)
	var hg2 = host.battle.context.game_state
	var cg2 = client.battle.context.game_state
	if hg2.active_player_id != cg2.active_player_id:
		await _free_app_root(host); await _free_app_root(client)
		return "结束后行动方不一致 host=%s client=%s" % [String(hg2.active_player_id), String(cg2.active_player_id)]
	if hg2.active_player_id != &"enemy":
		await _free_app_root(host); await _free_app_root(client)
		return "结束后未切到敌方回合 active=%s" % String(hg2.active_player_id)
	if hg2.turn_number != cg2.turn_number:
		await _free_app_root(host); await _free_app_root(client)
		return "结束后 turn_number 不一致 host=%d client=%d" % [hg2.turn_number, cg2.turn_number]
	# 注：turn_number 在单次 end_turn 不推进（回合数在下次 ROUND_START 才 +1），
	# 此处只验双端同步与行动方切换。
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 锁步同步：攻击全流程（选武器+选目标+迎击响应pass+损伤放置）双端一致
# 覆盖用户报告的 bug 路径：client 用攻击牌弹选择窗口、被攻击弹响应窗口。
# ═══════════════════════════════════════════

func _drain_damage_placement(host, client, target_mech_id: StringName) -> String:
	for _i in 20:
		var ht: StringName = _wait_input_type(host)
		if ht != &"place_damage_tokens":
			break
		var hwi: Dictionary = host.battle.context.action_ui_bridge.get_waiting_action_info()
		var amount: int = int(hwi.get("input_params", {}).get("amount", 0))
		var slots: Array = host.battle.context.damage_token_service.get_valid_damage_slots(target_mech_id)
		if slots.is_empty():
			return "无可用损伤槽位（amount=%d）" % amount
		for j in amount:
			var slot_id: StringName = slots[j % slots.size()]
			host._net_exec("damage_place", {"slot_id": slot_id, "target_mech_id": target_mech_id})
			client._apply_remote_input("damage_place", {"slot_id": slot_id, "target_mech_id": target_mech_id})
			await _pump(2)
		host._net_exec("ui_confirmed", {"data": {"placed": true}})
		client._apply_remote_input("ui_confirmed", {"data": {"placed": true}})
		await _pump(4)
	return ""


func test_lockstep_attack_flow_sync() -> Variant:
	var seed_val := 555
	var host = await _build_pvp_app_root(seed_val, &"player")
	var client = await _build_pvp_app_root(seed_val, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var hg = host.battle.context.game_state
	hg.active_player_id = &"player"
	client.battle.context.game_state.active_player_id = &"player"
	var player_mech = hg.get_mech_for_player(&"player")
	var enemy_mech = hg.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		await _free_app_root(host); await _free_app_root(client)
		return "机甲缺失"
	# 敌我相邻、在玩家武器射程内
	player_mech.position = {"q": 5, "r": 0}
	enemy_mech.position = {"q": 6, "r": 0}
	client.battle.context.game_state.get_mech_for_player(&"player").position = {"q": 5, "r": 0}
	client.battle.context.game_state.get_mech_for_player(&"enemy").position = {"q": 6, "r": 0}
	var weapon_ids: Array[StringName] = player_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		await _free_app_root(host); await _free_app_root(client)
		return "玩家无机甲武器"
	var weapon_id: StringName = weapon_ids[0]
	var enemy_hp_before: int = enemy_mech.current_hp

	var attack_cid: StringName = await _dev_add_card_both(host, client, &"add_action_card", &"player", "action_001_进攻")
	if attack_cid == &"":
		await _free_app_root(host); await _free_app_root(client)
		return "双端加进攻牌失败或 instance_id 不同步"

	# ① 打攻击牌 -> 双端暂停在 select_weapon（用户 bug：client 此处不弹窗）
	host._net_exec("play_action_card", {"player_id": &"player", "card_instance_id": attack_cid})
	await _pump(3)
	client._apply_remote_input("play_action_card", {"player_id": &"player", "card_instance_id": attack_cid})
	await _pump(3)
	if _wait_input_type(host) != &"select_weapon":
		await _free_app_root(host); await _free_app_root(client)
		return "host 打攻击牌后未暂停在 select_weapon: %s" % String(_wait_input_type(host))
	if _wait_input_type(client) != &"select_weapon":
		await _free_app_root(host); await _free_app_root(client)
		return "client 打攻击牌后未暂停在 select_weapon（弹窗信号未连，bug 未修复）: %s" % String(_wait_input_type(client))

	# ② 选武器 -> 双端暂停在 select_attack_target
	host._net_exec("ui_confirmed", {"data": {"weapon_id": weapon_id}})
	await _pump(3)
	client._apply_remote_input("ui_confirmed", {"data": {"weapon_id": weapon_id}})
	await _pump(3)
	if _wait_input_type(host) != &"select_attack_target":
		await _free_app_root(host); await _free_app_root(client)
		return "选武器后 host 未暂停在 select_attack_target: %s" % String(_wait_input_type(host))
	if _wait_input_type(client) != &"select_attack_target":
		await _free_app_root(host); await _free_app_root(client)
		return "选武器后 client 未暂停在 select_attack_target: %s" % String(_wait_input_type(client))

	# ③ 选目标(enemy_mech) -> 双端暂停在 respond_attack（用户 bug：client 被攻击不弹响应窗口）
	host._net_exec("ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	await _pump(3)
	client._apply_remote_input("ui_confirmed", {"data": {"target_id": enemy_mech.mech_id}})
	await _pump(3)
	if _wait_input_type(host) != &"respond_attack":
		await _free_app_root(host); await _free_app_root(client)
		return "选目标后 host 未暂停在 respond_attack: %s" % String(_wait_input_type(host))
	if _wait_input_type(client) != &"respond_attack":
		await _free_app_root(host); await _free_app_root(client)
		return "选目标后 client 未暂停在 respond_attack（响应窗口信号未连，bug 未修复）: %s" % String(_wait_input_type(client))

	# ④ 迎击响应 pass（不迎击）-> 命中 -> 损伤放置（若有）
	var resp_action_id: StringName = _wait_action_id(host)
	host._net_exec("respond_attack", {"action_id": resp_action_id, "pass": true})
	await _pump(3)
	client._apply_remote_input("respond_attack", {"action_id": resp_action_id, "pass": true})
	await _pump(3)

	# ⑤ 排空损伤放置（markers>0 时逐点 damage_place + ui_confirmed(placed)）
	var drain_err: String = await _drain_damage_placement(host, client, enemy_mech.mech_id)
	if drain_err != "":
		await _free_app_root(host); await _free_app_root(client)
		return "损伤放置排空失败: %s" % drain_err
	await _pump(4)

	# ⑥ 攻击动作双端完成、HP 一致
	var h_active: int = host.battle.context.action_registry.get_active_count()
	var c_active: int = client.battle.context.action_registry.get_active_count()
	if h_active != 0 or c_active != 0:
		await _free_app_root(host); await _free_app_root(client)
		return "攻击未完成 host_active=%d client_active=%d" % [h_active, c_active]
	var h_enemy_hp: int = host.battle.context.game_state.get_mech_for_player(&"enemy").current_hp
	var c_enemy_hp: int = client.battle.context.game_state.get_mech_for_player(&"enemy").current_hp
	if h_enemy_hp != c_enemy_hp:
		await _free_app_root(host); await _free_app_root(client)
		return "攻击后 enemy HP 不一致 host=%d client=%d" % [h_enemy_hp, c_enemy_hp]
	if h_enemy_hp > enemy_hp_before:
		await _free_app_root(host); await _free_app_root(client)
		return "攻击后 enemy HP 未下降 before=%d after=%d" % [enemy_hp_before, h_enemy_hp]
	await _free_app_root(host)
	await _free_app_root(client)
	return true


# ═══════════════════════════════════════════
# 识破偷牌弹窗路由：_popup_owner 应按 executor(防御方/识破使用方) 路由，
# 而非 discard_player_id(攻击方/被偷的人)。
# 修复前 bug：client 用识破响应攻击，弹窗却路由给攻击方 host -> host 选牌。
# ═══════════════════════════════════════════

func test_expose_steal_popup_routed_to_defender() -> Variant:
	var host = await _build_pvp_app_root(888, &"player")
	var client = await _build_pvp_app_root(888, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	# 识破偷牌 input_params（steal_action_card_action._step_determine_cards 构造）：
	#   executor = 识破使用方(防御方 = enemy)，discard_player_id = 攻击方(被偷的人 = player)
	var params := {
		"action_id": &"test_expose_steal",
		"mode": &"need_input",
		"executor": &"enemy",
		"count": 1,
		"face_up": false,
		"discard_player_id": &"player",
	}
	# host(local=player): owner 应=enemy != local -> 本端不弹(等对方 input)
	# client(local=enemy): owner 应=enemy == local -> 本端弹窗选牌
	var host_owner: StringName = host._popup_owner(&"discard_card_select", params)
	var client_owner: StringName = client._popup_owner(&"discard_card_select", params)
	await _free_app_root(host); await _free_app_root(client)
	if host_owner == &"player":
		return "未修复：弹窗仍按 discard_player_id 路由给攻击方 player（client 用识破却 host 选牌的 bug）"
	if host_owner != &"enemy":
		return "host 端识破偷牌弹窗归属错误：期望 enemy(防御方) 本端不弹，实际 %s" % String(host_owner)
	if client_owner != &"enemy":
		return "client 端识破偷牌弹窗归属错误：期望 enemy(防御方/识破使用方) 本端弹，实际 %s" % String(client_owner)
	return true


# ═══════════════════════════════════════════
# 联合攻击弹窗路由：_popup_owner 应按 target_mech_id 路由给 Target（被联合者）玩家，
# 而非发动攻击的 unite 机甲玩家。player 对 enemy 施加联合，player 攻击结算后，
# 弹窗应弹给 enemy(client)，host(player) 本端不弹。
# ═══════════════════════════════════════════

func test_unite_attack_popup_routed_to_target() -> Variant:
	var host = await _build_pvp_app_root(888, &"player")
	var client = await _build_pvp_app_root(888, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var enemy_mech = host.battle.context.game_state.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		await _free_app_root(host); await _free_app_root(client)
		return "找不到 enemy 机甲"
	# 联合攻击弹窗 input_params（TimingEngine.UNITE_ATTACK_OFFER 构造）：
	# target_mech_id = 联合状态所在机甲（Target = enemy），player_id = Target 玩家。
	var params := {
		"action_id": &"test_unite_attack",
		"effect_id": &"unite_status_attack",
		"card_ids": [],
		"target_mech_id": enemy_mech.mech_id,
		"status_id": &"status_test",
		"player_id": &"enemy",
		"label": "联合攻击：选择1张攻击牌使用",
	}
	# host(local=player): owner 应=enemy != local -> 本端不弹(等对方 input)
	# client(local=enemy): owner 应=enemy == local -> 本端弹窗选牌
	var host_owner: StringName = host._popup_owner(&"unite_attack_select", params)
	var client_owner: StringName = client._popup_owner(&"unite_attack_select", params)
	await _free_app_root(host); await _free_app_root(client)
	if host_owner != &"enemy":
		return "host 端联合攻击弹窗归属错误：期望 enemy(Target) 本端不弹，实际 %s" % String(host_owner)
	if client_owner != &"enemy":
		return "client 端联合攻击弹窗归属错误：期望 enemy(Target) 本端弹，实际 %s" % String(client_owner)
	return true


# ═══════════════════════════════════════════
# 维修移除损伤弹窗路由：_popup_owner 应按 executor(维修使用者) 路由，
# 即使维修对其他机甲使用，损伤移除位置也由使用者决定。
# 修复前 bug：damage_change 的 executor 从 action.record.source 推导，
# 但 _create_action 把 source 注入 action.source 而非 record -> executor 空 ->
# _popup_owner 返回空 -> 双端都不拦截 -> 所有玩家都弹窗、维修能作用多次。
# ═══════════════════════════════════════════

func test_repair_damage_removal_popup_routed_to_user() -> Variant:
	var host = await _build_pvp_app_root(888, &"player")
	var client = await _build_pvp_app_root(888, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	var enemy_mech = host.battle.context.game_state.get_mech_for_player(&"enemy")
	if enemy_mech == null:
		await _free_app_root(host); await _free_app_root(client)
		return "找不到 enemy 机甲"
	# 维修移除损伤 input_params（damage_change_action._step_set_damage decrease 构造）：
	# executor = 使用者(player/host)，mech_ids = 被维修机甲(enemy)，removal_mode=true。
	# 即使对 enemy 机甲使用，损伤框也只弹给使用者 player。
	var params := {
		"action_id": &"test_repair_remove",
		"mech_ids": [enemy_mech.mech_id],
		"amount": 2,
		"executor": &"player",
		"removal_mode": true,
	}
	# host(local=player): owner 应=player == local -> 本端弹（使用者操作损伤框）
	# client(local=enemy): owner 应=player != local -> 本端不弹（拦截，等对方 ui_confirmed）
	var host_owner: StringName = host._popup_owner(&"damage_token_placement", params)
	var client_owner: StringName = client._popup_owner(&"damage_token_placement", params)
	await _free_app_root(host); await _free_app_root(client)
	# 修复前 executor 空 -> owner 为空 -> 双端都不拦截 -> 双端都弹窗、维修作用多次
	if host_owner != &"player":
		return "host 端维修移除损伤弹窗归属错误：期望 player(使用者) 本端弹，实际 %s" % String(host_owner)
	if client_owner != &"player":
		return "client 端维修移除损伤弹窗归属错误：期望 player(使用者) 本端不弹，实际 %s" % String(client_owner)
	return true


# ═══════════════════════════════════════════
# 装备效果选项弹窗路由：设置在玩家A机甲上的装备牌，其 CHOOSE_ONE/CHOOSE_INTEGER
# 选项弹窗只给玩家A弹（拥有者）。
# 修复前：① CHOOSE_ONE/CHOOSE_INTEGER emit 不传 player_id；② set_equipment 动作 player_id
#   只在 action.source 不在 record -> _popup_owner 兜底 _waiting_action_owner 读 record.player_id
#   落空返回空；③ integer_select 甚至不在 _popup_owner match 列表 -> 三者叠加致 PvP 两端都弹。
# 修复后：emit 显式带 player_id=装备拥有者；integer_select 加入 _popup_owner match。
# ═══════════════════════════════════════════
func test_equipment_choice_popup_routed_to_owner() -> Variant:
	var host = await _build_pvp_app_root(888, &"player")
	var client = await _build_pvp_app_root(888, &"enemy")
	if host == null or client == null:
		await _free_app_root(host); await _free_app_root(client)
		return "建局失败"
	# effect_033 设置抽1 的 choose_one_effect input_params（修复后带 player_id=装备拥有者 player）
	var choice_params := {
		"action_id": &"test_equip_choice",
		"effect_id": &"equipment_effect_033",
		"options": [{"label": "抽1张行动牌", "effect_id": &"option_0", "option_index": 0}],
		"optional": true,
		"player_id": &"player",
	}
	# effect_040 弃牌换动力 的 choose_integer input_params（修复后带 player_id）
	var int_params := {
		"action_id": &"test_equip_int",
		"effect_id": &"equipment_effect_040",
		"label": "选择n",
		"min_value": 1,
		"max_value": 3,
		"bind_as": "n",
		"optional": true,
		"player_id": &"player",
	}
	# host(local=player): owner=player==local -> 本端弹（拥有者操作）
	# client(local=enemy): owner=player!=local -> 本端不弹（拦截，等对方 ui_confirmed）
	var host_choice: StringName = host._popup_owner(&"effect_choice", choice_params)
	var client_choice: StringName = client._popup_owner(&"effect_choice", choice_params)
	var host_int: StringName = host._popup_owner(&"integer_select", int_params)
	var client_int: StringName = client._popup_owner(&"integer_select", int_params)
	await _free_app_root(host); await _free_app_root(client)
	if host_choice != &"player":
		return "host 端装备二选一弹窗归属错误：期望 player 本端弹，实际 %s" % String(host_choice)
	if client_choice != &"player":
		return "client 端装备二选一弹窗归属错误：期望 player(本端不弹)，实际 %s" % String(client_choice)
	if host_int != &"player":
		return "host 端装备整数选择弹窗归属错误：期望 player 本端弹，实际 %s" % String(host_int)
	if client_int != &"player":
		return "client 端装备整数选择弹窗归属错误：期望 player(本端不弹)，实际 %s" % String(client_int)
	return true


# ═══════════════════════════════════════════
# 维修可用条件：自身与1格内机甲均满状态（满血+0损伤）时无可维修目标，
# 点击维修无反应；存在非满状态机甲时才可使用，且只能选非满状态者为对象。
# ═══════════════════════════════════════════

func test_repair_target_validation() -> Variant:
	var host = await _build_pvp_app_root(888, &"player")
	if host == null:
		return "建局失败"
	var gs = host.battle.context.game_state
	var pmech = gs.get_mech_for_player(&"player")
	if pmech == null:
		await _free_app_root(host)
		return "找不到玩家机甲"
	# 强制满状态：满血 + 清所有损伤
	pmech.current_hp = pmech.max_hp
	for sid in pmech.slots:
		var slot = pmech.slots[sid]
		if slot:
			slot.region_damage_tokens = 0
			if slot.equipped_card:
				slot.equipped_card.damage_tokens = 0
	if host._mech_is_full_state(pmech) != true:
		await _free_app_root(host)
		return "满血0损伤应判为满状态"
	if host._mech_can_be_repaired(pmech) != false:
		await _free_app_root(host)
		return "满状态机甲不应可被维修"
	# 自身有损伤 -> 可维修
	for sid in pmech.slots:
		var slot = pmech.slots[sid]
		if slot:
			slot.region_damage_tokens = 2
			break
	if host._mech_can_be_repaired(pmech) != true:
		await _free_app_root(host)
		return "有损伤机甲应可被维修"
	if host._has_repairable_target() != true:
		await _free_app_root(host)
		return "自身有损伤时应有可维修目标"
	# 全部满状态（自身+enemy）-> 无可维修目标
	for sid in pmech.slots:
		var slot = pmech.slots[sid]
		if slot:
			slot.region_damage_tokens = 0
	pmech.current_hp = pmech.max_hp
	var emech = gs.get_mech_for_player(&"enemy")
	if emech:
		emech.current_hp = emech.max_hp
		for sid in emech.slots:
			var slot = emech.slots[sid]
			if slot:
				slot.region_damage_tokens = 0
				if slot.equipped_card:
					slot.equipped_card.damage_tokens = 0
	if host._has_repairable_target() != false:
		await _free_app_root(host)
		return "全部满状态时应无可维修目标（实际 %s）" % str(host._has_repairable_target())
	await _free_app_root(host)
	return true
