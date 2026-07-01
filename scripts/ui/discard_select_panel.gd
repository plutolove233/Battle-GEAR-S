## DiscardSelectPanel.gd — 弃牌选择面板
##
## 显示待弃置的行动牌，允许玩家选择要弃置的牌。
## 明牌模式：显示牌名和类型（弃自己的牌时）。
## 暗牌模式：只显示通用标签（弃对手未知手牌时）。
extends VBoxContainer
class_name DiscardSelectPanel

## 选择完成时发射（玩家点击确认后）
signal selection_completed(selected_card_ids: Array[StringName])

## 当前 GameContext 引用
var _context = null  # type: GameContext

## 要弃牌的玩家 ID
var _discard_player_id: StringName = &""
## 需要弃置的牌数
var _count: int = 1
## 是否明牌
var _face_up: bool = true
## 牌类型过滤（空字符串表示不过滤）
var _card_type_filter: StringName = &""
## 已选择的牌 ID 列表
var _selected: Array[StringName] = []


## 配置面板参数
func configure(game_context, discard_player_id: StringName, count: int, face_up: bool, card_type_filter: StringName = &"") -> void:
	_context = game_context
	_discard_player_id = discard_player_id
	_count = count
	_face_up = face_up
	_card_type_filter = card_type_filter
	_selected.clear()
	_refresh()


## 刷新面板显示
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	var title = Label.new()
	if _face_up:
		title.text = "── 选择弃置 %d 张行动牌 ──" % _count
	else:
		title.text = "── 随机弃置对手 %d 张行动牌（暗牌）──" % _count
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	add_child(title)

	if not _context:
		return

	var gs = _context.game_state
	var player = gs.players.get(_discard_player_id)
	if not player:
		return

	# ── 显示可选择的行动牌 ──
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue

		# 应用 card_type_filter 过滤
		if _card_type_filter != &"" and card.def.action_type != _card_type_filter:
			continue

		var btn = Button.new()
		if _face_up:
			btn.text = "%s[%s]" % [card.def.display_name, _action_type_short(card.def)]
			btn.tooltip_text = card.def.effect_text
			# 根据行动类型上色
			if card.def.action_type == &"攻击":
				btn.add_theme_color_override("font_color", Color(0.9, 0.3, 0.2))
			elif card.def.action_type == &"迎击":
				btn.add_theme_color_override("font_color", Color(0.3, 0.7, 0.9))
			else:
				btn.add_theme_color_override("font_color", Color(0.3, 0.85, 0.5))
		else:
			# 暗牌：只显示通用标签
			btn.text = "行动牌 #%s" % str(card_id).right(4)
			btn.tooltip_text = "未知行动牌"
			btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

		btn.custom_minimum_size = Vector2(200, 36)

		# 已选择的牌高亮
		var cid = card_id
		if cid in _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)

		btn.pressed.connect(func(): _on_card_toggle(cid))
		add_child(btn)

	# ── 确认按钮 ──
	var confirm_btn = Button.new()
	confirm_btn.text = "确认弃置 (%d/%d)" % [_selected.size(), _count]
	confirm_btn.disabled = _selected.size() < _count
	confirm_btn.custom_minimum_size = Vector2(200, 36)
	confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4) if _selected.size() >= _count else Color(0.5, 0.5, 0.5))
	confirm_btn.pressed.connect(func(): _on_confirm())
	add_child(confirm_btn)


## 切换选择某张牌
func _on_card_toggle(card_id: StringName) -> void:
	if card_id in _selected:
		_selected.erase(card_id)
	elif _selected.size() < _count:
		_selected.append(card_id)
	_refresh()


## 确认选择
func _on_confirm() -> void:
	if _selected.size() >= _count:
		selection_completed.emit(_selected.slice(0, _count))


## 获取行动类型的简写
func _action_type_short(def) -> String:
	if def.action_type == &"攻击":
		return "攻"
	elif def.action_type == &"迎击":
		return "迎"
	elif def.action_type == &"辅助":
		return "辅"
	return "?"
