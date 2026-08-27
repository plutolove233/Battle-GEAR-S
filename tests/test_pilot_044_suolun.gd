## test_pilot_044_suolun.gd - 索伦（pilot_044）效果测试
##
## 索伦 1 按钮（被动双时点）：我方回合开始时（TURN_START，抽牌前）与回合结束后
## （TURN_AFTER_END，已弃超上限牌后），记录绑定机甲所有区域的损伤数为 X，
## 之后抽 X+1 张行动牌，再弃置 X 张行动牌（必选、不可取消）。
##
## 实现拆解（通用可复用，不绑定机师——任何卡 effect_ids 含 pilot_044_effect_01/02 即生效）：
##   1. effect_01（显示按钮）监听 TURN_START；effect_02（hide_button+合并描述）监听 TURN_AFTER_END。
##      两者 priority=10、listen_action_type=&"turn"、条件 IS_OWNER_TURN（仅"我方回合"触发）。
##   2. 计算 X 用效果专属 act_type PILOT_044_COMPUTE_DAMAGE（仿珀修斯 PILOT_007_COMPUTE_X，
##      参数化 store_key/plus_one_store_key/mech_id，复制改键即可复用），写入 payload。
##   3. 抽 X+1 张：EXECUTE_GAIN_CARD count=$runtime.pilot_044_draw_x（compute 写入 X+1，因 $runtime 不支持算术）。
##   4. 弃 X 张：EXECUTE_DISCARD from_target=false+choose=true+count=$runtime.pilot_044_discard_x
##      +no_cancel=true（自弃必选；executor 从 payload/source/binding_context 回退）。
##   5. X=0：抽1弃0——discard_card_action count<=0 守卫直接弃0张完成、不弹窗（通用）。
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
	battle.rng_seed = 90044
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


## 构造 turn 虚拟 action（fire TURN_START / TURN_AFTER_END 用；action_type 须与
## TurnService._fire_timing 一致 &"turn"，否则 listen_action_type 过滤跳过）。
## record 带 player_id + source，保证自弃 executor 回退链先命中 payload/source。
func _make_turn_action(battle, owner_id: StringName) -> _Action:
	var turn_action := _Action.new()
	turn_action.action_id = &"test_p044_turn_%d" % [randi() % 1000000]
	turn_action.action_type = &"turn"
	turn_action.record = {"turn_owner": owner_id, "player_id": owner_id}
	turn_action.state = &"running"
	turn_action.context = battle.context
	var mech = battle.context.game_state.get_mech_for_player(owner_id)
	turn_action.source = {"player_id": owner_id, "mech_id": mech.mech_id if mech != null else &""}
	battle.context.action_registry.register(turn_action)
	return turn_action


## fire 指定回合时点，返回虚拟 action（供检查 effect 是否挂起）。
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


# ═══════════════════════════════════════════
# 定义白盒测试
# ═══════════════════════════════════════════

## 测试1：effect_01/02 定义正确（双时点监听、priority10、IS_OWNER_TURN、动作链）。
func test_p044_definitions() -> Variant:
	var effs = _ActionPilotEffects.build_pilot_effects()
	var e1 = effs.get(&"pilot_044_effect_01")
	if e1 == null:
		return "缺 pilot_044_effect_01"
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
	if not a1.has("PILOT_044_COMPUTE_DAMAGE"):
		return "effect_01 actions 应含 PILOT_044_COMPUTE_DAMAGE"
	if not a1.has("EXECUTE_GAIN_CARD"):
		return "effect_01 actions 应含 EXECUTE_GAIN_CARD"
	if not a1.has("EXECUTE_DISCARD"):
		return "effect_01 actions 应含 EXECUTE_DISCARD"

	var e2 = effs.get(&"pilot_044_effect_02")
	if e2 == null:
		return "缺 pilot_044_effect_02"
	if e2.mode != _TimingConst.MODE_LISTEN:
		return "effect_02 mode 应 LISTEN"
	if e2.listen_timing != _TimingConst.TURN_AFTER_END:
		return "effect_02 应监听 TURN_AFTER_END 实=%s" % String(e2.listen_timing)
	if String(e2.listen_action_type) != "turn":
		return "effect_02 listen_action_type 应 turn"
	if int(e2.priority) != 10:
		return "effect_02 priority 应 10 实=%d" % int(e2.priority)
	if not e2.hide_button:
		return "effect_02 应 hide_button（合并到1按钮）"
	if int(e2.merge_desc_into_index) != 1:
		return "effect_02 merge_desc_into_index 应 1（并入 effect_01 按钮）"
	var ops2: Array = []
	for c in e2.conditions:
		ops2.append(String(c.get("op", &"")))
	if not ops2.has("IS_OWNER_TURN"):
		return "effect_02 应含 IS_OWNER_TURN 条件"
	var a2: Array = []
	for c in e2.actions:
		a2.append(String(c.get("type", &"")))
	if not a2.has("EXECUTE_DISCARD"):
		return "effect_02 actions 应含 EXECUTE_DISCARD"
	return true


# ═══════════════════════════════════════════
# 行为测试
# ═══════════════════════════════════════════

## 测试2：TURN_START 触发——损伤 X=2 → 抽3张、弹自弃窗（count=2 不可取消）、弃2张进弃牌堆。
func test_p044_turn_start_draw_and_discard() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_044_索伦", &"player")
	if card == null:
		return "找不到 pilot_044_索伦 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	# 我方回合（IS_OWNER_TURN 条件）
	gs.active_player_id = &"player"
	# 清空行动手牌（tutorial 初始有牌，避免干扰计数）
	player.action_hand.clear()
	_set_mech_damage(player_mech, 2)
	var pile_before: int = gs.deck_state.action_discard_pile.size()

	# fire TURN_START → 索伦 effect_01：记X=2、抽3、弃2挂起自弃窗
	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_discard_cards":
		return "TURN_START 应弹 select_discard_cards（自弃X张），wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	if int(input_params.get("count", 0)) != 2:
		return "弃牌 count 应=X=2 实=%d" % int(input_params.get("count", 0))
	if String(input_params.get("discard_player_id", &"")) != "player":
		return "自弃方应 player 实=%s" % String(input_params.get("discard_player_id", &""))
	if not bool(input_params.get("no_cancel", false)):
		return "自弃应 no_cancel=true（不可取消）"
	if String(input_params.get("executor", &"")) != "player":
		return "自弃执行者应 player 实=%s" % String(input_params.get("executor", &""))
	# 弹窗时手牌 = 刚抽的3张（清空后抽 X+1=3）
	if player.action_hand.size() != 3:
		return "弃牌窗时手牌应=抽3张 实=%d" % player.action_hand.size()

	# 玩家选2张弃
	var to_discard: Array = [player.action_hand[0], player.action_hand[1]]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": to_discard})
	await _pump_frames(12)
	# 弃2 → 手牌剩 3-2=1
	if player.action_hand.size() != 1:
		return "弃2后手牌应剩1 实=%d" % player.action_hand.size()
	for cid in to_discard:
		if not gs.deck_state.action_discard_pile.has(cid):
			return "弃的牌 %s 应进行动牌弃牌堆" % String(cid)
	if gs.deck_state.action_discard_pile.size() != pile_before + 2:
		return "弃牌堆应+2 前=%d 后=%d" % [pile_before, gs.deck_state.action_discard_pile.size()]
	return true


## 测试3：TURN_START 且 X=0 → 抽1张、弃0张、不弹自弃窗。
func test_p044_turn_start_x0_no_discard_popup() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_044_索伦", &"player")
	if card == null:
		return "找不到 pilot_044_索伦 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	player.action_hand.clear()
	_set_mech_damage(player_mech, 0)
	var pile_before: int = gs.deck_state.action_discard_pile.size()

	await _fire_turn(battle, _TimingConst.TURN_START, &"player")
	await _pump_frames(3)
	# X=0：不弹自弃窗（count<=0 守卫直接弃0张完成）
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) == "select_discard_cards":
		return "X=0 不应弹自弃窗"
	# 抽 X+1=1 张、弃0张 → 手牌=1
	if player.action_hand.size() != 1:
		return "X=0 抽1弃0后手牌应=1 实=%d" % player.action_hand.size()
	if gs.deck_state.action_discard_pile.size() != pile_before:
		return "X=0 不应产生弃牌 前=%d 后=%d" % [pile_before, gs.deck_state.action_discard_pile.size()]
	return true


## 测试4：TURN_AFTER_END 触发（effect_02 隐藏监听）——损伤 X=1 → 抽2张、弃1张。
func test_p044_turn_after_end_triggers() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var player = gs.players.get(&"player")
	var card = _make_pilot_instance(gs, cdb, "pilot_044_索伦", &"player")
	if card == null:
		return "找不到 pilot_044_索伦 定义"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	battle.context.action_ui_bridge.context = battle.context
	gs.active_player_id = &"player"
	player.action_hand.clear()
	_set_mech_damage(player_mech, 1)
	var pile_before: int = gs.deck_state.action_discard_pile.size()

	# fire TURN_AFTER_END → effect_02：记X=1、抽2、弃1挂起
	await _fire_turn(battle, _TimingConst.TURN_AFTER_END, &"player")
	await _pump_frames(3)
	var wait_info: Dictionary = _get_wait(battle)
	if String(wait_info.get("input_type", &"")) != "select_discard_cards":
		return "TURN_AFTER_END 应弹 select_discard_cards，wait=%s" % str(wait_info)
	var input_params: Dictionary = wait_info.get("input_params", {})
	if int(input_params.get("count", 0)) != 1:
		return "弃牌 count 应=X=1 实=%d" % int(input_params.get("count", 0))
	if player.action_hand.size() != 2:
		return "弃牌窗时手牌应=抽2张 实=%d" % player.action_hand.size()
	# 选1张弃
	var to_discard: Array = [player.action_hand[0]]
	battle.context.action_ui_bridge.on_ui_confirmed({"determined_card_ids": to_discard})
	await _pump_frames(12)
	if player.action_hand.size() != 1:
		return "弃1后手牌应剩1 实=%d" % player.action_hand.size()
	if gs.deck_state.action_discard_pile.size() != pile_before + 1:
		return "弃牌堆应+1 前=%d 后=%d" % [pile_before, gs.deck_state.action_discard_pile.size()]
	return true
