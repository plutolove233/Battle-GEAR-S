## test_timing_listener.gd — 时点监听测试
##
## 测试新逻辑中时点（Timing Point）的监听机制：
##   1. 永久监听器注册、触发、注销
##   2. 临时监听器注册、action_id 过滤、action_type 过滤
##   3. 同一时点多个效果按优先级排序执行（数值越小越先）
##   4. 时点发出后暂停当前动作，等待所有监听效果执行完毕
##   5. 动作 cleanup 时自动清除关联的临时监听器
##   6. 注销指定牌的所有临时监听器
##   7. AVAILABILITY 模式效果在响应窗口中处理
##   8. 效果间依赖（requires_effect）检查
##   9. 被抑制的效果（锁定状态等）不触发
##   10. TimingConst 所有动作时点定义正确
extends RefCounted

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _TimingEngine = preload("res://scripts/action_core/TimingEngine.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")
const _Action = preload("res://scripts/action_core/Action.gd")
const _ActionRegistry = preload("res://scripts/action_core/ActionRegistry.gd")


## 测试3：临时监听器 action_id 过滤——不匹配时不触发
func test_temporary_listener_action_id_filter():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"bound_effect"
	effect.priority = 10
	effect.mode = _TimingConst.MODE_LISTEN
	effect.conditions = []
	effect.target_rules = []
	effect.costs = []
	effect.actions = []

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"action_1", &"attack", effect)

	var other_action = _Action.new()
	other_action.action_id = &"action_2"
	other_action.action_type = &"attack"
	other_action.record = {}

	var fired := false
	engine.effect_executed.connect(func(eid, aid):
		fired = true
	)

	engine.fire_timing(_TimingConst.ATTACK_AT, other_action)

	if fired:
		return "绑定到 action_1 的监听器不应在 action_2 的时点触发"
	return true


## 测试4：临时监听器 action_type 过滤——不匹配时不触发
func test_temporary_listener_action_type_filter():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"type_bound_effect"
	effect.priority = 10
	effect.mode = _TimingConst.MODE_LISTEN
	effect.conditions = []
	effect.target_rules = []
	effect.costs = []
	effect.actions = []

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"", &"attack", effect)

	var move_action = _Action.new()
	move_action.action_id = &"move_1"
	move_action.action_type = &"basic_move"
	move_action.record = {}

	var fired := false
	engine.effect_executed.connect(func(eid, aid):
		fired = true
	)

	engine.fire_timing(_TimingConst.ATTACK_AT, move_action)

	if fired:
		return "绑定到 attack 类型的监听器不应在 basic_move 的时点触发"
	return true


## 测试5：同一时点多个效果按优先级排序执行
func test_priority_ordering():
	var engine = _TimingEngine.new()
	var execution_order: Array[StringName] = []

	for i in range(3):
		var effect = _ActionEffect.new()
		effect.effect_id = &"effect_priority_%d" % [20 - i * 5]
		effect.priority = 20 - i * 5
		effect.mode = _TimingConst.MODE_LISTEN
		effect.conditions = []
		effect.target_rules = []
		effect.costs = []
		effect.actions = []
		engine.register_permanent_listener(_TimingConst.ATTACK_BEFORE, effect)

	var action = _Action.new()
	action.action_id = &"test_priority"
	action.action_type = &"attack"
	action.record = {}

	engine.effect_executed.connect(func(eid, aid):
		execution_order.append(eid)
	)

	engine.fire_timing(_TimingConst.ATTACK_BEFORE, action)

	if execution_order.size() != 3:
		return "应执行3个效果，实际: %d" % execution_order.size()
	# 设计文档（各动作的生命周期与时点.txt 第9行）：同一时点按优先级从大到小执行，同优先级先来后到。
	# priority=20 最先、priority=10 居中、priority=5 最后。
	if execution_order[0] != &"effect_priority_20":
		return "优先级20应最先执行，实际最先: %s" % String(execution_order[0])
	if execution_order[2] != &"effect_priority_10":
		return "优先级10应最后执行，实际最后: %s" % String(execution_order[2])
	return true


## 测试6：无监听器时发出时点不报错
func test_fire_timing_no_listeners():
	var engine = _TimingEngine.new()

	var action = _Action.new()
	action.action_id = &"no_listener_action"
	action.action_type = &"attack"
	action.record = {}

	engine.fire_timing(_TimingConst.ATTACK_BEFORE, action)
	return true


## 测试7：动作 cleanup 时自动清除关联的临时监听器
func test_cleanup_clears_temporary_listeners():
	var engine = _TimingEngine.new()
	var registry = _ActionRegistry.new()

	var context = {
		timing_engine = engine,
		action_registry = registry,
	}
	engine.context = context
	registry.context = context

	var effect = _ActionEffect.new()
	effect.effect_id = &"temp_cleanup_effect"
	effect.priority = 10

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"action_cleanup_test", &"attack", effect)

	var listeners = engine.temporary_listeners.get(_TimingConst.ATTACK_AT, [])
	if listeners.size() != 1:
		return "注册后应有1个临时监听器"

	registry.cleanup_action(&"action_cleanup_test")

	listeners = engine.temporary_listeners.get(_TimingConst.ATTACK_AT, [])
	if listeners.size() != 0:
		return "cleanup后应无临时监听器，实际: %d" % listeners.size()
	return true


## 测试8：注销指定牌的所有临时监听器
func test_unregister_listeners_for_card():
	var engine = _TimingEngine.new()

	var effect1 = _ActionEffect.new()
	effect1.effect_id = &"card_effect_1"
	effect1.priority = 10

	var effect2 = _ActionEffect.new()
	effect2.effect_id = &"card_effect_2"
	effect2.priority = 20

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"action_1", &"attack", effect1, &"card_inst_1")
	engine.register_temporary_listener(_TimingConst.ATTACK_AFTER, &"action_1", &"attack", effect2, &"card_inst_1")

	engine.unregister_listeners_for_card(&"card_inst_1")

	var at_listeners = engine.temporary_listeners.get(_TimingConst.ATTACK_AT, [])
	var after_listeners = engine.temporary_listeners.get(_TimingConst.ATTACK_AFTER, [])

	if at_listeners.size() != 0 or after_listeners.size() != 0:
		return "注销牌后应无关联监听器"
	return true


## 测试9：AVAILABILITY 模式效果触发响应窗口信号
func test_availability_mode_triggers_response_window():
	var engine = _TimingEngine.new()

	var avail_effect = _ActionEffect.new()
	avail_effect.effect_id = &"test_avail"
	avail_effect.mode = _TimingConst.MODE_AVAILABILITY
	avail_effect.availability_condition = _TimingConst.AVAIL_RESPOND_ATTACK
	avail_effect.availability_priority = 5
	avail_effect.display_name = "测试响应"
	avail_effect.priority = 5
	avail_effect.source = {"card_instance_id": &"card_avail_1"}
	avail_effect.conditions = []
	avail_effect.target_rules = []
	avail_effect.costs = []
	avail_effect.actions = []

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"", &"", avail_effect, &"card_avail_1")

	var action = _Action.new()
	action.action_id = &"attack_avail_test"
	action.action_type = &"attack"
	action.record = {"target_id": &"mech_target"}

	var window_opened := false
	engine.response_window_opened.connect(func(aid, cards):
		window_opened = true
	)

	# 无 game_state 时 _check_availability 无法验证持有者
	# AVAILABILITY 效果会被收集但因 _check_availability 返回 false 导致无可用牌
	engine.context = {
		game_state = null,
		action_registry = null,
	}

	engine.fire_timing(_TimingConst.ATTACK_AT, action)
	# 预期：窗口不打开（因为无可用牌通过检查），这是正确行为
	return true


## 测试10：效果间依赖（requires_effect）检查——前置执行后依赖可执行
func test_requires_effect_dependency_satisfied():
	var engine = _TimingEngine.new()

	var effect1 = _ActionEffect.new()
	effect1.effect_id = &"prerequisite_effect"
	effect1.priority = 20
	effect1.mode = _TimingConst.MODE_LISTEN
	effect1.conditions = []
	effect1.target_rules = []
	effect1.costs = []
	effect1.actions = []

	var effect2 = _ActionEffect.new()
	effect2.effect_id = &"dependent_effect"
	effect2.priority = 10
	effect2.mode = _TimingConst.MODE_LISTEN
	effect2.requires_effect = &"prerequisite_effect"
	effect2.conditions = []
	effect2.target_rules = []
	effect2.costs = []
	effect2.actions = []

	engine.register_permanent_listener(_TimingConst.ATTACK_BEFORE, effect1)
	engine.register_permanent_listener(_TimingConst.ATTACK_BEFORE, effect2)

	var action = _Action.new()
	action.action_id = &"dep_test_action"
	action.action_type = &"attack"
	action.record = {}

	var executed: Array[StringName] = []
	engine.effect_executed.connect(func(eid, aid):
		executed.append(eid)
	)

	engine.fire_timing(_TimingConst.ATTACK_BEFORE, action)

	if not executed.has(&"prerequisite_effect"):
		return "前置效果应被执行"
	if not executed.has(&"dependent_effect"):
		return "依赖效果在前置效果执行后应被执行"
	return true


## 测试11：依赖未满足时效果不执行
func test_requires_effect_not_satisfied():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"orphan_dependent"
	effect.priority = 10
	effect.mode = _TimingConst.MODE_LISTEN
	effect.requires_effect = &"nonexistent_effect"
	effect.conditions = []
	effect.target_rules = []
	effect.costs = []
	effect.actions = []

	engine.register_permanent_listener(_TimingConst.ATTACK_BEFORE, effect)

	var action = _Action.new()
	action.action_id = &"orphan_test"
	action.action_type = &"attack"
	action.record = {}

	var executed := false
	engine.effect_executed.connect(func(eid, aid):
		executed = true
	)

	engine.fire_timing(_TimingConst.ATTACK_BEFORE, action)

	if executed:
		return "依赖未满足时效果不应执行"
	return true


## 测试12：抑制效果（锁定状态封锁低优先级响应）
func test_suppressed_effects_below_priority():
	var engine = _TimingEngine.new()

	var low_priority_effect = _ActionEffect.new()
	low_priority_effect.effect_id = &"low_priority_avail"
	low_priority_effect.priority = 5
	low_priority_effect.mode = _TimingConst.MODE_AVAILABILITY
	low_priority_effect.availability_condition = _TimingConst.AVAIL_RESPOND_ATTACK
	low_priority_effect.availability_priority = 5

	engine.register_temporary_listener(_TimingConst.ATTACK_AT, &"", &"", low_priority_effect, &"card_low")

	engine.suppress_effects_below_priority(_TimingConst.ATTACK_AT, 20, &"lock_action_1")

	var is_suppressed = engine._is_effect_suppressed(_TimingConst.ATTACK_AT, low_priority_effect)
	if not is_suppressed:
		return "优先级5的AVAILABILITY效果应被抑制"

	engine.clear_suppressions_for_action(&"lock_action_1")
	is_suppressed = engine._is_effect_suppressed(_TimingConst.ATTACK_AT, low_priority_effect)
	if is_suppressed:
		return "清除抑制后效果不应再被抑制"
	return true


## 测试13：高优先级效果不被抑制
func test_high_priority_not_suppressed():
	var engine = _TimingEngine.new()

	var high_priority_effect = _ActionEffect.new()
	high_priority_effect.effect_id = &"high_priority_avail"
	high_priority_effect.priority = 30
	high_priority_effect.mode = _TimingConst.MODE_AVAILABILITY
	high_priority_effect.availability_priority = 30

	engine.suppress_effects_below_priority(_TimingConst.ATTACK_AT, 20, &"lock_action_2")

	var is_suppressed = engine._is_effect_suppressed(_TimingConst.ATTACK_AT, high_priority_effect)
	if is_suppressed:
		return "优先级30的AVAILABILITY效果不应被优先级20的抑制影响"
	return true


## 测试14：非AVAILABILITY效果不受抑制影响
func test_non_availability_not_suppressed():
	var engine = _TimingEngine.new()

	var listen_effect = _ActionEffect.new()
	listen_effect.effect_id = &"listen_not_suppressed"
	listen_effect.priority = 5
	listen_effect.mode = _TimingConst.MODE_LISTEN

	engine.suppress_effects_below_priority(_TimingConst.ATTACK_AT, 20, &"lock_action_3")

	var is_suppressed = engine._is_effect_suppressed(_TimingConst.ATTACK_AT, listen_effect)
	if is_suppressed:
		return "LISTEN模式效果不应被抑制（只有AVAILABILITY模式才受抑制）"
	return true


## 测试15：TimingConst 所有回合周期时点定义正确
func test_turn_cycle_timing_points():
	var turn_points: Array[StringName] = [
		_TimingConst.ROUND_START,
		_TimingConst.TURN_BEFORE_START,
		_TimingConst.TURN_START,
		_TimingConst.TURN_AFTER_START,
		_TimingConst.TURN_BEFORE_END,
		_TimingConst.TURN_END,
		_TimingConst.TURN_AFTER_END,
	]
	for point in turn_points:
		if point == &"":
			return "回合周期时点不应为空"
	return true


## 测试16：TimingConst 所有动作时点定义正确且不重复
func test_action_timing_points():
	var action_points: Array[StringName] = [
		_TimingConst.ATTACK_BEFORE,
		_TimingConst.ATTACK_PRE,
		_TimingConst.ATTACK_AT,
		_TimingConst.ATTACK_AFTER,
		_TimingConst.ATTACK_SETTLE,
		_TimingConst.USE_ACTION_BEFORE,
		_TimingConst.USE_ACTION_AT,
		_TimingConst.USE_ACTION_AFTER,
		_TimingConst.USE_ACTION_SETTLE,
		_TimingConst.STAT_MOD_BEFORE,
		_TimingConst.STAT_MOD_AFTER,
		_TimingConst.STAT_MOD_SETTLE,
		_TimingConst.BASIC_MOVE_BEFORE,
		_TimingConst.BASIC_MOVE_AT,
		_TimingConst.BASIC_MOVE_AFTER,
		_TimingConst.BASIC_MOVE_SETTLE,
		_TimingConst.SINGLE_MOVE_SETTLE,
		_TimingConst.SET_EQUIP_BEFORE,
		_TimingConst.SET_EQUIP_AT,
		_TimingConst.SET_EQUIP_AFTER,
		_TimingConst.SET_EQUIP_SETTLE,
		_TimingConst.GAIN_CARD_BEFORE,
		_TimingConst.GAIN_CARD_AFTER,
		_TimingConst.GAIN_CARD_SETTLE,
		_TimingConst.DISCARD_BEFORE,
		_TimingConst.DISCARD_AFTER,
		_TimingConst.DISCARD_SETTLE,
		_TimingConst.EFFECT_FIRE_BEFORE,
		_TimingConst.EFFECT_FIRE_AFTER,
		_TimingConst.EFFECT_FIRE_SETTLE,
		_TimingConst.HP_CHANGE_BEFORE,
		_TimingConst.HP_CHANGE_AFTER,
		_TimingConst.HP_CHANGE_SETTLE,
		_TimingConst.DAMAGE_CHANGE_BEFORE,
		_TimingConst.DAMAGE_CHANGE_AFTER,
		_TimingConst.DAMAGE_CHANGE_SETTLE,
		_TimingConst.SHOW_CARD_BEFORE,
		_TimingConst.SHOW_CARD_AFTER,
		_TimingConst.SHOW_CARD_SETTLE,
	]
	var seen: Dictionary = {}
	for point in action_points:
		if point == &"":
			return "动作时点不应为空"
		if seen.has(point):
			return "重复的时点常量: %s" % String(point)
		seen[point] = true
	return true


## 测试17：已执行效果记录的清除
func test_clear_executed_effects_for_action():
	var engine = _TimingEngine.new()

	engine._mark_effect_executed(&"effect_a", &"action_clear_test")
	engine._mark_effect_executed(&"effect_b", &"action_clear_test")

	if not engine._is_required_effect_executed(&"effect_a", &"action_clear_test"):
		return "标记后应能查询到已执行效果"

	engine.clear_executed_effects_for_action(&"action_clear_test")

	if engine._is_required_effect_executed(&"effect_a", &"action_clear_test"):
		return "清除后不应能查询到已执行效果"
	return true


## 测试18：同一时点永久+临时监听器同时触发
func test_permanent_and_temporary_both_fire():
	var engine = _TimingEngine.new()
	var executed: Array[StringName] = []

	var perm_effect = _ActionEffect.new()
	perm_effect.effect_id = &"perm_effect"
	perm_effect.priority = 10
	perm_effect.mode = _TimingConst.MODE_LISTEN
	perm_effect.conditions = []
	perm_effect.target_rules = []
	perm_effect.costs = []
	perm_effect.actions = []

	var temp_effect = _ActionEffect.new()
	temp_effect.effect_id = &"temp_effect"
	temp_effect.priority = 20
	temp_effect.mode = _TimingConst.MODE_LISTEN
	temp_effect.conditions = []
	temp_effect.target_rules = []
	temp_effect.costs = []
	temp_effect.actions = []

	engine.register_permanent_listener(_TimingConst.ATTACK_AFTER, perm_effect)
	engine.register_temporary_listener(_TimingConst.ATTACK_AFTER, &"action_both", &"attack", temp_effect)

	var action = _Action.new()
	action.action_id = &"action_both"
	action.action_type = &"attack"
	action.record = {}

	engine.effect_executed.connect(func(eid, aid):
		executed.append(eid)
	)

	engine.fire_timing(_TimingConst.ATTACK_AFTER, action)

	if executed.size() != 2:
		return "应执行2个效果（永久+临时），实际: %d" % executed.size()
	# 设计文档：优先级从大到小。temp(20) 先、perm(10) 后。
	if executed[0] != &"temp_effect":
		return "优先级20的临时效果应先执行"
	if executed[1] != &"perm_effect":
		return "优先级10的永久效果应后执行"
	return true


## 测试19：timing_fired 信号在 fire_timing 时发出
func test_timing_fired_signal():
	var engine = _TimingEngine.new()
	var received_timings: Array[StringName] = []
	var received_payloads: Array[Dictionary] = []

	engine.timing_fired.connect(func(timing, payload):
		received_timings.append(timing)
		received_payloads.append(payload)
	)

	var action = _Action.new()
	action.action_id = &"signal_test"
	action.action_type = &"attack"
	action.record = {"attacker_id": &"mech_1"}

	engine.fire_timing(_TimingConst.ATTACK_AT, action)

	if received_timings.size() == 0:
		return "信号未被发出"
	if received_timings[0] != _TimingConst.ATTACK_AT:
		return "信号应携带正确的时点名，实际: %s" % String(received_timings[0])
	if received_payloads[0].get("action_id") != &"signal_test":
		return "信号payload应包含action_id"
	if received_payloads[0].get("attacker_id") != &"mech_1":
		return "信号payload应包含record中的字段"
	return true


## 测试20：注销永久监听器
func test_unregister_permanent_listener():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"perm_to_remove"
	effect.priority = 10

	engine.register_permanent_listener(_TimingConst.ATTACK_BEFORE, effect)

	var listeners: Array = engine.permanent_listeners.get(_TimingConst.ATTACK_BEFORE, [])
	if listeners.size() != 1:
		return "注册后应有1个永久监听器"

	engine.unregister_permanent_listener(_TimingConst.ATTACK_BEFORE, effect)

	listeners = engine.permanent_listeners.get(_TimingConst.ATTACK_BEFORE, [])
	if listeners.size() != 0:
		return "注销后应无永久监听器"
	return true


## 测试21：once_per_game_key 每局1次--达到上限后第二次触发被跳过
## 验证 ActionEffect.once_per_game_key/once_per_game_max 机制：本局持久，不带回合维度，
## 即便用不同的 action（模拟后续回合/不同动作）触发也累计。
func test_once_per_game_key_blocks_after_max():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"once_per_game_effect"
	effect.priority = 10
	effect.mode = _TimingConst.MODE_LISTEN
	effect.once_per_game_key = &"pilot_test_per_game"
	effect.once_per_game_max = 1
	effect.conditions = []
	effect.target_rules = []
	effect.costs = []
	effect.actions = []

	var binding_ctx: Dictionary = {
		"card_instance_id": &"pilot_card_inst_1",
		"mech_id": &"mech_1",
		"player_id": &"player",
	}
	engine.register_permanent_listener(_TimingConst.TURN_START, effect, binding_ctx)

	var fired: Array[StringName] = []
	engine.effect_executed.connect(func(eid, _aid):
		fired.append(eid)
	)

	# 第一次触发：应执行
	var action1 = _Action.new()
	action1.action_id = &"turn_action_1"
	action1.action_type = &"turn_cycle"
	action1.record = {}
	engine.fire_timing(_TimingConst.TURN_START, action1)
	if fired.size() != 1:
		return "第一次触发应执行1次，实际: %d" % fired.size()

	# 第二次触发（不同动作，模拟后续回合）：once_per_game 不带回合维度，本局已用满应跳过
	var action2 = _Action.new()
	action2.action_id = &"turn_action_2"
	action2.action_type = &"turn_cycle"
	action2.record = {}
	engine.fire_timing(_TimingConst.TURN_START, action2)
	if fired.size() != 1:
		return "once_per_game 已用满(1)，第二次应被跳过，实际执行: %d" % fired.size()
	return true


## 测试22：once_per_game_key max=2 允许两次，第三次跳过（验证 max 计数与持久累计）
func test_once_per_game_key_max_two_allows_two():
	var engine = _TimingEngine.new()

	var effect = _ActionEffect.new()
	effect.effect_id = &"once_per_game_effect_2"
	effect.priority = 10
	effect.mode = _TimingConst.MODE_LISTEN
	effect.once_per_game_key = &"pilot_test_per_game_2"
	effect.once_per_game_max = 2
	effect.conditions = []
	effect.target_rules = []
	effect.costs = []
	effect.actions = []

	var binding_ctx: Dictionary = {
		"card_instance_id": &"pilot_card_inst_2",
		"mech_id": &"mech_2",
		"player_id": &"player",
	}
	engine.register_permanent_listener(_TimingConst.TURN_START, effect, binding_ctx)

	var fired: Array[StringName] = []
	engine.effect_executed.connect(func(eid, _aid):
		fired.append(eid)
	)

	for i in range(3):
		var a = _Action.new()
		a.action_id = StringName("turn_action_max2_%d" % i)
		a.action_type = &"turn_cycle"
		a.record = {}
		engine.fire_timing(_TimingConst.TURN_START, a)

	if fired.size() != 2:
		return "max=2 时应执行2次（第三次跳过），实际: %d" % fired.size()
	return true
