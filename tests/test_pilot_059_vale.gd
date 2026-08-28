## test_pilot_059_vale.gd - 薇尔（pilot_059）效果测试
##
## 薇尔 1 按钮（被动 LISTEN TURN_START）：我方回合开始时，可以移除或设置我方1损伤
## （弹损伤调整面板：每槽位 +1/-1+取消，仅1次机会），之后统计我方机甲所有损伤数 N：
##   N<threshold(4) → 获得 gold_amount(3) 金币
##   N==threshold   → 视为使用 1 张补给（抽 2 行动 + 1 装备，纯虚拟）
##   N>threshold    → 移除我方最多 max_remove(2) 损伤（damage_change decrease + allow_cancel/max_mode）
##
## 实现拆解（通用可复用，不绑定机师——任何卡 effect_ids 含 pilot_059_effect_01 即生效）：
##   1. effect_01（显示按钮）监听 TURN_START，priority=10、listen_action_type=&"turn"、
##      条件 IS_OWNER_TURN，动作 = [PILOT_059_TURN_START_FLOW]（多阶段流程 handler）。
##   2. handler 首次弹 damage_adjust 面板挂起（_pending_effect phase=pilot_059_adjust）；
##      resume 应用调整（set 放1损+查损坏 / remove 移1损 / cancel 不动）→
##      PILOT_044_COMPUTE_DAMAGE 统计 N → 三分支经 _seq_effect_actions 串行执行。
##   3. N>threshold 分支走 EXECUTE_DAMAGE_CHANGE decrease + allow_cancel/max_mode：
##      面板可逐点移除最多2损伤、「完成」提前结束、「取消」不移除直接结算。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _Action = preload("res://scripts/action_core/Action.gd")


func _new_battle() -> BattleState:
	var registry := DataRegistry.new()
	var load_result := registry.load_all()
	if not load_result.ok:
		push_error(load_result.message)
	var battle := BattleState.new()
	battle.rng_seed = 90059
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	return battle


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


func _make_pilot_instance(gs, cdb, card_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 构造 turn 虚拟 action（fire TURN_START 用；action_type 与 TurnService._fire_timing 一致 &"turn"）
func _make_turn_action(battle, owner_id: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p059_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": owner_id, "player_id": owner_id}
	turn_action.state = &"running"
	turn_action.context = battle.context
	var mech = battle.context.game_state.get_mech_for_player(owner_id)
	turn_action.source = {"player_id": owner_id, "mech_id": mech.mech_id if mech != null else &""}
	battle.context.action_registry.register(turn_action)
	return turn_action


## fire 指定回合时点，返回虚拟 action（供检查 effect 是否挂起）
func _fire_turn(battle, timing: StringName, owner_id: StringName) -> _Action:
	var ta := _make_turn_action(battle, owner_id)
	battle.context.timing_engine.fire_timing(timing, ta)
	return ta


## 读取当前等待输入信息（UI 路由等待），无则返回 {}
func _get_wait(battle) -> Dictionary:
	return battle.context.action_ui_bridge.get_waiting_action_info()


## 设置绑定机甲总损伤数 X（先全清再设置，避免 tutorial 初始损伤干扰计数）。
func _set_mech_damage(mech, total: int) -> void:
	for slot in mech.slots.values():
		slot.region_damage_tokens = 0
	if total > 0 and not mech.slots.is_empty():
		(mech.slots.values()[0]).region_damage_tokens = total


## 查询机甲总损伤数
func _get_total_damage(mech) -> int:
	var total: int = 0
	for slot in mech.slots.values():
		total += slot.region_damage_tokens
		if slot.equipped_card != null:
			total += slot.equipped_card.damage_tokens
	return total


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01 定义正确（LISTEN TURN_START、priority10、IS_OWNER_TURN、PILOT_059_TURN_START_FLOW）。
func test_p059_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	var e1 = effs.get(&"pilot_059_effect_01")
	if e1 == null:
		return "缺 pilot_059_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "effect_01 mode 应 LISTEN 实=%s" % String(e1.mode)
	if e1.listen_timing != _TimingConst.TURN_START:
		return "effect_01 应监听 TURN_START 实=%s" % String(e1.listen_timing)
	if String(e1.listen_action_type) != "turn":
		return "effect_01 listen_action_type 应 turn"
	if int(e1.priority) != 10:
		return "effect_01 priority 应 10 实=%d" % int(e1.priority)
	if e1.hide_button:
		return "effect_01 应是显示按钮（1显示按钮模式）"
	var ops1: Array = []
	for c in e1.conditions:
		ops1.append(String(c.get("op", &"")))
	if not ops1.has("IS_OWNER_TURN"):
		return "effect_01 应含 IS_OWNER_TURN 条件"
	var a1: Array = []
	for c in e1.actions:
		a1.append(String(c.get("type", &"")))
	if not a1.has("PILOT_059_TURN_START_FLOW"):
		return "effect_01 actions 应含 PILOT_059_TURN_START_FLOW"
	var p1: Dictionary = e1.actions[0].get("params", {})
	if int(p1.get("threshold", 0)) != 4:
		return "params.threshold 应 4 实=%d" % int(p1.get("threshold", 0))
	if int(p1.get("gold_amount", 0)) != 3:
		return "params.gold_amount 应 3 实=%d" % int(p1.get("gold_amount", 0))
	if int(p1.get("max_remove", 0)) != 2:
		return "params.max_remove 应 2 实=%d" % int(p1.get("max_remove", 0))
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：TURN_START 弹 damage_adjust 面板 → 玩家 set 1损伤到可放置槽位 → N=1<4 → 获3金币。
func test_p059_set_lt4_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_059_薇尔", &"player")
	if card == null:
		return "找不到 pilot_059_薇尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_set_mech_damage(player_mech, 0)
	var gold_before: int = player.gold
	var set_slots: Array = battle.context.damage_token_service.get_valid_damage_slots(player_mech.mech_id)
	if set_slots.is_empty():
		return "无可放置损伤槽位"

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "damage_adjust":
		return "TURN_START 应弹 damage_adjust 面板，wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	if String(input_params.get("mech_id", &"")) != String(player_mech.mech_id):
		return "damage_adjust mech_id 应=%s 实=%s" % [String(player_mech.mech_id), String(input_params.get("mech_id", &""))]

	# 玩家选择设置1损伤到可放置槽位 → N=1<4 → 获3金
	battle.context.action_ui_bridge.on_ui_confirmed({"choice": "set", "slot_id": set_slots[0]})
	await _pump_frames(6)
	if _get_total_damage(player_mech) != 1:
		return "set 后损伤应=1 实=%d" % _get_total_damage(player_mech)
	if player.gold != gold_before + 3:
		return "N<4 应获3金币 前=%d 后=%d" % [gold_before, player.gold]
	return true


## 测试3：TURN_START → 玩家 remove 1损伤 → N=4 → 视为使用1张补给（抽2行动+1装备）。
func test_p059_remove_eq4_supply() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_059_薇尔", &"player")
	if card == null:
		return "找不到 pilot_059_薇尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	# 初始5损伤，remove 1 → N=4 → 补给
	_set_mech_damage(player_mech, 5)
	var first_slot: StringName = player_mech.slots.keys()[0]
	var ah_before: int = player.action_hand.size()
	var eh_before: int = player.equipment_hand.size()

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "damage_adjust":
		return "TURN_START 应弹 damage_adjust 面板，wait=%s" % str(wait_info)

	# 玩家选择移除1损伤（从首个有损伤槽位）→ N=4 → 视为补给抽2行动+1装备
	battle.context.action_ui_bridge.on_ui_confirmed({"choice": "remove", "slot_id": first_slot})
	await _pump_frames(12)
	if _get_total_damage(player_mech) != 4:
		return "remove 后损伤应=4 实=%d" % _get_total_damage(player_mech)
	if player.action_hand.size() != ah_before + 2:
		return "N=4 补给应抽2行动 前=%d 后=%d" % [ah_before, player.action_hand.size()]
	if player.equipment_hand.size() != eh_before + 1:
		return "N=4 补给应抽1装备 前=%d 后=%d" % [eh_before, player.equipment_hand.size()]
	return true


## 测试4：取消调整，初始5损伤 → N=5>4 → 弹最多移除面板（removal+allow_cancel+max_mode），移除2 → 完成。
func test_p059_cancel_gt4_remove_max2() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_059_薇尔", &"player")
	if card == null:
		return "找不到 pilot_059_薇尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_set_mech_damage(player_mech, 5)
	var first_slot: StringName = player_mech.slots.keys()[0]

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "damage_adjust":
		return "TURN_START 应弹 damage_adjust 面板，wait=%s" % str(wait_info)

	# 取消调整 → N=5>4 → 弹最多移除面板
	battle.context.action_ui_bridge.on_ui_confirmed({"choice": "cancel"})
	await _pump_frames(6)
	wait_info = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "place_damage_tokens":
		return "N>4 应弹最多移除面板(place_damage_tokens)，wait=%s" % str(wait_info)
	var dp_params: Dictionary = wait_info.get("input_params", {})
	if not bool(dp_params.get("removal_mode", false)):
		return "移除面板应 removal_mode=true"
	if int(dp_params.get("amount", 0)) != 2:
		return "移除面板 amount 应=2 实=%d" % int(dp_params.get("amount", 0))
	if not bool(dp_params.get("allow_cancel", false)):
		return "移除面板应 allow_cancel=true"
	if not bool(dp_params.get("max_mode", false)):
		return "移除面板应 max_mode=true"

	# 玩家移除2损伤（模拟逐点 damage_remove，首槽 region 5→3），然后「完成」提前结束
	battle.context.game_actions.remove_damage_tokens({"mech_id": player_mech.mech_id, "slot_id": first_slot, "amount": 2})
	battle.context.action_ui_bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(12)
	if _get_total_damage(player_mech) != 3:
		return "移除2后损伤应=3 实=%d" % _get_total_damage(player_mech)
	return true


## 测试5：取消调整，初始0损伤 → N=0<4 → 获3金币（取消调整不影响后续分支）。
func test_p059_cancel_adjust_lt4_gold() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_059_薇尔", &"player")
	if card == null:
		return "找不到 pilot_059_薇尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_set_mech_damage(player_mech, 0)
	var gold_before: int = player.gold

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "damage_adjust":
		return "TURN_START 应弹 damage_adjust 面板，wait=%s" % str(wait_info)

	battle.context.action_ui_bridge.on_ui_confirmed({"choice": "cancel"})
	await _pump_frames(6)
	if _get_total_damage(player_mech) != 0:
		return "取消调整后损伤应=0 实=%d" % _get_total_damage(player_mech)
	if player.gold != gold_before + 3:
		return "取消调整后 N=0<4 应获3金币 前=%d 后=%d" % [gold_before, player.gold]
	return true


## 测试6：取消调整，初始5损伤 → N>4 → 最多移除面板点「取消」（不移除）→ 损伤仍5。
func test_p059_remove_panel_cancel() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_059_薇尔", &"player")
	if card == null:
		return "找不到 pilot_059_薇尔 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	_set_mech_damage(player_mech, 5)

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "damage_adjust":
		return "TURN_START 应弹 damage_adjust 面板，wait=%s" % str(wait_info)

	battle.context.action_ui_bridge.on_ui_confirmed({"choice": "cancel"})
	await _pump_frames(6)
	wait_info = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "place_damage_tokens":
		return "N>4 应弹最多移除面板，wait=%s" % str(wait_info)

	# 「取消」= 不移除任何损伤直接结算（damage_change 收到 placed 即跳过移除）
	battle.context.action_ui_bridge.on_ui_confirmed({"placed": true})
	await _pump_frames(12)
	if _get_total_damage(player_mech) != 5:
		return "移除面板取消后损伤应仍=5 实=%d" % _get_total_damage(player_mech)
	return true
