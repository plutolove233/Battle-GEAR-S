## SellEquipmentPanel.gd — 卖出装备面板
##
## 专门用于卖出装备的选择界面
## 先选择装备，再点击确认按钮卖出
extends PanelContainer
class_name SellEquipmentPanel

## 玩家确认卖出选中的装备
signal equipment_confirmed(card_id: StringName)
## 取消选择
signal cancelled()

const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")

## 当前 GameContext 引用
var _context = null  # type: GameContext

## 本窗口控制的玩家（PvP host=player, client=enemy）。列出该玩家可卖出的装备。
var local_player_id: StringName = &"player"

## 已选择的装备 card_id
var _selected_card_id: StringName = &""

## 内部布局
var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _title_label: Label
var _confirm_btn: Button
var _cancel_btn: Button


## 配置面板
func configure(game_context) -> void:
	_context = game_context
	_selected_card_id = &""
	_ensure_layout()
	_refresh()


## 确保布局已初始化
func _ensure_layout() -> void:
	if _vbox:
		return

	# 创建主 VBox 容器
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	# 标题
	_title_label = Label.new()
	_title_label.text = "── 卖出装备 ──"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	_vbox.add_child(_title_label)

	# 滚动容器
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
	_scroll.set_meta("content", scroll_content)

	# 确认按钮
	_confirm_btn = Button.new()
	_confirm_btn.custom_minimum_size = Vector2(240, 40)
	_confirm_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_confirm_btn.pressed.connect(func(): _on_confirm())
	_vbox.add_child(_confirm_btn)

	# 取消按钮
	_cancel_btn = Button.new()
	_cancel_btn.text = "取消"
	_cancel_btn.custom_minimum_size = Vector2(240, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.pressed.connect(func(): cancelled.emit())
	_vbox.add_child(_cancel_btn)


## 刷新显示
func _refresh() -> void:
	if not _vbox:
		return

	# 更新确认按钮状态
	_confirm_btn.text = "确认卖出" if _selected_card_id != &"" else "请选择装备"
	_confirm_btn.disabled = _selected_card_id == &""
	_confirm_btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3) if _selected_card_id != &"" else Color(0.5, 0.5, 0.5))

	# 获取滚动内容容器
	var scroll_content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if not scroll_content:
		return

	# 清空现有内容
	for child in scroll_content.get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	var player = gs.players.get(local_player_id)
	var mech = gs.get_mech_for_player(local_player_id)
	if not player or not mech:
		return

	var has_options = false

	# 1. 玩家手中的装备牌
	for card_id: StringName in player.equipment_hand:
		var card = gs.get_card(card_id)
		if card and card.def:
			has_options = true
			var btn = Button.new()
			# "禁"标签装备不能主动卖出（法尔科 pilot_078 等）：置灰禁选，后端 CardSetService 双保险。
			var forbid = _ActionPilotEffects.equip_forbid_tagged(card)
			btn.text = "%s (手中)%s" % [card.def.display_name, "（禁）" if forbid else ""]
			btn.custom_minimum_size = Vector2(260, 36)
			btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
			btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
			btn.disabled = forbid
			# 已选中高亮
			var cid = card.instance_id
			if cid == _selected_card_id:
				btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
				btn.modulate = Color(1.2, 1.2, 0.8)
			btn.pressed.connect(func(): _on_card_selected(cid))
			scroll_content.add_child(btn)

	# 2. 备用区的装备牌
	for rs_id: StringName in [&"reserve_1", &"reserve_2"]:
		if mech.slots.has(rs_id) and mech.slots[rs_id].equipped_card != null:
			var card = mech.slots[rs_id].equipped_card
			if card and card.def:
				has_options = true
				var reserve_name = "备用1" if rs_id == &"reserve_1" else "备用2"
				var btn = Button.new()
				# "禁"标签装备不能主动卖出（法尔科 pilot_078 等）：置灰禁选，后端 CardSetService 双保险。
				var forbid = _ActionPilotEffects.equip_forbid_tagged(card)
				btn.text = "%s: %s%s" % [reserve_name, card.def.display_name, "（禁）" if forbid else ""]
				btn.custom_minimum_size = Vector2(260, 36)
				btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
				btn.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
				btn.disabled = forbid
				# 已选中高亮
				var cid = card.instance_id
				if cid == _selected_card_id:
					btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
					btn.modulate = Color(1.2, 1.2, 0.8)
				btn.pressed.connect(func(): _on_card_selected(cid))
				scroll_content.add_child(btn)

	# 3. 已设置到部件区域、且有"已设置可卖出"效果(effect_001)的装备（量产装）
	# 遍历6个部件 slot，若 slot 装备的 effect_ids 含 equipment_effect_001 则列出
	var effect_ids_map: Dictionary = {}
	if _context != null and _context.get("card_database") != null:
		var cdb = _context.card_database
		if cdb.get("loader") != null:
			effect_ids_map = cdb.loader.get_effect_ids_map()
		elif cdb.has_method("get_effect_ids_map"):
			effect_ids_map = cdb.get_effect_ids_map()
	for slot_id: StringName in [&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿"]:
		if not mech.slots.has(slot_id):
			continue
		var slot = mech.slots[slot_id]
		if slot == null or slot.equipped_card == null:
			continue
		var card = slot.equipped_card
		if card == null or card.def == null:
			continue
		var eids: Array = effect_ids_map.get(card.def.card_id, [])
		if not eids.has(&"equipment_effect_001"):
			continue
		has_options = true
		var btn = Button.new()
		btn.text = "%s: %s (已设置·卖出后区域变空)" % [String(slot_id), card.def.display_name]
		btn.custom_minimum_size = Vector2(260, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.7, 0.85, 0.5))
		var cid = card.instance_id
		if cid == _selected_card_id:
			btn.add_theme_color_override("font_color", Color(1.0, 0.85, 0.2))
			btn.modulate = Color(1.2, 1.2, 0.8)
		btn.pressed.connect(func(): _on_card_selected(cid))
		scroll_content.add_child(btn)

	if not has_options:
		var no_opt = Label.new()
		no_opt.text = "（没有可卖出的装备）"
		no_opt.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
		no_opt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		scroll_content.add_child(no_opt)


## 选择/取消选择某张装备牌
func _on_card_selected(card_id: StringName) -> void:
	if _selected_card_id == card_id:
		_selected_card_id = &""  # 再次点击取消选择
	else:
		_selected_card_id = card_id
	_refresh()


## 确认卖出
func _on_confirm() -> void:
	if _selected_card_id != &"":
		equipment_confirmed.emit(_selected_card_id)
