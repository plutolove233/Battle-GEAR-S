## DevModePanel.gd — 开发者模式面板
##
## 提供卡牌和属性修改的调试UI。
## 直接操作 GameContext/GameState，不依赖额外的 DevModeService。
class_name DevModePanel
extends Control

const _CardInstance = preload("res://scripts/runtime/CardInstance.gd")

## 引用
var context: GameContext = null

## UI元素
var player_dropdown: OptionButton
var action_card_dropdown: OptionButton
var equipment_card_dropdown: OptionButton
var slot_dropdown: OptionButton
var damage_slot_dropdown: OptionButton
var pilot_dropdown: OptionButton
var pilot_info_label: Label
var attack_limit_spin: SpinBox
var action_limit_spin: SpinBox
var gold_spin: SpinBox

var action_cards_label: Label
var equipment_label: Label
var mech_info_label: Label

## 滚动容器引用（刷新内容后强制重算滚动范围用）
var _scroll: ScrollContainer = null

## 当前选中的玩家
var current_player_id: StringName = &""
## 防止刷新玩家下拉时 select() → item_selected → _refresh_all 递归
var _refreshing_player_list: bool = false
## 行动牌/装备牌下拉内容仅依赖 card_database（静态），只构建一次；context 变化时重建
var _card_lists_built: bool = false
var _built_context = null

## PvP client 模式：true 时不本地改 state，而是 emit dev_edit_requested 让 app_root 转发 intent 给 host
var network_mode: bool = false
## dev 编辑请求（client 模式）：op + params（含 target 玩家）
signal dev_edit_requested(op: StringName, params: Dictionary)
## 本地（非 PvP）编辑已应用：app_root 据此刷新主战斗 UI。
## PvP 走 _net_exec(dev_edit) 已在双端 _refresh_battle，network_mode=true 时各 handler 提前 return 不会 emit 本信号。
signal edit_applied()

## 颜色
const COLOR_ACTION = Color(0.2, 0.6, 1.0)
const COLOR_EQUIP = Color(1.0, 0.6, 0.2)
const COLOR_DANGER = Color(1.0, 0.3, 0.3)
const COLOR_SUCCESS = Color(0.3, 0.9, 0.4)

## 信号：关闭面板
signal close_requested


func _ready() -> void:
	visible = false
	_setup_ui()


func _setup_ui() -> void:
	# 半透明背景
	var bg := ColorRect.new()
	bg.color = Color(0.0, 0.0, 0.0, 0.75)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	# 主容器 — 占满全屏，内容由 ScrollContainer 裁剪
	var main_vbox := VBoxContainer.new()
	main_vbox.anchor_left = 0.0
	main_vbox.anchor_top = 0.0
	main_vbox.anchor_right = 1.0
	main_vbox.anchor_bottom = 1.0
	main_vbox.offset_top = 8
	main_vbox.offset_bottom = -8
	main_vbox.offset_left = 8
	main_vbox.offset_right = -8
	main_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_vbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main_vbox.add_theme_constant_override("separation", 6)
	add_child(main_vbox)

	# ScrollContainer — 面板内容过长时可滚动
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	main_vbox.add_child(scroll)
	_scroll = scroll  # 存引用，供刷新内容后强制重算滚动范围

	# 外部 MarginContainer 限制宽度
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 32)
	margin.add_theme_constant_override("margin_right", 32)
	scroll.add_child(margin)

	# 内容区
	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 6)
	margin.add_child(content)

	# ── 标题行 + 关闭按钮 ──
	var header_hbox := HBoxContainer.new()
	content.add_child(header_hbox)

	var title := Label.new()
	title.text = "🔧 开发者模式"
	title.add_theme_font_size_override("font_size", 18)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header_hbox.add_child(title)

	var close_btn := Button.new()
	close_btn.text = "× 关闭"
	close_btn.custom_minimum_size = Vector2(80, 28)
	close_btn.pressed.connect(_on_close)
	header_hbox.add_child(close_btn)

	# ── 玩家选择 ──
	var player_hbox := HBoxContainer.new()
	content.add_child(player_hbox)
	var player_label := Label.new()
	player_label.text = "玩家: "
	player_hbox.add_child(player_label)
	player_dropdown = OptionButton.new()
	player_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	player_dropdown.item_selected.connect(_on_player_selected)
	player_hbox.add_child(player_dropdown)

	content.add_child(_create_separator())

	# === 行动牌部分 ===
	var action_section := _create_section("行动牌管理", COLOR_ACTION)
	content.add_child(action_section)

	var add_action_hbox := HBoxContainer.new()
	action_section.add_child(add_action_hbox)
	add_action_hbox.add_child(_make_label("添加: "))
	action_card_dropdown = OptionButton.new()
	action_card_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_action_hbox.add_child(action_card_dropdown)
	_color_dropdown(action_card_dropdown, COLOR_ACTION)
	var add_action_btn := Button.new()
	add_action_btn.text = "添加"
	add_action_btn.pressed.connect(_on_add_action_card)
	add_action_hbox.add_child(add_action_btn)

	var discard_action_hbox := HBoxContainer.new()
	action_section.add_child(discard_action_hbox)
	var discard_action_btn := Button.new()
	discard_action_btn.text = "弃置所有行动牌"
	discard_action_btn.pressed.connect(_on_discard_all_action_cards)
	discard_action_hbox.add_child(discard_action_btn)

	var discard_one_hbox := HBoxContainer.new()
	action_section.add_child(discard_one_hbox)
	var discard_one_btn := Button.new()
	discard_one_btn.text = "弃置手牌中第一张行动牌"
	discard_one_btn.pressed.connect(_on_discard_one_action_card)
	discard_one_hbox.add_child(discard_one_btn)

	action_cards_label = Label.new()
	action_cards_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	action_cards_label.custom_minimum_size.y = 50
	action_section.add_child(action_cards_label)

	content.add_child(_create_separator())

	# === 装备牌部分 ===
	var equip_section := _create_section("装备牌管理", COLOR_EQUIP)
	content.add_child(equip_section)

	var add_equip_hbox := HBoxContainer.new()
	equip_section.add_child(add_equip_hbox)
	add_equip_hbox.add_child(_make_label("添加: "))
	equipment_card_dropdown = OptionButton.new()
	equipment_card_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_equip_hbox.add_child(equipment_card_dropdown)
	_color_dropdown(equipment_card_dropdown, COLOR_EQUIP)
	var add_equip_btn := Button.new()
	add_equip_btn.text = "添加"
	add_equip_btn.pressed.connect(_on_add_equipment_card)
	add_equip_hbox.add_child(add_equip_btn)

	var set_slot_hbox := HBoxContainer.new()
	equip_section.add_child(set_slot_hbox)
	set_slot_hbox.add_child(_make_label("设置手牌第一张装备到槽位: "))
	slot_dropdown = OptionButton.new()
	slot_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	set_slot_hbox.add_child(slot_dropdown)
	_color_dropdown(slot_dropdown, COLOR_EQUIP)
	var set_slot_btn := Button.new()
	set_slot_btn.text = "设置"
	set_slot_btn.pressed.connect(_on_set_equipment_to_slot)
	set_slot_hbox.add_child(set_slot_btn)

	var discard_equip_section := HBoxContainer.new()
	equip_section.add_child(discard_equip_section)
	var discard_equip_btn := Button.new()
	discard_equip_btn.text = "弃置所有未设置装备牌"
	discard_equip_btn.pressed.connect(_on_discard_all_equipment_cards)
	discard_equip_section.add_child(discard_equip_btn)
	var unequip_all_btn := Button.new()
	unequip_all_btn.text = "卸下所有已设置装备"
	unequip_all_btn.pressed.connect(_on_unequip_all_equipment)
	discard_equip_section.add_child(unequip_all_btn)

	equipment_label = Label.new()
	equipment_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	equipment_label.custom_minimum_size.y = 70
	equip_section.add_child(equipment_label)

	content.add_child(_create_separator())

	# === 区域损伤部分 ===
	var damage_section := _create_section("区域损伤管理", COLOR_DANGER)
	content.add_child(damage_section)

	var damage_hbox := HBoxContainer.new()
	damage_section.add_child(damage_hbox)
	damage_hbox.add_child(_make_label("槽位: "))
	damage_slot_dropdown = OptionButton.new()
	damage_slot_dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	damage_slot_dropdown.name = "DamageSlotDropdown"
	damage_hbox.add_child(damage_slot_dropdown)
	_color_dropdown(damage_slot_dropdown, COLOR_DANGER)
	var add_damage_btn := Button.new()
	add_damage_btn.text = "+1"
	add_damage_btn.pressed.connect(_on_add_region_damage)
	damage_hbox.add_child(add_damage_btn)
	var remove_damage_btn := Button.new()
	remove_damage_btn.text = "-1"
	remove_damage_btn.pressed.connect(_on_remove_region_damage)
	damage_hbox.add_child(remove_damage_btn)

	var damage_all_hbox := HBoxContainer.new()
	damage_section.add_child(damage_all_hbox)
	var clear_damage_btn := Button.new()
	clear_damage_btn.text = "清除所有区域损伤"
	clear_damage_btn.pressed.connect(_on_clear_all_region_damage)
	damage_all_hbox.add_child(clear_damage_btn)

	content.add_child(_create_separator())

	# === 属性修改器部分 ===
	var modify_section := _create_section("属性修改器", COLOR_SUCCESS)
	content.add_child(modify_section)

	# HP修改
	var hp_hbox := HBoxContainer.new()
	modify_section.add_child(hp_hbox)
	hp_hbox.add_child(_make_label("生命值: "))
	var hp_minus_btn := Button.new()
	hp_minus_btn.text = "-10"
	hp_minus_btn.pressed.connect(func(): _on_modify_hp(-10))
	hp_hbox.add_child(hp_minus_btn)
	var hp_plus_btn := Button.new()
	hp_plus_btn.text = "+10"
	hp_plus_btn.pressed.connect(func(): _on_modify_hp(10))
	hp_hbox.add_child(hp_plus_btn)
	var hp_set_btn := Button.new()
	hp_set_btn.text = "满血"
	hp_set_btn.pressed.connect(_on_set_full_hp)
	hp_hbox.add_child(hp_set_btn)

	# 动力修改
	var power_hbox := HBoxContainer.new()
	modify_section.add_child(power_hbox)
	power_hbox.add_child(_make_label("动力: "))
	var power_minus_btn := Button.new()
	power_minus_btn.text = "-5"
	power_minus_btn.pressed.connect(func(): _on_modify_power(-5))
	power_hbox.add_child(power_minus_btn)
	var power_plus_btn := Button.new()
	power_plus_btn.text = "+5"
	power_plus_btn.pressed.connect(func(): _on_modify_power(5))
	power_hbox.add_child(power_plus_btn)
	var power_set_btn := Button.new()
	power_set_btn.text = "满动力"
	power_set_btn.pressed.connect(_on_set_full_power)
	power_hbox.add_child(power_set_btn)

	# 金币修改
	var gold_hbox := HBoxContainer.new()
	modify_section.add_child(gold_hbox)
	gold_hbox.add_child(_make_label("金币: "))
	var gold_minus_btn := Button.new()
	gold_minus_btn.text = "-10"
	gold_minus_btn.pressed.connect(func(): _on_modify_gold(-10))
	gold_hbox.add_child(gold_minus_btn)
	var gold_plus_btn := Button.new()
	gold_plus_btn.text = "+10"
	gold_plus_btn.pressed.connect(func(): _on_modify_gold(10))
	gold_hbox.add_child(gold_plus_btn)
	var gold_set_btn := Button.new()
	gold_set_btn.text = "设为50"
	gold_set_btn.pressed.connect(_on_set_gold_50)
	gold_hbox.add_child(gold_set_btn)

	# 护甲修改
	var armor_hbox := HBoxContainer.new()
	modify_section.add_child(armor_hbox)
	armor_hbox.add_child(_make_label("护甲(所有区域+1): "))
	var armor_plus_btn := Button.new()
	armor_plus_btn.text = "+1"
	armor_plus_btn.pressed.connect(func(): _on_modify_armor(1))
	armor_hbox.add_child(armor_plus_btn)
	var armor_minus_btn := Button.new()
	armor_minus_btn.text = "-1"
	armor_minus_btn.pressed.connect(func(): _on_modify_armor(-1))
	armor_hbox.add_child(armor_minus_btn)

	# 机甲信息显示
	mech_info_label = Label.new()
	mech_info_label.autowrap_mode = TextServer.AUTOWRAP_WORD
	mech_info_label.custom_minimum_size.y = 50
	modify_section.add_child(mech_info_label)

	# ── 机师管理区（换机师 + 修改攻击数/行动牌上限/金币）──
	var pilot_section := _create_section("机师管理", Color(0.6, 0.5, 1.0))
	content.add_child(pilot_section)

	# 换机师：下拉选机师 → change_pilot（走 set/unset_pilot，注销旧 listener + 建新牌）
	var change_hbox := HBoxContainer.new()
	pilot_section.add_child(change_hbox)
	change_hbox.add_child(_make_label("换机师: "))
	pilot_dropdown = OptionButton.new()
	pilot_dropdown.custom_minimum_size = Vector2(220, 30)
	change_hbox.add_child(pilot_dropdown)
	var change_btn := Button.new()
	change_btn.text = "换机师"
	change_btn.pressed.connect(_on_change_pilot)
	change_hbox.add_child(change_btn)
	# 显示当前机师
	pilot_info_label = Label.new()
	pilot_info_label.add_theme_font_size_override("font_size", 12)
	pilot_info_label.add_theme_color_override("font_color", Color(0.8, 0.8, 0.9))
	pilot_section.add_child(pilot_info_label)

	# 修改数值：攻击数/行动牌上限/金币（modify_player_limits，即时重算 max_attacks_per_turn）
	var limits_hbox := HBoxContainer.new()
	pilot_section.add_child(limits_hbox)
	limits_hbox.add_child(_make_label("攻击数: "))
	attack_limit_spin = SpinBox.new()
	attack_limit_spin.min_value = 0
	attack_limit_spin.max_value = 10
	attack_limit_spin.value = 1
	attack_limit_spin.custom_minimum_size = Vector2(60, 30)
	limits_hbox.add_child(attack_limit_spin)
	limits_hbox.add_child(_make_label("行动牌上限: "))
	action_limit_spin = SpinBox.new()
	action_limit_spin.min_value = 0
	action_limit_spin.max_value = 10
	action_limit_spin.value = 5
	action_limit_spin.custom_minimum_size = Vector2(60, 30)
	limits_hbox.add_child(action_limit_spin)
	limits_hbox.add_child(_make_label("金币: "))
	gold_spin = SpinBox.new()
	gold_spin.min_value = 0
	gold_spin.max_value = 999
	gold_spin.value = 0
	gold_spin.custom_minimum_size = Vector2(60, 30)
	limits_hbox.add_child(gold_spin)
	var limits_btn := Button.new()
	limits_btn.text = "应用"
	limits_btn.pressed.connect(_on_apply_limits)
	limits_hbox.add_child(limits_btn)


func _make_label(text: String) -> Label:
	var lbl := Label.new()
	lbl.text = text
	return lbl


## 给下拉框按钮文字上色（含 hover/pressed/focus 各态），使当前选中项在按钮上一眼可见。
func _color_dropdown(dropdown: OptionButton, color: Color) -> void:
	dropdown.add_theme_color_override("font_color", color)
	dropdown.add_theme_color_override("font_hover_color", color)
	dropdown.add_theme_color_override("font_pressed_color", color)
	dropdown.add_theme_color_override("font_focus_color", color)


## 取下拉框当前选中项的 metadata（clear 前调用以在重建后恢复选中）。
func _dropdown_selected_meta(dropdown: OptionButton) -> Variant:
	if dropdown == null or dropdown.item_count == 0:
		return null
	var idx := dropdown.get_selected_id()
	if idx < 0:
		return null
	return dropdown.get_item_metadata(idx)


func _create_section(title_text: String, color: Color) -> VBoxContainer:
	var section := VBoxContainer.new()
	section.add_theme_constant_override("separation", 4)

	var label := Label.new()
	label.text = title_text
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", 14)
	section.add_child(label)

	return section


func _create_separator() -> HSeparator:
	var sep := HSeparator.new()
	sep.add_theme_constant_override("separation", 4)
	return sep


func setup(p_context: GameContext) -> void:
	context = p_context
	_refresh_all()


# ═══════════════════════════════════════════
# 刷新UI方法
# ═══════════════════════════════════════════

func _refresh_all() -> void:
	# context 重建（如 PvP 换种子/新局）时，静态卡牌列表需重建
	if context != _built_context:
		_built_context = context
		_card_lists_built = false
	_refresh_player_list()
	# 行动牌/装备牌列表仅依赖 card_database（静态），每局只构建一次，避免每次刷新丢失选中
	if not _card_lists_built:
		_refresh_action_card_list()
		_refresh_equipment_card_list()
		_card_lists_built = true
	_refresh_slot_list()
	_refresh_pilot_list()
	_update_info_display()


func _gs() -> GameState:
	return context.game_state if context else null


func _current_player() -> PlayerState:
	var gs := _gs()
	if gs == null or current_player_id == &"":
		return null
	return gs.players.get(current_player_id)


func _current_mech() -> MechState:
	var gs := _gs()
	if gs == null or current_player_id == &"":
		return null
	return gs.get_mech_for_player(current_player_id)


func _refresh_player_list() -> void:
	_refreshing_player_list = true
	_refresh_player_list_impl()
	_refreshing_player_list = false


func _refresh_player_list_impl() -> void:
	player_dropdown.clear()
	var gs := _gs()
	if gs == null:
		return
	# 首次进入：默认选第一个玩家；否则保留当前已选玩家
	if current_player_id == &"" or not gs.players.has(current_player_id):
		current_player_id = gs.players.keys()[0] if not gs.players.is_empty() else &""
	var select_index := 0
	var index := 0
	for pid: StringName in gs.players:
		player_dropdown.add_item(String(pid), index)
		player_dropdown.set_item_metadata(index, pid)
		if pid == current_player_id:
			select_index = index
		index += 1
	if index > 0:
		# select() 在选中项变化时触发 item_selected → _on_player_selected → _refresh_all。
		# _refreshing_player_list 守卫让递归回调直接 return，避免无限递归。
		player_dropdown.select(select_index)


func _on_player_selected(_index: int) -> void:
	if _refreshing_player_list:
		return
	var metadata = player_dropdown.get_item_metadata(_index)
	if metadata != null and metadata != current_player_id:
		current_player_id = metadata
		_refresh_all()


func _refresh_action_card_list() -> void:
	var prev_meta: Variant = _dropdown_selected_meta(action_card_dropdown)
	action_card_dropdown.clear()
	if context == null or context.card_database == null:
		return
	var db = context.card_database
	var index := 0
	var select_index := 0
	for card_id: StringName in db.card_defs:
		var def = db.card_defs[card_id]
		if def == null:
			continue
		if def.card_kind == &"action":
			action_card_dropdown.add_item("%s [%s]" % [def.display_name, String(def.rarity)], index)
			action_card_dropdown.set_item_metadata(index, card_id)
			if card_id == prev_meta:
				select_index = index
			index += 1
	if index > 0:
		action_card_dropdown.select(select_index)


func _refresh_equipment_card_list() -> void:
	var prev_meta: Variant = _dropdown_selected_meta(equipment_card_dropdown)
	equipment_card_dropdown.clear()
	if context == null or context.card_database == null:
		return
	var db = context.card_database
	var index := 0
	var select_index := 0
	for card_id: StringName in db.card_defs:
		var def = db.card_defs[card_id]
		if def == null:
			continue
		if def.card_kind == &"equipment":
			var prefix := ""
			match def.equipment_kind:
				&"PART": prefix = "[部件] "
				&"WEAPON": prefix = "[武器] "
				_: prefix = "[装备] "
			equipment_card_dropdown.add_item("%s%s [%s]" % [prefix, def.display_name, String(def.rarity)], index)
			equipment_card_dropdown.set_item_metadata(index, card_id)
			if card_id == prev_meta:
				select_index = index
			index += 1
	if index > 0:
		equipment_card_dropdown.select(select_index)


func _refresh_slot_list() -> void:
	var prev_slot_meta: Variant = _dropdown_selected_meta(slot_dropdown)
	var prev_dmg_meta: Variant = _dropdown_selected_meta(damage_slot_dropdown)
	slot_dropdown.clear()
	if damage_slot_dropdown != null:
		damage_slot_dropdown.clear()

	var mech := _current_mech()
	if mech == null:
		return
	var index := 0
	var select_index := 0
	var select_dmg_index := 0
	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		var slot_name := String(slot_id)
		if slot.equipped_card and slot.equipped_card.def:
			slot_name += " (%s)" % slot.equipped_card.def.display_name
		slot_dropdown.add_item(slot_name, index)
		slot_dropdown.set_item_metadata(index, slot_id)
		if slot_id == prev_slot_meta:
			select_index = index
		if damage_slot_dropdown != null:
			damage_slot_dropdown.add_item("%s (损伤:%d)" % [String(slot_id), slot.region_damage_tokens], index)
			damage_slot_dropdown.set_item_metadata(index, slot_id)
			if slot_id == prev_dmg_meta:
				select_dmg_index = index
		index += 1
	if index > 0:
		slot_dropdown.select(select_index)
		if damage_slot_dropdown != null:
			damage_slot_dropdown.select(select_dmg_index)


## 刷新机师下拉：列出 card_database 所有 pilot 卡定义（card_def_id 作 metadata）。
func _refresh_pilot_list() -> void:
	if pilot_dropdown == null or context == null or context.card_database == null:
		return
	var prev_meta: Variant = _dropdown_selected_meta(pilot_dropdown)
	pilot_dropdown.clear()
	var index := 0
	var select_index := 0
	for card_id: StringName in context.card_database.card_defs:
		var def = context.card_database.card_defs[card_id]
		if def == null or def.card_kind != &"pilot":
			continue
		pilot_dropdown.add_item("%s [%s]" % [def.display_name, String(def.rarity)], index)
		pilot_dropdown.set_item_metadata(index, card_id)
		if card_id == prev_meta:
			select_index = index
		index += 1
	if index > 0:
		pilot_dropdown.select(select_index)


func _update_info_display() -> void:
	var gs := _gs()
	var player := _current_player()
	var mech := _current_mech()

	# ── 行动牌列表 ──
	if player and not player.action_hand.is_empty():
		var action_text := "行动牌 (%d张): " % player.action_hand.size()
		var names: Array[String] = []
		for card_id: StringName in player.action_hand:
			var card: CardInstance = gs.get_card(card_id) if gs else null
			if card and card.def:
				names.append(card.def.display_name)
			else:
				names.append(String(card_id))
		action_text += ", ".join(names)
		action_cards_label.text = action_text
	else:
		action_cards_label.text = "行动牌: 无"

	# ── 装备牌列表 ──
	var equip_lines: Array[String] = []
	if mech:
		for slot_id: StringName in mech.slots:
			var slot: MechSlotState = mech.slots[slot_id]
			if slot.equipped_card and slot.equipped_card.def:
				var def = slot.equipped_card.def
				# 按卡牌类型区分显示：装备(部件/武器)有 durability；机师/事件/行动牌无
				if def.card_kind == &"equipment":
					var durability: int = def.durability
					var sd_text := "损伤:%d/%d" % [slot.region_damage_tokens, durability]
					equip_lines.append("  [%s] %s %s" % [String(slot_id), def.display_name, sd_text])
				else:
					equip_lines.append("  [%s] %s (损伤:%d)" % [String(slot_id), def.display_name, slot.region_damage_tokens])
			else:
				equip_lines.append("  [%s] (空) 损伤:%d" % [String(slot_id), slot.region_damage_tokens])
		var hand_count := player.equipment_hand.size() if player else 0
		equip_lines.append("  手牌: %d张" % hand_count)
	else:
		equip_lines.append("  (无机甲)")
	equipment_label.text = "装备牌:\n%s" % "\n".join(equip_lines)

	# ── 机甲信息 ──
	if mech:
		var player_gold: int = player.gold if player else 0
		mech_info_label.text = "机甲: %s | HP: %d/%d | 动力: %d | 护甲: %d | 金币: %d | %s" % [
			String(current_player_id),
			mech.current_hp, mech.max_hp,
			mech.power,
			mech.get_armor(),
			player_gold,
			"已摧毁" if mech.destroyed else "存活"
		]
	else:
		mech_info_label.text = ""

	# ── 机师信息 ──
	if pilot_info_label != null:
		var pilot_text := "机师: 无"
		if mech:
			var pslot = mech.slots.get(&"pilot")
			if pslot != null and pslot.equipped_card != null and pslot.equipped_card.def != null:
				pilot_text = "机师: %s | 攻击 %d/%d | 行动牌上限 %d" % [
					pslot.equipped_card.def.display_name,
					mech.attack_count_this_turn, mech.max_attacks_per_turn,
					player.action_card_limit if player else 0
				]
		pilot_info_label.text = pilot_text

	# autowrap 长文本 label（装备/行动牌/机甲信息）内容变化后实际高度可能变，
	# ScrollContainer 的滚动范围未必同步刷新 -> 滚不到底。deferred 强制重算。
	if _scroll != null and is_instance_valid(_scroll):
		_scroll.update_minimum_size()


# ═══════════════════════════════════════════
# 行动牌操作
# ═══════════════════════════════════════════

func _on_add_action_card() -> void:
	var gs := _gs()
	var player := _current_player()
	if gs == null or player == null or context == null:
		return

	var index := action_card_dropdown.get_selected_id()
	if index < 0:
		return
	var card_id: StringName = action_card_dropdown.get_item_metadata(index)
	if card_id == &"":
		return
	if network_mode:
		dev_edit_requested.emit(&"add_action_card", {"target": current_player_id, "card_id": card_id})
		return
	var def = context.card_database.get_card(card_id)
	if def == null:
		return

	# 创建 CardInstance
	var inst := _CardInstance.new(gs.next_id("card"), def)
	inst.owner_player_id = current_player_id
	inst.mech_id = _current_mech().mech_id if _current_mech() else &""
	inst.zone = &"action_hand"
	gs.cards[inst.instance_id] = inst

	# 加入手牌
	player.action_hand.append(inst.instance_id)

	# 注册 AVAILABILITY 效果（迎击牌等）
	if context.has_method("register_hand_card_availability"):
		context.register_hand_card_availability(inst.instance_id)

	_update_info_display()
	edit_applied.emit()


func _on_discard_all_action_cards() -> void:
	var gs := _gs()
	var player := _current_player()
	if gs == null or player == null or context == null:
		return
	if network_mode:
		dev_edit_requested.emit(&"discard_all_action_cards", {"target": current_player_id})
		return
	for card_id: StringName in player.action_hand.duplicate():
		_do_discard_action_card(card_id, player)

	_update_info_display()
	edit_applied.emit()


func _on_discard_one_action_card() -> void:
	var gs := _gs()
	var player := _current_player()
	if gs == null or player == null or context == null:
		return
	if network_mode:
		dev_edit_requested.emit(&"discard_one_action_card", {"target": current_player_id})
		return
	if player.action_hand.is_empty():
		return
	_do_discard_action_card(player.action_hand[0], player)
	_update_info_display()
	edit_applied.emit()


func _do_discard_action_card(card_id: StringName, player: PlayerState) -> void:
	if context and context.has_method("unregister_hand_card_availability"):
		context.unregister_hand_card_availability(card_id)
	var card: CardInstance = _gs().get_card(card_id)
	if card:
		card.zone = &"discard"
	player.action_hand.erase(card_id)


# ═══════════════════════════════════════════
# 装备牌操作
# ═══════════════════════════════════════════

func _on_add_equipment_card() -> void:
	var gs := _gs()
	var player := _current_player()
	if gs == null or player == null or context == null:
		return

	var index := equipment_card_dropdown.get_selected_id()
	if index < 0:
		return
	var card_id: StringName = equipment_card_dropdown.get_item_metadata(index)
	if card_id == &"":
		return
	if network_mode:
		dev_edit_requested.emit(&"add_equipment_card", {"target": current_player_id, "card_id": card_id})
		return
	var def = context.card_database.get_card(card_id)
	if def == null:
		return

	# 创建 CardInstance
	var inst := _CardInstance.new(gs.next_id("card"), def)
	inst.owner_player_id = current_player_id
	inst.mech_id = _current_mech().mech_id if _current_mech() else &""
	inst.zone = &"equipment_hand"
	gs.cards[inst.instance_id] = inst

	# 加入装备手牌
	player.equipment_hand.append(inst.instance_id)

	_update_info_display()
	edit_applied.emit()


func _on_set_equipment_to_slot() -> void:
	var gs := _gs()
	var player := _current_player()
	var mech := _current_mech()
	if gs == null or player == null or mech == null or context == null:
		return

	# 获取下拉选中的装备牌定义（选哪张设哪张，不再固定取手牌第一张）
	var equip_index := equipment_card_dropdown.get_selected_id()
	if equip_index < 0:
		return
	var card_def_id: StringName = equipment_card_dropdown.get_item_metadata(equip_index)
	if card_def_id == &"":
		return
	var def = context.card_database.get_card(card_def_id)
	if def == null:
		return

	# 获取选中的槽位
	var slot_index := slot_dropdown.get_selected_id()
	if slot_index < 0:
		return
	var slot_id: StringName = slot_dropdown.get_item_metadata(slot_index)
	if slot_id == &"":
		return

	if network_mode:
		dev_edit_requested.emit(&"set_equipment_to_slot", {"target": current_player_id, "card_def_id": card_def_id, "slot_id": slot_id})
		return

	# 若该玩家手牌已有这张牌的实例，复用之；否则创建一个新实例加入手牌
	# （card_set_service.set_equipment 要求卡牌在玩家手牌中）
	var equip_card_id: StringName = &""
	for cid: StringName in player.equipment_hand:
		var c: CardInstance = gs.get_card(cid)
		if c and c.def and c.def.card_id == card_def_id:
			equip_card_id = cid
			break
	if equip_card_id == &"":
		var inst := _CardInstance.new(gs.next_id("card"), def)
		inst.owner_player_id = current_player_id
		inst.mech_id = mech.mech_id
		inst.zone = &"equipment_hand"
		gs.cards[inst.instance_id] = inst
		player.equipment_hand.append(inst.instance_id)
		equip_card_id = inst.instance_id

	# 调用 CardSetService 设置（handle slot compatibility, replacement, damage cleanup）
	if context.card_set_service:
		var result: Dictionary = context.card_set_service.set_equipment(current_player_id, equip_card_id, slot_id)
		if not result.get("ok", false):
			# 类型不匹配等：把刚创建的临时实例从手牌撤回，避免残留
			if player.equipment_hand.has(equip_card_id):
				player.equipment_hand.erase(equip_card_id)
				gs.cards.erase(equip_card_id)
		_update_info_display()
		return

	# fallback: 手动设置
	_manual_set_equipment(equip_card_id, slot_id)
	_update_info_display()
	edit_applied.emit()


func _manual_set_equipment(card_id: StringName, slot_id: StringName) -> void:
	var gs := _gs()
	var player := _current_player()
	var mech := _current_mech()
	if gs == null or player == null or mech == null:
		return

	if not mech.slots.has(slot_id):
		return
	var slot: MechSlotState = mech.slots[slot_id]
	var card: CardInstance = gs.get_card(card_id)
	if card == null:
		return

	# 简单类型检查
	if slot.slot_kind == &"WEAPON" and card.def.equipment_kind != &"WEAPON":
		return
	if slot.slot_kind == &"PART" and card.def.equipment_kind != &"PART":
		return

	# 替换已有装备
	if slot.equipped_card != null:
		context.deck_service.discard_card(slot.equipped_card.instance_id, &"replaced")
		slot.equipped_card = null

	# 移除耐久值对应的区域损伤
	var durability: int = card.def.durability
	if durability > 0:
		var to_remove := mini(durability, slot.region_damage_tokens)
		slot.region_damage_tokens -= to_remove

	player.equipment_hand.erase(card_id)
	card.zone = &"equipped"
	card.slot_id = slot_id
	card.mech_id = mech.mech_id
	slot.equipped_card = card

	# 新牌继承区域剩余损伤；损伤≥耐久立即损坏弃置（区域损伤保留）
	if slot.slot_kind != &"RESERVE":
		card.damage_tokens = slot.region_damage_tokens
		if durability > 0 and card.damage_tokens >= durability:
			context.deck_service.discard_card(card.instance_id, &"damage_durability")
			slot.equipped_card = null
			var _omp: int = mech.max_power
			mech.max_power = mech.get_total_power()
			mech.sync_own_power_after_max_change(_omp)


func _on_discard_all_equipment_cards() -> void:
	var gs := _gs()
	var player := _current_player()
	if gs == null or player == null or context == null:
		return
	if network_mode:
		dev_edit_requested.emit(&"discard_all_equipment_cards", {"target": current_player_id})
		return
	for card_id: StringName in player.equipment_hand.duplicate():
		context.deck_service.discard_card(card_id, &"dev_mode")
	player.equipment_hand.clear()
	_update_info_display()
	edit_applied.emit()


func _on_unequip_all_equipment() -> void:
	var gs := _gs()
	var mech := _current_mech()
	if gs == null or mech == null or context == null:
		return
	if network_mode:
		dev_edit_requested.emit(&"unequip_all_equipment", {"target": current_player_id})
		return
	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		if slot.equipped_card != null:
			context.deck_service.discard_card(slot.equipped_card.instance_id, &"replaced")
			slot.equipped_card = null
	_update_info_display()
	edit_applied.emit()


# ═══════════════════════════════════════════
# 区域损伤操作
# ═══════════════════════════════════════════

func _get_selected_damage_slot() -> MechSlotState:
	var slot_id := _get_selected_damage_slot_id()
	if slot_id == &"":
		return null
	var mech := _current_mech()
	if mech == null or not mech.slots.has(slot_id):
		return null
	return mech.slots[slot_id]


## 取损伤槽位下拉选中的 slot_id（network_mode emit 用）
func _get_selected_damage_slot_id() -> StringName:
	if damage_slot_dropdown == null:
		return &""
	var idx := damage_slot_dropdown.get_selected_id()
	if idx < 0:
		return &""
	var slot_id: StringName = damage_slot_dropdown.get_item_metadata(idx)
	return slot_id


## dev 模式直接调整区域损伤：同时改 region_damage_tokens 与装备卡 damage_tokens（双计，
## 与正常 DamageTokenService 一致），使游戏内装备面板可见。不触发时点/损坏检查（额外权限）。
func _dev_adjust_damage(slot: MechSlotState, mech, amount: int) -> void:
	slot.region_damage_tokens = maxi(0, slot.region_damage_tokens + amount)
	if slot.equipped_card != null:
		slot.equipped_card.damage_tokens = maxi(0, slot.equipped_card.damage_tokens + amount)
	if mech != null:
		mech.recalc_power_limits()  # 派生动力(016/021/048)随损伤变，同步max_power/power


func _on_add_region_damage() -> void:
	if network_mode:
		var sid := _get_selected_damage_slot_id()
		if sid != &"":
			dev_edit_requested.emit(&"add_region_damage", {"target": current_player_id, "slot_id": sid})
		return
	var slot: MechSlotState = _get_selected_damage_slot()
	if slot != null:
		_dev_adjust_damage(slot, _current_mech(), 1)
	_refresh_all()
	edit_applied.emit()


func _on_remove_region_damage() -> void:
	if network_mode:
		var sid := _get_selected_damage_slot_id()
		if sid != &"":
			dev_edit_requested.emit(&"remove_region_damage", {"target": current_player_id, "slot_id": sid})
		return
	var slot: MechSlotState = _get_selected_damage_slot()
	if slot != null and slot.region_damage_tokens > 0:
		_dev_adjust_damage(slot, _current_mech(), -1)
	_refresh_all()
	edit_applied.emit()


func _on_clear_all_region_damage() -> void:
	if network_mode:
		dev_edit_requested.emit(&"clear_all_region_damage", {"target": current_player_id})
		return
	var mech := _current_mech()
	if mech == null:
		return
	for slot_id: StringName in mech.slots:
		var slot: MechSlotState = mech.slots[slot_id]
		slot.region_damage_tokens = 0
		if slot.equipped_card != null:
			slot.equipped_card.damage_tokens = 0
	mech.recalc_power_limits()  # 清空损伤后派生动力归零，同步max_power/power
	_refresh_all()
	edit_applied.emit()


# ═══════════════════════════════════════════
# 属性修改器
# ═══════════════════════════════════════════

func _on_modify_hp(amount: int) -> void:
	if network_mode:
		dev_edit_requested.emit(&"modify_hp", {"target": current_player_id, "amount": amount})
		return
	var mech := _current_mech()
	if mech:
		mech.current_hp = clampi(mech.current_hp + amount, 0, mech.max_hp)
	_update_info_display()
	edit_applied.emit()


func _on_set_full_hp() -> void:
	if network_mode:
		dev_edit_requested.emit(&"set_full_hp", {"target": current_player_id})
		return
	var mech := _current_mech()
	if mech:
		mech.current_hp = mech.max_hp
	_update_info_display()
	edit_applied.emit()


func _on_modify_power(amount: int) -> void:
	if network_mode:
		dev_edit_requested.emit(&"modify_power", {"target": current_player_id, "amount": amount})
		return
	var mech := _current_mech()
	if mech:
		mech.dev_modify_power(amount)
	_update_info_display()
	edit_applied.emit()


func _on_set_full_power() -> void:
	if network_mode:
		dev_edit_requested.emit(&"set_full_power", {"target": current_player_id})
		return
	var mech := _current_mech()
	if mech:
		mech.restore_own_power_to_full()
	_update_info_display()
	edit_applied.emit()


func _on_modify_gold(amount: int) -> void:
	if network_mode:
		dev_edit_requested.emit(&"modify_gold", {"target": current_player_id, "amount": amount})
		return
	var player := _current_player()
	if player:
		player.gold = maxi(0, player.gold + amount)
	_update_info_display()
	edit_applied.emit()


func _on_set_gold_50() -> void:
	if network_mode:
		dev_edit_requested.emit(&"set_gold_50", {"target": current_player_id})
		return
	var player := _current_player()
	if player:
		player.gold = 50
	_update_info_display()
	edit_applied.emit()


func _on_modify_armor(amount: int) -> void:
	if network_mode:
		dev_edit_requested.emit(&"modify_armor", {"target": current_player_id, "amount": amount})
		return
	var mech := _current_mech()
	if mech:
		for slot_id: StringName in mech.slots:
			mech.slots[slot_id].armor_modifier += amount
	_update_info_display()
	edit_applied.emit()


## 换机师：下拉选 pilot_def_id → DevModeService.change_pilot（unset 旧 + set 新，注销旧 listener）。
func _on_change_pilot() -> void:
	var pilot_def_id: Variant = _dropdown_selected_meta(pilot_dropdown)
	if pilot_def_id == null or current_player_id == &"":
		return
	if network_mode:
		dev_edit_requested.emit(&"change_pilot", {"target": current_player_id, "pilot_def_id": pilot_def_id})
		return
	var gs := _gs()
	if gs == null:
		return
	var mech := _current_mech()
	if mech == null:
		return
	var dev := DevModeService.new()
	dev.context = context
	var result: Dictionary = dev.change_pilot(current_player_id, StringName(pilot_def_id))
	if not result.get("ok", false):
		if gs.log is Array:
			gs.log.append({"message": "dev 换机师失败: %s" % String(result.get("message", "")), "details": {}})
		return
	_update_info_display()
	edit_applied.emit()


## 应用攻击数/行动牌上限/金币：DevModeService.modify_player_limits（即时重算 max_attacks_per_turn）。
func _on_apply_limits() -> void:
	if current_player_id == &"":
		return
	var atk: int = int(attack_limit_spin.value)
	var alim: int = int(action_limit_spin.value)
	var gold: int = int(gold_spin.value)
	if network_mode:
		dev_edit_requested.emit(&"modify_limits", {"target": current_player_id, "attack_limit": atk, "action_card_limit": alim, "gold": gold})
		return
	var dev := DevModeService.new()
	dev.context = context
	dev.modify_player_limits(current_player_id, atk, alim, gold)
	_update_info_display()
	edit_applied.emit()


# ═══════════════════════════════════════════
# 面板控制
# ═══════════════════════════════════════════

func _on_close() -> void:
	close_requested.emit()


func toggle() -> void:
	visible = not visible
	if visible:
		_refresh_all()
