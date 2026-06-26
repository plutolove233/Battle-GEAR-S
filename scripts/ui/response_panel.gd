## ResponsePanel.gd — 迎击选择面板
##
## 被攻击时弹出，显示手牌中的迎击牌列表 + 跳过按钮。
extends VBoxContainer
class_name ResponsePanel

## 选择迎击牌
signal response_selected(card_id: StringName)
## 跳过迎击
signal response_passed()

const _ActionCardDef = preload("res://scripts/card_defs/ActionCardDef.gd")

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 当前攻击 ID
var _attack_id: StringName = &""


## 配置面板：显示迎击选项
func configure(game_context, attack_id: StringName) -> void:
	_context = game_context
	_attack_id = attack_id
	_refresh()


## 刷新迎击牌列表
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	# 标题
	var title = Label.new()
	title.text = "── 迎击选择 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(title)

	if not _context:
		return

	var gs = _context.game_state
	# 迎击牌属于被攻击方
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

	# 查找手牌中的迎击牌
	var has_counter: bool = false
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue
		if card.def is _ActionCardDef and card.def.action_type == &"迎击":
			has_counter = true
			var btn = Button.new()
			btn.text = "%s [%s]" % [card.def.display_name, card.def.effect_text.left(20)]
			btn.custom_minimum_size = Vector2(200, 36)
			var cid = card_id
			btn.pressed.connect(func(): response_selected.emit(cid))
			add_child(btn)

	if not has_counter:
		var no_card = Label.new()
		no_card.text = "（无迎击牌）"
		no_card.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		add_child(no_card)

	# 跳过按钮
	var pass_btn = Button.new()
	pass_btn.text = "跳过迎击"
	pass_btn.custom_minimum_size = Vector2(200, 36)
	pass_btn.pressed.connect(func(): response_passed.emit())
	add_child(pass_btn)
