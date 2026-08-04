## trap_explosion_action.gd - 陷阱爆炸动作
##
## 陷阱被触发（机甲进入其格 / 被攻击 / 被连锁引爆）时由 MarkerService 发起。
## 一次爆炸处理整片相连的陷阱（递归扩散：每个引爆陷阱再引爆其 1 格范围内的陷阱），
## 对每个受波及机甲累计伤害/损伤（每个覆盖该机甲的陷阱各贡献 TRAP_BLAST_DAMAGE 伤害 +
## TRAP_BLAST_TOKENS 损伤），逐机甲串行结算（各算各的）。
##
## 损伤经 damage_change 路由（执行者=机甲方，逐个设置类似攻击损伤设置），
## reason="trap_explosion" 使盾牌（DAMAGE_SOURCE_IS_ATTACK_OR_TRAP）可转移陷阱损伤。
extends Action
class_name TrapExplosionAction

const _TimingConst = preload("res://scripts/action_core/TimingConst.gd")
const _ActionEffect = preload("res://scripts/action_core/ActionEffect.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")
const _GameConfig = preload("res://scripts/config/GameConfig.gd")


func _init() -> void:
	action_type = &"trap_explosion"


func setup_steps() -> void:
	# compute_blast：洪水扩散+移除陷阱+逐机甲累计伤害，构建合成效果经 _execute_effect 串行结算。
	# settle：占位（日志在 compute 写入）。
	steps = [
		{step_name = &"compute_blast", timing_point = &"", handler = _step_compute_blast},
		{step_name = &"settle",         timing_point = &"", handler = _step_settle},
	]


func get_display_name() -> String:
	return "陷阱爆炸"


## ① 计算并执行爆炸
func _step_compute_blast(action: Action) -> Dictionary:
	var gs = context.game_state
	var map_state = gs.map_state
	var trigger_q: int = int(action.record.get("trigger_q", 0))
	var trigger_r: int = int(action.record.get("trigger_r", 0))
	var trigger_mech_id: StringName = action.record.get("trigger_mech_id", &"")

	# ── 1. 洪水扩散：从触发格起，收集所有距离 ≤ TRAP_BLAST_RANGE 相连的陷阱（连锁爆） ──
	# 触发陷阱已由调用方（_check_map_markers / place_or_trigger trigger）移除，此处只收集其余陷阱。
	var all_traps: Array = []
	for m in map_state.markers:
		if m.get("type", &"") == &"TRAP":
			all_traps.append(m)
	var exploded: Dictionary = {}  # marker_id -> marker
	var frontier: Array = [{"q": trigger_q, "r": trigger_r}]
	var visited: Dictionary = {}
	while not frontier.is_empty():
		var cell: Dictionary = frontier.pop_front()
		var ck: String = "%s,%s" % [int(cell.get("q", 0)), int(cell.get("r", 0))]
		if visited.has(ck):
			continue
		visited[ck] = true
		var cell_pos: Dictionary = {"q": int(cell.get("q", 0)), "r": int(cell.get("r", 0))}
		for t in all_traps:
			var mid: StringName = t.get("marker_id", &"")
			if exploded.has(mid):
				continue
			var t_pos: Dictionary = {"q": int(t.get("q", 0)), "r": int(t.get("r", 0))}
			if _HexGrid.distance(cell_pos, t_pos) <= _GameConfig.TRAP_BLAST_RANGE:
				exploded[mid] = t
				frontier.append(t_pos)
	# 移除所有被引爆的陷阱
	for mid in exploded:
		map_state.remove_marker(mid)

	# ── 2. 逐机甲累计伤害/损伤 ──
	# blast_cells = 触发陷阱格 + 所有被引爆陷阱格。每个覆盖某机甲（距离 ≤ RANGE）的陷阱各贡献一份。
	var blast_cells: Array = [{"q": trigger_q, "r": trigger_r}]
	for t in exploded.values():
		blast_cells.append({"q": int(t.get("q", 0)), "r": int(t.get("r", 0))})
	var mech_dmg: Dictionary = {}  # mech_id -> {hp, tokens}
	for cell in blast_cells:
		var cell_pos: Dictionary = {"q": int(cell.get("q", 0)), "r": int(cell.get("r", 0))}
		for m_id in gs.mechs:
			var m = gs.mechs[m_id]
			if m == null or m.destroyed:
				continue
			if _HexGrid.distance(cell_pos, m.position) <= _GameConfig.TRAP_BLAST_RANGE:
				if not mech_dmg.has(m_id):
					mech_dmg[m_id] = {"hp": 0, "tokens": 0}
				mech_dmg[m_id]["hp"] += _GameConfig.TRAP_BLAST_DAMAGE
				mech_dmg[m_id]["tokens"] += _GameConfig.TRAP_BLAST_TOKENS

	gs.write_log(&"marker_trap_exploded", {
		"trigger_q": trigger_q, "trigger_r": trigger_r,
		"trigger_mech_id": String(trigger_mech_id),
		"traps_triggered": exploded.size() + 1,
		"mechs_affected": mech_dmg.size(),
	})

	# ── 3. 构建合成效果：扁平化每个机甲的 [damage_change, hp_change]，经 _execute_effect 串行结算 ──
	# 顺序：damage_change 在前 -> 其 DAMAGE_REDIRECT_WINDOW 时点让盾牌(effect_136b/127/133)转移损伤+
	# 写 shield_hp_reduction 到本 trap_explosion record；随后 hp_change 读 shield_hp_reduction 扣减HP。
	# _execute_actions 的 _seq 机制确保多个需输入子动作（盾牌确认窗/损伤面板）串行而非并发。
	var blast_actions: Array = []
	for m_id in mech_dmg:
		var dmg: Dictionary = mech_dmg[m_id]
		if int(dmg["tokens"]) > 0:
			var owner = gs.get_player_for_mech(m_id)
			var owner_pid: StringName = owner.player_id if owner != null else &""
			blast_actions.append({"type": &"EXECUTE_DAMAGE_CHANGE", "params": {
				"mech_ids": [m_id], "value": int(dmg["tokens"]), "method": &"increase",
				"executor": owner_pid, "reason": &"trap_explosion"}})
		if int(dmg["hp"]) > 0:
			blast_actions.append({"type": &"EXECUTE_HP_CHANGE", "params": {
				"mech_ids": [m_id], "value": int(dmg["hp"]), "method": &"decrease", "reason": &"trap_explosion"}})
	if blast_actions.is_empty():
		return {}

	var blast_effect = _ActionEffect.new()
	blast_effect.effect_id = &"trap_explosion_blast"
	blast_effect.mode = _TimingConst.MODE_DIRECT
	blast_effect.priority = 10
	blast_effect.set_conditions([{"op": &"ALWAYS"}])
	blast_effect.set_target_rules([{"rule": &"NO_TARGET"}])
	blast_effect.set_costs([])
	blast_effect.set_actions(blast_actions)

	var payload: Dictionary = action.record.duplicate()
	if not payload.has("binding_context"):
		payload["binding_context"] = {}
	context.timing_engine._execute_effect(blast_effect, payload, action)

	# 若产生了未完成的子动作（damage_change 弹面板），声明等待，ActionEngine 挂起本动作。
	if not action.pending_effect_action_ids.is_empty():
		return {"effect_action_created": true}
	return {}


## ② 结算（占位）
func _step_settle(_action: Action) -> Dictionary:
	return {}
