## ResponsePanel.gd — 迎击/掩护选择面板
##
## 被攻击时弹出，显示手牌中的迎击牌和掩护牌列表 + 跳过按钮。
extends VBoxContainer
class_name ResponsePanel

## 选择迎击/掩护牌
signal response_selected(card_id: StringName)
## 跳过迎击
signal response_passed()

const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 当前攻击 ID
var _attack_id: StringName = &""


## 配置面板：显示迎击和掩护选项
func configure(game_context, attack_id: StringName) -> void:
	_context = game_context
	_attack_id = attack_id
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

	# P2-2: 检查被攻击方是否被锁定（cannot_respond）
	# 关键顺序：先检查迎击牌是否有ignore_lock效果，再决定是否跳过
	var target_mech = gs.mechs.get(target_id)
	var is_locked: bool = false
	if target_mech:
		for status in target_mech.statuses:
			if String(status.get("type", "")) == "CANNOT_RESPOND":
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
			btn.text = "%s [迎击]" % card.def.display_name
			btn.tooltip_text = card.def.effect_text
			btn.custom_minimum_size = Vector2(240, 36)
			if is_locked and has_ignore_lock:
				# 视觉提示：此牌可无视锁定使用
				btn.text = "%s [迎击·无视锁定]" % card.def.display_name
			var cid = card_id
			btn.pressed.connect(func(): response_selected.emit(cid))
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
					var cid = card_id
					btn.pressed.connect(func(): response_selected.emit(cid))
					add_child(btn)

	if not has_any:
		var no_card = Label.new()
		no_card.text = "（无可用响应牌）"
		no_card.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_card)

	# 跳过按钮
	var pass_btn = Button.new()
	pass_btn.text = "跳过响应"
	pass_btn.custom_minimum_size = Vector2(240, 36)
	pass_btn.pressed.connect(func(): response_passed.emit())
	add_child(pass_btn)


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
