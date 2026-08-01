## ImmediateSetEquipmentPanel.gd - 立即设置装备面板（effect_005）
##
## effect_005（联邦左臂/近战左腿）离场诱发：抽1张装备牌后必须立即设置到区域，
## 若不立即设置则需要直接弃置。本面板列出抽到的牌与所有合法空槽供玩家选择；
## 确认某槽 -> slot_selected(slot_id)；取消 -> cancelled()（抽到的牌将被弃置）。
extends PanelContainer
class_name ImmediateSetEquipmentPanel

## 玩家选了某个合法槽
signal slot_selected(slot_id: StringName)
## 玩家选择卖出（仅 effect_065 allow_sell 时出现）
signal sell_selected()
## 玩家取消（不设置，抽到的牌将被弃置）
signal cancelled()

var _context = null  # type: GameContext

var _drawn_card_id: StringName = &""
var _valid_slots: Array = []
var _mech_id: StringName = &""
var _allow_sell: bool = false
var _sell_price: int = 0

var _vbox: VBoxContainer
var _scroll: ScrollContainer
var _title_label: Label
var _source_label: Label
var _drawn_label: Label
var _cancel_btn: Button
var _sell_btn: Button

## 槽位中文显示名
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿", &"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2", &"event_1": "事件", &"pilot_1": "机师",
}


## 配置面板：game_context / 抽到的卡实例 id / 合法空槽列表 / 机甲 id
## allow_sell/sell_price：effect_065 抽装备"立即设置或卖出"时显示卖出按钮
## source_label：来源效果标签（"牌名：效果描述"），显示在面板顶部
func configure(game_context, drawn_card_id: StringName, valid_slots: Array, mech_id: StringName, allow_sell: bool = false, sell_price: int = 0, source_label: String = "") -> void:
	_context = game_context
	_drawn_card_id = drawn_card_id
	_valid_slots = valid_slots
	_mech_id = mech_id
	_allow_sell = allow_sell
	_sell_price = sell_price
	_ensure_layout()
	if _source_label:
		_source_label.text = source_label
		_source_label.visible = source_label != ""
	_refresh()


func _ensure_layout() -> void:
	if _vbox:
		return
	_vbox = VBoxContainer.new()
	_vbox.add_theme_constant_override("separation", 8)
	add_child(_vbox)

	_title_label = Label.new()
	_title_label.text = "── 立即设置装备 ──"
	_title_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
	_vbox.add_child(_title_label)

	_source_label = Label.new()
	_source_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
	_source_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_source_label.add_theme_font_size_override("font_size", 14)
	_source_label.visible = false
	_vbox.add_child(_source_label)

	_drawn_label = Label.new()
	_drawn_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_drawn_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.9))
	_vbox.add_child(_drawn_label)

	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(280, 160)
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	_vbox.add_child(_scroll)

	var content = VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 4)
	_scroll.add_child(content)
	_scroll.set_meta("content", content)

	_sell_btn = Button.new()
	_sell_btn.text = "卖出"
	_sell_btn.custom_minimum_size = Vector2(280, 40)
	_sell_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_sell_btn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.3))
	_sell_btn.pressed.connect(func(): sell_selected.emit())
	_sell_btn.visible = false
	_vbox.add_child(_sell_btn)

	_cancel_btn = Button.new()
	_cancel_btn.text = "不设置（弃置抽到的牌）"
	_cancel_btn.custom_minimum_size = Vector2(280, 40)
	_cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_cancel_btn.pressed.connect(func(): cancelled.emit())
	_vbox.add_child(_cancel_btn)


func _refresh() -> void:
	if not _vbox:
		return
	# 抽到的牌名
	var drawn_name: String = "？"
	if _context != null and _context.get("game_state") != null:
		var c = _context.game_state.get_card(_drawn_card_id)
		if c != null and c.def != null:
			drawn_name = String(c.def.display_name)
	_drawn_label.text = "抽到：%s\n选择要设置到的区域%s" % [drawn_name, "\n或选择卖出" if _allow_sell else ""]
	if _sell_btn:
		_sell_btn.visible = _allow_sell
		_sell_btn.text = "卖出（+%d 金币）" % _sell_price

	var content = _scroll.get_meta("content") if _scroll.has_meta("content") else null
	if content == null:
		return
	for child in content.get_children():
		child.queue_free()
	for slot_id in _valid_slots:
		var btn = Button.new()
		var slot_display: String = SLOT_NAMES.get(slot_id, String(slot_id))
		# 显示当前槽位装备（占用则提示将替换）
		var cur_text: String = "空"
		if _context != null and _context.get("game_state") != null and _mech_id != &"":
			var mch = _context.game_state.mechs.get(_mech_id)
			if mch != null and mch.slots.has(slot_id):
				var sl = mch.slots[slot_id]
				if sl != null and sl.get("equipped_card") != null and sl.equipped_card.def != null:
					cur_text = "占用: %s（将替换）" % String(sl.equipped_card.def.display_name)
		btn.text = "设置到 %s（%s）" % [slot_display, cur_text]
		btn.custom_minimum_size = Vector2(300, 36)
		btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		btn.add_theme_color_override("font_color", Color(0.7, 0.85, 0.5))
		var sid: StringName = slot_id
		btn.pressed.connect(func(): slot_selected.emit(sid))
		content.add_child(btn)
