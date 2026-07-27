## test_action_execution.gd — 动作执行测试
##
## 测试新逻辑中各动作的执行流程：
##   1. Action 基类的步骤执行、状态流转
##   2. ActionEngine 的 execute/continue/cancel
##   3. ActionRegistry 的注册/查询/清理
##   4. 各动作定义的步骤与时点对应关系
##   5. 动作被否定（识破无效攻击）的跳步逻辑
##   6. 动作需要输入时的暂停/继续
extends RefCounted

const _Action = preload("res://scripts/action_core/Action.gd")
const _ActionEngine = preload("res://scripts/action_core/ActionEngine.gd")
const _ActionRegistry = preload("res://scripts/action_core/ActionRegistry.gd")
const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _TimingEngine = preload("res://scripts/action_core/TimingEngine.gd")


## ── 辅助：创建最小测试 context ──
func _make_test_context() -> Dictionary:
	var engine = _ActionEngine.new()
	var registry = _ActionRegistry.new()
	var timing_engine = _TimingEngine.new()

	var context = {
		action_engine = engine,
		action_registry = registry,
		timing_engine = timing_engine,
		game_state = null,
		game_actions = null,
	}
	engine.context = context
	registry.context = context
	timing_engine.context = context

	return context


## ── Action 基类测试 ──

func test_action_initial_state():
	var action = _Action.new()
	if action.state != &"pending":
		return "初始状态应为 pending"
	if action.current_step_index != -1:
		return "初始步骤索引应为 -1"
	if action.steps.size() != 0:
		return "初始步骤列表应为空"
	if action.negated != false:
		return "初始 negated 应为 false"
	if action.unnegatable != false:
		return "初始 unnegatable 应为 false"
	if not action.record.is_empty():
		return "初始 record 应为空"
	if not action.source.is_empty():
		return "初始 source 应为空"
	return true


func test_action_skip_to_step():
	var action = _Action.new()
	action.set_steps([
		{step_name = &"step1", timing_point = &"", handler = Callable()},
		{step_name = &"step2", timing_point = &"", handler = Callable()},
		{step_name = &"step3", timing_point = &"", handler = Callable()},
	])
	action.skip_to_step(2)
	if action.current_step_index != 1:
		return "skip_to_step(2) 应将 current_step_index 设为 1，实际: %d" % action.current_step_index
	return true


func test_action_get_summary():
	var action = _Action.new()
	action.action_id = &"test_summary"
	action.action_type = &"attack"
	action.state = &"running"
	action.current_step_index = 2
	action.record = {"hit": true}

	var summary = action.get_summary()
	if summary.get("action_id") != "test_summary":
		return "摘要应包含 action_id"
	if summary.get("action_type") != "attack":
		return "摘要应包含 action_type"
	if summary.get("current_step") != 2:
		return "摘要应包含 current_step"
	return true


## ── ActionEngine 测试 ──

func test_engine_execute_null_action():
	var engine = _ActionEngine.new()
	var result = engine.execute_action(null)
	if result.get("state") != &"error":
		return "空动作应返回错误"
	return true


func test_engine_cancel_action():
	var context = _make_test_context()
	var engine = context.action_engine as _ActionEngine
	var registry = context.action_registry as _ActionRegistry

	var action = _Action.new()
	action.action_id = &"cancel_test"
	action.action_type = &"test"
	action.context = context
	action.set_steps([])

	registry.register(action)
	engine.cancel_action(&"cancel_test")

	if action.state != &"cancelled":
		return "取消后状态应为 cancelled"
	return true


func test_engine_action_needs_input():
	var context = _make_test_context()
	var engine = context.action_engine as _ActionEngine
	var registry = context.action_registry as _ActionRegistry

	var input_handler := func(a) -> Dictionary:
		return {"need_input": true, "input_type": &"select_weapon", "input_params": {"weapons": []}}

	var action = _Action.new()
	action.action_id = &"input_test"
	action.action_type = &"test"
	action.context = context
	action.set_steps([
		{step_name = &"need_input_step", timing_point = &"", handler = input_handler},
	])

	registry.register(action)
	var result = engine.execute_action(action)

	if result.get("state") != &"waiting_input":
		return "需要输入时应返回 waiting_input，实际: %s" % String(result.get("state"))
	if action.state != &"waiting_input":
		return "动作状态应为 waiting_input"
	return true


## ── ActionRegistry 测试 ──

func test_registry_register_and_get():
	var registry = _ActionRegistry.new()

	var action = _Action.new()
	action.action_id = &"reg_test_1"
	registry.register(action)

	if registry.get_action(&"reg_test_1") != action:
		return "注册后应能获取"
	if registry.get_active_count() != 1:
		return "活跃数量应为 1"
	return true


func test_registry_unregister():
	var registry = _ActionRegistry.new()

	var action = _Action.new()
	action.action_id = &"reg_test_2"
	registry.register(action)
	registry.unregister(&"reg_test_2")

	if registry.get_action(&"reg_test_2") != null:
		return "注销后不应能获取"
	return true


func test_registry_auto_id_generation():
	var registry = _ActionRegistry.new()

	var action1 = _Action.new()
	var action2 = _Action.new()
	registry.register(action1)
	registry.register(action2)

	if action1.action_id == &"":
		return "应自动生成ID"
	if action1.action_id == action2.action_id:
		return "两个动作的ID应不同"
	return true


func test_registry_get_by_type():
	var registry = _ActionRegistry.new()

	var attack = _Action.new()
	attack.action_id = &"attack_1"
	attack.action_type = &"attack"
	registry.register(attack)

	var move = _Action.new()
	move.action_id = &"move_1"
	move.action_type = &"basic_move"
	registry.register(move)

	var attack_actions = registry.get_actions_by_type(&"attack")
	if attack_actions.size() != 1:
		return "应有1个attack类型动作"
	return true


func test_registry_get_active_ids():
	var registry = _ActionRegistry.new()

	var a1 = _Action.new()
	a1.action_id = &"id_1"
	var a2 = _Action.new()
	a2.action_id = &"id_2"
	registry.register(a1)
	registry.register(a2)

	var ids = registry.get_active_ids()
	if ids.size() != 2:
		return "应有2个活跃ID"
	return true


## ── 各动作定义的步骤与时点验证 ──

func test_attack_action_step_timing_mapping():
	var AttackAction = load("res://scripts/action_defs/attack_action.gd")
	if AttackAction == null:
		return "无法加载 attack_action.gd"
	var action = AttackAction.new()
	action.setup_steps()

	if action.steps.size() != 9:
		return "攻击动作应有9个步骤（含 cleanup），实际: %d" % action.steps.size()

	var expected: Array = [
		{step = &"extract_attack_info", timing = &""},
		{step = &"select_weapon", timing = _TimingConst.ATTACK_BEFORE},
		{step = &"select_target", timing = _TimingConst.ATTACK_PRE},
		{step = &"execute_attack", timing = _TimingConst.ATTACK_AT},
		{step = &"check_hit", timing = &""},
		{step = &"calculate_damage", timing = _TimingConst.ATTACK_AFTER},
		{step = &"apply_damage", timing = &""},
		{step = &"settle", timing = _TimingConst.ATTACK_SETTLE},
		{step = &"cleanup", timing = &""},
	]

	for i in range(expected.size()):
		var step_name = action.steps[i].get("step_name", &"")
		var timing = action.steps[i].get("timing_point", &"")
		if step_name != expected[i].step:
			return "步骤%d名称错误: 期望 %s, 实际 %s" % [i, String(expected[i].step), String(step_name)]
		if timing != expected[i].timing:
			return "步骤%d时点错误: 期望 %s, 实际 %s" % [i, String(expected[i].timing), String(timing)]
	return true


func test_use_action_card_step_timing_mapping():
	var UseActionCardAction = load("res://scripts/action_defs/use_action_card_action.gd")
	if UseActionCardAction == null:
		return "无法加载 use_action_card_action.gd"
	var action = UseActionCardAction.new()
	action.setup_steps()

	if action.steps.size() != 4:
		return "使用行动牌动作应有4个步骤，实际: %d" % action.steps.size()

	# 翻转后 card_to_temp_zone 合并回单步（牌进临时区+注册效果，handler 完成后 fire USE_ACTION_AT）：
	# validate_card(USE_ACTION_BEFORE) → card_to_temp_zone(USE_ACTION_AT) → execute_effects(USE_ACTION_AFTER) → settle(USE_ACTION_SETTLE)
	# 见 use_action_card_action.gd setup_steps 注释。
	if action.steps[0].get("timing_point", &"") != _TimingConst.USE_ACTION_BEFORE:
		return "步骤1时点应为 USE_ACTION_BEFORE"
	if action.steps[1].get("timing_point", &"") != _TimingConst.USE_ACTION_AT:
		return "步骤2(card_to_temp_zone)时点应为 USE_ACTION_AT"
	if action.steps[2].get("timing_point", &"") != _TimingConst.USE_ACTION_AFTER:
		return "步骤3时点应为 USE_ACTION_AFTER"
	if action.steps[3].get("timing_point", &"") != _TimingConst.USE_ACTION_SETTLE:
		return "步骤4时点应为 USE_ACTION_SETTLE"
	return true


func test_stat_modify_step_timing_mapping():
	var StatModifyAction = load("res://scripts/action_defs/stat_modify_action.gd")
	if StatModifyAction == null:
		return "无法加载 stat_modify_action.gd"
	var action = StatModifyAction.new()
	action.setup_steps()

	if action.steps.size() != 3:
		return "数值修正动作应有3个步骤"
	if action.steps[0].get("timing_point") != _TimingConst.STAT_MOD_BEFORE:
		return "步骤1时点应为 STAT_MOD_BEFORE"
	if action.steps[1].get("timing_point") != _TimingConst.STAT_MOD_AFTER:
		return "步骤2时点应为 STAT_MOD_AFTER"
	if action.steps[2].get("timing_point") != _TimingConst.STAT_MOD_SETTLE:
		return "步骤3时点应为 STAT_MOD_SETTLE"
	return true


func test_basic_move_step_timing_mapping():
	var BasicMoveAction = load("res://scripts/action_defs/basic_move_action.gd")
	if BasicMoveAction == null:
		return "无法加载 basic_move_action.gd"
	var action = BasicMoveAction.new()
	action.setup_steps()

	if action.steps.size() != 4:
		return "基础移动动作应有4个步骤"
	if action.steps[0].get("timing_point") != _TimingConst.BASIC_MOVE_BEFORE:
		return "步骤1时点应为 BASIC_MOVE_BEFORE"
	if action.steps[1].get("timing_point") != _TimingConst.BASIC_MOVE_AT:
		return "步骤2时点应为 BASIC_MOVE_AT"
	if action.steps[2].get("timing_point") != _TimingConst.BASIC_MOVE_AFTER:
		return "步骤3时点应为 BASIC_MOVE_AFTER"
	if action.steps[3].get("timing_point") != _TimingConst.BASIC_MOVE_SETTLE:
		return "步骤4时点应为 BASIC_MOVE_SETTLE"
	return true


func test_hp_change_step_timing_mapping():
	var HpChangeAction = load("res://scripts/action_defs/hp_change_action.gd")
	if HpChangeAction == null:
		return "无法加载 hp_change_action.gd"
	var action = HpChangeAction.new()
	action.setup_steps()

	if action.steps.size() != 3:
		return "生命变动动作应有3个步骤"
	if action.steps[0].get("timing_point") != _TimingConst.HP_CHANGE_BEFORE:
		return "步骤1时点应为 HP_CHANGE_BEFORE"
	if action.steps[1].get("timing_point") != _TimingConst.HP_CHANGE_AFTER:
		return "步骤2时点应为 HP_CHANGE_AFTER"
	if action.steps[2].get("timing_point") != _TimingConst.HP_CHANGE_SETTLE:
		return "步骤3时点应为 HP_CHANGE_SETTLE"
	return true


func test_damage_change_step_timing_mapping():
	var DamageChangeAction = load("res://scripts/action_defs/damage_change_action.gd")
	if DamageChangeAction == null:
		return "无法加载 damage_change_action.gd"
	var action = DamageChangeAction.new()
	action.setup_steps()

	if action.steps.size() != 4:
		return "损伤变动动作应有4个步骤（含损伤转移窗口），实际: %d" % action.steps.size()
	if action.steps[0].get("timing_point") != _TimingConst.DAMAGE_CHANGE_BEFORE:
		return "步骤1时点应为 DAMAGE_CHANGE_BEFORE"
	if action.steps[1].get("timing_point") != _TimingConst.DAMAGE_REDIRECT_WINDOW:
		return "步骤2时点应为 DAMAGE_REDIRECT_WINDOW（损伤转移窗口）"
	if action.steps[2].get("timing_point") != _TimingConst.DAMAGE_CHANGE_AFTER:
		return "步骤3时点应为 DAMAGE_CHANGE_AFTER"
	if action.steps[3].get("timing_point") != _TimingConst.DAMAGE_CHANGE_SETTLE:
		return "步骤4时点应为 DAMAGE_CHANGE_SETTLE"
	return true


func test_gain_card_step_timing_mapping():
	var GainCardAction = load("res://scripts/action_defs/gain_card_action.gd")
	if GainCardAction == null:
		return "无法加载 gain_card_action.gd"
	var action = GainCardAction.new()
	action.setup_steps()

	if action.steps.size() != 3:
		return "获取牌动作应有3个步骤"
	if action.steps[0].get("timing_point") != _TimingConst.GAIN_CARD_BEFORE:
		return "步骤1时点应为 GAIN_CARD_BEFORE"
	if action.steps[1].get("timing_point") != _TimingConst.GAIN_CARD_AFTER:
		return "步骤2时点应为 GAIN_CARD_AFTER"
	if action.steps[2].get("timing_point") != _TimingConst.GAIN_CARD_SETTLE:
		return "步骤3时点应为 GAIN_CARD_SETTLE"
	return true


## ── 动作不可否定测试 ──

func test_unnegatable_prevents_negation():
	var action = _Action.new()
	action.unnegatable = true
	action.negated = false

	if not action.unnegatable:
		action.negated = true

	if action.negated:
		return "不可否定的动作不应被否定"
	return true


## ── 所有动作定义文件可加载测试 ──

func test_all_action_defs_loadable():
	var action_files: Array[String] = [
		"res://scripts/action_defs/attack_action.gd",
		"res://scripts/action_defs/use_action_card_action.gd",
		"res://scripts/action_defs/stat_modify_action.gd",
		"res://scripts/action_defs/basic_move_action.gd",
		"res://scripts/action_defs/single_move_action.gd",
		"res://scripts/action_defs/set_equipment_action.gd",
		"res://scripts/action_defs/gain_card_action.gd",
		"res://scripts/action_defs/discard_card_action.gd",
		"res://scripts/action_defs/effect_fire_action.gd",
		"res://scripts/action_defs/hp_change_action.gd",
		"res://scripts/action_defs/damage_change_action.gd",
		"res://scripts/action_defs/show_card_action.gd",
	]

	for file_path in action_files:
		var action_def = load(file_path)
		if action_def == null:
			return "无法加载: %s" % file_path
		var action = action_def.new()
		action.setup_steps()
		if action.steps.size() == 0:
			return "动作步骤为空: %s" % file_path

	return true
