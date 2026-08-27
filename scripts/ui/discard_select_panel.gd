## DiscardSelectPanel.gd — 弃牌选择面板
##
## 显示待弃置的行动牌，允许玩家选择要弃置的牌。
## 明牌模式：显示牌名和类型（弃自己的牌时）。
## 暗牌模式：只显示通用标签（弃对手未知手牌时）。
## 先点击选择牌高亮，再点击确认按钮提交。
extends PanelContainer
class_name DiscardSelectPanel

## 选择完成时发射（玩家点击确认后）
signal selection_completed(selected_card_ids: Array[StringName])
## 取消选择
signal selection_cancelled()

## 当前 GameContext 引用
var _context = null  # type: GameContext

## 要弃牌的玩家 ID
var _discard_player_id: StringName = &""
## 需要弃置的牌数（最多可选张数）
var _count: int = 1
## 至少选择的张数（0=须选满 count，>0=至少选 min_count 张，可少选）
var _min_count: int = 0
## 自定义标题（非空则优先于通用模板）
var _title_override: String = ""
## 白名单：非空时只列出这些牌（塔莉娅赐予：只列刚抽的剩余禁牌）
var _allowed_card_ids: Array = []
## 是否明牌
var _face_up: bool = true
## 牌类型过滤（空字符串表示不过滤）
var _card_type_filter: StringName = &""
## 动作语义（gain=获取/偷牌，discard=弃置），影响标题/按钮文案
var _action_verb: StringName = &"discard"
## 来源标签（"牌名：效果描述"，来自发动效果，可空）
var _source_text: String = ""
## 无取消按钮（pilot_007 类型破绽强制弃牌：须选够张数后确认，不可放弃）
var _no_cancel: bool = false
## 已选择的牌 ID 列表
var _selected: Array[StringName] = []
## 排除的牌 ID 列表（默多克展示转化：选另外2张时排除展示的牌A，不使其被选）
var _exclude_card_ids: Array = []

## 内部布局容器
var _vbox: VBoxContainer
## 滚动容器
var _scroll: ScrollContainer
## 确认按钮
var _confirm_btn: Button
## 取消按钮
var _cancel_btn: Button
## 计数标签
var _count_label: Label
## 来源标签
var _source_label: Label


## 配置面板参数
func configure(game_context, discard_player_id: StringName, count: int, face_up: bool, card_type_filter: StringName = &"", action_verb: StringName = &"discard", source_label: String = "", no_cancel: bool = false, exclude_card_ids: Array = [], min_count: int = 0, title_override: String = "", allowed_card_ids: Array = []) -> void:
	_context = game_context
	_discard_player_id = discard_player_id
	_count = count
	_face_up = face_up
	_card_type_filter = card_type_filter
	_action_verb = action_verb
	_source_text = source_label
	_no_cancel = no_cancel
	_exclude_card_ids = exclude_card_ids
	_min_count = min_count
	_title_override = title_override
	_allowed_card_ids = allowed_card_ids
	_selected.clear()

	# 确保布局已初始化
	_ensure_layout()
	_refresh()


## 确保布局已初始化（处理 configure 在 _ready 之前被调用的情况）
func _ready() -> void:
	# 延迟一帧确保父容器已完全设置
	call_deferred("_ensure_layout")


## 延迟初始化布局
func _ensure_layout() -> void:
	if _vbox:
		return

	# 创建主 VBox 容器
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	# 来源标签（效果牌名+描述，可空）
	_source_label = Label.new()
	_source_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 14)
	_vbox.add_child(_source_label)

	# 标题
	_count_label = Label.new()
	_count_label.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_vbox.add_child(_count_label)

	# 滚动容器（用于牌列表）
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(280, 200)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_vbox.add_child(_scroll)

	# 滚动内容容器
	var scroll_content = VBoxContainer.new()
	scroll_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_content.add_theme_constant_override("separation", 4)
	_scroll.add_child(scroll_content)
	# 保存引用以便刷新时使用
	_scroll.set_meta("content", scroll_content)

	# 确认按钮
	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(200, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	# 取消按钮
	_cancel_btn = Button.new()
	_cancel_btn.text = "取消"
	_cancel_btn.custom_minimum_size = Vector2(200, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.pressed.connect(func(): selection_cancelled.emit())
	_vbox.add_child(_cancel_btn)


## 刷新面板显示
func _refresh() -> void:
	if not _vbox:
		return

	# 来源标签
	if _source_label:
		_source_label.text = _source_text if _source_text != "" else ""
		# 转化模式：标题已含 label，隐藏来源标签避免重复
		_source_label.visible = _source_text != "" and _action_verb != &"convert"

	# 更新标题
	var verb := _verb_text()
	var _need: int = _min_count if _min_count > 0 else _count
	if _title_override != "":
		_count_label.text = "── %s ──" % _title_override
	elif _action_verb == &"convert":
		# 转化模式（迪恩）：标题用 cost label（"选择转化使用的N张行动牌"），优先于通用模板
		if _source_text != "":
			_count_label.text = "── %s ──" % _source_text
		else:
			_count_label.text = "── 选择转化使用的 %d 张行动牌 ──" % _count
	elif _face_up:
		_count_label.text = "── 选择%s %d 张行动牌 ──" % [verb, _count]
	else:
		_count_label.text = "── 选择%s对手 %d 张行动牌（暗牌）──" % [verb, _count]

	# 更新确认按钮
	if _action_verb == &"convert":
		# 转化模式：按钮"确认选择"，带已选/需选计数
		_confirm_btn.text = "确认选择 (%d/%d)" % [_selected.size(), _count]
	else:
		_confirm_btn.text = "确认%s (%d/%d)" % [verb, _selected.size(), _count]
	_confirm_btn.disabled = _selected.size() < _need
	_confirm_btn.add_theme_color_override("font_color", Color(0.3, 0.9, 0.4) if _selected.size() >= _need else Color(0.5, 0.5, 0.5))

	# 无取消按钮模式（强制弃牌：不可放弃）
	if _cancel_btn:
		_cancel_btn.visible = not _no_cancel

	# 获取滚动内容容器
	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return

	# 清空现有按钮
	for child in scroll_content.get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	var player = gs.players.get(_discard_player_id)
	if not player:
		return

	# ── 显示可选择的行动牌 ──
	# display_index：暗牌模式下用作不泄露信息的编号（第1张/第2张…），
	# 不用 card_id（形如 action_012_识破，会泄露牌名）。
	var display_index := 0
	for card_id: StringName in player.action_hand:
		var card = gs.cards.get(card_id)
		if not card or not card.def:
			continue

		# 白名单过滤（塔莉娅赐予：只列刚抽的剩余禁牌）
		if not _allowed_card_ids.is_empty() and card_id not in _allowed_card_ids:
			continue

		# 应用 card_type_filter 过滤
		if _card_type_filter != &"" and card.def.action_type != _card_type_filter:
			continue

		# 排除指定牌（默多克展示转化：选另外2张时排除展示的牌A）
		if card_id in _exclude_card_ids:
			continue

		display_index += 1
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
			# 暗牌：只显示编号，不泄露牌名/牌id
			btn.text = "行动牌 #%d" % display_index
			btn.tooltip_text = "未知行动牌"
			btn.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))

		btn.custom_minimum_size = Vector2(260, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER

		# 已选择的牌高亮
		var cid = card_id
		if cid in _selected:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)

		btn.pressed.connect(func(): _on_card_toggle(cid))
		scroll_content.add_child(btn)


## 切换选择某张牌
func _on_card_toggle(card_id: StringName) -> void:
	if card_id in _selected:
		_selected.erase(card_id)
	elif _selected.size() < _count:
		_selected.append(card_id)
	_refresh()


## 确认选择
func _on_confirm() -> void:
	var _need: int = _min_count if _min_count > 0 else _count
	if _selected.size() >= _need:
		selection_completed.emit(_selected.slice(0, _count))


## 动作语义文案（获取/弃置/转化）
func _verb_text() -> String:
	match _action_verb:
		&"gain": return "获取"
		&"convert": return "转化"
		_: return "弃置"


## 获取行动类型的简写
func _action_type_short(def) -> String:
	if def.action_type == &"攻击":
		return "攻"
	elif def.action_type == &"迎击":
		return "迎"
	elif def.action_type == &"辅助":
		return "辅"
	return "?"
