## test_pilot_002_wrbirl.gd - 莱比尔（pilot_002）重做后逻辑测试
##
## 验证重做裁定（用户口述，覆盖旧拆解文档）：
##   effect_01 EX 按钮：授予「其他」联邦阵营机师（不含莱比尔自身）进攻/防御转化能力
##     - 进攻：A 交任意张行动牌给5格内 B，A 自己当作进攻使用（消耗 A 攻击数，
##       A 武器范围内任选目标，与 B 无关），结算后 A 抽2
##     - 防御：A 被攻击时，交牌给5格内 B（任意人含攻击者），A 自己当作防御响应
##       （护甲+5 本次攻击可见、损伤标记-1），A 抽2。交牌不进临时区直接给 B 手牌
##   effect_02 联邦「机甲框架」护甲+4（按框架阵营判断，与 EX 按机师牌阵营分开）
##   effect_03 取消/恢复加成（我方回合1次，选其他机甲，弹窗二选一：取消/恢复）
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
	battle.rng_seed = 12345
	var start_result := battle.start_tutorial(registry)
	if not start_result.ok:
		push_error(start_result.message)
	_clear_pilot_static()
	return battle


## 清空 pilot 静态状态（_pilot_aura / _pilot_002_batches），避免跨测试泄漏
func _clear_pilot_static() -> void:
	for src in _ActionPilotEffects._pilot_aura.keys():
		_ActionPilotEffects.unregister_faction_aura(src)
	var b_sources: Array = []
	for bid in _ActionPilotEffects._pilot_002_batches.keys():
		b_sources.append(_ActionPilotEffects._pilot_002_batches[bid].get("grant_source", &""))
	for s in b_sources:
		_ActionPilotEffects.clear_pilot_002_batches_for_source(s)


func _make_instance(gs, cdb, card_def_id: String, owner_id: StringName):
	var pdef = cdb.get_card(StringName(card_def_id))
	if pdef == null:
		return null
	var inst_id: StringName = gs.next_id(&"card")
	var card = _CardInstance.new(inst_id, pdef)
	card.owner_player_id = owner_id
	gs.cards[inst_id] = card
	return card


func _make_attack(battle, attacker_id: StringName, target_id: StringName, extra: Dictionary = {}) -> _Action:
	var attack := _Action.new()
	attack.action_id = &"test_p002_%d" % [randi() % 1000000]
	attack.action_type = &"attack"
	attack.record = {
		"attacker_id": attacker_id,
		"target_id": target_id,
		"weapon_might": int(extra.get("weapon_might", 5)),
		"target_count": 1,
	}
	attack.record.merge(extra, true)
	attack.state = &"running"
	attack.context = battle.context
	battle.context.action_registry.register(attack)
	return attack


## 测试1：进攻分支定义——EXECUTE_ATTACK cardless + consume_turn_attack_count + DRAW 2 + ATTACK_COUNT_ABOVE
func test_pilot_002_offense_uses_execute_attack_cardless() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var atk = effects.get(&"pilot_002_granted_transfer_attack")
	if atk == null:
		return "缺 granted_transfer_attack"
	var has_exec_attack := false
	var has_draw2 := false
	for a in atk.actions:
		if String(a.get("type", "")) == "EXECUTE_ATTACK":
			var p: Dictionary = a.get("params", {})
			if bool(p.get("cardless_weapon_attack", false)) and bool(p.get("consume_turn_attack_count", false)):
				has_exec_attack = true
		if String(a.get("type", "")) == "EXECUTE_GAIN_CARD" and int(a.get("params", {}).get("count", 0)) == 2:
			has_draw2 = true
	if not has_exec_attack:
		return "进攻分支应用 EXECUTE_ATTACK cardless+consume_turn_attack_count（A 自己进攻消耗攻击数）"
	if not has_draw2:
		return "进攻分支应抽2"
	var has_atk_count := false
	for c in atk.conditions:
		if String(c.get("op", "")) == "ATTACK_COUNT_ABOVE" and int(c.get("params", {}).get("threshold", -1)) == 0:
			has_atk_count = true
	if not has_atk_count:
		return "进攻分支条件应含 ATTACK_COUNT_ABOVE threshold=0（主动攻击须可攻击）"
	return true


## 测试2：防御分支定义——A 自己防御（SELF_MECH_IS_ATTACK_TARGET + CHOOSE_OTHER_MECH 选 B
##   + TRANSFER + ADD_MECH_TEMP_ARMOR+5($binding_context.mech_id) + MODIFY_ATTACK_MARKERS-1 + DRAW 2），
##   不再用批次机制（GRANT_TRANSFER_BATCH_AS_NAMED_TYPE / PILOT_002_USE_BATCH_AS_NAMED）
func test_pilot_002_defense_a_self_defends() -> Variant:
	var effects = _ActionPilotEffects.build_pilot_effects()
	var def = effects.get(&"pilot_002_granted_transfer_defense")
	if def == null:
		return "缺 granted_transfer_defense"
	var has_self_target := false
	for c in def.conditions:
		if String(c.get("op", "")) == "SELF_MECH_IS_ATTACK_TARGET":
			has_self_target = true
	if not has_self_target:
		return "防御分支条件应含 SELF_MECH_IS_ATTACK_TARGET（A 自身被攻击）"
	var has_choose_other := false
	for r in def.target_rules:
		if String(r.get("rule", "")) == "CHOOSE_OTHER_MECH":
			has_choose_other = true
	if not has_choose_other:
		return "防御分支目标应含 CHOOSE_OTHER_MECH（选交牌目标 B）"
	var has_transfer := false
	var has_armor := false
	var has_markers := false
	var has_batch := false
	for a in def.actions:
		var t: String = String(a.get("type", ""))
		if t == "TRANSFER_ACTION_CARDS":
			has_transfer = true
		elif t == "ADD_MECH_TEMP_ARMOR":
			var p: Dictionary = a.get("params", {})
			if int(p.get("delta", 0)) == 5 and String(p.get("mech_id", "")) == "$binding_context.mech_id":
				has_armor = true
		elif t == "MODIFY_ATTACK_MARKERS" and int(a.get("params", {}).get("delta", 0)) == -1:
			has_markers = true
		if t in ["GRANT_TRANSFER_BATCH_AS_NAMED_TYPE", "PILOT_002_USE_BATCH_AS_NAMED"]:
			has_batch = true
	if not has_transfer:
		return "防御分支应含 TRANSFER_ACTION_CARDS"
	if not has_armor:
		return "防御分支应含 ADD_MECH_TEMP_ARMOR +5 mech_id=$binding_context.mech_id（A 自己护甲+5）"
	if not has_markers:
		return "防御分支应含 MODIFY_ATTACK_MARKERS -1（A 本次攻击损伤-1）"
	if has_batch:
		return "防御分支不应再用批次机制（A 自己防御，非 B 转化）"
	return true


## 测试3：ADD_MECH_TEMP_ARMOR 的 params.mech_id 优先解析（$binding_context.mech_id）
## 响应窗口触发时 payload.mech_id 是莱比尔牌持有者机甲，须显式指定被授予被攻击方 A。
func test_pilot_002_add_temp_armor_respects_binding_context_mech() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")  # A（被攻击方/被授予）
	var enemy_mech = gs.get_mech_for_player(&"enemy")    # 莱比尔牌持有者（误路由目标）
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {})
	# 模拟响应窗口非迎击路径：payload.mech_id=enemy_mech（牌持有者），binding_context.mech_id=player_mech（A）
	var payload: Dictionary = {
		"binding_context": {"mech_id": player_mech.mech_id, "player_id": &"player"},
		"mech_id": enemy_mech.mech_id,
		"source_mech_id": enemy_mech.mech_id,
		"attack_action_id": attack.action_id,
	}
	var armor_before: int = player_mech.temp_armor_bonus
	var enemy_before: int = enemy_mech.temp_armor_bonus
	battle.context.action_service.execute_sub_action(
		{"type": &"ADD_MECH_TEMP_ARMOR", "params": {"delta": 5, "mech_id": "$binding_context.mech_id"}},
		payload, attack)
	if player_mech.temp_armor_bonus != armor_before + 5:
		return "A(player_mech) 护甲应+5 实=%d（before=%d）" % [player_mech.temp_armor_bonus, armor_before]
	if enemy_mech.temp_armor_bonus != enemy_before:
		return "误路由：enemy_mech 护甲不应变 实=%d（before=%d）" % [enemy_mech.temp_armor_bonus, enemy_before]
	var grants: Array = attack.record.get("temp_armor_grants", [])
	if grants.is_empty() or String(grants[0].get("mech_id", "")) != String(player_mech.mech_id):
		return "temp_armor_grants 应登记 A(player_mech)"
	return true


## 测试4：MODIFY_ATTACK_MARKERS -1 写入攻击动作 record["extra_markers"]（供 _step_apply_damage 读取）
func test_pilot_002_modify_attack_markers_writes_attack() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {})
	battle.context.action_service.execute_sub_action(
		{"type": &"MODIFY_ATTACK_MARKERS", "params": {"delta": -1}},
		{"attack_action_id": attack.action_id}, attack)
	if int(attack.record.get("extra_markers", 0)) != -1:
		return "attack extra_markers 应=-1 实=%d" % int(attack.record.get("extra_markers", 0))
	return true


## 测试5：effect_02 护甲+4 按机甲框架阵营判断（与 EX 按机师牌阵营分开）
##   player_mech 基础框架=联邦 -> +4；enemy_mech 原始框架=帝国 -> 0（即使莱比尔在场）
func test_pilot_002_armor_bonus_uses_frame_faction() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")  # 基础框架=联邦
	var enemy_mech = gs.get_mech_for_player(&"enemy")    # 原始框架=帝国
	var card = _make_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔"
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	if _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech) != 4:
		return "联邦框架应+4 实=%d" % _ActionPilotEffects.get_pilot_002_federation_armor_bonus(player_mech)
	if _ActionPilotEffects.get_pilot_002_federation_armor_bonus(enemy_mech) != 0:
		return "帝国框架应0（护甲按框架阵营，非机师牌阵营）实=%d" % _ActionPilotEffects.get_pilot_002_federation_armor_bonus(enemy_mech)
	return true


## 测试6：莱比尔自身也获 EX（effect_01 授予所有联邦阵营机师含自身，去自身排除）
func test_pilot_002_grant_includes_self() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return "找不到 pilot_002_莱比尔"
	# 给 enemy_mech 装联邦机师（仅设槽，不注册其效果），作为被授予方
	var fed_pilot = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"enemy")
	if fed_pilot == null:
		return "找不到 pilot_001_阿克罗姆"
	var enemy_pilot_slot = enemy_mech.slots.get(&"pilot")
	if enemy_pilot_slot == null:
		return "enemy_mech 缺 pilot 槽"
	enemy_pilot_slot.equipped_card = fed_pilot
	fed_pilot.zone = &"pilot_slot"
	fed_pilot.slot_id = &"pilot"
	fed_pilot.mech_id = enemy_mech.mech_id
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	var te = battle.context.timing_engine
	var on_self := false
	var on_enemy := false
	for timing: StringName in te.permanent_listeners:
		for entry in te.permanent_listeners[timing]:
			var eff = entry.get("effect")
			if eff != null and String(eff.effect_id) == "pilot_002_granted_transfer_attack":
				var bc: Dictionary = entry.get("binding_context", {})
				if String(bc.get("card_instance_id", &"")) == String(card.instance_id):
					if String(bc.get("mech_id", &"")) == String(player_mech.mech_id):
						on_self = true
					if String(bc.get("mech_id", &"")) == String(enemy_mech.mech_id):
						on_enemy = true
	if not on_self:
		return "莱比尔自身 player_mech 也应被授予 EX（去自身排除）"
	if not on_enemy:
		return "enemy_mech（联邦机师）应被授予 EX"
	return true


## 公共设置：莱比尔装在 player_mech，联邦机师(pilot_001)装在 enemy_mech，
## set_pilot 触发 effect_01 授予 enemy_mech EX 进攻(DIRECT)+防御(AVAILABILITY) listener。
## 返回 {player_mech, enemy_mech, pilot_card, fed_pilot}；失败返回空字典。
func _setup_rabil_grant(battle) -> Dictionary:
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var player_mech = gs.get_mech_for_player(&"player")
	var enemy_mech = gs.get_mech_for_player(&"enemy")
	var card = _make_instance(gs, cdb, "pilot_002_莱比尔", &"player")
	if card == null:
		return {}
	var fed_pilot = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"enemy")
	if fed_pilot == null:
		return {}
	var enemy_pilot_slot = enemy_mech.slots.get(&"pilot")
	if enemy_pilot_slot == null:
		return {}
	enemy_pilot_slot.equipped_card = fed_pilot
	fed_pilot.zone = &"pilot_slot"
	fed_pilot.slot_id = &"pilot"
	fed_pilot.mech_id = enemy_mech.mech_id
	battle.context.game_setup_service.set_pilot(player_mech.mech_id, card)
	return {"player_mech": player_mech, "enemy_mech": enemy_mech, "pilot_card": card, "fed_pilot": fed_pilot}


## 给指定玩家手牌补1张行动牌（从行动牌堆顶抽），返回 card_instance_id；牌堆空返回 &""。
func _give_action_card(battle, player_id: StringName) -> StringName:
	var gs = battle.context.game_state
	var player = gs.players.get(player_id)
	if player == null or gs.deck_state.action_deck.is_empty():
		return &""
	var cid: StringName = gs.deck_state.action_deck[0]
	gs.deck_state.action_deck.remove_at(0)
	player.action_hand.append(cid)
	var c = gs.get_card(cid)
	if c != null:
		c.zone = &"action_hand"
	return cid


## 测试7：_find_effect_listener 按 mech_id 去歧义--多机甲共享 pilot_002 实例时，
## 精确返回被授予机甲 A(enemy_mech) 的 listener，莱比尔自身(player_mech)无 listener 返回 null。
## 此 helper 同时支撑 Fix A(_execute_effect_by_id 跨机甲去歧义)与 Fix C'(响应窗口推导响应方)。
func test_pilot_002_find_listener_disambiguates_by_mech() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败（缺 pilot_002_莱比尔 或 pilot_001_阿克罗姆）"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	var te = battle.context.timing_engine
	# enemy_mech(联邦机师)应能找到 granted 进攻 listener，binding_context.mech_id=enemy
	var entry_enemy = te._find_effect_listener(&"pilot_002_granted_transfer_attack", pilot_card.instance_id, enemy_mech.mech_id)
	if entry_enemy == null:
		return "应为 enemy_mech 找到 granted 进攻 listener（按 mech_id 去歧义）"
	var e_bind: Dictionary = entry_enemy.get("binding_context", {})
	if String(e_bind.get("mech_id", &"")) != String(enemy_mech.mech_id):
		return "enemy listener 的 mech_id 应=enemy_mech 实=%s" % String(e_bind.get("mech_id", &""))
	# 莱比尔自身也获 EX（去自身排除），应命中自身的 granted listener（mech_id=player_mech）
	var entry_self = te._find_effect_listener(&"pilot_002_granted_transfer_attack", pilot_card.instance_id, player_mech.mech_id)
	if entry_self == null:
		return "莱比尔自身 player_mech 也应有 granted listener（去自身排除）"
	var s_bind: Dictionary = entry_self.get("binding_context", {})
	if String(s_bind.get("mech_id", &"")) != String(player_mech.mech_id):
		return "自身 listener 的 mech_id 应=player_mech 实=%s" % String(s_bind.get("mech_id", &""))
	return true


## 测试8：响应窗口路由(Fix C')--pilot_002 防御效果来源牌在莱比尔机甲(player_mech)上，
## 但实际响应方是被攻击的联邦机甲 A(enemy_mech)。handle_response_selection 应按 attack target
## 从 granted listener 推导 responder_mech_id=A(enemy_mech)，否则 ADD_MECH_TEMP_ARMOR 等会误作用到莱比尔。
func test_pilot_002_defense_response_routes_to_granted_mech() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	# A=enemy_mech 被攻击：attack target=enemy_mech，attacker=player_mech(莱比尔)
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {})
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id}
	var defense_effect = _ActionPilotEffects.build_pilot_effects().get(&"pilot_002_granted_transfer_defense")
	if defense_effect == null:
		return "缺 granted_transfer_defense"
	# card_data：来源牌=pilot_002(在 player_mech 上)，effect_id=防御分支
	var card_data: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"effect_id": &"pilot_002_granted_transfer_defense",
		"effect": defense_effect,
		"availability_priority": 5,
	}
	var selected: Array[Dictionary] = [card_data]
	var te = battle.context.timing_engine
	te.handle_response_selection(attack.action_id, selected)
	var resp: Dictionary = attack.record.get("response_source", {})
	if String(resp.get("mech_id", &"")) != String(enemy_mech.mech_id):
		return "响应方应推导为被攻击的 A(enemy_mech) 实=%s" % String(resp.get("mech_id", &""))
	if String(resp.get("player_id", &"")) != String(&"enemy"):
		return "响应方 player_id 应=enemy 实=%s" % String(resp.get("player_id", &""))
	return true


## 测试9：_execute_effect_by_id 跨机甲路由(Fix A + 回退过滤)--source.mech_id 指定执行机甲时：
##   正例(source=A=enemy_mech)走 _find_effect_listener 精确命中 A 的 granted 进攻 listener，
##     条件通过后请求目标选择(request_target_selection 信号触发)；
##   反例(source=莱比尔自身 player_mech，无自身 listener)回退循环按 mech_id 过滤跳过 enemy_mech
##     的 listener，不执行(信号不触发)--证明回退过滤避免误取其他机甲的 granted listener。
func test_pilot_002_offense_effect_routes_by_source_mech() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = battle.context.game_state
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	# enemy_mech 挪到 player_mech 5格内(HAS_OTHER_MECH_IN_HEX_RANGE 通过)
	enemy_mech.position = {"q": 3, "r": 2}
	# 给 enemy 1张行动牌(HAS_ACTION_CARD_IN_HAND 通过)
	if _give_action_card(battle, &"enemy") == &"":
		return "无法给 enemy 补行动牌"
	var te = battle.context.timing_engine
	var fired := [false]
	te.request_target_selection.connect(func(_a, _e, _r, _p) -> void: fired[0] = true)
	# 断开 ActionUIBridge 的 action_needs_input 自动 resume，避免 _auto_mech_target 续跑
	# CHOOSE_MANY_CARDS（未选牌）-> TRANSFER nil 卡牌报错。测9仅验证路由触发选目标信号。
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)
	# 正例：source.mech_id=A(enemy_mech) -> 命中 A 的 listener -> 条件通过 -> 请求选目标
	var mock_pos = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {})
	mock_pos.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	var payload_pos: Dictionary = {
		"source": {"card_instance_id": pilot_card.instance_id, "mech_id": enemy_mech.mech_id, "player_id": &"enemy", "effect_id": &"pilot_002_granted_transfer_attack"},
		"phase": &"MAIN",
		"player_id": &"enemy",
		"source_mech_id": enemy_mech.mech_id,
	}
	te._execute_effect_by_id(&"pilot_002_granted_transfer_attack", payload_pos, mock_pos)
	if not fired[0]:
		return "正例：source=A(enemy_mech) 应命中 A 的 granted listener 并请求选目标（实未触发）"
	# 反例：source.mech_id=不存在的机甲(无 granted listener) -> _find 无命中，
	# 回退循环按 mech_id 过滤也跳过所有真实 listener，不执行（验证回退过滤）
	fired[0] = false
	var mock_neg = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {})
	mock_neg.source = {"player_id": &"player", "mech_id": player_mech.mech_id}
	var payload_neg: Dictionary = {
		"source": {"card_instance_id": pilot_card.instance_id, "mech_id": &"fake_mech_no_grant", "player_id": &"player", "effect_id": &"pilot_002_granted_transfer_attack"},
		"phase": &"MAIN",
		"player_id": &"player",
		"source_mech_id": &"fake_mech_no_grant",
	}
	te._execute_effect_by_id(&"pilot_002_granted_transfer_attack", payload_neg, mock_neg)
	if fired[0]:
		return "反例：source=不存在机甲 不应执行任何 granted listener（回退应按 mech_id 过滤）"
	return true


## 测试10：防御响应挂起不抢跑（Fix 问题2）--A 被攻击选"EX-莱比尔转化防御"后，
## attack 应挂起选目标(waiting_timing + _pending_effect)，不 continue_action 越过 ATTACK_AT 直接命中。
func test_pilot_002_defense_response_pauses_not_continues() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	enemy_mech.position = {"q": 3, "r": 2}  # 5格内（HAS_OTHER_MECH_IN_HEX_RANGE 通过）
	if _give_action_card(battle, &"enemy") == &"":
		return "无法给 enemy 补行动牌"
	# A=enemy_mech 被攻击
	var attack = _make_attack(battle, player_mech.mech_id, enemy_mech.mech_id, {})
	attack.source = {"player_id": &"player", "mech_id": player_mech.mech_id}
	attack.state = &"waiting_timing"  # 模拟 ATTACK_AT 暂停
	var defense_effect = _ActionPilotEffects.build_pilot_effects().get(&"pilot_002_granted_transfer_defense")
	if defense_effect == null:
		return "缺 granted_transfer_defense"
	var card_data: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"effect_id": &"pilot_002_granted_transfer_defense",
		"effect": defense_effect,
		"availability_priority": 5,
	}
	var te = battle.context.timing_engine
	# 断开 action_needs_input 避免 ActionUIBridge 自动 resume 续跑效果链
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)
	var selected: Array[Dictionary] = []
	selected.append(card_data)
	te.handle_response_selection(attack.action_id, selected)
	# 验证：挂起选目标，不 continue_action 推进攻击越过 ATTACK_AT
	if attack.state != &"waiting_timing":
		return "防御应挂起选目标(waiting_timing)不抢跑 实=%s" % String(attack.state)
	if not te._pending_effect.has(attack.action_id):
		return "防御应存 _pending_effect 等选目标 resume（实未存=被 continue 抢跑）"
	return true


## 测试11：换机师刷新 granted 加成（Fix 问题4）--换非联邦机师 EX 消失，换回联邦 EX 恢复。
func test_pilot_002_grant_refresh_on_pilot_change() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = battle.context.game_state
	var cdb = battle.context.card_database
	var enemy_mech = setup["enemy_mech"]
	var te = battle.context.timing_engine
	var _has_grant := func() -> bool:
		for _t: StringName in te.permanent_listeners:
			for _e in te.permanent_listeners[_t]:
				var _feff = _e.get("effect") if _e is Dictionary else null
				if _feff != null and String(_feff.effect_id) == "pilot_002_granted_transfer_attack":
					var _bc: Dictionary = _e.get("binding_context", {}) if _e is Dictionary else {}
					if String(_bc.get("mech_id", &"")) == String(enemy_mech.mech_id):
						return true
		return false
	# 初始：enemy_mech(联邦机师) 已获 EX
	if not _has_grant.call():
		return "初始 enemy_mech 应有 granted EX"
	# 换帝国机师（pilot_005 肯特）：先 unset 再 set
	battle.context.game_setup_service.unset_pilot(enemy_mech.mech_id)
	var imp_pilot = _make_instance(gs, cdb, "pilot_005_肯特", &"enemy")
	if imp_pilot == null:
		return "找不到 pilot_005_肯特"
	battle.context.game_setup_service.set_pilot(enemy_mech.mech_id, imp_pilot)
	if _has_grant.call():
		return "换帝国机师后 enemy_mech 不应有 EX（ungrant 清旧+非联邦不授予）"
	# 换回联邦机师
	battle.context.game_setup_service.unset_pilot(enemy_mech.mech_id)
	var fed_pilot2 = _make_instance(gs, cdb, "pilot_001_阿克罗姆", &"enemy")
	if fed_pilot2 == null:
		return "找不到 pilot_001_阿克罗姆"
	battle.context.game_setup_service.set_pilot(enemy_mech.mech_id, fed_pilot2)
	if not _has_grant.call():
		return "换回联邦机师后 enemy_mech 应重新获 EX（_refresh 授予）"
	return true


## 测试12：防御完整 resume 链（Fix 问题2）--人类玩家 A 被攻击选"EX-莱比尔转化防御"后，
## 选 B->选牌->续跑 TRANSFER+护甲+5+损伤-1+抽2 全流程。
## target_id 语义冲突修复：选 B 后 target_id=B，但 SELF_MECH_IS_ATTACK_TARGET 读 attack_target_id=A 通过。
## 用人类 player 做防御方（enemy 是 AI 会被 _is_ai_owner 跳过 CHOOSE_MANY_CARDS 选牌窗）。
func test_pilot_002_defense_resume_target_id_not_conflict() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var gs = battle.context.game_state
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	var pilot_card = setup["pilot_card"]
	enemy_mech.position = {"q": 3, "r": 2}  # 5格内（HAS_OTHER_MECH_IN_HEX_RANGE 通过）
	# 给 player（人类防御方）补1张行动牌（CHOOSE_MANY_CARDS 选牌 + TRANSFER 用）
	var p_card := _give_action_card(battle, &"player")
	if p_card == &"":
		return "无法给 player 补行动牌"
	var p_hand_before: int = gs.players[&"player"].action_hand.size()
	# A=player_mech（人类）被 enemy_mech 攻击
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {})
	attack.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	attack.state = &"waiting_timing"
	var defense_effect = _ActionPilotEffects.build_pilot_effects().get(&"pilot_002_granted_transfer_defense")
	if defense_effect == null:
		return "缺 granted_transfer_defense"
	var card_data: Dictionary = {
		"card_instance_id": pilot_card.instance_id,
		"effect_id": &"pilot_002_granted_transfer_defense",
		"effect": defense_effect,
		"availability_priority": 5,
	}
	var te = battle.context.timing_engine
	for _c in te.action_needs_input.get_connections():
		te.action_needs_input.disconnect(_c.callable)
	var selected: Array[Dictionary] = []
	selected.append(card_data)
	te.handle_response_selection(attack.action_id, selected)
	# 防御挂起选目标，payload 应含 attack_target_id=A=player_mech
	if not te._pending_effect.has(attack.action_id):
		return "防御应挂起 _pending_effect 等选目标"
	var pending: Dictionary = te._pending_effect[attack.action_id]
	var pend_payload: Dictionary = pending.get("payload", {})
	if String(pend_payload.get("attack_target_id", &"")) != String(player_mech.mech_id):
		return "payload 应含 attack_target_id=A(player_mech) 实=%s" % String(pend_payload.get("attack_target_id", &""))
	# 选 B=enemy_mech：resume 注入 target_id=B，重跑 _execute_effect
	# SELF_MECH_IS_ATTACK_TARGET 应读 attack_target_id=A 通过（A==A），不被 target_id=B 覆盖致失败
	te.resume_pending_effect(attack.action_id, {"target_id": enemy_mech.mech_id})
	# 验证：条件通过 -> 进入 CHOOSE_MANY_CARDS 选牌（再次挂起 waiting_timing + _pending_effect choose_many_cards）
	if not te._pending_effect.has(attack.action_id):
		return "选 B 后应挂起选牌(choose_many_cards) 实无 _pending_effect（条件被 target_id=B 破坏？）"
	var pending2: Dictionary = te._pending_effect[attack.action_id]
	if String(pending2.get("phase", &"")) != "choose_many_cards":
		return "应进入 choose_many_cards 选牌阶段 实=%s" % String(pending2.get("phase", &""))
	# 选牌：交 p_card 给 B=enemy_mech，续跑 TRANSFER+ADD_MECH_TEMP_ARMOR+MODIFY_ATTACK_MARKERS+DRAW
	te.resume_pending_effect(attack.action_id, {"selected_card_ids": [p_card], "cancelled": false})
	# 验证护甲+5（A 自己防御，$binding_context.mech_id=A=player_mech）
	if player_mech.temp_armor_bonus < 5:
		return "A(player_mech) 护甲应+5 实=%d" % player_mech.temp_armor_bonus
	# 验证损伤-1（attack extra_markers=-1）
	if int(attack.record.get("extra_markers", 0)) != -1:
		return "attack extra_markers 应=-1 实=%d" % int(attack.record.get("extra_markers", 0))
	# 验证抽2（player 手牌净增：-1交牌+2抽=+1）
	var p_hand_after: int = gs.players[&"player"].action_hand.size()
	if p_hand_after != p_hand_before + 1:
		return "player 手牌应净+1（交1抽2）实 before=%d after=%d" % [p_hand_before, p_hand_after]
	return true


## 测试13：莱比尔防御被"锁定"封锁--priority=5 < 20，A 被攻击者锁定时，
## granted 防御不出现在响应窗口（get_available_cards 不含）。
## 规则书 行动牌效果20·锁定效果1：所有 priority < 20 的响应攻击效果被取消。
## 对照：未锁定时防御在列表。封锁检查走通用路径（granted 无 availability_condition）。
func test_pilot_002_defense_locked_out() -> Variant:
	var battle = _new_battle()
	if battle == null or battle.context == null:
		return "battle 初始化失败"
	var setup = _setup_rabil_grant(battle)
	if setup.is_empty():
		return "setup 失败"
	var player_mech = setup["player_mech"]
	var enemy_mech = setup["enemy_mech"]
	enemy_mech.position = {"q": 3, "r": 2}  # 5格内（HAS_OTHER_MECH_IN_HEX_RANGE 通过）
	if _give_action_card(battle, &"player") == &"":
		return "无法给 player 补行动牌"
	var te = battle.context.timing_engine
	# attack: enemy_mech 攻击 player_mech(A)
	var attack = _make_attack(battle, enemy_mech.mech_id, player_mech.mech_id, {})
	attack.source = {"player_id": &"enemy", "mech_id": enemy_mech.mech_id}
	# 对照：未锁定 -> granted 防御在响应窗口可用列表
	var avail_before: Array[Dictionary] = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	var has_def_before := false
	for c in avail_before:
		if String(c.get("effect_id", &"")) == "pilot_002_granted_transfer_defense":
			has_def_before = true
			break
	if not has_def_before:
		return "未锁定时莱比尔防御应在响应窗口可用列表 实=%d 项" % avail_before.size()
	# 施加锁定：locker=enemy 玩家 对 A(player_mech) 锁定
	player_mech.add_status({"type": &"LOCKED", "source_player_id": &"enemy"})
	# 锁定后 -> granted 防御被封锁（不在列表）
	var avail_after: Array[Dictionary] = te.get_available_cards(_TimingConst.ATTACK_AT, attack)
	for c in avail_after:
		if String(c.get("effect_id", &"")) == "pilot_002_granted_transfer_defense":
			return "锁定后莱比尔防御应被封锁（priority=5<20 不在响应窗口）实仍出现"
	return true
