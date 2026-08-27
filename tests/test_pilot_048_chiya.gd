## test_pilot_048_chiya.gd — 赤牙 pilot_048 攻击损伤+1·损伤位置由我方指定
##
## 权威文本：「我方攻击造成的损伤+1。我方发动的攻击即使被目标响应，也依然由我方来决定损伤设置的位置。」
##
## 拆解（1 按钮被动，纯通用机制组装，不新增原子动作、不与机师ID绑定）：
##   - LISTEN ATTACK_AFTER priority 10（同破甲/塞万提斯通用时点）+ 条件 SELF_MECH_IS_ATTACKER + ATTACK_HIT。
##   - 动作1 MODIFY_ATTACK_MARKERS delta=+1：写攻击 record.extra_markers，attack_action 第⑦步
##     在 ATTACK_AFTER fire 后合并入 markers 一次放置（未命中 _step_apply_damage 提前 return）。
##   - 动作2 SET_ACTION_RECORD_FLAG flag=attacker_always_places_damage_tokens value=true：
##     通用flag，attack_action 第⑦步读此flag——被响应但带flag→仍由攻击方设置损伤（默认被响应由目标方设置）。
##     任何效果设置该flag即生效，双连 fork 深拷贝 record 自动继承。
##
## 覆盖（PvP 双人类）：
##   - 效果定义形状（MODE_LISTEN/ATTACK_AFTER/条件/2动作）
##   - 我方命中 → extra_markers=+1 且 flag 已写
##   - 未命中 → 无 +1 无 flag
##   - 非我方攻击（我方为被攻击方）→ 不触发
##   - 真实流程：我方带赤牙攻击+目标防御响应 → damage_change executor=我方（损伤由我方设置）
##   - 真实流程（回归）：无赤牙+目标防御响应 → damage_change executor=目标（默认规则）
##   - 真实流程：我方带赤牙攻击未响应 → 损伤=floor(might/5)+1 且 executor=我方
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
	# PvP 双人类玩家：同种子 + 地图特征 + enemy 人类（与 app_root._start_pvp_host 一致）
	battle.rng_seed = 12345
	battle.pvp_map_features = true
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	var enemy_player = battle.context.game_state.players.get(&"enemy")
	if enemy_player != null:
		enemy_player.is_human = true
	return battle


func _pump_frames(n: int) -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null:
		return
	for i in n:
		await tree.process_frame


## 建一张牌实例并登记到 gs.cards（card_def_id 带_名字后缀）
func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


## 设赤牙为 owner_id 机甲的机师（set_pilot 注册 LISTEN 永久监听器）；失败返回 null
func _setup_chiya(battle, owner_id: StringName):
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var mech = gs.get_mech_for_player(owner_id)
	if mech == null:
		return null
	var card = _make_instance(gs, cdb, "pilot_048_赤牙", owner_id)
	if card == null:
		return null
	battle.context.game_setup_service.set_pilot(mech.mech_id, card)
	return {"mech": mech, "pilot_card": card, "gs": gs, "cdb": cdb, "te": battle.context.timing_engine}


## 构造一个已注册的 attack 动作（running 态），返回 action
func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p048_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": int(extra.get("weapon_might", 5)),
		"weapon_range": int(extra.get("weapon_range", 1)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 清空地图全部格子地形为 NORMAL（避免随机 GREEN/RED 干扰武器射程 BFS）
func _clear_map_terrain(battle) -> void:
	var ms = battle.context.game_state.map_state
	if ms == null:
		return
	for key in ms.cells:
		ms.cells[key].terrain = &"NORMAL"


## 清空指定玩家行动手牌（注销监听器+移回行动牌堆），避免初始迎击/防御牌干扰响应窗口
func _clear_hand(battle, player_side: StringName) -> void:
	var gs = battle.context.game_state
	var player = gs.players.get(player_side)
	if player == null:
		return
	var ids: Array = []
	for cid in player.action_hand:
		ids.append(cid)
	for cid in ids:
		battle.context.timing_engine.unregister_listeners_for_card(cid)
		player.action_hand.erase(cid)
		gs.deck_state.action_deck.append(cid)
		var c = gs.get_card(cid)
		if c:
			c.zone = &"action_deck"


## 把指定 card_def_id 的牌塞入指定玩家手牌（注册可用性监听器），返回 instance_id；找不到返回空
func _ensure_card_in_hand(battle, player_side: StringName, card_def_id: String) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_side)
	if player == null:
		return &""
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
	for i in range(gs.deck_state.action_discard_pile.size()):
		var cid: StringName = gs.deck_state.action_discard_pile[i]
		var c = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			gs.deck_state.action_discard_pile.remove_at(i)
			player.action_hand.append(cid)
			c.zone = &"action_hand"
			c.owner_player_id = &""
			c.mech_id = &""
			battle.context.register_hand_card_availability(cid)
			return cid
	return &""


## 设机甲首武器威力为 might（基础武器改 base_weapons，装备牌改 def.might）
func _set_first_weapon_might(mech, might: int) -> void:
	if not mech.base_weapons.is_empty():
		mech.base_weapons[0]["might"] = might
	var w1_slot = mech.slots.get(&"weapon_1") if mech.slots.has(&"weapon_1") else null
	if w1_slot != null and w1_slot.equipped_card != null and w1_slot.equipped_card.def != null:
		w1_slot.equipped_card.def.might = might


## 等待并找到 attack 的 damage_change 子动作（暂停在 place_damage_tokens）；未出现返回 null
func _find_damage_change(battle, attack_id: StringName):
	var ar = battle.context.action_registry
	var attack = ar.get_action(attack_id)
	if attack == null:
		return null
	for guard in range(40):
		for cid in attack.pending_effect_action_ids:
			var sub = ar.get_action(cid)
			if sub != null and sub.action_type == &"damage_change":
				return sub
		await _pump_frames(3)
	return null


## 发起真实攻击流程（execute_attack_action）。target_has_defend=true 时目标手牌仅有防御并响应。
## 返回 {ok, msg?, attack_id, dc}。dc 为 damage_change 动作（可能为 null）。
func _run_attack_flow(battle, attacker_side: StringName, target_side: StringName, target_has_defend: bool) -> Dictionary:
	var gs = battle.context.game_state
	var attacker_mech = gs.get_mech_for_player(attacker_side)
	var target_mech = gs.get_mech_for_player(target_side)
	if attacker_mech == null or target_mech == null:
		return {"ok": false, "msg": "机甲缺失"}
	attacker_mech.position = {"q": 5, "r": 0}
	target_mech.position = {"q": 6, "r": 0}
	_set_first_weapon_might(attacker_mech, 12)
	_clear_map_terrain(battle)
	_clear_hand(battle, target_side)
	var defend_cid: StringName = &""
	if target_has_defend:
		defend_cid = _ensure_card_in_hand(battle, target_side, "action_009_防御")
		if defend_cid == &"":
			return {"ok": false, "msg": "找不到 防御 牌"}
	var attack_card_id: StringName = _ensure_card_in_hand(battle, attacker_side, "action_001_进攻")
	if attack_card_id == &"":
		return {"ok": false, "msg": "攻击方无攻击牌"}
	var weapon_ids: Array = attacker_mech.get_weapon_ids()
	if weapon_ids.is_empty():
		return {"ok": false, "msg": "攻击方无机甲武器"}
	var weapon_id: StringName = weapon_ids[0]
	battle.context.action_ui_bridge.context = battle.context
	var atk_result: Dictionary = battle.execute_attack_action(attacker_side, target_side, weapon_id, attack_card_id)
	var attack_id: StringName = atk_result.get("action_id", &"") if atk_result is Dictionary else &""
	if attack_id == &"":
		return {"ok": false, "msg": "attack action_id 为空: %s" % str(atk_result)}
	if target_has_defend:
		var wait_info: Dictionary = battle.context.action_ui_bridge.get_waiting_action_info()
		if String(wait_info.get("input_type", &"")) != &"respond_attack":
			return {"ok": false, "msg": "未暂停 respond_attack: %s" % String(wait_info.get("input_type", &""))}
		var sel: Array[Dictionary] = [{
			"effect_id": &"defend_availability",
			"card_instance_id": defend_cid,
			"availability_priority": 5,
		}]
		battle.context.timing_engine.handle_response_selection(attack_id, sel)
	var dc = await _find_damage_change(battle, attack_id)
	return {"ok": true, "attack_id": attack_id, "dc": dc}


## ── 效果定义形状 ──
func test_pilot_048_effect_definition() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var e1 = effects.get(&"pilot_048_effect_01")
	if e1 == null:
		return "缺 pilot_048_effect_01"
	if e1.mode != _TimingConst.MODE_LISTEN:
		return "mode 应 LISTEN"
	if e1.listen_timing != _TimingConst.ATTACK_AFTER:
		return "listen_timing 应 ATTACK_AFTER"
	if int(e1.priority) != 10:
		return "priority 应 10"
	if e1.listen_action_type != &"attack":
		return "listen_action_type 应 attack"
	var conds: Array = e1.conditions if e1.conditions != null else []
	if conds.size() != 2:
		return "条件应2个，实=%d" % conds.size()
	var ops: Array = []
	for c in conds:
		ops.append(c.get("op", &""))
	if not ops.has(&"SELF_MECH_IS_ATTACKER"):
		return "条件应含 SELF_MECH_IS_ATTACKER: %s" % str(ops)
	if not ops.has(&"ATTACK_HIT"):
		return "条件应含 ATTACK_HIT: %s" % str(ops)
	var acts: Array = e1.actions if e1.actions != null else []
	if acts.size() != 2:
		return "动作应2个，实=%d" % acts.size()
	var a0: Dictionary = acts[0]
	if a0.get("type", &"") != &"MODIFY_ATTACK_MARKERS":
		return "动作0 应 MODIFY_ATTACK_MARKERS，实=%s" % String(a0.get("type", &""))
	if int(a0.get("params", {}).get("delta", 0)) != 1:
		return "动作0 delta 应 1"
	var a1: Dictionary = acts[1]
	if a1.get("type", &"") != &"SET_ACTION_RECORD_FLAG":
		return "动作1 应 SET_ACTION_RECORD_FLAG，实=%s" % String(a1.get("type", &""))
	if String(a1.get("params", {}).get("flag", &"")) != &"attacker_always_places_damage_tokens":
		return "动作1 flag 应 attacker_always_places_damage_tokens"
	if bool(a1.get("params", {}).get("value", false)) != true:
		return "动作1 value 应 true"
	return true


## ── 我方攻击命中 → extra_markers=+1 且 flag 已写 ──
func test_pilot_048_hit_extra_markers_and_flag() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_chiya(battle, &"player")
	if s == null:
		return "setup 失败（缺 pilot_048_赤牙）"
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, s.mech.mech_id, s.gs.get_mech_for_player(&"enemy").mech_id, {"weapon_might": 12, "weapon_range": 1})
	attack.record["damage"] = 5
	attack.record["base_damage"] = 5
	attack.record["hit"] = true
	attack.record["markers"] = 2
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_markers", 0)) != 1:
		return "命中应 extra_markers +1 实=%d" % int(attack.record.get("extra_markers", 0))
	var flags: Dictionary = attack.record.get("_effect_flags", {})
	var entry: Dictionary = flags.get(&"attacker_always_places_damage_tokens", {})
	if bool(entry.get("value", false)) != true:
		return "命中应写通用flag attacker_always_places_damage_tokens=true"
	return true


## ── 未命中 → 无 +1 无 flag ──
func test_pilot_048_miss_no_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_chiya(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var attack := _make_attack(battle, s.mech.mech_id, s.gs.get_mech_for_player(&"enemy").mech_id, {"weapon_might": 12, "weapon_range": 1})
	attack.record["damage"] = 0
	attack.record["hit"] = false
	attack.record["markers"] = 0
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_markers", 0)) != 0:
		return "未命中不应 extra_markers +1 实=%d" % int(attack.record.get("extra_markers", 0))
	if attack.record.has("_effect_flags") and attack.record.get("_effect_flags", {}).has(&"attacker_always_places_damage_tokens"):
		return "未命中不应写通用flag"
	return true


## ── 非我方攻击（我方为被攻击方）→ 不触发 ──
func test_pilot_048_not_attacker_no_effect() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var s = _setup_chiya(battle, &"player")
	if s == null:
		return "setup 失败"
	battle.context.action_ui_bridge.context = battle.context
	var enemy_mech = s.gs.get_mech_for_player(&"enemy")
	var attack := _make_attack(battle, enemy_mech.mech_id, s.mech.mech_id, {"weapon_might": 12, "weapon_range": 1})
	attack.record["damage"] = 5
	attack.record["hit"] = true
	attack.record["markers"] = 2
	s.te.fire_timing(_TimingConst.ATTACK_AFTER, attack)
	await _pump_frames(5)
	if int(attack.record.get("extra_markers", 0)) != 0:
		return "非我方攻击不应 extra_markers +1 实=%d" % int(attack.record.get("extra_markers", 0))
	if attack.record.has("_effect_flags") and attack.record.get("_effect_flags", {}).has(&"attacker_always_places_damage_tokens"):
		return "非我方攻击不应写通用flag"
	return true


## ── 真实流程：我方带赤牙攻击+目标防御响应 → 损伤 executor=我方（损伤由我方设置）──
func test_pilot_048_responded_executor_attacker() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if _setup_chiya(battle, &"player") == null:
		return "setup 失败（缺 pilot_048_赤牙）"
	var r: Dictionary = await _run_attack_flow(battle, &"player", &"enemy", true)
	if not r.get("ok", false):
		return r.get("msg", "攻击流程失败")
	var dc = r.get("dc")
	if dc == null:
		return "未产生 damage_change"
	if String(dc.record.get("executor", &"")) != &"player":
		return "被响应+赤牙：损伤 executor 应=player（我方设置），实=%s" % String(dc.record.get("executor", &""))
	return true


## ── 真实流程（回归）：无赤牙+目标防御响应 → 损伤 executor=目标（默认规则）──
func test_pilot_048_responded_default_executor_target() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var r: Dictionary = await _run_attack_flow(battle, &"player", &"enemy", true)
	if not r.get("ok", false):
		return r.get("msg", "攻击流程失败")
	var dc = r.get("dc")
	if dc == null:
		return "未产生 damage_change"
	if String(dc.record.get("executor", &"")) != &"enemy":
		return "无赤牙+被响应：损伤 executor 应=enemy（默认目标方设置），实=%s" % String(dc.record.get("executor", &""))
	return true


## ── 真实流程：我方带赤牙攻击未响应 → 损伤=floor(might/5)+1 且 executor=我方 ──
func test_pilot_048_unresponded_markers_plus1() -> Variant:
	var battle := _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	if _setup_chiya(battle, &"player") == null:
		return "setup 失败（缺 pilot_048_赤牙）"
	var r: Dictionary = await _run_attack_flow(battle, &"player", &"enemy", false)
	if not r.get("ok", false):
		return r.get("msg", "攻击流程失败")
	var dc = r.get("dc")
	if dc == null:
		return "未产生 damage_change"
	if int(dc.record.get("value", 0)) != 3:
		return "未响应+赤牙：损伤应=floor(12/5)+1=3，实=%d" % int(dc.record.get("value", 0))
	if String(dc.record.get("executor", &"")) != &"player":
		return "未响应：损伤 executor 应=player，实=%s" % String(dc.record.get("executor", &""))
	return true
