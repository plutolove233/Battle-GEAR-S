## ResponsePanel.gd — 迎击/掩护选择面板
##
## 被攻击时弹出，显示手牌中的迎击牌和掩护牌列表。
## 先点击选择响应牌高亮，再点击确认按钮提交。
## 跳过按钮可直接跳过响应。
extends VBoxContainer
class_name ResponsePanel

## 确认选择迎击/掩护牌
signal response_selected(card_id: StringName)
## 跳过迎击
signal response_passed()

## 新系统：选择了 AVAILABILITY 模式的效果牌
signal availability_effect_selected(effect_id: StringName, card_instance_id: StringName)

const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 当前攻击 ID
var _attack_id: StringName = &""

## 新系统：BattleState 引用（用于查询 TimingEngine 可用牌）
var _battle_state = null  # type: BattleState
## 是否使用新系统模式（默认 true）
var _use_new_system: bool = true

## 当前选中的响应牌信息（新系统: effect_id + card_instance_id, 旧系统: card_id）
var _selected_effect_id: StringName = &""
var _selected_card_instance_id: StringName = &""
## client 模式：host 转发的可用响应牌（非空时优先用，不查 TimingEngine）
var _override_available_cards: Array = []
## 确认按钮
var _confirm_btn: Button


## 配置面板：主要接口，自动使用新动作系统
func configure(game_context, attack_id: StringName) -> void:
	_context = game_context
	_attack_id = attack_id
	_battle_state = null
	_use_new_system = true
	_selected_effect_id = &""
	_selected_card_instance_id = &""
	_refresh()


## 配置面板：通过 BattleState 使用新动作系统
func configure_new_system(battle_state, attack_id: StringName) -> void:
	_battle_state = battle_state
	_attack_id = attack_id
	_context = battle_state.context if battle_state else null
	_use_new_system = true
	_selected_effect_id = &""
	_selected_card_instance_id = &""
	_override_available_cards = []
	_refresh()


## 配置面板：直接传入可用响应牌（client 模式，host 转发 available_cards，无需查 TimingEngine）
func configure_with_cards(battle_state, attack_id: StringName, available_cards: Array) -> void:
	_battle_state = battle_state
	_attack_id = attack_id
	_context = battle_state.context if battle_state else null
	_use_new_system = true
	_selected_effect_id = &""
	_selected_card_instance_id = &""
	_override_available_cards = available_cards
	_refresh()


## 配置面板：旧系统兼容接口（已弃用，请使用 configure）
## @deprecated
func configure_legacy(game_context, attack_id: StringName) -> void:
	_context = game_context
	_attack_id = attack_id
	_battle_state = null
	_use_new_system = false
	_selected_effect_id = &""
	_selected_card_instance_id = &""
	_refresh()


## 刷新迎击牌和掩护牌列表
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	# 标题
	var title = Label.new()
	title.text = "── 响应选择 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	# 新系统模式：使用 TimingEngine 的 AVAILABILITY 牌
	if _use_new_system:
		_refresh_new_system()
	else:
		# 旧系统模式：查询手牌中的迎击牌和掩护牌
		_refresh_old_system()

	# 确认按钮（始终显示）
	_confirm_btn = Button.new()
	_confirm_btn.text = "确认响应" if _selected_card_instance_id != &"" else "请选择响应牌"
	_confirm_btn.custom_minimum_size = Vector2(240, 36)
	_confirm_btn.disabled = _selected_card_instance_id == &""
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4) if _selected_card_instance_id != &"" else Color(0.5, 0.5, 0.5))
	_confirm_btn.pressed.connect(func(): _on_confirm())
	add_child(_confirm_btn)

	# 跳过按钮
	var pass_btn = Button.new()
	pass_btn.text = "跳过响应"
	pass_btn.custom_minimum_size = Vector2(240, 36)
	pass_btn.pressed.connect(func(): response_passed.emit())
	add_child(pass_btn)


## 新系统：使用 TimingEngine 的 AVAILABILITY 模式效果牌
func _refresh_new_system() -> void:
	var available_cards: Array[Dictionary] = []

	# client 模式：优先用 host 转发的 available_cards
	if not _override_available_cards.is_empty():
		for c in _override_available_cards:
			if c is Dictionary:
				available_cards.append(c)
	else:
		# 优先：从 TimingEngine 直接查询当前等待动作的可用牌
		if _context != null and _context.timing_engine != null:
			var _TC = preload("res://scripts/action_core/TimingConst.gd")
			# 查找当前处于 waiting_timing 状态的动作
			if _context.action_registry != null:
				for aid: StringName in _context.action_registry.active_actions:
					var action = _context.action_registry.get_action(aid)
					if action and action.state == &"waiting_timing":
						available_cards = _context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)
						break

		# 退回：通过 battle_state 查询
		if available_cards.is_empty() and _battle_state != null:
			available_cards = _battle_state.get_available_response_cards(_attack_id)

		# 退回：通过 ActionUIBridge 查询等待中的动作
		if available_cards.is_empty() and _context != null and _context.action_ui_bridge != null:
			var wait_info: Dictionary = _context.action_ui_bridge.get_waiting_action_info()
			if not wait_info.is_empty() and _context.timing_engine != null and _context.action_registry != null:
				var _TC = preload("res://scripts/action_core/TimingConst.gd")
				var action = _context.action_registry.get_action(wait_info.get("action_id", &""))
				if action:
					available_cards = _context.timing_engine.get_available_cards(_TC.ATTACK_AT, action)

	var has_any: bool = false
	for card_info: Dictionary in available_cards:
		has_any = true
		var btn = Button.new()
		var card_name: String = card_info.get("card_name", String(card_info.get("effect_id", &"")))
		btn.text = "%s [响应]" % card_name
		btn.tooltip_text = card_info.get("display_name", card_name)
		btn.custom_minimum_size = Vector2(240, 36)

		var effect_id: StringName = card_info.get("effect_id", &"")
		var card_instance_id: StringName = card_info.get("card_instance_id", &"")

		# 已选中高亮
		if card_instance_id == _selected_card_instance_id:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)

		btn.pressed.connect(func(): _on_response_card_selected(effect_id, card_instance_id))
		add_child(btn)

	if not has_any:
		var no_card = Label.new()
		no_card.text = "（无可用响应牌）"
		no_card.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_card)


## 旧系统：查询手牌中的迎击牌和掩护牌
func _refresh_old_system() -> void:
	if not _context:
		return

	var gs = _context.game_state
	# 迎击牌/掩护牌属于被攻击方
	var attack = gs.attacks.get(_attack_id, {})
	var target_id: StringName = attack.get("target_id", &"")
	var target_player_id: StringName = &""
	for pid: StringName in gs.players:
		var mech = gs.get_mech_for_player(pid)
		if mech and mech.mech_id == target_id:
			target_player_id = pid
			break

	if target_player_id == &"":
		var err = Label.new()
		err.text = "无法确定被攻击方"
		add_child(err)
		return

	var player = gs.players.get(target_player_id)
	if not player:
		return

	# 检查被攻击方是否被攻击方锁定（LOCKED，且来源为攻击方玩家）
	# 识破等带 ignore_lock 的响应牌仍可使用
	var attacker_id: StringName = attack.get("attacker_id", &"")
	var attacker_player = gs.get_player_for_mech(attacker_id)
	var attacker_player_id: StringName = attacker_player.player_id if attacker_player else &""

	var target_mech = gs.mechs.get(target_id)
	var is_locked: bool = false
	if target_mech and attacker_player_id != &"":
		for status in target_mech.statuses:
			if String(status.get("type", "")) == "LOCKED" and String(status.get("source_player_id", "")) == String(attacker_player_id):
				is_locked = true
				break

	# 查找手牌中的迎击牌
	# P2-2: 被锁定但有ignore_lock的牌（识破）仍可使用
	var has_any: bool = false
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		if card.def is _ActionCardDef and card.def.action_type == &"迎击":
			# P2-2: 检查此牌是否有ignore_lock效果
			var has_ignore_lock: bool = false
			if is_locked and card.def.effects:
				for effect in card.def.effects:
					if effect == null: continue
					for action: Dictionary in effect.actions:
						if action is Dictionary and String(action.get("type", "")) == "APPLY_OR_CHECK_LOCKED":
							var action_params: Dictionary = action.get("params", {})
							if action_params.get("ignore_lock", false):
								has_ignore_lock = true

			# 被锁定且无ignore_lock效果 → 跳过此牌
			if is_locked and not has_ignore_lock:
				continue

			has_any = true
			var btn = Button.new()
			if is_locked and has_ignore_lock:
				btn.text = "%s [迎击·无视锁定]" % card.def.display_name
			else:
				btn.text = "%s [迎击]" % card.def.display_name
			btn.tooltip_text = card.def.effect_text
			btn.custom_minimum_size = Vector2(240, 36)
			# 已选中高亮
			if card_id == _selected_card_instance_id:
				btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
				btn.modulate = Color(1.2, 1.2, 0.8)
			var cid = card_id
			btn.pressed.connect(func(): _on_old_response_card_selected(cid))
			add_child(btn)

	# 查找手牌中的掩护牌（被锁定时仍可使用）
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		if card.def is _ActionCardDef and card.def.action_type == &"辅助":
			# 检查是否为掩护牌（效果hook为ON_ATTACK_DECLARED）
			if _is_cover_card(card):
				# 检查掩护条件：武器范围内有被攻击的机甲
				if _check_cover_condition(card, attack):
					has_any = true
					var btn = Button.new()
					btn.text = "%s [掩护]" % card.def.display_name
					btn.tooltip_text = card.def.effect_text
					btn.custom_minimum_size = Vector2(240, 36)
					# 已选中高亮
					if card_id == _selected_card_instance_id:
						btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
						btn.modulate = Color(1.2, 1.2, 0.8)
					var cid = card_id
					btn.pressed.connect(func(): _on_old_response_card_selected(cid))
					add_child(btn)

	if not has_any:
		var no_card = Label.new()
		no_card.text = "（无可用响应牌）"
		no_card.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_card)


## 选择新系统响应牌
func _on_response_card_selected(effect_id: StringName, card_instance_id: StringName) -> void:
	if _selected_card_instance_id == card_instance_id:
		_selected_effect_id = &""
		_selected_card_instance_id = &""  # 再次点击取消选择
	else:
		_selected_effect_id = effect_id
		_selected_card_instance_id = card_instance_id
	_refresh()


## 选择旧系统响应牌
func _on_old_response_card_selected(card_id: StringName) -> void:
	if _selected_card_instance_id == card_id:
		_selected_card_instance_id = &""  # 再次点击取消选择
	else:
		_selected_card_instance_id = card_id
	_refresh()


## 确认响应选择
func _on_confirm() -> void:
	if _selected_card_instance_id == &"":
		return
	# 只 emit 一个信号。历史上这里同时 emit availability_effect_selected 与 response_selected，
	# 而 app_root 对两者分别连接了 _on_availability_effect_selected / _on_response_selected，
	# 二者都会调用 timing_engine.handle_response_selection —— 导致同一张响应牌被处理两次：
	# 第二次调用时迎击牌 use_action_card 被再次发起，且 attack_action_id 被偷换成当时正在
	# 等待输入的 single_move 子动作 id，原攻击动作因此卡死、既不命中也不造成伤害。
	# 统一只走 response_selected（app_root._on_response_selected 会自行查 AVAILABILITY 效果）。
	response_selected.emit(_selected_card_instance_id)


## 判断是否为掩护牌
func _is_cover_card(card) -> bool:
	if card == null or card.def == null:
		return false
	for effect in card.def.effects:
		if effect and String(effect.hook) == "ON_ATTACK_DECLARED":
			return true
	return false


## 检查掩护牌的条件是否满足
## 掩护条件：已设置武器的范围内存在机甲(包括我方)被攻击
func _check_cover_condition(_card, attack: Dictionary) -> bool:
	if _context == null:
		return false
	var target_id: StringName = attack.get("target_id", &"")
	if target_id == &"":
		return false
	return true
