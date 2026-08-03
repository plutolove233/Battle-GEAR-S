## EquipmentPanel.gd — 机甲装备面板
##
## 显示机甲的所有槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位显示装备名、护甲/动力数值、损伤/耐久。
extends VBoxContainer
class_name EquipmentPanel

const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")

## 备用区设置按钮被点击（参数：备用区槽位ID，如"reserve_1"）
signal reserve_set_clicked(slot_id: StringName)

## 装备主动效果"发动"按钮被点击（参数：来源牌实例ID, 效果ID）
signal equipment_active_clicked(card_instance_id: StringName, effect_id: StringName)

## 「详情」按钮被点击（参数：当前机甲 MechState）——打开机甲详细信息框
signal mech_detail_requested(mech)

## 当前机甲引用
var _mech = null  # type: MechState

## 是否是敌方机甲（用于决定是否显示背面信息）
var _is_enemy: bool = false

## GameContext 引用（用于扫描装备 DIRECT 主动效果，仅玩家面板注入）
var _context = null

## 装备悬停效果浮框（鼠标移到框架装备上时显示效果文本/数值/绑定效果）
var _tooltip_popup: PanelContainer = null
var _tooltip_rich: RichTextLabel = null
var _hovered_card_cid: StringName = &""

## 槽位显示顺序
const SLOT_ORDER: Array[StringName] = [
	&"头部", &"躯干", &"右臂", &"左臂", &"右腿", &"左腿",
	&"weapon_1", &"weapon_2",
	&"reserve_1", &"reserve_2",
	&"event", &"pilot",
]

## 槽位中文名映射
const SLOT_NAMES: Dictionary = {
	&"头部": "头部", &"躯干": "躯干", &"右臂": "右臂", &"左臂": "左臂",
	&"右腿": "右腿", &"左腿": "左腿",
	&"weapon_1": "武器1", &"weapon_2": "武器2",
	&"reserve_1": "备用1", &"reserve_2": "备用2",
	&"event": "事件", &"pilot": "机师",
}


## 配置面板
## mech: 机甲状态
## is_enemy: 是否是敌方机甲（用于决定是否显示背面信息）
## game_context: 可选，注入后显示该机甲装备的 DIRECT 主动效果"发动"按钮
func configure(mech, is_enemy: bool = false, game_context = null) -> void:
	_mech = mech
	_is_enemy = is_enemy
	_context = game_context
	_refresh()


func _ready() -> void:
	# _process 仅在悬停浮框可见时启用，初始关闭避免每帧空跑
	set_process(false)


## 刷新装备显示
func _refresh() -> void:
	_hide_tooltip()
	for child in get_children():
		child.queue_free()

	if not _mech:
		return

	# 标题 + 详情按钮（仅注入了 context 的面板显示：主面板有，敌方信息弹窗内无）
	var title_row := HBoxContainer.new()
	var title := Label.new()
	title.text = "── 装备面板 ──"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_row.add_child(title)
	if _mech != null and _context != null:
		var detail_btn := Button.new()
		detail_btn.text = "详情"
		detail_btn.custom_minimum_size = Vector2(46, 24)
		detail_btn.tooltip_text = "查看机甲动力/护甲来源明细与状态"
		detail_btn.pressed.connect(func(): mech_detail_requested.emit(_mech))
		title_row.add_child(detail_btn)
	add_child(title_row)

	# 生命/动力摘要
	var summary = Label.new()
	summary.text = "HP: %d/%d  动力: %d  护甲: %d" % [
		_mech.current_hp, _mech.max_hp,
		_mech.power, _mech.get_armor()
	]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(summary)

	# 基础武器信息不再单列一行：武器槽（weapon_1/weapon_2）为空时
	# 已在 _add_slot_row 中显示基础武器名与威/射，无需重复。
	# 本机甲装备主动效果索引：card_instance_id -> Array[Dictionary{effect, bind_ctx}]
	# 仅在 _refresh 内构建一次，供各槽位行查询自己该挂哪些「触发」按钮，
	# 避免每个槽位行都重复扫描、把同一按钮挂到所有槽位上。
	var _active_by_card: Dictionary = {}
	if not _is_enemy and _context != null and _context.get("timing_engine") != null:
		var _TC = preload("res://scripts/action_core/TimingConst.gd")
		for timing: StringName in _context.timing_engine.permanent_listeners:
			var entries: Array = _context.timing_engine.permanent_listeners[timing]
			for entry in entries:
				if entry == null or not (entry is Dictionary):
					continue
				var eff = entry.get("effect")
				if eff == null or eff.mode != _TC.MODE_DIRECT:
					continue
				# 跳过 actions 为空的 DIRECT 占位效果（001卖出权限、002/008/014/016/021派生值实时重算、023无效果）
				# 这些没有可执行的主动动作，不该挂「触发」按钮（点了也没反应）。
				if eff.actions == null or eff.actions.is_empty():
					continue
				var bind_ctx: Dictionary = entry.get("binding_context", {})
				if String(bind_ctx.get("mech_id", &"")) != String(_mech.mech_id):
					continue
				var cid: StringName = bind_ctx.get("card_instance_id", &"")
				if cid == &"":
					continue
				if not _active_by_card.has(cid):
					_active_by_card[cid] = []
				_active_by_card[cid].append({"effect": eff, "bind_ctx": bind_ctx})

	# 各槽位
	for slot_id: StringName in SLOT_ORDER:
		if not _mech.slots.has(slot_id):
			continue
		var slot: MechSlotState = _mech.slots[slot_id]
		_add_slot_row(slot_id, slot, _active_by_card)


## 添加单行槽位显示
## active_by_card: card_instance_id -> Array[Dictionary{effect, bind_ctx}]，
## 本槽位 equipped_card 命中的主动效果会在此行内挂「触发」按钮。
func _add_slot_row(slot_id: StringName, slot, active_by_card: Dictionary = {}) -> void:
	var hbox = HBoxContainer.new()

	# 槽位名
	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_id, String(slot_id))
	name_label.custom_minimum_size = Vector2(50, 24)
	hbox.add_child(name_label)

	# 装备名
	var equip_label = Label.new()
	if slot.equipped_card and slot.equipped_card.def:
		equip_label.text = slot.equipped_card.def.display_name
		# 附加数值信息
		if slot.equipped_card.def is _EquipmentCardDef:
			var eq_def = slot.equipped_card.def
			if eq_def.equipment_kind == &"PART":
				equip_label.text += " [甲%d 动%d]" % [eq_def.armor, eq_def.power]
			elif eq_def.equipment_kind == &"WEAPON":
				equip_label.text += " [威%d 射%d]" % [eq_def.might, eq_def.range_value]
	elif slot_id == &"weapon_1" or slot_id == &"weapon_2":
		# 武器槽位为空时显示基础武器信息
		var slot_index: int = 0 if slot_id == &"weapon_1" else 1
		var base_weapon = _mech.get_base_weapon(slot_index)
		if not base_weapon.is_empty():
			equip_label.text = "%s [威:%d 射:%d](空)" % [
				base_weapon.get("name", "基础武器"),
				base_weapon.get("might", 0),
				base_weapon.get("range_value", 1),
			]
			equip_label.add_theme_color_override("font_color", Color.CYAN)
		else:
			equip_label.text = "（空）"
	elif slot_id == &"reserve_1" or slot_id == &"reserve_2":
		# 备用区：对我方显示背面信息，对敌人显示"备用 未知"
		if slot.equipped_card and slot.equipped_card.def is _EquipmentCardDef:
			if _is_enemy:
				# 敌方：显示"备用 未知"
				equip_label.text = "备用 未知"
				equip_label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))
			else:
				# 我方：显示"备用 XXX"
				equip_label.text = "备用 %s" % slot.equipped_card.def.display_name
				equip_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
		else:
			equip_label.text = "（空）"
	else:
		equip_label.text = "（空）"
	equip_label.custom_minimum_size = Vector2(100, 20)
	hbox.add_child(equip_label)

	# 损伤/耐久
	var damage_label = Label.new()
	if slot.equipped_card and slot.equipped_card.def is _EquipmentCardDef:
		var durability: int = slot.equipped_card.def.durability
		var card_dmg: int = slot.equipped_card.damage_tokens
		# 备用区特殊规则：装备耐久视为1
		if slot.slot_kind == &"RESERVE":
			durability = 1
		damage_label.text = "损伤:%d/%d" % [card_dmg, durability]
		if card_dmg >= durability:
			damage_label.add_theme_color_override("font_color", Color.RED)
		elif card_dmg > 0:
			damage_label.add_theme_color_override("font_color", Color.YELLOW)
	elif slot.region_damage_tokens > 0:
		damage_label.text = "区域损伤:%d" % slot.region_damage_tokens
		damage_label.add_theme_color_override("font_color", Color.YELLOW)
	else:
		damage_label.text = ""
	damage_label.custom_minimum_size = Vector2(70, 20)
	hbox.add_child(damage_label)

	# 有效护甲和动力（部件槽位）
	if slot.slot_kind == &"PART":
		var armor_label = Label.new()
		armor_label.text = "甲:%d" % slot.get_effective_armor(_mech)
		armor_label.custom_minimum_size = Vector2(35, 20)
		hbox.add_child(armor_label)

		var power_label = Label.new()
		power_label.text = "动:%d" % slot.get_effective_power()
		power_label.custom_minimum_size = Vector2(35, 20)
		hbox.add_child(power_label)

	# 武器槽位显示基础武器的耐久（固定1）
	if (slot_id == &"weapon_1" or slot_id == &"weapon_2") and not slot.equipped_card:
		var base_weapon = _mech.get_base_weapon(0 if slot_id == &"weapon_1" else 1)
		if not base_weapon.is_empty():
			damage_label.text = "（基础武器）"
			damage_label.add_theme_color_override("font_color", Color.CYAN)

	# 备用区设置按钮（仅在我方且有装备时显示）
	if (slot_id == &"reserve_1" or slot_id == &"reserve_2") and not _is_enemy:
		if slot.equipped_card != null:
			var set_btn = Button.new()
			set_btn.text = "设置"
			set_btn.custom_minimum_size = Vector2(40, 20)
			var captured_slot_id = slot_id
			set_btn.pressed.connect(func(): reserve_set_clicked.emit(captured_slot_id))
			hbox.add_child(set_btn)

	# 装备主动效果「触发」按钮：仅挂在该效果来源装备所在的槽位行内，
	# 按 equipped_card.instance_id 查 active_by_card 命中（仅玩家面板、有 context 时）。
	if not _is_enemy and slot.equipped_card != null and not active_by_card.is_empty():
		var inst_id: StringName = slot.equipped_card.instance_id
		if active_by_card.has(inst_id):
			for item: Dictionary in active_by_card[inst_id]:
				var eff = item.get("effect")
				var bind_ctx: Dictionary = item.get("bind_ctx", {})
				var btn = Button.new()
				btn.text = "触发"
				btn.tooltip_text = eff.description
				# 与备用区「设置」按钮同尺寸，避免撑满屏幕；效果详情靠悬停浮框显示
				btn.custom_minimum_size = Vector2(40, 20)
				# 按条件/每回合1次置灰：不满足（如帝国腿未移动8格）或已用满时 disabled，
				# 避免点了才被 effect_fire 静默跳过（"点了没反应"）。
				var can_trigger: bool = false
				if _context != null and _context.get("timing_engine") != null:
					can_trigger = _context.timing_engine.can_trigger_active_effect(eff, bind_ctx)
				btn.disabled = not can_trigger
				btn.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7) if can_trigger else Color(0.5, 0.5, 0.5))
				var cid: StringName = bind_ctx.get("card_instance_id", &"")
				var eid: StringName = eff.effect_id
				btn.pressed.connect(func(): equipment_active_clicked.emit(cid, eid))
				hbox.add_child(btn)

	# 悬停效果浮框：有装备牌且非「敌方备用区（隐藏信息）」时，整行可悬停查看效果
	if slot.equipped_card != null and not (_is_enemy and slot.slot_kind == &"RESERVE"):
		hbox.mouse_filter = Control.MOUSE_FILTER_STOP
		# Labels 设 IGNORE 让 HBox 成为整行的顶层命中控件，接收 mouse_entered/exited
		for c in hbox.get_children():
			if c is Label:
				c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var captured_slot = slot
		var captured_cid: StringName = slot.equipped_card.instance_id
		hbox.mouse_entered.connect(func(): _on_equipment_hover_entered(captured_slot, captured_cid))
		hbox.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))

	add_child(hbox)


# ═══════════════════════════════════════════
# 装备悬停效果浮框
# ═══════════════════════════════════════════


func _on_equipment_hover_entered(slot, cid: StringName) -> void:
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return
	_hovered_card_cid = cid
	_ensure_tooltip()
	_tooltip_rich.text = _build_tooltip_bbcode(slot, cid)
	_tooltip_popup.visible = true
	_tooltip_popup.reset_size()
	set_process(true)


func _on_equipment_hover_exited() -> void:
	_hide_tooltip()


func _hide_tooltip() -> void:
	_hovered_card_cid = &""
	if _tooltip_popup != null and is_instance_valid(_tooltip_popup):
		_tooltip_popup.visible = false
	set_process(false)


func _process(_delta: float) -> void:
	if _tooltip_popup == null or not is_instance_valid(_tooltip_popup) or not _tooltip_popup.visible:
		set_process(false)
		return
	var vp_size := get_viewport_rect().size
	var mouse_pos := get_global_mouse_position()
	var pos := mouse_pos + Vector2(16, 16)
	var sz := _tooltip_popup.size
	if pos.x + sz.x > vp_size.x:
		pos.x = mouse_pos.x - sz.x - 16
	if pos.y + sz.y > vp_size.y:
		pos.y = vp_size.y - sz.y - 4
	_tooltip_popup.set_position(pos)


func _ensure_tooltip() -> void:
	if _tooltip_popup != null and is_instance_valid(_tooltip_popup):
		return
	_tooltip_popup = PanelContainer.new()
	_tooltip_popup.set_as_top_level(true)
	_tooltip_popup.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_popup.visible = false
	_tooltip_popup.add_theme_stylebox_override("panel", _make_tooltip_stylebox())
	_tooltip_rich = RichTextLabel.new()
	_tooltip_rich.bbcode_enabled = true
	_tooltip_rich.fit_content = true
	_tooltip_rich.custom_minimum_size = Vector2(280, 0)
	_tooltip_rich.add_theme_font_size_override("normal_font_size", 13)
	_tooltip_rich.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_tooltip_popup.add_child(_tooltip_rich)
	add_child(_tooltip_popup)


func _make_tooltip_stylebox() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.12, 0.96)
	sb.border_color = Color(0.4, 0.5, 0.7, 0.9)
	sb.set_border_width_all(1)
	sb.set_content_margin_all(8)
	return sb


## 武器当前状态详情（用于 tooltip）：有效威力/范围 + 修正来源 + 聚能层数与理论加成。
## 聚能加成（威力+delta*stacks）只在攻击时触发，此处仅告知玩家理论上限。
func _weapon_status_bbcode(slot, cid: StringName) -> String:
	if slot == null or slot.equipped_card == null:
		return ""
	var card = slot.equipped_card
	var stats: Dictionary = _GenEquipEffects.get_effective_weapon_stats(card)
	var might_e: int = int(stats.get("might", 0))
	var range_e: int = int(stats.get("range_value", 0))
	var lines: Array = []
	lines.append("[color=#8cf]当前 威%d 射%d[/color]" % [might_e, range_e])
	# 修正来源（聚能 effect_093/095 临时+范围/威力、其他 might/range_modifiers、形态）
	var mods: Array = []
	if "might_modifiers" in card and card.might_modifiers is Array:
		for m in card.might_modifiers:
			if m is Dictionary:
				mods.append("威%+d" % int(m.get("delta", 0)))
	if "range_modifiers" in card and card.range_modifiers is Array:
		for m in card.range_modifiers:
			if m is Dictionary:
				mods.append("射%+d" % int(m.get("delta", 0)))
	var mode: StringName = card.weapon_mode if "weapon_mode" in card else &""
	if String(mode) == "extended":
		mods.append("形态:威-5射+2")
	if not mods.is_empty():
		lines.append("[color=#9c9]修正：%s[/color]" % " ".join(mods))
	# 聚能状态（按 weapon_id=该牌实例 匹配，每张武器牌独立）
	if _mech != null and _mech.statuses is Array:
		var stacks := 0
		var delta := 4
		for s in _mech.statuses:
			if s is Dictionary and s.get("type", &"") == &"ENERGY_CHARGE" and String(s.get("weapon_id", &"")) == String(cid):
				stacks = int(s.get("stacks", 1))
				delta = int(s.get("delta", 4))
				break
		if stacks > 0:
			lines.append("[color=#fc6]聚能 %d层（攻击时威力+%d）[/color]" % [stacks, delta * stacks])
	if lines.size() <= 1:
		return ""
	return "\n".join(lines)


func _build_tooltip_bbcode(slot, cid: StringName) -> String:
	if slot == null or slot.equipped_card == null or slot.equipped_card.def == null:
		return ""
	var def = slot.equipped_card.def
	var lines: Array = []
	# 标题：牌名 [稀有度]
	lines.append("[color=#ffd][b]%s[/b][/color] [color=#aaa][%s][/color]" % [def.display_name, String(def.rarity)])
	# 数值
	var stats: Array = []
	if def is _EquipmentCardDef:
		var eq = def
		if eq.equipment_kind == &"PART":
			stats.append("甲%d" % eq.armor)
			stats.append("动%d" % eq.power)
			stats.append("耐久%d" % eq.durability)
			stats.append("部件·%s" % SLOT_NAMES.get(slot.slot_id, String(slot.slot_id)))
		elif eq.equipment_kind == &"WEAPON":
			stats.append("威%d" % eq.might)
			stats.append("射%d" % eq.range_value)
			if String(eq.weapon_kind) != "":
				stats.append(String(eq.weapon_kind))
			stats.append("耐久%d" % eq.durability)
			stats.append("武器")
	if not stats.is_empty():
		lines.append("[color=#9cf]%s[/color]" % " ".join(stats))
	# 武器状态详情：当前有效威力/范围 + 修正来源 + 聚能层数（理论加成）
	if def is _EquipmentCardDef and def.equipment_kind == &"WEAPON":
		var wstat := _weapon_status_bbcode(slot, cid)
		if wstat != "":
			lines.append(wstat)
	# 损伤/耐久
	if def is _EquipmentCardDef:
		var dur: int = def.durability
		if slot.slot_kind == &"RESERVE":
			dur = 1
		var dmg: int = slot.equipped_card.damage_tokens
		var dmg_color := "#9a9" if dmg == 0 else ("yellow" if dmg < dur else "red")
		lines.append("[color=%s]损伤 %d/%d[/color]" % [dmg_color, dmg, dur])
	# 效果文本（牌面印刷）
	if def.effect_text.strip_edges() != "":
		lines.append("[color=#ccc]效果：[/color]")
		lines.append(def.effect_text)
	# 绑定效果（实现层 ActionEffect）
	var bound := _collect_bound_effects(cid)
	if not bound.is_empty():
		lines.append("[color=#ccc]绑定效果：[/color]")
		for b in bound:
			var mode_text := _mode_text(String(b.get("mode", "")))
			var bdesc: String = String(b.get("description", ""))
			if bdesc.strip_edges() == "":
				bdesc = String(b.get("display_name", ""))
			lines.append("• [color=#bdf]%s[/color]: %s [color=#888](%s)[/color]" % [String(b.get("effect_id", "")), bdesc, mode_text])
	return "\n".join(lines)


## 扫描 timing_engine.permanent_listeners，收集该装备牌绑定的所有 ActionEffect（DIRECT/LISTEN/AVAILABILITY）
func _collect_bound_effects(cid: StringName) -> Array:
	var result: Array = []
	if _context == null or _context.get("timing_engine") == null:
		return result
	var seen: Dictionary = {}
	for timing: StringName in _context.timing_engine.permanent_listeners:
		var entries: Array = _context.timing_engine.permanent_listeners[timing]
		for entry in entries:
			if entry == null or not (entry is Dictionary):
				continue
			var bc: Dictionary = entry.get("binding_context", {})
			if String(bc.get("card_instance_id", &"")) != String(cid):
				continue
			var eff = entry.get("effect")
			if eff == null:
				continue
			if seen.has(eff.effect_id):
				continue
			seen[eff.effect_id] = true
			result.append({
				"effect_id": eff.effect_id,
				"display_name": eff.display_name,
				"description": eff.description,
				"mode": eff.mode,
			})
	return result


func _mode_text(mode: String) -> String:
	match mode:
		"DIRECT": return "主动"
		"LISTEN": return "被动"
		"AVAILABILITY": return "响应"
	return mode
