## DamageAdjustPanel.gd — 损伤调整面板（薇尔 pilot_059 回合开始）
##
## 让我方在回合开始时选择「移除1损伤」或「设置1损伤」（仅1次机会，也可取消）。
## 每个槽位同时显示 +1 与 -1 按钮：+1 走标准放置规则（优先有装备牌的区域，由
## DamageTokenService.get_valid_damage_slots 限定可选槽位），-1 需该槽位已有损伤。
## 点任意一次即完成关闭并 emit 信号；面板自身不修改状态（resume_effect 双端锁步由
## TimingEngine handler 应用），只负责收集选择。取消 emit adjust_cancelled。
extends PanelContainer
class_name DamageAdjustPanel

## 面板背景样式（深色不透明 + 金色描边，与损伤放置面板一致）
const _BG_STYLE := {
	"bg_color": Color(0.08, 0.09, 0.12, 0.96),
	"border_width": 2,
	"border_color": Color(0.85, 0.75, 0.3, 0.9),
	"corner_radius": 6,
	"content_margin": 12,
}

## 玩家选择完成：slot_id + is_set（true=设置1损伤，false=移除1损伤）
signal adjust_chosen(slot_id: StringName, is_set: bool)
## 玩家取消调整（不设置也不移除）
signal adjust_cancelled()

## 槽位显示顺序
const SLOT_ORDER: Array[StringName] = [
	&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿",
	&"weapon_1", &"weapon_2", &"reserve_1", &"reserve_2",
	&"event_1", &"pilot_1",
]

## 槽位中文显示名
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿", &"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2", &"event_1": "事件", &"pilot_1": "机师",
}

## 当前 GameContext 引用
var _context = null  # type: GameContext
## 目标机甲 ID
var _target_mech_id: StringName = &""
## 来源标签（"牌名：效果描述"，可空）
var _source_text: String = ""


## 配置面板
func configure(game_context, target_mech_id: StringName, source_label: String = "") -> void:
	_context = game_context
	_target_mech_id = target_mech_id
	_source_text = source_label
	_ensure_styled()
	_refresh()


## 确保面板背景样式已应用（深色不透明 + 金色描边，战场上清晰可读）
func _ensure_styled() -> void:
	custom_minimum_size = Vector2(400, 0)
	var style = StyleBoxFlat.new()
	style.bg_color = _BG_STYLE.bg_color
	style.set_border_width_all(_BG_STYLE.border_width)
	style.border_color = _BG_STYLE.border_color
	style.set_corner_radius_all(_BG_STYLE.corner_radius)
	style.set_content_margin_all(_BG_STYLE.content_margin)
	add_theme_stylebox_override("panel", style)


## 刷新面板显示
func _refresh() -> void:
	for child in get_children():
		child.queue_free()

	if not _context:
		return

	var gs = _context.game_state
	var mech: MechState = gs.mechs.get(_target_mech_id)
	if not mech:
		return

	var vbox = VBoxContainer.new()
	vbox.name = "DamageAdjustContent"
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	# +1 可选槽位：标准放置规则（有装备牌区域优先；有装备槽位存在时空槽不可选）
	var set_slots: Array[StringName] = []
	if _context.damage_token_service:
		set_slots = _context.damage_token_service.get_valid_damage_slots(_target_mech_id)

	# 标题
	var title = Label.new()
	title.text = "── 调整损伤（可移除或设置1损伤，仅1次机会）──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	# 来源标签（效果来源，可空）
	if _source_text != "":
		var src_label = Label.new()
		src_label.text = _source_text
		src_label.add_theme_color_override("font_color", Color(0.95, 0.82, 0.45))
		src_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		src_label.add_theme_font_size_override("font_size", 14)
		vbox.add_child(src_label)

	# 目标机甲名称
	var mech_name = Label.new()
	mech_name.text = "目标: %s" % (mech.frame_def.display_name if mech.frame_def else String(_target_mech_id))
	mech_name.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(mech_name)

	# 提示：+1 优先放有装备牌区域
	var hint = Label.new()
	hint.text = "+1 优先放置于有装备牌的区域"
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.add_theme_color_override("font_color", Color(0.6, 0.65, 0.7))
	hint.add_theme_font_size_override("font_size", 13)
	vbox.add_child(hint)

	# 每个槽位一行：名称 + 装备信息 + [+1] [-1]
	for slot_id: StringName in SLOT_ORDER:
		if not mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = mech.slots[slot_id]
		var can_set: bool = slot_id in set_slots
		var can_remove: bool = (slot.region_damage_tokens > 0) or (slot.equipped_card != null and slot.equipped_card.damage_tokens > 0)
		_add_slot_row(vbox, slot_id, slot, can_set, can_remove)

	# 取消按钮
	var cancel_btn = Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(120, 28)
	cancel_btn.pressed.connect(func(): adjust_cancelled.emit())
	cancel_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	vbox.add_child(cancel_btn)


## 添加一个槽位行：名称 + 装备信息 + [+1] [-1] 按钮
func _add_slot_row(parent: Control, slot_id: StringName, slot: MechSlotState, can_set: bool, can_remove: bool) -> void:
	var hbox = HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 8)

	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_id, String(slot_id))
	name_label.custom_minimum_size = Vector2(50, 0)
	hbox.add_child(name_label)

	var info_label = Label.new()
	if slot.equipped_card:
		var card_name: String = slot.equipped_card.def.display_name if slot.equipped_card.def else "?"
		var dmg: int = slot.equipped_card.damage_tokens
		var dur: int = slot.get_equipment_durability()
		info_label.text = "%s 损伤:%d/%d" % [card_name, dmg, dur]
	else:
		info_label.text = "（空）损伤:%d" % slot.region_damage_tokens
	info_label.custom_minimum_size = Vector2(160, 0)
	info_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_child(info_label)

	var minus_btn = Button.new()
	minus_btn.text = "-1"
	minus_btn.custom_minimum_size = Vector2(45, 28)
	minus_btn.disabled = not can_remove
	minus_btn.pressed.connect(func(): adjust_chosen.emit(slot_id, false))
	hbox.add_child(minus_btn)

	var plus_btn = Button.new()
	plus_btn.text = "+1"
	plus_btn.custom_minimum_size = Vector2(45, 28)
	plus_btn.disabled = not can_set
	plus_btn.pressed.connect(func(): adjust_chosen.emit(slot_id, true))
	hbox.add_child(plus_btn)

	parent.add_child(hbox)
