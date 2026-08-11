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
const _ActionPilotEffects = preload("res://scripts/generated_database/ActionPilotEffects.gd")
const _TC = preload("res://scripts/action_core/TimingConst.gd")

## 备用区设置按钮被点击（参数：备用区槽位ID，如"reserve_1"）
signal reserve_set_clicked(slot_id: StringName)

## 装备主动效果"发动"按钮被点击（参数：来源牌实例ID, 效果ID）
signal equipment_active_clicked(card_instance_id: StringName, effect_id: StringName)

## granted 授予效果按钮被点击（参数：来源牌实例ID, 效果ID, 执行机甲ID）。
## 用于 pilot_002 莱比尔授予联邦机甲的"协同·进攻"EX 按钮--来源牌(pilot_002)在莱比尔机甲上，
## 但执行机甲是被授予的联邦机甲 A，故须显式传 A 的 mech_id（equipment_active_clicked 仅2参无法表达）。
signal granted_effect_clicked(card_instance_id: StringName, effect_id: StringName, mech_id: StringName)

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

## 机师效果按钮数字加粗字体（FontVariation 合成粗体，懒创建复用）
var _bold_font: FontVariation = null

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
	summary.text = "HP: %d/%d  动力: %d  护甲: %d  攻击: %d/%d" % [
		_mech.current_hp, _mech.max_hp,
		_mech.power, _mech.get_armor(),
		_mech.attack_count_this_turn, _mech.max_attacks_per_turn
	]
	summary.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(summary)

	# 基础武器信息不再单列一行：武器槽（weapon_1/weapon_2）为空时
	# 已在 _add_slot_row 中显示基础武器名与威/射，无需重复。
	# 本机甲装备主动效果索引：card_instance_id -> Array[Dictionary{effect, bind_ctx}]
	# 仅在 _refresh 内构建一次，供各槽位行查询自己该挂哪些「触发」按钮，
	# 避免每个槽位行都重复扫描、把同一按钮挂到所有槽位上。
	var _active_by_card: Dictionary = {}
	# granted 授予效果（pilot_002 莱比尔协同·进攻等）：来源牌不在本机甲上，但 binding_context.mech_id
	# 指向本机甲 A。无法经 _active_by_card（按槽位牌 instance_id 匹配）渲染，单独收集到机师槽行挂 EX 按钮。
	var _granted_effects: Array = []
	if not _is_enemy and _context != null and _context.get("timing_engine") != null:
		for timing: StringName in _context.timing_engine.permanent_listeners:
			var entries: Array = _context.timing_engine.permanent_listeners[timing]
			for entry in entries:
				if entry == null or not (entry is Dictionary):
					continue
				var eff = entry.get("effect")
				if eff == null:
					continue
				var bind_ctx: Dictionary = entry.get("binding_context", {})
				# granted 判定优先（pilot_002_granted_* 进攻 DIRECT + 防御 AVAILABILITY 都进 EX 按钮区；
				# pilot_005_granted_* 帝国压制 LISTEN 也进 EX 按钮区，置灰展示）。
				# 莱比尔自身也获 EX（去自身排除），按 effect_id 前缀判定而非来源牌 mech_id。
				# 防御(AVAILABILITY)/被动(LISTEN) 虽不能主动点，仍渲染置灰 EX 按钮供悬停看描述。
				var _is_granted: bool = String(eff.effect_id).begins_with("pilot_002_granted_") or String(eff.effect_id).begins_with("pilot_005_granted_")
				if _is_granted:
					if String(bind_ctx.get("mech_id", &"")) != String(_mech.mech_id):
						continue
					_granted_effects.append({"effect": eff, "bind_ctx": bind_ctx})
					continue
				var is_pilot_slot: bool = String(bind_ctx.get("slot_id", &"")) == "pilot"
				# DIRECT：主动按钮（所有来源）。LISTEN：被动按钮（仅机师槽，置灰展示）。
				# AVAILABILITY（响应窗口牌）与装备 LISTEN（整行悬停展示）不挂按钮。
				if eff.mode == _TC.MODE_DIRECT:
					# 跳过 actions 为空的 DIRECT 占位效果（派生值实时重算/卖出权限等无主动动作）
					if eff.actions == null or eff.actions.is_empty():
						continue
				elif is_pilot_slot and eff.mode == _TC.MODE_LISTEN:
					pass  # 机师被动效果：挂置灰圆形按钮，悬停看描述/状态
				else:
					continue
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
		_add_slot_row(slot_id, slot, _active_by_card, _granted_effects if String(slot_id) == "pilot" else [])


## 添加单行槽位显示
## active_by_card: card_instance_id -> Array[Dictionary{effect, bind_ctx}]，
## 本槽位 equipped_card 命中的主动效果会在此行内挂「触发」按钮。
## granted_effects: 授予型 DIRECT 效果（来源牌不在本机甲），仅机师槽行渲染为 EX 按钮。
func _add_slot_row(slot_id: StringName, slot, active_by_card: Dictionary = {}, granted_effects: Array = []) -> void:
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

	# 装备/机师效果按钮：仅挂在该效果来源牌所在槽位行内（玩家面板、有 context 时）。
	# 机师槽：1/2/3 圆形按钮，从 get_effects_for_pilot 拿全部 effect_ids（含未注册的被动 effect_01/02），
	#   注册了 listener 的主动可点，未注册/被动(LISTEN) 置灰但可悬停看描述。
	# 装备槽：主动效果挂"触发"按钮，按条件/每回合1次置灰。
	if not _is_enemy and slot.equipped_card != null and _context != null:
		var inst_id: StringName = slot.equipped_card.instance_id
		var is_pilot_slot: bool = String(slot_id) == "pilot"
		if is_pilot_slot:
			var pilot_def_id: StringName = slot.equipped_card.def.card_id
			var all_eids: Array = _ActionPilotEffects.get_effects_for_pilot(pilot_def_id, _context)
			var active_items: Array = active_by_card.get(inst_id, [])
			all_eids.sort_custom(func(a, b): return String(a) < String(b))  # effect_01<02<03 保证 1/2/3 稳定
			var _eff_index: int = 0
			# pilot_003 瑟尔基尔：effect_02 离堆强制使用是纯自动触发被动，不建按钮，描述合并到 effect_01 hover
			# 其他机师（莱比尔等）的 LISTEN 被动按钮仍保留（置灰+悬停说明）
			var _is_p003: bool = String(pilot_def_id) == "pilot_003_瑟尔基尔"
			var _is_p004: bool = String(pilot_def_id) == "pilot_004_玛沙"
			var _is_p006: bool = String(pilot_def_id) == "pilot_006_里昂"
			var _is_p008: bool = String(pilot_def_id) == "pilot_008_安德洛美达"
			var _listen_eff: Variant = null
			if _is_p003:
				for _eid_pre in all_eids:
					var _eff_pre = _ActionPilotEffects.build_pilot_effects().get(StringName(_eid_pre))
					if _eff_pre != null and _eff_pre.mode == _TC.MODE_LISTEN:
						_listen_eff = _eff_pre
						break
			elif _is_p004:
				# pilot_004：effect_01b 护甲恢复隐藏被动，描述合并到按钮1(01a) hover
				_listen_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_004_effect_01b")
			elif _is_p006:
				# pilot_006：effect_02 狩猎追击隐藏被动（ATTACK_PRE 抽牌打标签），描述合并到按钮1(01) hover
				_listen_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_006_effect_02")
			elif _is_p008:
				# pilot_008：effect_01b 回收维修(弃置)隐藏被动，描述合并到按钮1(01a) hover（01a/01b 共享 once_per_turn）
				_listen_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_008_effect_01b")
			for eid_raw in all_eids:
				var eid: StringName = StringName(eid_raw)
				# pilot_001 双重生效：01a(确认入口)+01b(自动重跑) 合并为1个按钮（01a 代表），跳过 01b。
				if String(eid) == "pilot_001_effect_01b":
					continue
				# pilot_004：effect_01b 护甲恢复隐藏被动（不建按钮，描述合并到按钮1）
				if String(eid) == "pilot_004_effect_01b":
					continue
				# pilot_006：effect_02 狩猎追击隐藏被动（ATTACK_PRE 抽牌打标签，描述合并到按钮1）
				if _is_p006 and String(eid) == "pilot_006_effect_02":
					continue
				# pilot_008：effect_01b 回收维修(弃置)隐藏被动（描述合并到按钮1），3按钮=01a/02/03
				if _is_p008 and String(eid) == "pilot_008_effect_01b":
					continue
				var eff = _ActionPilotEffects.build_pilot_effects().get(eid)
				if eff == null:
					continue
				# pilot_003：被动效果（effect_02 离堆）不建按钮，描述合并到首个主动按钮 hover
				if _is_p003 and eff.mode == _TC.MODE_LISTEN:
					continue
				_eff_index += 1
				# 首个主动按钮（effect_01）hover 时附带 LISTEN 被动效果描述
				var _hover_extra: Variant = _listen_eff if (_eff_index == 1 and _listen_eff != null) else null
				# 查是否注册了 listener（主动效果）；未注册的（effect_01 光环/effect_02 派生）被动置灰
				var bind_ctx: Dictionary = {}
				var is_registered: bool = false
				for ai in active_items:
					if String(ai.get("effect").effect_id) == String(eid):
						bind_ctx = ai.get("bind_ctx", {})
						is_registered = true
						break
				if not is_registered:
					bind_ctx = {"card_instance_id": inst_id, "mech_id": _mech.mech_id, "player_id": _mech.owner_player_id, "slot_id": &"pilot", "card_def_id": pilot_def_id}
				var is_passive: bool = eff.mode == _TC.MODE_LISTEN or not is_registered
				var btn = Button.new()
				btn.text = str(_eff_index)
				btn.custom_minimum_size = Vector2(26, 26)
				btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				btn.add_theme_font_override("font", _ensure_bold_font())
				btn.add_theme_font_size_override("font_size", 15)
				btn.add_theme_constant_override("outline_size", 4)
				btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
				var circle := StyleBoxFlat.new()
				circle.bg_color = Color(0.16, 0.22, 0.32, 0.95)
				circle.border_color = Color(0.5, 0.7, 0.9, 0.9)
				circle.set_border_width_all(1)
				circle.set_corner_radius_all(13)
				circle.set_content_margin_all(0)
				btn.add_theme_stylebox_override("normal", circle)
				var circle_hover := circle.duplicate()
				circle_hover.bg_color = Color(0.25, 0.32, 0.45, 1.0)
				btn.add_theme_stylebox_override("hover", circle_hover)
				var circle_dis := circle.duplicate()
				circle_dis.bg_color = Color(0.1, 0.12, 0.16, 0.9)
				btn.add_theme_stylebox_override("disabled", circle_dis)
				# 置灰判定：被动(LISTEN/未注册) 永远置灰不可点但可悬停；主动按条件/每回合1次置灰。
				var can_trigger: bool = false
				if not is_passive and _context.get("timing_engine") != null:
					can_trigger = _context.timing_engine.can_trigger_active_effect(eff, bind_ctx)
				btn.disabled = is_passive or not can_trigger
				btn.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7) if (not is_passive and can_trigger) else Color(0.5, 0.5, 0.5))
				if not is_passive:
					var _cid_press: StringName = bind_ctx.get("card_instance_id", inst_id)
					btn.pressed.connect(func(): equipment_active_clicked.emit(_cid_press, eid))
				btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(eff, bind_ctx, _hover_extra))
				btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
				hbox.add_child(btn)
		elif not active_by_card.is_empty() and active_by_card.has(inst_id):
			# 装备槽：主动效果"触发"按钮（LISTEN 非机师槽已在 _refresh 过滤，此处皆 DIRECT 主动）
			var items: Array = active_by_card[inst_id]
			for item: Dictionary in items:
				var eff = item.get("effect")
				var bind_ctx: Dictionary = item.get("bind_ctx", {})
				var btn = Button.new()
				btn.text = "触发"
				btn.custom_minimum_size = Vector2(40, 20)
				var can_trigger: bool = false
				if _context.get("timing_engine") != null:
					can_trigger = _context.timing_engine.can_trigger_active_effect(eff, bind_ctx)
				btn.disabled = not can_trigger
				btn.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7) if can_trigger else Color(0.5, 0.5, 0.5))
				var cid: StringName = bind_ctx.get("card_instance_id", &"")
				var eid: StringName = eff.effect_id
				btn.pressed.connect(func(): equipment_active_clicked.emit(cid, eid))
				hbox.add_child(btn)

	# granted 授予效果 EX 按钮（pilot_002 莱比尔转化进攻+防御）：仅机师槽行，合并为1个圆形"EX"按钮。
	# 进攻(DIRECT)可主动点击；防御(AVAILABILITY)走响应窗口不能主动用，但其描述合并到 EX 按钮悬停说明。
	# 样式同 1/2/3 效果按钮。莱比尔自身也获 EX（去自身排除）。
	# 被 effect_03 取消加成的机甲（aura 不 active）EX 按钮直接消失（不渲染，非置灰）。
	if not _is_enemy and String(slot_id) == "pilot" and not granted_effects.is_empty() and _context != null and _context.get("game_state") != null:
		var _gs = _context.game_state
		# 收集进攻(DIRECT)与防御(AVAILABILITY)效果，合并为1个按钮
		var _g_direct: Variant = null
		var _g_direct_bind: Dictionary = {}
		var _g_defense: Variant = null
		var _g_defense_bind: Dictionary = {}
		var _g_listen: Variant = null
		var _g_listen_bind: Dictionary = {}
		for g_item in granted_effects:
			var g_eff = g_item.get("effect")
			var g_bind: Dictionary = g_item.get("bind_ctx", {})
			if g_eff == null:
				continue
			if g_eff.mode == _TC.MODE_DIRECT and _g_direct == null:
				_g_direct = g_eff
				_g_direct_bind = g_bind
			elif g_eff.mode == _TC.MODE_AVAILABILITY and _g_defense == null:
				_g_defense = g_eff
				_g_defense_bind = g_bind
			elif g_eff.mode == _TC.MODE_LISTEN and _g_listen == null:
				_g_listen = g_eff
				_g_listen_bind = g_bind
		# 主效果：优先进攻（可点），次防御（置灰），末被动 LISTEN（置灰仅展示，如肯特帝国压制）
		var _g_main = _g_direct if _g_direct != null else (_g_defense if _g_defense != null else _g_listen)
		var _g_main_bind: Dictionary = _g_direct_bind if _g_direct != null else (_g_defense_bind if _g_defense != null else _g_listen_bind)
		if _g_main != null:
			var _g_mid: StringName = _g_main_bind.get("mech_id", &"")
			# 取消加成 -> EX 按钮消失（不渲染）
			if _ActionPilotEffects.is_aura_active_for_mech(_gs, _g_mid):
				var g_btn = Button.new()
				g_btn.text = "EX"
				g_btn.custom_minimum_size = Vector2(26, 26)
				g_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				g_btn.add_theme_font_override("font", _ensure_bold_font())
				g_btn.add_theme_font_size_override("font_size", 13)
				g_btn.add_theme_constant_override("outline_size", 4)
				g_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
				var g_circle := StyleBoxFlat.new()
				g_circle.bg_color = Color(0.16, 0.22, 0.32, 0.95)
				g_circle.border_color = Color(0.5, 0.7, 0.9, 0.9)
				g_circle.set_border_width_all(1)
				g_circle.set_corner_radius_all(13)
				g_circle.set_content_margin_all(0)
				g_btn.add_theme_stylebox_override("normal", g_circle)
				var g_hover := g_circle.duplicate()
				g_hover.bg_color = Color(0.25, 0.32, 0.45, 1.0)
				g_btn.add_theme_stylebox_override("hover", g_hover)
				var g_dis := g_circle.duplicate()
				g_dis.bg_color = Color(0.1, 0.12, 0.16, 0.9)
				g_btn.add_theme_stylebox_override("disabled", g_dis)
				# 进攻(DIRECT)主动可点；防御(AVAILABILITY)走响应窗口，EX 按钮置灰仅展示描述
				var g_is_direct: bool = _g_main.mode == _TC.MODE_DIRECT
				var g_can: bool = g_is_direct and _context.get("timing_engine") != null and _context.timing_engine.can_trigger_active_effect(_g_main, _g_main_bind)
				g_btn.disabled = not g_can
				g_btn.add_theme_color_override("font_color", Color(0.6, 0.9, 0.7) if g_can else Color(0.5, 0.5, 0.5))
				var g_cid: StringName = _g_main_bind.get("card_instance_id", &"")
				var g_eid: StringName = _g_main.effect_id
				if g_is_direct:
					g_btn.pressed.connect(func(): granted_effect_clicked.emit(g_cid, g_eid, _g_mid))
				# 悬停：显示进攻+防御合并描述（防御描述作补充）
				g_btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(_g_main, _g_main_bind, _g_defense))
				g_btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
				hbox.add_child(g_btn)

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


## 机师效果按钮悬停浮框：显示该效果的描述、当前可发动次数、发动条件。
## 独立于整行浮框（按钮粒度），复用 _tooltip_popup 定位/样式。
## extra_eff：合并展示的附加效果（pilot_002 EX 按钮合并进攻+防御描述）。
func _on_pilot_effect_button_hover_entered(eff, bind_ctx: Dictionary, extra_eff = null) -> void:
	if eff == null:
		return
	_ensure_tooltip()
	var lines: Array = []
	# 标题：效果名 + 模式
	var mode_text := _mode_text(String(eff.mode))
	lines.append("[color=#ffd][b]%s[/b][/color] [color=#aaa](%s)[/color]" % [String(eff.display_name), mode_text])
	# 描述
	if String(eff.description).strip_edges() != "":
		lines.append("[color=#ccc]%s[/color]" % String(eff.description))
	# 附加效果描述（EX 按钮合并的防御效果，作补充说明）
	if extra_eff != null and String(extra_eff.description).strip_edges() != "":
		lines.append("[color=#fc9][b]%s[/b][/color]" % String(extra_eff.display_name))
		lines.append("[color=#ccc]%s[/color]" % String(extra_eff.description))
	# 当前可发动次数（once_per_turn）
	var te = _context.get("timing_engine") if _context != null else null
	if te != null and te.has_method(&"_current_turn_number") and eff.once_per_turn_key != &"":
		var cid: StringName = bind_ctx.get("card_instance_id", &"")
		var turn_id: int = te._current_turn_number()
		var key: String = "%s:%s" % [String(cid), String(eff.once_per_turn_key)]
		var turn_map: Dictionary = te._once_per_turn_used.get(key, {})
		var used: int = int(turn_map.get(turn_id, 0))
		var maxu: int = int(eff.once_per_turn_max)
		var remain: int = maxi(0, maxu - used)
		var color := "#9c9" if remain > 0 else "#c66"
		lines.append("[color=%s]本回合可发动：%d/%d[/color]" % [color, remain, maxu])
	# 发动/触发条件：转成可读中文列出（具体能否发动由按钮置灰体现）
	var cond_text := _conditions_to_text(eff.conditions)
	if cond_text != "":
		var cond_label := "可用条件"
		match String(eff.mode):
			"LISTEN": cond_label = "触发条件"
			"AVAILABILITY": cond_label = "响应条件"
		lines.append("[color=#9cf]%s：%s[/color]" % [cond_label, cond_text])
	_tooltip_rich.text = "\n".join(lines)
	_tooltip_popup.visible = true
	_tooltip_popup.reset_size()
	set_process(true)


## 把效果的 conditions（op 字典数组）转成可读中文，供悬停浮框显示。
## 未识别的 op 直接显示原始名（不隐藏条件）。
func _conditions_to_text(conditions) -> String:
	if conditions == null or not (conditions is Array) or conditions.is_empty():
		return ""
	var parts: Array = []
	for cond in conditions:
		if cond == null or not (cond is Dictionary):
			continue
		var op: String = String(cond.get("op", &""))
		var params: Dictionary = cond.get("params", {})
		var text := _condition_op_text(op, params)
		if text != "":
			parts.append(text)
	if parts.is_empty():
		return ""
	return "、".join(parts)


func _condition_op_text(op: String, params: Dictionary) -> String:
	match op:
		&"IS_OWNER_TURN": return "我方回合"
		&"IS_OWNER_MAIN_PHASE": return "我方主阶段"
		&"SELF_MECH_ALIVE": return "本机甲存活"
		&"ATTACKER_ALIVE": return "攻击方存活"
		&"HAS_ANY_MECH_ON_FIELD": return "场上有机甲"
		&"HAS_OTHER_MECH_ON_FIELD": return "场上有其他机甲"
		&"SELF_MECH_IS_ATTACKER": return "本机甲为攻击方"
		&"SELF_MECH_IS_ATTACK_TARGET": return "本机甲为被攻击目标"
		&"SELF_MECH_IS_ATTACKER_OR_TARGET": return "本机甲参与战斗(攻/守)"
		&"SELF_MECH_NOT_ATTACK_TARGET": return "本机甲非被攻击目标"
		&"ATTACK_HAS_TARGET": return "攻击有目标"
		&"ATTACK_TARGET_HAS_SOURCE_MARK": return "攻击目标为本轮狩猎标记"
		&"ATTACK_SOURCE_IS_PHYSICAL_ACTION_CARD": return "攻击源为实体行动牌(非当作)"
		&"ATTACK_SOURCE_CARD_CAN_BE_CLAIMED": return "攻击源牌可夺取"
		&"SOURCE_CARD_INSTANCE_CAN_BE_GAINED": return "源牌可获取"
		&"PAYLOAD_IS_PHYSICAL_ACTION_CARD": return "实体行动牌(非当作)"
		&"USED_CARD_EXECUTOR_IS_SELF": return "使用牌者为本机甲"
		&"PILOT_AURA_ACTIVE_FOR_MECH": return "机师光环对本机甲生效"
		&"MECH_HAS_USABLE_ATTACK_CARD": return "有可用攻击牌"
		&"HAS_ACTION_CARD_IN_HAND": return "手牌行动牌≥%d" % int(params.get("minimum", 1))
		&"HAS_ACTION_CARD_TYPE_IN_HAND": return "手牌有%s牌" % String(params.get("card_type", ""))
		&"HAS_OTHER_MECH_IN_HEX_RANGE": return "%d格内有其他机甲" % int(params.get("range", 0))
		&"ATTACK_TARGET_IN_HEX_RANGE": return "被攻击目标在%d格内" % int(params.get("range", 0))
		&"SELF_EFFECTIVE_ARMOR_ABOVE": return "护甲>%d" % int(params.get("threshold", 0))
		&"OWNER_POWER_ABOVE_OR_EQUAL": return "动力≥%d" % int(params.get("threshold", 0))
		&"OPPOSING_ATTACK_PARTICIPANT_ACTION_HAND_ABOVE": return "对侧参战者行动牌>%d" % int(params.get("threshold", 0))
		&"OWNER_ATTACK_CARD_USE_INDEX_THIS_TURN_BELOW": return "本回合攻击牌使用<%d次" % int(params.get("max_index", 0))
		&"HP_CHANGE_AMOUNT_ABOVE": return "回复量>%d" % int(params.get("threshold", 0))
		&"DAMAGE_CHANGE_AMOUNT_ABOVE": return "移除损伤>%d" % int(params.get("threshold", 0))
		&"HP_CHANGE_METHOD_IS": return "生命变化=%s" % String(params.get("method", ""))
		&"DAMAGE_CHANGE_METHOD_IS": return "损伤变化=%s" % String(params.get("method", ""))
		&"PAYLOAD_TARGET_IN_VARIABLE_HEX_RANGE": return "目标在%d+X格内" % int(params.get("base_range", 0))
		&"USED_CARD_TYPE_IS": return "使用%s牌" % String(params.get("card_type", ""))
		&"ATTACK_SOURCE_ACTION_CARD_TYPE_IS": return "攻击源为%s牌" % String(params.get("card_type", ""))
		&"PAYLOAD_PHYSICAL_CARD_DEF_ID_IS": return "牌为%s" % String(params.get("card_def_id", ""))
		&"DISCARD_CONTAINS_CARD_DEF_ID": return "弃牌堆含%s" % String(params.get("card_def_id", ""))
		&"PAYLOAD_CARD_HAS_RUNTIME_TAG": return "牌有%s标记" % String(params.get("tag", ""))
		&"PAYLOAD_FROM_ZONE_IS": return "来自%s区" % String(params.get("zone", ""))
		&"SOURCE_RUNTIME_MODIFIER_EXISTS": return "存在%s修饰层" % String(params.get("tag", ""))
	return op


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


## 机师效果按钮数字加粗字体：基于默认主题字体 + variation_embolden 合成粗体（懒创建复用）
func _ensure_bold_font() -> FontVariation:
	if _bold_font != null and is_instance_valid(_bold_font):
		return _bold_font
	var fv := FontVariation.new()
	fv.base_font = get_theme_default_font()
	fv.variation_embolden = 0.8
	_bold_font = fv
	return _bold_font


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
	# 机师牌状态：已用次数/剩余次数 + X 变量 + 特殊状态（pilot_008 X / pilot_006 悬赏 / pilot_009 控制）
	if slot.slot_id == &"pilot":
		var pstate := _build_pilot_status_bbcode(slot, cid)
		if pstate != "":
			lines.append("[color=#ccc]机师状态：[/color]")
			lines.append(pstate)
	return "\n".join(lines)


## 机师牌状态 BBcode：once_per_turn 已用/剩余 + pilot_008 X + pilot_006 悬赏 + pilot_009 控制。
## 从 timing_engine._once_per_turn_used 与 ActionPilotEffects 静态读（仿 _collect_bound_effects 遍历）。
func _build_pilot_status_bbcode(slot, cid: StringName) -> String:
	if slot == null or slot.equipped_card == null or _context == null:
		return ""
	var lines: Array = []
	var te = _context.get("timing_engine")
	var pfx = _ActionPilotEffects
	# 1. once_per_turn 使用次数（遍历该牌所有绑定 effect，显示 已用/上限）
	if te != null and te.has_method(&"_is_once_per_turn_used_up"):
		var turn_id: int = te._current_turn_number()
		for timing: StringName in te.permanent_listeners:
			for entry in te.permanent_listeners[timing]:
				if entry == null or not (entry is Dictionary):
					continue
				var bc: Dictionary = entry.get("binding_context", {})
				if String(bc.get("card_instance_id", &"")) != String(cid):
					continue
				var eff = entry.get("effect")
				if eff == null or eff.once_per_turn_key == &"":
					continue
				var key: String = "%s:%s" % [String(cid), String(eff.once_per_turn_key)]
				var turn_map: Dictionary = te._once_per_turn_used.get(key, {})
				var used: int = int(turn_map.get(turn_id, 0))
				var maxu: int = int(eff.once_per_turn_max)
				var color := "#9a9" if used < maxu else "#c66"
				lines.append("• [color=%s]%s：%d/%d[/color]" % [color, String(eff.display_name), used, maxu])
	# 2. pilot_008 X 变量
	if _mech != null and _mech.slots.get(&"pilot") != null and _mech.slots[&"pilot"].equipped_card != null:
		var pc: String = String(_mech.slots[&"pilot"].equipped_card.instance_id)
		if String(pc) == String(cid):
			var pdef = _mech.slots[&"pilot"].equipped_card.def
			if pdef != null and String(pdef.card_id) == "pilot_008_安德洛美达":
				lines.append("• [color=#9cf]X 变量：%d（回收维修次数，上限5）[/color]" % pfx.get_pilot_008_x(_mech.slots[&"pilot"].equipped_card))
	# 3. pilot_006 狩猎标记
	if String(cid) != &"":
		var mark: StringName = pfx.get_pilot_006_mark(cid)
		if mark != &"":
			var target_name := ""
			if _context != null and _context.get("game_state") != null:
				var tm = _context.game_state.mechs.get(mark)
				if tm != null:
					target_name = String(tm.mech_id)
			lines.append("• [color=#fc6]狩猎目标：%s[/color]" % target_name)
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
