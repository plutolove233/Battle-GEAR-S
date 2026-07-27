## ActionUIBridge.gd — UI与ActionEngine的桥接层
##
## 负责将 ActionEngine 需要玩家输入的步骤转换为 UI 弹窗/选框，
## 并在玩家确认后调用 ActionService.continue_action() 继续执行。
##
## 连接信号：
##   ActionEngine.action_needs_input → _on_action_needs_input
##   UI组件的确认信号 → _on_ui_confirmed
extends RefCounted
class_name ActionUIBridge

const _TC = preload("res://scripts/action_core/TimingConst.gd")
const _RangeCalculator = preload("res://scripts/battle/RangeCalculator.gd")
const _HexGrid = preload("res://scripts/battle/hex_grid.gd")

## 依赖注入：GameContext 容器
var context = null

## 当前等待输入的动作ID
var _waiting_action_id: StringName = &""
## 当前等待的输入类型
var _current_input_type: StringName = &""
## 当前输入参数
var _current_input_params: Dictionary = {}

## ── 信号 ──
signal request_ui_popup(popup_type: StringName, params: Dictionary)
signal action_input_resolved(action_id: StringName, input_data: Dictionary)


## 初始化：连接 ActionEngine 与 TimingEngine 信号
## 注意：响应窗口（respond_attack）的 input 请求由 TimingEngine 发出
## （TimingEngine._handle_response_window 在 ATTACK_AT 时点 emit action_needs_input），
## 而非 ActionEngine。因此必须同时连接 TimingEngine 的同名信号，否则
## 响应窗口信号无人接收，ResponsePanel 永远不会弹出，攻击动作卡死在 waiting_timing。
func setup() -> void:
	if context != null and context.action_engine != null:
		context.action_engine.action_needs_input.connect(_on_action_needs_input)
		context.action_engine.action_completed.connect(_on_action_completed)
		context.action_engine.action_cancelled.connect(_on_action_cancelled)
	if context != null and context.timing_engine != null:
		context.timing_engine.action_needs_input.connect(_on_action_needs_input)


## ActionEngine 需要玩家输入时的回调
func _on_action_needs_input(action_id: StringName, input_type: StringName, input_params: Dictionary) -> void:
	_waiting_action_id = action_id
	_current_input_type = input_type
	_current_input_params = input_params

	# 根据输入类型分发到不同的 UI 弹窗
	match input_type:
		&"select_weapon":
			# AI 攻击选武器：自动选第一把武器（AI 普通攻击已预填 weapon_id 不走此；
			# 反击 attack B 等未预填武器的 AI 攻击走此分支）
			if _is_ai_source(input_params):
				_auto_select_weapon(action_id, input_params)
				return
			request_ui_popup.emit(&"weapon_select", input_params)
		&"select_attack_target":
			# AI 攻击选目标：自动选射程内第一个敌方
			if _is_ai_source(input_params):
				_auto_select_attack_target(action_id, input_params)
				return
			request_ui_popup.emit(&"attack_target_select", input_params)
		&"select_move_target":
			# 迎击移动（回避/疾行/反击）：若移动方为 AI，自动选格移动躲开攻击方；
			# 否则弹选格 UI 给玩家。
			# AI 自动决策改 call_deferred：避免 re-entrant continue_action 在移动循环中
			# 嵌套过深（高动力时机甲多步移动，每步同步重入 continue_action 致栈溢出）。
			# deferred 后每步移动独立一帧，循环变迭代式，栈不增长。
			if _is_ai_mover(input_params):
				call_deferred("_auto_move_target", action_id, input_params)
				return
			request_ui_popup.emit(&"move_target_select", input_params)
		&"select_equipment_slot":
			request_ui_popup.emit(&"equipment_slot_select", input_params)
		&"select_discard_cards":
			# AI 弃牌（闪击2/装备效果/机师效果强制弃牌等）：自动弃前 N 张行动牌，不弹人类窗
			if _is_ai_source(input_params):
				_auto_discard_cards(action_id, input_params)
				return
			request_ui_popup.emit(&"discard_card_select", input_params)
		&"place_damage_tokens":
			# AI（executor 非 player）不弹 UI，自动放置损伤
			if _is_ai_executor(input_params):
				_auto_place_damage_tokens(input_params)
				return
			request_ui_popup.emit(&"damage_token_placement", input_params)
		&"show_cards":
			request_ui_popup.emit(&"card_show", input_params)
		&"choose_one":
			# AI 二选一：默认选第一项（最小可用策略）
			if _is_ai_source(input_params):
				on_ui_confirmed({"chosen_option_index": 0})
				return
			request_ui_popup.emit(&"choice_select", input_params)
		&"select_mech_target":
			# 锁定/联合目标选择：AI 自动选第一个存活敌方
			if _is_ai_source(input_params):
				_auto_mech_target(action_id, input_params)
				return
			request_ui_popup.emit(&"mech_target_select", input_params)
		&"respond_attack":
			# 响应窗口：若响应方（被攻击目标）为 AI，自动决策；否则弹响应窗口给玩家
			if _is_ai_responder(input_params):
				_auto_respond(action_id, input_params)
				return
			# 响应窗口：列出所有 AVAILABILITY 模式的效果牌
			_show_response_window(action_id, input_params)
		&"confirm_use_card":
			# 使用行动牌前的确认对话框
			request_ui_popup.emit(&"use_card_confirm", input_params)
		&"select_weapon_for_charge":
			# 聚能武器选择：AI 自动选第一把武器
			if _is_ai_source(input_params):
				_auto_select_weapon(action_id, input_params)
				return
			request_ui_popup.emit(&"weapon_charge_select", input_params)
		&"select_repair_target":
			# 维修目标机甲选择：AI 自动选自身（最小可用，避免卡死）
			if _is_ai_source(input_params):
				_auto_repair_target(action_id, input_params)
				return
			request_ui_popup.emit(&"repair_target_select", input_params)
		&"choose_one_effect":
			# 维修二选一：回复4HP vs 移除2损伤。AI 自动决策；玩家弹 effect_choice
			if _is_ai_source(input_params):
				_auto_repair_choose_one(action_id, input_params)
				return
			request_ui_popup.emit(&"effect_choice", input_params)
		&"select_target_mech":
			# 锁定/联合目标选择：AI 自动选第一个存活敌方
			if _is_ai_source(input_params):
				_auto_mech_target(action_id, input_params)
				return
			request_ui_popup.emit(&"mech_target_select", input_params)
		&"redirect_select":
			# 损伤转移汇总窗（A6 装备效果）：玩家选转移若干点到本牌区域。
			# AI 已在 TimingEngine._execute_actions 的 OFFER_DAMAGE_REDIRECT 分支自动决策，此处仅玩家路径。
			request_ui_popup.emit(&"redirect_select", input_params)
		&"select_thrust_cards":
			# 推进 effect2 多选：持有者使用迎击牌时弹窗选若干推进一起打出。
			# AI 已在 TimingEngine._execute_actions 的 CHOOSE_MANY_CARDS 分支跳过，此处仅玩家路径。
			request_ui_popup.emit(&"thrust_select", input_params)
		&"select_unite_attack_card":
			# 联合状态效果1：unite机甲攻击结算后，弹窗让 Target 选1张攻击牌联合攻击。
			# AI Target 已在 TimingEngine._execute_actions 的 UNITE_ATTACK_OFFER 分支跳过。
			# 弹窗路由到 Target 玩家（_popup_owner 按 target_mech_id 反查 owner）。
			request_ui_popup.emit(&"unite_attack_select", input_params)
		&"select_awaken_card_type":
			# 觉醒：弃牌堆无预判/识破时，弹框让玩家选1种行动牌（列种类+数量）。
			# AI 自动选第一项（最小可用，避免挂死）；人类弹 awaken_select 窗。
			if _is_ai_source(input_params):
				var aw_opts: Array = input_params.get("options", [])
				var aw_pick: StringName = &""
				if not aw_opts.is_empty():
					var first: Dictionary = aw_opts[0] if aw_opts[0] is Dictionary else {}
					aw_pick = first.get("def_id", &"")
				on_ui_confirmed({"chosen_card_def_id": aw_pick})
				return
			request_ui_popup.emit(&"awaken_select", input_params)
		_:
			push_warning("ActionUIBridge: 未知输入类型: %s" % String(input_type))
			request_ui_popup.emit(&"generic_input", input_params)


## 判断 place_damage_tokens 的执行者是否为 AI（非人类玩家）
func _is_ai_executor(input_params: Dictionary) -> bool:
	var executor: StringName = input_params.get("executor", &"")
	if executor == &"":
		return false
	# executor 可能是 player_id 或 mech_id：优先按 player_id 查，否则按 mech_id 反查 owner
	if context != null and context.game_state != null:
		if context.game_state.players.has(executor):
			return not _is_human_player_id(executor)
		var m = context.game_state.mechs.get(executor)
		if m != null:
			return not _is_human_player_id(m.owner_player_id)
	return false


## 判断某 player_id 是否由人类控制。
## 未知（无 context / 玩家不存在）默认 true（人类），保守走 UI 弹窗而非自动决策，
## 与历史 `!= &"player"` 在 not-found 时返回 false（即非 AI）的行为一致。
func _is_human_player_id(player_id: StringName) -> bool:
	if player_id == &"" or context == null or context.game_state == null:
		return true
	var player = context.game_state.players.get(player_id)
	if player == null:
		return true
	return player.is_human


## 判断效果发起方是否为 AI（非人类）。来源机甲经 input_params.mech_id / source_mech_id 定位。
func _is_ai_source(input_params: Dictionary) -> bool:
	var mech_id: StringName = _resolve_owner_mech_id(input_params)
	return _is_ai_mech_id(mech_id)


## 从 input_params 多种字段统一提取"发起方机甲 id"
## 不同 input_type 携带字段不同：attacker_id(攻击选武器/目标) / executor(弃牌) /
## mech_id·source_mech_id(维修/锁定/联合/二选一) / target_id(响应窗口,此处不用)。
func _resolve_owner_mech_id(input_params: Dictionary) -> StringName:
	var mech_id: StringName = input_params.get("attacker_id", &"")
	if mech_id == &"":
		mech_id = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if mech_id == &"":
		mech_id = input_params.get("executor", &"")
	# executor/player_id 可能是 player_id 而非 mech_id：反查其机甲
	if mech_id == &"" or context == null or context.game_state == null:
		var pid: StringName = input_params.get("player_id", &"")
		if pid != &"" and context != null and context.game_state != null:
			var m = context.game_state.get_mech_for_player(pid)
			if m != null:
				return m.mech_id
		return &""
	# 若取到的 mech_id 实为 player_id（mechs 字典查不到），反查
	if context != null and context.game_state != null and not context.game_state.mechs.has(mech_id):
		var m2 = context.game_state.get_mech_for_player(mech_id)
		if m2 != null:
			return m2.mech_id
	return mech_id


## 判断机甲 id 是否属于 AI（非人类）
func _is_ai_mech_id(mech_id: StringName) -> bool:
	var owner = _get_player_for_mech_id(mech_id)
	return owner != null and not owner.is_human


## 通过 GameState 的机甲→玩家关系判断控制方，避免只读 mech.owner_player_id 导致
## 临时/旧状态下把人类机甲误判为 AI（或反之）。
func _get_player_for_mech_id(mech_id: StringName):
	if mech_id == &"" or context == null or context.game_state == null:
		return null
	var player = context.game_state.get_player_for_mech(mech_id)
	if player != null:
		return player
	var mech = context.game_state.mechs.get(mech_id)
	if mech != null:
		player = context.game_state.players.get(mech.owner_player_id)
	return player


## AI 自动选维修目标：默认选自身机甲（若自身有损伤或未满血优先自身）。
func _auto_repair_target(action_id: StringName, input_params: Dictionary) -> void:
	var mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if mech_id == &"":
		on_ui_cancelled()
		return
	on_ui_confirmed({"target_id": mech_id, "target_mech_id": mech_id})


## AI 自动选维修二选一：自身未满血→回复4生命(选项0)；否则若有损伤→移除2损伤(选项1)；默认0。
func _auto_repair_choose_one(_action_id: StringName, input_params: Dictionary) -> void:
	var mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	var idx: int = 0
	if mech_id != &"" and context != null and context.game_state != null:
		var mech = context.game_state.mechs.get(mech_id)
		if mech != null:
			var full: bool = mech.current_hp >= mech.max_hp
			var has_damage: bool = false
			for slot_id in mech.slots:
				var slot = mech.slots[slot_id]
				if slot != null and slot.damage_tokens > 0:
					has_damage = true
					break
			if full and has_damage:
				idx = 1  # 满血但有损伤 → 移除损伤
			else:
				idx = 0  # 否则回复生命
	on_ui_confirmed({"chosen_option_index": idx})


## AI 自动选攻击武器：选机甲第一把武器（AI 普通攻击已预填武器不走此；
## 反击 attack B 等未预填武器的 AI 攻击走此分支）。
func _auto_select_weapon(_action_id: StringName, input_params: Dictionary) -> void:
	var attacker_id: StringName = input_params.get("attacker_id", input_params.get("mech_id", &""))
	if attacker_id == &"" or context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var attacker = context.game_state.mechs.get(attacker_id)
	if attacker == null:
		on_ui_cancelled()
		return
	var weapon_ids: Array[StringName] = attacker.get_weapon_ids()
	if weapon_ids.is_empty():
		on_ui_cancelled()
		return
	on_ui_confirmed({"weapon_id": weapon_ids[0]})


## AI 自动选攻击目标：在所选武器射程内选第一个存活敌方；无可选则取消
func _auto_select_attack_target(_action_id: StringName, input_params: Dictionary) -> void:
	var attacker_id: StringName = input_params.get("attacker_id", &"")
	if attacker_id == &"" or context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var attacker = context.game_state.mechs.get(attacker_id)
	if attacker == null:
		on_ui_cancelled()
		return
	var weapon_range: int = int(input_params.get("weapon_range", 1))
	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}
	# 射程内第一个存活敌方（非自身、非同阵营）
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if mid == attacker_id:
			continue
		if m.owner_player_id == attacker.owner_player_id:
			continue
		if _RangeCalculator.is_in_weapon_range(attacker.position, m.position, weapon_range, map_cells):
			on_ui_confirmed({"target_id": mid})
			return
	# 射程内无敌方：取消（避免 AI 攻击卡死）
	on_ui_cancelled()


## AI 自动弃牌：弃前 N 张行动牌（明牌顺序，AI 不挑）。optional 弃牌（闪击2）也走此。
func _auto_discard_cards(_action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var mech_id: StringName = _resolve_owner_mech_id(input_params)
	var player_id: StringName = input_params.get("player_id", &"")
	if player_id == &"" and mech_id != &"" and context.game_state != null:
		var mch = context.game_state.mechs.get(mech_id)
		if mch != null:
			player_id = mch.owner_player_id
	if player_id == &"":
		on_ui_cancelled()
		return
	var player = context.game_state.players.get(player_id)
	if player == null:
		on_ui_cancelled()
		return
	var count: int = int(input_params.get("count", 1))
	var picked: Array = []
	for cid: StringName in player.action_hand:
		picked.append(cid)
		if picked.size() >= count:
			break
	if picked.is_empty():
		# 无牌可弃：optional 弃牌取消；强制弃牌也无牌可弃只能取消
		on_ui_confirmed({"selected_action_card_ids": [], "determined_card_ids": [], "cancelled": true})
		return
	# 回填两个键：
	#   - selected_action_card_ids：optional 弃牌（闪击2）走 resume_pending_effect 读此
	#   - determined_card_ids：discard_card 动作走 continue_action 重跑 _step_determine_cards 读此
	# on_ui_confirmed 内按 has_pending_effect 自动分发到对应路径，另一键被忽略。
	on_ui_confirmed({
		"selected_action_card_ids": picked,
		"determined_card_ids": picked,
	})


## AI 自动选目标机甲（锁定/联合等）：选第一个存活的敌方机甲
func _auto_mech_target(_action_id: StringName, input_params: Dictionary) -> void:
	var src_mech_id: StringName = input_params.get("mech_id", input_params.get("source_mech_id", &""))
	if context == null or context.game_state == null:
		on_ui_cancelled()
		return
	var picked: StringName = &""
	for mid: StringName in context.game_state.mechs:
		var m = context.game_state.mechs[mid]
		if m == null or m.destroyed:
			continue
		if mid == src_mech_id:
			continue
		picked = mid
		break
	if picked == &"":
		on_ui_cancelled()
		return
	on_ui_confirmed({"target_id": picked, "target_mech_id": picked})


## 判断响应窗口的响应方（被攻击目标）是否为 AI
func _is_ai_responder(input_params: Dictionary) -> bool:
	var target_id: StringName = input_params.get("target_id", &"")
	if target_id == &"" or context == null or context.game_state == null:
		return false
	return _is_ai_mech_id(target_id)


## 判断迎击移动的移动方机甲是否为 AI（非人类）
## 回避/疾行/反击效果发起的 single_move 的 input_params.mech_id 即移动方机甲。
func _is_ai_mover(input_params: Dictionary) -> bool:
	var mech_id: StringName = input_params.get("mech_id", &"")
	return _is_ai_mech_id(mech_id)


## AI 自动移动：分两类——
## (a) 迎击移动（移动方=防御方/被攻击目标，回避/疾行/反击发起）：优先逃出攻击方射程；
## (b) 强袭追击移动（移动方=攻击者，强袭 effect2 在目标响应后发起）：保持在目标射程内以保证
##     本攻击命中，同时尽量远离目标的武器范围以躲反击（若有空间）。无法兼顾则优先保命中。
## 循环移动期间每次选格都会再次回调本方法，直到动力耗尽或无路可走，自动结束循环。
func _auto_move_target(action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.game_state == null:
		_resolve_action_cancel(action_id)
		return
	var mech_id: StringName = input_params.get("mech_id", &"")
	var mech = context.game_state.mechs.get(mech_id)
	if mech == null:
		_resolve_action_cancel(action_id)
		return
	var available_power: int = int(input_params.get("available_power", 0))
	var pos: Dictionary = mech.position

	# 取 attack 动作的 attacker_id / target_id / weapon_range（沿父链查）
	var attacker_pos: Dictionary = {}
	var target_pos: Dictionary = {}
	var target_id: StringName = &""
	var weapon_range: int = 1
	var mover_is_attacker: bool = false
	if context.action_registry != null:
		var cur_id: StringName = action_id
		for _i in 4:
			var cur = context.action_registry.get_action(cur_id)
			if cur == null:
				break
			if cur.action_type == &"attack":
				var atk_id: StringName = cur.record.get("attacker_id", &"")
				var atk_mech = context.game_state.mechs.get(atk_id)
				if atk_mech != null:
					attacker_pos = atk_mech.position
				target_id = cur.record.get("target_id", &"")
				var tgt_mech = context.game_state.mechs.get(target_id)
				if tgt_mech != null:
					target_pos = tgt_mech.position
				weapon_range = int(cur.record.get("weapon_range", 1))
				mover_is_attacker = (atk_id == mech_id)
				break
			cur_id = cur.parent_action_id
			if cur_id == &"":
				break

	# 目标反击最大射程（强袭躲反击用）：取目标所有武器 range 最大值
	var target_counter_range: int = 0
	if target_id != &"":
		var tgt_mech2 = context.game_state.mechs.get(target_id)
		if tgt_mech2 != null:
			for wid: StringName in tgt_mech2.get_weapon_ids():
				var wcard = context.game_state.get_card(wid)
				if wcard != null and wcard.def != null:
					target_counter_range = max(target_counter_range, wcard.def.range_value)

	var map_cells: Dictionary = context.game_state.map_state.cells if context.game_state.map_state else {}

	# 相邻可达格（剩余动力足够）
	var neighbors: Array[Dictionary] = _RangeCalculator.get_move_reachable_hexes(pos, max(1, available_power), map_cells)
	if neighbors.is_empty():
		_resolve_action_cancel(action_id)
		return

	# 迎击移动：若当前格已逃出攻击范围，停止移动（逃脱达成，避免 0 动力原地循环致栈溢出）
	if not mover_is_attacker and not attacker_pos.is_empty():
		if not _RangeCalculator.is_in_weapon_range(attacker_pos, pos, weapon_range, map_cells):
			_resolve_action_cancel(action_id)
			return

	var best: Dictionary = {}
	if mover_is_attacker and not target_pos.is_empty():
		best = _score_assault_move(neighbors, target_pos, weapon_range, map_cells, target_counter_range)
	else:
		var prev_pos: Dictionary = input_params.get("previous_position", {})
		best = _score_evade_move(neighbors, attacker_pos, weapon_range, map_cells, prev_pos)

	if best.is_empty():
		_resolve_action_cancel(action_id)
		return

	# 选中原地（无更优格）则停止移动，避免 0 动力消耗移动死循环（栈溢出）
	if int(best.get("q", 0)) == int(pos.get("q", 0)) and int(best.get("r", 0)) == int(pos.get("r", 0)):
		_resolve_action_cancel(action_id)
		return

	var cell_id: String = "%d,%d" % [int(best.get("q", 0)), int(best.get("r", 0))]
	_resolve_action_input(action_id, {"target_cell": cell_id})


## 强袭追击评分：优先保持在目标射程内（保命中 +2000），其次躲开目标反击射程（+500，
## 仅在不破坏命中的前提下；若我方武器射程<目标反击射程才能兼顾），其次靠近目标（距离越小越好）。
func _score_assault_move(neighbors: Array, target_pos: Dictionary, weapon_range: int, map_cells: Dictionary, target_counter_range: int) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1e9
	for hex in neighbors:
		var in_range: bool = _RangeCalculator.is_in_weapon_range(target_pos, hex, weapon_range, map_cells)
		var dist: int = _HexGrid.distance(target_pos, hex)
		var score: float = (2000.0 if in_range else 0.0) + (-dist * 10.0)
		# 躲反击：该格不在目标武器射程内（命中优先级 2000 >> 500，不会为躲反击而放弃命中）
		if target_counter_range > 0:
			var in_counter: bool = _RangeCalculator.is_in_weapon_range(target_pos, hex, target_counter_range, map_cells)
			if not in_counter:
				score += 500.0
		if score > best_score:
			best_score = score
			best = hex
	return best


## 迎击移动评分：优先逃出攻击范围（+1000），其次离攻击方更远。
## previous_pos：上一步起点，施加大惩罚防回访振荡（B1 修复）。
func _score_evade_move(neighbors: Array, attacker_pos: Dictionary, weapon_range: int, map_cells: Dictionary, previous_pos: Dictionary = {}) -> Dictionary:
	var best: Dictionary = {}
	var best_score: float = -1e9
	for hex in neighbors:
		var in_range: bool = false
		if not attacker_pos.is_empty():
			in_range = _RangeCalculator.is_in_weapon_range(attacker_pos, hex, weapon_range, map_cells)
		var dist: int = 0
		if not attacker_pos.is_empty():
			dist = _HexGrid.distance(attacker_pos, hex)
		# 出范围 +1000，距离越远分越高
		var score: float = (dist * 1.0) + (1000.0 if not in_range else 0.0)
		# 防回访：回到上一步起点施大惩罚（避免两等距格来回跳）
		if not previous_pos.is_empty() and int(hex.get("q", 0)) == int(previous_pos.get("q", 0)) and int(hex.get("r", 0)) == int(previous_pos.get("r", 0)):
			score -= 10000.0
		if score > best_score:
			best_score = score
			best = hex
	return best


## AI 自动放置损伤（不弹 UI），放置后回填动作继续执行
func _auto_place_damage_tokens(input_params: Dictionary) -> void:
	var mech_ids: Array = input_params.get("mech_ids", [])
	var amount: int = int(input_params.get("amount", 0))
	var removal: bool = bool(input_params.get("removal_mode", false))
	# removal 模式（维修移除损伤）：自动移除；放置模式：damage_token_service 按优先级放置
	if context != null:
		for mech_id: StringName in mech_ids:
			if removal and context.game_actions != null:
				context.game_actions.remove_damage_tokens({"mech_id": mech_id, "amount": amount})
			elif not removal and context.damage_token_service != null:
				context.damage_token_service.place_damage_tokens({
					"mech_id": mech_id,
					"count": amount,
				})
	# 回填动作（damage_change 的 set_damage 步骤收到任意 input 即继续结算）
	on_ui_confirmed({"auto_placed": true})


## AI 自动响应攻击窗口
## 委托给 AIController.decide_response（能逃则逃，不能逃才反打）；无 AIController 时退回"最高优先级"。
func _auto_respond(action_id: StringName, input_params: Dictionary) -> void:
	if context == null or context.timing_engine == null:
		return
	var available: Array[Dictionary] = []
	if context.timing_engine != null and context.action_registry != null:
		var action = context.action_registry.get_action(action_id)
		if action != null:
			available = context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)
	if available.is_empty():
		var empty_sel: Array[Dictionary] = []
		context.timing_engine.handle_response_selection(action_id, empty_sel)
		return
	var selected: Array = []
	if context.ai_controller != null:
		selected = context.ai_controller.decide_response(action_id, available)
	if selected.is_empty():
		# 退回原策略：使用最高优先级响应牌
		selected = [available[0]]
	# handle_response_selection 期望 Array[Dictionary]；selected 是 Array，逐项构造
	var best_sel: Array[Dictionary] = []
	for entry in selected:
		if entry is Dictionary:
			best_sel.append(entry)
	context.timing_engine.handle_response_selection(action_id, best_sel)


## 显示响应窗口
func _show_response_window(action_id: StringName, params: Dictionary) -> void:
	var available_cards: Array = []
	if context != null and context.timing_engine != null and context.action_registry != null:
		var action = context.action_registry.get_action(action_id)
		if action != null:
			available_cards = context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)

	# 将可用效果转换为UI显示数据
	# 注意：get_available_cards 返回的是 Dictionary 数组，每个元素含
	# effect_id / card_instance_id / display_name 等键（无 source 字段）。
	var display_data: Array[Dictionary] = []
	for entry in available_cards:
		var card_instance_id: StringName = entry.get("card_instance_id", &"")
		var card = context.game_state.get_card(card_instance_id) if card_instance_id != &"" and context != null and context.game_state != null else null
		display_data.append({
			"effect_id": entry.get("effect_id", &""),
			"card_instance_id": card_instance_id,
			"display_name": entry.get("display_name", &""),
			"card_name": card.def.display_name if card and card.def else String(entry.get("effect_id", &"")),
		})

	request_ui_popup.emit(&"response_window", {
		"action_id": action_id,
		"available_cards": display_data,
		"attacker_id": params.get("attacker_id", &""),
		"target_id": params.get("target_id", &""),
	})


## UI组件确认后的回调（由 UI 调用）
func on_ui_confirmed(input_data: Dictionary) -> void:
	if _waiting_action_id == &"":
		return

	var action_id: StringName = _waiting_action_id
	_waiting_action_id = &""
	_current_input_type = &""
	_current_input_params = {}

	_apply_action_input(action_id, input_data)


## UI组件取消时的回调
func on_ui_cancelled() -> void:
	if _waiting_action_id == &"":
		return

	var action_id: StringName = _waiting_action_id
	_waiting_action_id = &""
	_current_input_type = &""
	_current_input_params = {}

	_apply_action_cancel(action_id)


## 按 action_id 精确回填输入（不走共享 _waiting_action_id 槽）。
## 供 call_deferred 的 AI 自动决策（_auto_move_target）使用：延迟回调执行时，
## _waiting_action_id 可能已被后到的 waiting_input 动作覆盖（如强袭 effect2 与响应移动
## 并发 waiting_input），若用 on_ui_confirmed 会把输入错路由到后到动作（玩家被 AI 自动
## 移动的 bug）。此处仅当共享槽仍指向本动作时清槽，并直接回填本动作。
func _resolve_action_input(action_id: StringName, input_data: Dictionary) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_apply_action_input(action_id, input_data)


## 按 action_id 精确取消（供 call_deferred 的 AI 自动决策使用，理由同 _resolve_action_input）。
func _resolve_action_cancel(action_id: StringName) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""
		_current_input_type = &""
		_current_input_params = {}
	_apply_action_cancel(action_id)


## 实际回填输入到指定动作：优先恢复 TimingEngine 挂起的效果，否则 continue_action。
func _apply_action_input(action_id: StringName, input_data: Dictionary) -> void:
	action_input_resolved.emit(action_id, input_data)
	# 目标选择 / 二选一 等由 TimingEngine 挂起的效果：走 resume_pending_effect 续跑
	# （这些效果的目标检查在动作执行之前，continue_action 直接走下一 step 会漏掉效果执行）
	if context != null and context.timing_engine != null and context.timing_engine.has_pending_effect(action_id):
		context.timing_engine.resume_pending_effect(action_id, input_data)
		return
	# 调用 ActionService 继续执行动作
	if context != null and context.action_service != null:
		context.action_service.continue_action(action_id, input_data)


## 实际取消指定动作：TimingEngine 挂起的效果走 resume_pending_effect(cancelled)，否则 cancel_action。
func _apply_action_cancel(action_id: StringName) -> void:
	# TimingEngine 挂起的效果（目标选择/二选一）：取消则不执行该效果，恢复动作继续后续步骤
	if context != null and context.timing_engine != null and context.timing_engine.has_pending_effect(action_id):
		context.timing_engine.resume_pending_effect(action_id, {"cancelled": true})
		return
	if context != null and context.action_service != null:
		context.action_service.cancel_action(action_id)


## 动作完成时的回调
func _on_action_completed(action_id: StringName, _action_type: StringName, _record: Dictionary) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""


## 动作取消时的回调
func _on_action_cancelled(action_id: StringName, _action_type: StringName) -> void:
	if _waiting_action_id == action_id:
		_waiting_action_id = &""


## 获取当前等待输入的动作信息
## 返回空字典表示无等待中的动作，否则返回 action_id / input_type / input_params
func get_waiting_action_info() -> Dictionary:
	if _waiting_action_id == &"":
		return {}
	return {
		"action_id": _waiting_action_id,
		"input_type": _current_input_type,
		"input_params": _current_input_params,
	}
