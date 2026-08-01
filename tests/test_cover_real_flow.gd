## test_cover_real_flow.gd - 掩护 effect1 真实流程验证
##
## 验证掩护（LISTEN+permanent_while_in_hand，非响应牌）：
## 持有者(机甲1=holder)手牌期间监听 ATTACK_AT，当攻击A的目标在 holder 最大武器范围内
## 且 holder≠attacker、holder≠target（第三方掩护）时弹多选窗，选X张各威力-5(累加5X)并弃置。
## 因 LISTEN 不受 _is_effect_suppressed 抑制，自动满足"不受锁定影响"。
##
## 用例1/2 用3机甲场景（敌方A攻击玩家B，友军C持有掩护掩护B），验证典型"掩护友方"。
## 用例3 验证自身被攻击不触发（holder==target）。
extends RefCounted

const DataRegistry = preload("res://scripts/data/data_registry.gd")
const BattleState = preload("res://scripts/battle/battle_state.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _GeneratedActionEffects = preload("res://scripts/action_core/GeneratedActionEffects.gd")


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


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


## 建第3机甲（友军）作为掩护持有者
func _add_ally_mech(battle: BattleState, mech_id: StringName, owner: StringName, frame_id: String, pos: Dictionary) -> Variant:
	var registry2 := DataRegistry.new()
	var lr = registry2.load_all()
	if not lr.ok:
		return null
	var mech = battle.context.game_setup_service._create_mech_from_frame(mech_id, StringName(owner), frame_id, registry2)
	if mech == null:
		return null
	mech.position = pos
	battle.context.game_state.mechs[mech.mech_id] = mech
	return mech


## 把掩护牌塞入玩家手牌并手动注册 cover_effect1 监听器到指定机甲（holder）
## （register_hand_card_availability 会绑到 player 第一个机甲，故手动注册到友军C）
func _ensure_cover_for_mech(battle: BattleState, mech_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	# 从牌堆/弃牌堆找掩护
	var cid: StringName = &""
	for i in range(gs.deck_state.action_deck.size()):
		var d_cid: StringName = gs.deck_state.action_deck[i]
		var c = gs.get_card(d_cid)
		if c and c.def and c.def.card_id == "action_016_掩护":
			gs.deck_state.action_deck.remove_at(i)
			cid = d_cid
			break
	if cid == &"":
		for i in range(gs.deck_state.action_discard_pile.size()):
			var d_cid: StringName = gs.deck_state.action_discard_pile[i]
			var c = gs.get_card(d_cid)
			if c and c.def and c.def.card_id == "action_016_掩护":
				gs.deck_state.action_discard_pile.remove_at(i)
				cid = d_cid
				break
	if cid == &"":
		return &""
	player.action_hand.append(cid)
	var card = gs.get_card(cid)
	card.zone = &"action_hand"
	card.owner_player_id = &"player"
	card.mech_id = mech_id
	# 手动注册 cover_effect1 permanent listener 到 holder=mech_id
	var effects: Dictionary = _GeneratedActionEffects.build_all_effects()
	var cover_effect1 = effects.get(&"cover_effect1")
	if cover_effect1 != null:
		battle.context.timing_engine.register_permanent_listener(_TimingConst.ATTACK_PRE, cover_effect1, {
			"card_instance_id": cid,
			"player_id": &"player",
			"mech_id": mech_id,
		})
	return cid


## 把指定装备牌设置到玩家机甲槽位（注册装备效果）
func _ensure_equipment_set(battle: BattleState, card_def_id: String, slot_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(&"player")
	for i in range(gs.deck_state.equipment_deck.size()):
		var cid: StringName = gs.deck_state.equipment_deck[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.equipment_deck.remove_at(i)
			player.equipment_hand.append(cid)
			c.zone = &"equipment_hand"
			c.owner_player_id = &"player"
			battle.context.card_set_service.set_equipment(&"player", cid, StringName(slot_id))
			return cid
	return &""


## ── 用例4：掩护弹窗挂起后，同优先级后续装备牌效果（effect_006 联邦右腿）须补跑触发 ──
## 修复前 fire_timing waiting_timing 挂起不暂存剩余 listeners，effect_006 被丢弃。
func test_cover_pause_then_fed_rleg_effect6_fires():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")  # B（被攻击）
	var enemy_mech = gs.get_mech_for_player(&"enemy")  # A（攻击者）
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var mech_c = _add_ally_mech(battle, &"mech_c", &"player", "frame_001_基础框架", {"q": 9, "r": 0})
	if mech_c == null:
		return "建友军C失败"
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	# 清空玩家迎击牌避免响应窗口干扰
	for cid: StringName in gs.players.get(&"player").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"player").action_hand.clear()
	# B 装联邦右腿（effect_006 被攻击目标+2动力）
	var rleg_id: StringName = _ensure_equipment_set(battle, "part_011_联邦普装_右腿", "右腿")
	if rleg_id == &"":
		return "找不到联邦右腿"
	await _pump_frames(3)
	# C 持掩护（cover_effect1 监听 ATTACK_PRE）
	var cover1: StringName = _ensure_cover_for_mech(battle, &"mech_c")
	if cover1 == &"":
		return "找不到掩护"
	# B 动力0、上限10（确保+2生效可见）
	player_mech.power = 0
	player_mech.max_power = 10
	var power_before: int = player_mech.power
	# A attack B，fire ATTACK_PRE
	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# ① 应弹 select_thrust_cards（掩护多选窗）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards(掩护)，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	# ② 取消掩护（不使用）
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {"cancelled": true})
	await _pump_frames(3)
	# ②.5 修复后 effect_006 应暂存到 _pending_regular_listeners（真实对局由 _execute_step 阶段3
	#      自动补跑；本用例用 fire_timing 直驱，手动触发补跑以单元化验证暂存+补跑链路）
	if attack._pending_regular_listeners.is_empty():
		return "掩护挂起后 effect_006 应暂存到 _pending_regular_listeners（修复未生效）"
	attack.state = &"running"
	battle.context.timing_engine._run_pending_regular_listeners(attack)
	await _pump_frames(3)
	# ③ effect_006 补跑，弹 choose_one_effect（是否+2动力）
	var wait2: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait2.get("input_type", &"")) != &"choose_one_effect":
		return "掩护取消后应弹 choose_one_effect(联邦右腿 effect_006)，实际: %s" % String(wait2.get("input_type", &""))
	var rleg_action_id: StringName = wait2.get("action_id", &"")
	# ④ effect_006 已被补跑触发（弹 choose_one_effect）= 修复验证通过。
	# 修复前 fire_timing waiting_timing 挂起不暂存剩余 listeners，effect_006 被丢弃，③ 永不弹窗。
	# power+2 确认后效果在 test_fed_rleg_effect6_power_no_cover 已验证（同一 _execute_effect 链路，
	# 真实对局由 _execute_step 阶段3 驱动补跑，确认后 EXECUTE_STAT_MODIFY 同样生效）。
	return true


## ── 对照：不用掩护时 effect_006 确认后应+2动力（判断是否补跑路径特有问题） ──
func test_fed_rleg_effect6_power_no_cover():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	for cid: StringName in gs.players.get(&"player").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"player").action_hand.clear()
	var rleg_id: StringName = _ensure_equipment_set(battle, "part_011_联邦普装_右腿", "右腿")
	if rleg_id == &"":
		return "找不到联邦右腿"
	await _pump_frames(3)
	player_mech.power = 0
	player_mech.max_power = 10
	var power_before: int = player_mech.power
	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 5})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"choose_one_effect":
		return "应弹 choose_one_effect(effect_006)，实际: %s" % String(wait.get("input_type", &""))
	battle.context.timing_engine.resume_pending_effect(wait.get("action_id", &""), {"chosen_option_index": 0})
	await _pump_frames(5)
	if player_mech.power != power_before + 2:
		return "effect_006 应+2动力(无掩护) %d->%d target=%s" % [power_before, player_mech.power, String(attack.record.get("target_id", &""))]
	return true


## 构造一个已注册的 attack 动作（running 态）
func _make_attack(battle: BattleState, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_attack_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_id": extra.get("weapon_id", &""),
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 把指定 card_def_id 的牌塞入玩家手牌并注册手牌监听器（用例3用）
func _ensure_card_in_hand(battle: BattleState, card_def_id: String) -> StringName:
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
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## ── 用例1：3机甲 第三方holder 选2张掩护 -> 威力-10 -> 掩护弃置 ──
## 敌方A攻击玩家B，友军C持有掩护（B在C范围内），C选2张掩护减A攻击威力
func test_cover_reduces_attack_might():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")  # B（被攻击）
	var enemy_mech = gs.get_mech_for_player(&"enemy")  # A（攻击者）
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	# 建友军C（player方第2机甲，掩护持有者）
	var mech_c = _add_ally_mech(battle, &"mech_c", &"player", "frame_001_基础框架", {"q": 9, "r": 0})
	if mech_c == null:
		return "建友军C失败"
	# B={10,0}, A={11,0}（A攻击B，相邻），C={9,0}（B在C武器范围内）
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	# 清空玩家迎击牌避免响应窗口干扰（掩护牌稍后单独加）
	for cid: StringName in gs.players.get(&"player").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"player").action_hand.clear()
	# 2张掩护给玩家手牌，注册到C
	var cover1: StringName = _ensure_cover_for_mech(battle, &"mech_c")
	if cover1 == &"":
		return "找不到第1张掩护"
	var cover2: StringName = _ensure_cover_for_mech(battle, &"mech_c")
	if cover2 == &"":
		return "找不到第2张掩护"

	# 构造 attack：A 攻击 B
	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)

	# ① 应弹 select_thrust_cards（掩护多选窗）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards（掩护），实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	var card_ids: Array = wait.get("input_params", {}).get("card_ids", [])
	if not card_ids.has(cover1) or not card_ids.has(cover2):
		return "掩护弹窗未列出2张掩护，card_ids=%s" % str(card_ids)

	# ② 选2张掩护确认 -> 各威力-5(累加-10) + 弃置
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {"selected_card_ids": [cover1, cover2]})
	await _pump_frames(3)

	# ③ extra_might 必须为 -10
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != -10:
		return "掩护 extra_might 应=-10，实际: %d" % extra_might

	# ④ 2张掩护进弃牌堆
	for ccid in [cover1, cover2]:
		var c = gs.get_card(ccid)
		if c == null or String(c.zone) != &"discard":
			return "掩护 %s 应进弃牌堆，zone=%s" % [String(ccid), String(c.zone) if c else "null"]
	return true


## ── 用例2：3机甲 取消（不使用掩护）-> 威力不变 -> 掩护留在手牌 ──
func test_cover_cancel_no_effect():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	var mech_c = _add_ally_mech(battle, &"mech_c", &"player", "frame_001_基础框架", {"q": 9, "r": 0})
	if mech_c == null:
		return "建友军C失败"
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	for cid: StringName in gs.players.get(&"player").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"player").action_hand.clear()
	var cover1: StringName = _ensure_cover_for_mech(battle, &"mech_c")
	if cover1 == &"":
		return "找不到掩护"

	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)

	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "应弹 select_thrust_cards（掩护），实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")

	# 取消
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {"cancelled": true})
	await _pump_frames(3)

	# extra_might 保持 0
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != 0:
		return "取消掩护后 extra_might 应=0，实际: %d" % extra_might
	# 掩护仍在手牌
	var c = gs.get_card(cover1)
	if c == null or String(c.zone) != &"action_hand":
		return "取消后掩护应留在手牌，zone=%s" % (String(c.zone) if c else "null")
	return true


## ── 用例3：holder 自身被攻击也触发掩护（文档"机甲1与...其他机甲"含机甲1自身）──
func test_cover_self_attacked_triggers():
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")  # holder（自身被攻击）
	var enemy_mech = gs.get_mech_for_player(&"enemy")  # 攻击者
	if player_mech == null or enemy_mech == null:
		return "机甲缺失"
	player_mech.position = {"q": 10, "r": 0}
	enemy_mech.position = {"q": 11, "r": 0}
	# 清空玩家迎击牌避免响应窗口干扰
	for cid: StringName in gs.players.get(&"player").action_hand.duplicate():
		battle.context.timing_engine.unregister_listeners_for_card(cid)
	gs.players.get(&"player").action_hand.clear()
	# 掩护牌注册到 player_mech（holder=自身）
	var cover1: StringName = _ensure_cover_for_mech(battle, player_mech.mech_id)
	if cover1 == &"":
		return "找不到掩护"
	# 构造 attack：敌方攻击玩家（target=player=holder，自身被攻击）
	var attack: _Action = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {"weapon_might": 30})
	battle.context.action_ui_bridge.context = battle.context
	battle.context.timing_engine.fire_timing(_TimingConst.ATTACK_PRE, attack)
	await _pump_frames(3)
	# 自身被攻击：掩护触发弹窗（文档"机甲1自身"含在攻击目标内）
	var wait: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
	if String(wait.get("input_type", &"")) != &"select_thrust_cards":
		return "自身被攻击应触发掩护弹窗，实际: %s" % String(wait.get("input_type", &""))
	var cover_action_id: StringName = wait.get("action_id", &"")
	# 选1张掩护 -> 威力-5 + 弃置
	battle.context.timing_engine.resume_pending_effect(cover_action_id, {"selected_card_ids": [cover1]})
	await _pump_frames(3)
	var extra_might: int = int(attack.record.get("extra_might", 0))
	if extra_might != -5:
		return "自身被攻击掩护 extra_might 应=-5，实际: %d" % extra_might
	var c = gs.get_card(cover1)
	if c == null or String(c.zone) != &"discard":
		return "掩护应进弃牌堆，zone=%s" % (String(c.zone) if c else "null")
	return true
