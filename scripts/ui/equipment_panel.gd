## EquipmentPanel.gd - 机甲装备面板
##
## 显示机甲的所有槽位（6部件+2武器+2备用+1事件+1机师），
## 每个槽位显示装备名、护甲/动力数值、损伤/耐久。
##
## 差量刷新：标题/摘要/12行槽位骨架只建一次，各标签就地更新文本与颜色；
## 动态按钮（触发/1-2-3/EX/RE）集中在每行的 btn_box 内按需重建，
## 样式盒懒创建后共享复用。旧实现每次刷新 queue_free 整树再重建
## （约60个Label+全部按钮+每按钮3个StyleBoxFlat），是点击延迟的主要构成之一。
extends VBoxContainer
class_name EquipmentPanel

const _MechState = preload("res://scripts/runtime/MechState.gd")
const _MechSlotState = preload("res://scripts/runtime/MechSlotState.gd")
const _EquipmentCardDef = preload("res://scripts/card_defs/EquipmentCardDef.gd")
const _EventCardDef = preload("res://scripts/card_defs/EventCardDef.gd")
const _GenEquipEffects = preload("res://scripts/generated_database/GeneratedEquipmentEffects.gd")
const _GenEventEffects = preload("res://scripts/generated_database/GeneratedEventEffects.gd")
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

## 「详情」按钮被点击（参数：当前机甲 MechState）--打开机甲详细信息框
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

# ── 差量刷新缓存 ──
## 骨架（标题行+摘要标签）是否已构建
var _skeleton_built: bool = false
## 生命/动力摘要标签（持久，只改文本）
var _summary_label: Label = null
## 「详情」按钮（持久，可见性随 context 注入切换）
var _detail_btn: Button = null
## 槽位行缓存：slot_id -> {hbox, equip_label, damage_label, armor_label, power_label, set_btn, btn_box}
var _slot_rows: Dictionary = {}

## 动态按钮共享样式盒（懒创建，[normal, hover, disabled]；同款按钮共用一份，
## 避免每次重建按钮时各分配 3 个 StyleBoxFlat）
var _sb_circle: Array = []  # 蓝灰圆形（机师 1/2/3 与 EX）
var _sb_re24: Array = []    # 紫色 RE（pilot_024 琳）
var _sb_re81: Array = []    # 绿色 RE（pilot_081 汀兰）
var _sb_re83: Array = []    # 橙色 RE（pilot_083 瓦恩）


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


## 刷新装备显示（差量）
func _refresh() -> void:
	_hide_tooltip()

	if not _mech:
		_teardown_all()
		return

	_ensure_skeleton()
	# 详情按钮：仅注入了 context 的面板显示（主面板有，敌方信息弹窗内无）
	_detail_btn.visible = _context != null

	# 生命/动力摘要
	_summary_label.text = "HP: %d/%d  动力: %d  护甲: %d  攻击: %d/%d" % [
		_mech.current_hp, _mech.max_hp,
		_mech.power, _mech.get_armor(),
		_mech.attack_count_this_turn, _mech.max_attacks_per_turn
	]

	# 基础武器信息不再单列一行：武器槽（weapon_1/weapon_2）为空时
	# 已在 _update_slot_row 中显示基础武器名与威/射，无需重复。
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
				# 通用化：新授予机制（泰特 pilot_073 等）在 binding 打 granted=true 标记，优先据此判定；
				# pilot_002/005 旧前缀保留兼容。
				var _is_granted: bool = bool(bind_ctx.get("granted", false)) or String(eff.effect_id).begins_with("pilot_002_granted_") or String(eff.effect_id).begins_with("pilot_005_granted_")
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

	# 各槽位（行骨架按 slot_id 缓存复用，内容就地更新）
	for slot_id: StringName in SLOT_ORDER:
		var slot: MechSlotState = _mech.slots.get(slot_id)
		_update_slot_row(slot_id, slot, _active_by_card, _granted_effects if String(slot_id) == "pilot" else [])


## 构建骨架（标题行 + 摘要标签，仅首次）
func _ensure_skeleton() -> void:
	if _skeleton_built:
		return
	_skeleton_built = true

	# 标题 + 详情按钮
	var title_row := HBoxContainer.new()
	var title := Label.new()
	title.text = "── 装备面板 ──"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_row.add_child(title)
	_detail_btn = Button.new()
	_detail_btn.text = "详情"
	_detail_btn.custom_minimum_size = Vector2(46, 24)
	_detail_btn.tooltip_text = "查看机甲动力/护甲来源明细与状态"
	_detail_btn.pressed.connect(_on_detail_pressed)
	title_row.add_child(_detail_btn)
	add_child(title_row)

	# 生命/动力摘要
	_summary_label = Label.new()
	_summary_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_summary_label)


## 详情按钮回调：按下时读当前 _mech（不闭包捕获，换机甲后不发出过期引用）
func _on_detail_pressed() -> void:
	if _mech != null:
		mech_detail_requested.emit(_mech)


## 无机甲时释放骨架与全部行缓存
func _teardown_all() -> void:
	_slot_rows.clear()
	for child in get_children():
		child.queue_free()
	_skeleton_built = false
	_summary_label = null
	_detail_btn = null


## 获取（或懒建）某槽位的持久行骨架
func _ensure_row(slot_id: StringName, slot) -> Dictionary:
	# 注意：不得用 `var row: Dictionary = _slot_rows.get(slot_id)`——槽位不在缓存时
	# get() 返回 nil，赋给 Dictionary 值类型变量会抛 "Trying to assign value of type
	# 'Nil' to a variable of type 'Dictionary'"（GDScript 4 禁止 nil 赋给值类型）。
	if _slot_rows.has(slot_id):
		return _slot_rows[slot_id]

	var hbox = HBoxContainer.new()

	# 槽位名
	var name_label = Label.new()
	name_label.text = SLOT_NAMES.get(slot_id, String(slot_id))
	name_label.custom_minimum_size = Vector2(50, 24)
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(name_label)

	# 装备名
	var equip_label = Label.new()
	equip_label.custom_minimum_size = Vector2(100, 20)
	equip_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(equip_label)

	# 损伤/耐久
	var damage_label = Label.new()
	damage_label.custom_minimum_size = Vector2(70, 20)
	damage_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hbox.add_child(damage_label)

	# 有效护甲和动力（部件槽位；槽位类型不变，骨架期确定）
	var armor_label: Label = null
	var power_label: Label = null
	if slot != null and slot.slot_kind == &"PART":
		armor_label = Label.new()
		armor_label.custom_minimum_size = Vector2(35, 20)
		armor_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(armor_label)
		power_label = Label.new()
		power_label.custom_minimum_size = Vector2(35, 20)
		power_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hbox.add_child(power_label)

	# 备用区设置按钮（骨架期建好，可见性/置灰按刷新状态切换）
	var set_btn: Button = null
	if slot_id == &"reserve_1" or slot_id == &"reserve_2":
		set_btn = Button.new()
		set_btn.text = "设置"
		set_btn.custom_minimum_size = Vector2(40, 20)
		var captured_slot_id = slot_id
		set_btn.pressed.connect(func(): reserve_set_clicked.emit(captured_slot_id))
		hbox.add_child(set_btn)

	# 动态按钮区（触发/1-2-3/EX/RE）：每次刷新整体重建子按钮，样式盒共享
	var btn_box = HBoxContainer.new()
	hbox.add_child(btn_box)

	# 整行悬停：悬停瞬间实时读当前槽位与装备牌（换装/换机甲后闭包不过期）
	hbox.mouse_entered.connect(_make_row_hover_handler(slot_id))
	hbox.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))

	add_child(hbox)
	var row: Dictionary = {
		"hbox": hbox, "equip_label": equip_label, "damage_label": damage_label,
		"armor_label": armor_label, "power_label": power_label,
		"set_btn": set_btn, "btn_box": btn_box,
	}
	_slot_rows[slot_id] = row
	return row


## 整行悬停回调工厂：有装备牌且非「敌方备用区（隐藏信息）」时展示效果浮框
func _make_row_hover_handler(slot_id: StringName) -> Callable:
	return func():
		if _mech == null or not _mech.slots.has(slot_id):
			return
		var slot = _mech.slots[slot_id]
		if slot == null or slot.equipped_card == null:
			return
		if _is_enemy and slot.slot_kind == &"RESERVE":
			return
		_on_equipment_hover_entered(slot, slot.equipped_card.instance_id)


## 更新单行槽位显示（就地更新标签文本/颜色/按钮状态）
## active_by_card: card_instance_id -> Array[Dictionary{effect, bind_ctx}]，
## 本槽位 equipped_card 命中的主动效果会在行内挂「触发」按钮。
## granted_effects: 授予型 DIRECT 效果（来源牌不在本机甲），仅机师槽行渲染为 EX 按钮。
func _update_slot_row(slot_id: StringName, slot, active_by_card: Dictionary, granted_effects: Array) -> void:
	if slot == null:
		# 该机甲无此槽位：隐藏既有行（has() 判定，避免 nil 赋给 Dictionary 抛错）
		if _slot_rows.has(slot_id):
			_slot_rows[slot_id]["hbox"].visible = false
		return

	var row: Dictionary = _ensure_row(slot_id, slot)
	row["hbox"].visible = true

	# ── 装备名（就地更新；先清颜色覆盖，防止上一刷新的条件色残留）──
	var equip_label: Label = row["equip_label"]
	equip_label.remove_theme_color_override(&"font_color")
	if slot.equipped_card and slot.equipped_card.def:
		equip_label.text = slot.equipped_card.def.display_name
		# 附加数值信息
		if slot.equipped_card.def is _EquipmentCardDef:
			var eq_def = slot.equipped_card.def
			if eq_def.equipment_kind == &"PART":
				equip_label.text += " [甲%d 动%d]" % [eq_def.armor, eq_def.power]
			elif eq_def.equipment_kind == &"WEAPON":
				equip_label.text += " [威%d 射%d]" % [eq_def.might, eq_def.range_value]
		elif slot.equipped_card.def is _EventCardDef:
			# 事件牌：显示计时方式与剩余计时数（instant 即时结算，其余显示剩余数）
			var ev_def = slot.equipped_card.def
			if ev_def.timer_mode == _GenEventEffects.TIMER_MODE_INSTANT:
				equip_label.text += " [即时]"
			else:
				equip_label.text += " [计时%d]" % int(slot.equipped_card.get("timer"))
			# 任务进度（通用 progress_display 元数据：遍历牌 effect_ids 取效果声明的进度）：
			# 行内直接显示 "进度X/Y"，已领取（claimed_counter_key>=1）追加"已领"。
			var ev_prog := _event_progress_text(slot.equipped_card)
			if ev_prog != "":
				equip_label.text += " " + ev_prog
			equip_label.add_theme_color_override("font_color", Color(0.75, 0.55, 0.85))
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
				# "禁"标签（法尔科 pilot_078 弃2抽高级装备置备用区等）：打标签玩家下个回合开始前
				# 不能主动设置，备用标签追加"(禁)"并置灰提示。
				if _ActionPilotEffects.equip_forbid_tagged(slot.equipped_card):
					equip_label.text += "（禁）"
					equip_label.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
				else:
					equip_label.add_theme_color_override("font_color", Color(0.85, 0.75, 0.3))
		else:
			equip_label.text = "（空）"
	else:
		equip_label.text = "（空）"

	# ── 损伤/耐久（先清颜色覆盖）──
	var damage_label: Label = row["damage_label"]
	damage_label.remove_theme_color_override(&"font_color")
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

	# ── 有效护甲和动力（部件槽位）──
	if row["armor_label"] != null and row["power_label"] != null:
		row["armor_label"].text = "甲:%d" % slot.get_effective_armor(_mech)
		row["power_label"].text = "动:%d" % slot.get_effective_power()

	# 武器槽位显示基础武器的耐久（固定1）
	if (slot_id == &"weapon_1" or slot_id == &"weapon_2") and not slot.equipped_card:
		var base_weapon = _mech.get_base_weapon(0 if slot_id == &"weapon_1" else 1)
		if not base_weapon.is_empty():
			damage_label.text = "（基础武器）"
			damage_label.add_theme_color_override("font_color", Color.CYAN)

	# ── 备用区设置按钮（仅在我方且有装备时显示）──
	var set_btn: Button = row["set_btn"]
	if set_btn != null:
		set_btn.visible = (not _is_enemy) and slot.equipped_card != null
		if set_btn.visible:
			# "禁"标签装备不能主动设置（法尔科 pilot_078 等）：按钮置灰，后端 CardSetService 双保险。
			set_btn.disabled = _ActionPilotEffects.equip_forbid_tagged(slot.equipped_card)

	# ── 整行悬停命中条件：有装备牌且非敌方备用区 ──
	# 有牌时 HBox 设为顶层命中控件（Labels 已 IGNORE），无牌时恢复容器默认（PASS）
	row["hbox"].mouse_filter = Control.MOUSE_FILTER_STOP \
		if (slot.equipped_card != null and not (_is_enemy and slot.slot_kind == &"RESERVE")) \
		else Control.MOUSE_FILTER_PASS

	# ── 动态按钮区 ──
	_rebuild_row_buttons(row, slot_id, slot, active_by_card, granted_effects)


## 重建行内动态按钮（触发/1-2-3/EX/RE）。
## 按钮数量少且状态（置灰/悬停描述）每刷新都可能变化，故整区重建；
## 样式盒经 _get_*_styleboxes 共享，避免 StyleBoxFlat 重复分配。
func _rebuild_row_buttons(row: Dictionary, slot_id: StringName, slot, active_by_card: Dictionary, granted_effects: Array) -> void:
	var btn_box: HBoxContainer = row["btn_box"]
	for c in btn_box.get_children():
		btn_box.remove_child(c)
		c.queue_free()

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
			# 通用按钮机制（绑定效果条目而非机师ID）：hide_button 效果不建按钮，
			# merge_desc_into_index>0 时其描述合并到对应可见按钮的 hover（数组形式传入 hover handler）。
			var _build_effs: Dictionary = _ActionPilotEffects.build_pilot_effects()
			var _visible_effs: Array = []   # [{eff, eid, bind_ctx, is_registered}]
			var _hidden_merge: Dictionary = {}  # {按钮序号(int) -> Array[ActionEffect]}
			for eid_raw in all_eids:
				var eid: StringName = StringName(eid_raw)
				var eff = _build_effs.get(eid)
				if eff == null:
					continue
				if bool(eff.hide_button):
					var _m_idx: int = int(eff.merge_desc_into_index)
					if _m_idx > 0:
						var _m_arr: Array = _hidden_merge.get(_m_idx, [])
						_m_arr.append(eff)
						_hidden_merge[_m_idx] = _m_arr
					continue
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
				_visible_effs.append({"eff": eff, "eid": eid, "bind_ctx": bind_ctx, "is_registered": is_registered})
			var _eff_index: int = 0
			for _vi in _visible_effs:
				var eff = _vi.eff
				var eid: StringName = _vi.eid
				var bind_ctx: Dictionary = _vi.bind_ctx
				var is_registered: bool = _vi.is_registered
				_eff_index += 1
				# 该按钮序号上需合并的隐藏效果描述（数组，可为空）--hover handler 同时支持单效果与数组
				var _hover_extra: Variant = _hidden_merge.get(_eff_index, null)
				var is_passive: bool = eff.mode == _TC.MODE_LISTEN or not is_registered
				var btn = Button.new()
				btn.text = str(_eff_index)
				btn.custom_minimum_size = Vector2(26, 26)
				btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				btn.add_theme_font_override("font", _ensure_bold_font())
				btn.add_theme_font_size_override("font_size", 15)
				btn.add_theme_constant_override("outline_size", 4)
				btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
				var _sbs := _get_circle_styleboxes()
				btn.add_theme_stylebox_override("normal", _sbs[0])
				btn.add_theme_stylebox_override("hover", _sbs[1])
				btn.add_theme_stylebox_override("disabled", _sbs[2])
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
				btn_box.add_child(btn)
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
				btn_box.add_child(btn)

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
			# 悬停附加描述：除主效果外其余 granted 效果（pilot_002 防御 AVAILABILITY /
			# 泰特授予的隐藏 LISTEN apply/consume/turnend），数组形式传入 hover handler 合并展示。
			var _g_extra: Array = []
			for g_item2 in granted_effects:
				var g_eff2 = g_item2.get("effect")
				if g_eff2 == null or g_eff2 == _g_main:
					continue
				_g_extra.append(g_eff2)
			# 取消加成 -> EX 按钮消失（不渲染）。仅 pilot_002/005 光环授予（bind 无 granted 标记）
			# 受光环开关控制；泰特 pilot_073 等新授予（bind.granted=true）无光环开关，直接渲染。
			if bool(_g_main_bind.get("granted", false)) or _ActionPilotEffects.is_aura_active_for_mech(_gs, _g_mid):
				var g_btn = Button.new()
				g_btn.text = "EX"
				g_btn.custom_minimum_size = Vector2(26, 26)
				g_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				g_btn.add_theme_font_override("font", _ensure_bold_font())
				g_btn.add_theme_font_size_override("font_size", 13)
				g_btn.add_theme_constant_override("outline_size", 4)
				g_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
				var _g_sbs := _get_circle_styleboxes()
				g_btn.add_theme_stylebox_override("normal", _g_sbs[0])
				g_btn.add_theme_stylebox_override("hover", _g_sbs[1])
				g_btn.add_theme_stylebox_override("disabled", _g_sbs[2])
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
				g_btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(_g_main, _g_main_bind, _g_extra))
				g_btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
				btn_box.add_child(g_btn)

	# pilot_024 琳 RE 请求维修按钮：场上琳（非本机甲）在4格内时，本机师槽行渲染"RE"圆形按钮。
	# 请求方自己回合1次，点击即消耗本回合 RE 次数（琳拒绝也不刷新）；满状态不可点。
	# 点击 emit granted_effect_clicked(琳 pilot 牌 instance_id, "pilot_024_re_request", 本机甲 mech_id)，
	# app_root 走 effect_fire -> RE 请求流程（给琳弹确认窗）。
	if String(slot_id) == "pilot" and not _is_enemy and _context != null and _context.get("game_state") != null:
		var _gs24 = _context.game_state
		var _lin24_mid: StringName = _ActionPilotEffects.pilot_024_find_lin_mech(_gs24)
		# 本机甲非琳（不能请求自己）；琳在场存活
		if _lin24_mid != &"" and _lin24_mid != _mech.mech_id:
			var _lin24_m = _gs24.mechs.get(_lin24_mid)
			if _lin24_m != null and not _lin24_m.destroyed and _lin24_m.current_hp > 0:
				# 4格内才显示（离开4格外按钮消失）
				if _ActionPilotEffects.pilot_024_requester_in_range(_gs24, _mech.mech_id, _lin24_mid, 4):
					var _re24_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_024_re_request")
					if _re24_eff != null:
						var _re24_can: bool = String(_gs24.active_player_id) == String(_mech.owner_player_id) \
							and _ActionPilotEffects.pilot_024_mech_repairable(_gs24, _mech.mech_id) \
							and not _ActionPilotEffects.pilot_024_re_used_this_round(_gs24, _mech.mech_id)
						var _re24_btn = Button.new()
						_re24_btn.text = "RE"
						_re24_btn.custom_minimum_size = Vector2(26, 26)
						_re24_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
						_re24_btn.add_theme_font_override("font", _ensure_bold_font())
						_re24_btn.add_theme_font_size_override("font_size", 12)
						_re24_btn.add_theme_constant_override("outline_size", 4)
						_re24_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
						var _re24_sbs := _get_re24_styleboxes()
						_re24_btn.add_theme_stylebox_override("normal", _re24_sbs[0])
						_re24_btn.add_theme_stylebox_override("hover", _re24_sbs[1])
						_re24_btn.add_theme_stylebox_override("disabled", _re24_sbs[2])
						_re24_btn.disabled = not _re24_can
						_re24_btn.add_theme_color_override("font_color", Color(0.95, 0.8, 0.95) if _re24_can else Color(0.5, 0.5, 0.5))
						var _lin24_pilot_card = _ActionPilotEffects.pilot_024_lin_pilot_card(_gs24)
						var _re24_cid: StringName = _lin24_pilot_card.instance_id if _lin24_pilot_card != null else &""
						var _re24_mid_emit: StringName = _mech.mech_id
						_re24_btn.pressed.connect(func(): granted_effect_clicked.emit(_re24_cid, &"pilot_024_re_request", _re24_mid_emit))
						# 悬停说明（RE 按钮的 effect 定义）
						var _re24_bind: Dictionary = {
							"card_instance_id": _re24_cid,
							"mech_id": _mech.mech_id,
							"player_id": _mech.owner_player_id,
							"slot_id": &"pilot",
							"card_def_id": &"pilot_024_琳",
						}
						_re24_btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(_re24_eff, _re24_bind))
						_re24_btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
						btn_box.add_child(_re24_btn)

	# pilot_081 汀兰 RE 请求回复按钮：本机甲在光环格上（有覆盖的存活汀兰持有者，含自身）时，
	# 机师槽行逐持有者渲染"RE"按钮。请求方自己回合1次，点击即消耗本回合次数（持有者拒绝也不刷新）。
	# 不卡满血（金币收益始终有效）。点击 emit granted_effect_clicked(持有者 pilot 牌 instance_id,
	# "pilot_081_re_request", 本机甲 mech_id)，app_root 走 effect_fire -> RE 请求流程（给持有者弹确认窗）。
	if String(slot_id) == "pilot" and not _is_enemy and _context != null and _context.get("game_state") != null:
		var _gs81 = _context.game_state
		var _cov81_holders: Array = _ActionPilotEffects.pilot_081_find_covering_holders(_gs81, _mech.mech_id)
		if not _cov81_holders.is_empty():
			var _re81_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_081_re_request")
			if _re81_eff != null:
				# 资格判定为请求方作用域（所有持有者按钮同状态）：己方回合 + 本回合未用过
				var _re81_can: bool = String(_gs81.active_player_id) == String(_mech.owner_player_id) \
					and not _ActionPilotEffects.pilot_081_re_used_this_turn(_gs81, _mech.mech_id)
				for _h81_mid: StringName in _cov81_holders:
					var _h81_m = _gs81.mechs.get(_h81_mid)
					if _h81_m == null or _h81_m.destroyed:
						continue
					var _h81_slot = _h81_m.slots.get(&"pilot") if _h81_m.slots != null else null
					if _h81_slot == null or _h81_slot.equipped_card == null or _h81_slot.equipped_card.def == null:
						continue
					if String(_h81_slot.equipped_card.def.card_id) != "pilot_081_汀兰":
						continue
					var _re81_cid: StringName = StringName(_h81_slot.equipped_card.instance_id)
					var _re81_btn = Button.new()
					_re81_btn.text = "RE"
					_re81_btn.custom_minimum_size = Vector2(26, 26)
					_re81_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					_re81_btn.add_theme_font_override("font", _ensure_bold_font())
					_re81_btn.add_theme_font_size_override("font_size", 12)
					_re81_btn.add_theme_constant_override("outline_size", 4)
					_re81_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
					var _re81_sbs := _get_re81_styleboxes()
					_re81_btn.add_theme_stylebox_override("normal", _re81_sbs[0])
					_re81_btn.add_theme_stylebox_override("hover", _re81_sbs[1])
					_re81_btn.add_theme_stylebox_override("disabled", _re81_sbs[2])
					_re81_btn.disabled = not _re81_can
					_re81_btn.add_theme_color_override("font_color", Color(0.85, 0.95, 0.85) if _re81_can else Color(0.5, 0.5, 0.5))
					var _re81_mid_emit: StringName = _mech.mech_id
					_re81_btn.pressed.connect(func(): granted_effect_clicked.emit(_re81_cid, &"pilot_081_re_request", _re81_mid_emit))
					# 悬停说明（RE 按钮的 effect 定义；持有者 pilot 牌实例注入 binding）
					var _re81_bind: Dictionary = {
						"card_instance_id": _re81_cid,
						"mech_id": _mech.mech_id,
						"player_id": _mech.owner_player_id,
						"slot_id": &"pilot",
						"card_def_id": &"pilot_081_汀兰",
					}
					_re81_btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(_re81_eff, _re81_bind))
					_re81_btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
					btn_box.add_child(_re81_btn)

	# pilot_083 瓦恩 RE 请求武器修改按钮：本机甲3格内有覆盖的存活瓦恩持有者（排除自身--
	# 瓦恩持有者不能自己请求自己）时，机师槽行逐持有者渲染"RE"按钮。请求方自己回合1次，
	# 点击即消耗本回合次数（持有者拒绝也不刷新）。
	# 需持有≥1把武器（含虚拟，按钮资格与效果一致）。点击 emit granted_effect_clicked(持有者 pilot 牌
	# instance_id, "pilot_083_re_request", 本机甲 mech_id)，app_root 走 effect_fire -> RE 请求流程
	# （给瓦恩持有者选请求方武器 -> 三横排选项 -> 施加）。
	if String(slot_id) == "pilot" and not _is_enemy and _context != null and _context.get("game_state") != null:
		var _gs83 = _context.game_state
		var _cov83_holders: Array = _ActionPilotEffects.pilot_083_find_covering_holders(_gs83, _mech.mech_id)
		if not _cov83_holders.is_empty() \
				and not _ActionPilotEffects.pilot_083_list_weapon_options(_gs83, _mech.mech_id).is_empty():
			var _re83_eff = _ActionPilotEffects.build_pilot_effects().get(&"pilot_083_re_request")
			if _re83_eff != null:
				# 资格判定为请求方作用域（所有持有者按钮同状态）：己方回合 + 本回合未用过
				var _re83_can: bool = String(_gs83.active_player_id) == String(_mech.owner_player_id) \
					and not _ActionPilotEffects.pilot_083_re_used_this_turn(_gs83, _mech.mech_id)
				for _h83_mid: StringName in _cov83_holders:
					var _h83_m = _gs83.mechs.get(_h83_mid)
					if _h83_m == null or _h83_m.destroyed:
						continue
					var _h83_slot = _h83_m.slots.get(&"pilot") if _h83_m.slots != null else null
					if _h83_slot == null or _h83_slot.equipped_card == null or _h83_slot.equipped_card.def == null:
						continue
					if String(_h83_slot.equipped_card.def.card_id) != "pilot_083_瓦恩":
						continue
					var _re83_cid: StringName = StringName(_h83_slot.equipped_card.instance_id)
					var _re83_btn = Button.new()
					_re83_btn.text = "RE"
					_re83_btn.custom_minimum_size = Vector2(26, 26)
					_re83_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
					_re83_btn.add_theme_font_override("font", _ensure_bold_font())
					_re83_btn.add_theme_font_size_override("font_size", 12)
					_re83_btn.add_theme_constant_override("outline_size", 4)
					_re83_btn.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.7))
					var _re83_sbs := _get_re83_styleboxes()
					_re83_btn.add_theme_stylebox_override("normal", _re83_sbs[0])
					_re83_btn.add_theme_stylebox_override("hover", _re83_sbs[1])
					_re83_btn.add_theme_stylebox_override("disabled", _re83_sbs[2])
					_re83_btn.disabled = not _re83_can
					_re83_btn.add_theme_color_override("font_color", Color(0.95, 0.85, 0.75) if _re83_can else Color(0.5, 0.5, 0.5))
					var _re83_mid_emit: StringName = _mech.mech_id
					_re83_btn.pressed.connect(func(): granted_effect_clicked.emit(_re83_cid, &"pilot_083_re_request", _re83_mid_emit))
					# 悬停说明（RE 按钮的 effect 定义；持有者 pilot 牌实例注入 binding）
					var _re83_bind: Dictionary = {
						"card_instance_id": _re83_cid,
						"mech_id": _mech.mech_id,
						"player_id": _mech.owner_player_id,
						"slot_id": &"pilot",
						"card_def_id": &"pilot_083_瓦恩",
					}
					_re83_btn.mouse_entered.connect(func(): _on_pilot_effect_button_hover_entered(_re83_eff, _re83_bind))
					_re83_btn.mouse_exited.connect(Callable(self, "_on_equipment_hover_exited"))
					btn_box.add_child(_re83_btn)


# ═══════════════════════════════════════════
# 共享样式盒（懒创建）
# ═══════════════════════════════════════════


## 圆形按钮样式组：[normal, hover, disabled]
func _make_circle_stylebox_set(bg: Color, border: Color, hover_bg: Color, dis_bg: Color) -> Array:
	var circle := StyleBoxFlat.new()
	circle.bg_color = bg
	circle.border_color = border
	circle.set_border_width_all(1)
	circle.set_corner_radius_all(13)
	circle.set_content_margin_all(0)
	var hover := circle.duplicate()
	hover.bg_color = hover_bg
	var dis := circle.duplicate()
	dis.bg_color = dis_bg
	return [circle, hover, dis]


## 机师 1/2/3 与 EX 按钮的蓝灰圆形样式（共享）
func _get_circle_styleboxes() -> Array:
	if _sb_circle.is_empty():
		_sb_circle = _make_circle_stylebox_set(
			Color(0.16, 0.22, 0.32, 0.95), Color(0.5, 0.7, 0.9, 0.9),
			Color(0.25, 0.32, 0.45, 1.0), Color(0.1, 0.12, 0.16, 0.9))
	return _sb_circle


## pilot_024 琳 RE 按钮的紫色圆形样式（共享）
func _get_re24_styleboxes() -> Array:
	if _sb_re24.is_empty():
		_sb_re24 = _make_circle_stylebox_set(
			Color(0.18, 0.12, 0.28, 0.95), Color(0.9, 0.6, 0.9, 0.9),
			Color(0.28, 0.2, 0.42, 1.0), Color(0.1, 0.08, 0.14, 0.9))
	return _sb_re24


## pilot_081 汀兰 RE 按钮的绿色圆形样式（共享）
func _get_re81_styleboxes() -> Array:
	if _sb_re81.is_empty():
		_sb_re81 = _make_circle_stylebox_set(
			Color(0.10, 0.30, 0.16, 0.95), Color(0.30, 0.85, 0.40, 0.9),
			Color(0.16, 0.42, 0.22, 1.0), Color(0.08, 0.14, 0.10, 0.9))
	return _sb_re81


## pilot_083 瓦恩 RE 按钮的橙色圆形样式（共享）
func _get_re83_styleboxes() -> Array:
	if _sb_re83.is_empty():
		_sb_re83 = _make_circle_stylebox_set(
			Color(0.22, 0.14, 0.30, 0.95), Color(0.95, 0.75, 0.30, 0.9),
			Color(0.32, 0.22, 0.42, 1.0), Color(0.10, 0.08, 0.14, 0.9))
	return _sb_re83


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


## 事件牌任务进度文本（通用 progress_display 元数据驱动，不绑卡牌）：
## 遍历牌 def.effect_ids 查 GeneratedEventEffects 效果的 progress_display，
## 返回 "进度X/Y[已领]"；无进度声明返回 ""。
func _event_progress_text(card) -> String:
	if card == null or card.def == null:
		return ""
	var eid_list: Array = card.def.get("effect_ids") if card.def.get("effect_ids") != null else []
	var counters: Dictionary = card.counters if card.counters != null else {}
	for eid_raw in eid_list:
		var eff = _GenEventEffects.get_effect_by_id(StringName(String(eid_raw)))
		if eff == null or eff.progress_display.is_empty():
			continue
		var pd: Dictionary = eff.progress_display
		var prog: int = int(counters.get("var_%s" % String(pd.get("counter_key", &"")), 0))
		var text := "进度%d/%d" % [prog, int(pd.get("threshold", 0))]
		var claimed_key = pd.get("claimed_counter_key", &"")
		if claimed_key != &"" and int(counters.get("var_%s" % String(claimed_key), 0)) >= 1:
			text += "[已领]"
		return text
	return ""


func _hide_tooltip() -> void:
	_hovered_card_cid = &""
	if _tooltip_popup != null and is_instance_valid(_tooltip_popup):
		_tooltip_popup.visible = false
	set_process(false)


## 机师效果按钮悬停浮框：显示该效果的描述、当前可发动次数、发动条件。
## 独立于整行浮框（按钮粒度），复用 _tooltip_popup 定位/样式。
## extra_eff：合并展示的附加效果（pilot_002 EX 按钮合并进攻+防御描述；
## pilot_020 按钮2 合并的隐藏被动 effect_03/04 传 Array）。
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
	# 附加效果描述（EX 按钮合并的防御效果 / pilot_020 按钮2 合并的隐藏被动，作补充说明）
	var _extra_effs: Array = []
	if extra_eff is Array:
		_extra_effs = extra_eff
	elif extra_eff != null:
		_extra_effs.append(extra_eff)
	for _xe in _extra_effs:
		if _xe != null and String(_xe.description).strip_edges() != "":
			lines.append("[color=#fc9][b]%s[/b][/color]" % String(_xe.display_name))
			lines.append("[color=#ccc]%s[/color]" % String(_xe.description))
	# pilot_020 肯德 按钮2(弃置计数)：附加当前回合已弃置 X 张行动牌
	var te = _context.get("timing_engine") if _context != null else null
	if String(eff.effect_id) == "pilot_020_effect_02" and te != null and te.has_method(&"_current_turn_number"):
		var p020_turn: int = te._current_turn_number()
		var p020_cid: StringName = bind_ctx.get("card_instance_id", &"")
		var p020_gs = _context.get("game_state") if _context != null else null
		if p020_gs != null and p020_gs.cards != null and p020_cid != &"":
			var p020_card = p020_gs.cards.get(p020_cid)
			if p020_card != null:
				var p020_x: int = _ActionPilotEffects.get_pilot_020_x(p020_card, p020_turn)
				lines.append("[color=#9cf]本回合已弃置：%d 张行动牌[/color]" % p020_x)
	# pilot_028 乌尔 三个按钮（宣言/需交牌/X+1）：附加本轮宣言类型 + 当前 X（范围4+X）
	if String(eff.effect_id).begins_with("pilot_028_"):
		var p028_cid: StringName = bind_ctx.get("card_instance_id", &"")
		var p028_gs = _context.get("game_state") if _context != null else null
		if p028_gs != null and p028_gs.cards != null and p028_cid != &"":
			var p028_card = p028_gs.cards.get(p028_cid)
			if p028_card != null:
				var p028_decl: String = _ActionPilotEffects.get_pilot_028_declared(p028_card)
				if p028_decl == "":
					p028_decl = "未宣言"
				var p028_xv: int = _ActionPilotEffects.get_pilot_028_x(p028_card)
				lines.append("[color=#ffa]本轮宣言：%s[/color]" % p028_decl)
				lines.append("[color=#9cf]当前X：%d（范围4+X=%d）[/color]" % [p028_xv, 4 + p028_xv])
	# 通用进度显示（progress_display 元数据）：任务牌计数/奖励效果悬停显示当前进度与领取状态
	if not eff.progress_display.is_empty():
		var pd_main: Dictionary = eff.progress_display
		var pd_cid: StringName = bind_ctx.get("card_instance_id", &"")
		var pd_gs = _context.get("game_state") if _context != null else null
		if pd_gs != null and pd_gs.cards != null and pd_cid != &"":
			var pd_card = pd_gs.cards.get(pd_cid)
			if pd_card != null:
				var pd_prog: int = int(pd_card.counters.get("var_%s" % String(pd_main.get("counter_key", &"")), 0)) if pd_card.counters != null else 0
				var pd_line: String = "当前进度：%d/%d" % [pd_prog, int(pd_main.get("threshold", 0))]
				var pd_claim_key = pd_main.get("claimed_counter_key", &"")
				if pd_claim_key != &"":
					var pd_claimed: bool = pd_card.counters != null and int(pd_card.counters.get("var_%s" % String(pd_claim_key), 0)) >= 1
					pd_line += "（已领取）" if pd_claimed else "（未领取）"
				var pd_color := "#9c9" if pd_prog >= int(pd_main.get("threshold", 0)) else "#9cf"
				lines.append("[color=%s]%s[/color]" % [pd_color, pd_line])
	# 当前可发动次数（once_per_turn）
	if te != null and te.has_method(&"_current_turn_number") and eff.once_per_turn_key != &"":
		var cid: StringName = bind_ctx.get("card_instance_id", &"")
		# 授予效果（EX 按钮）：各目标独立计数，与 TimingEngine 计数键一致（泰特 pilot_073 等）。
		if te.has_method(&"once_per_turn_scope_cid"):
			cid = te.once_per_turn_scope_cid(bind_ctx, cid)
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
		# 去重：同一 effect（多监听共享额度，如亚林设置+弃置）只显示一次
		var _seen_keys: Dictionary = {}
		for timing: StringName in te.permanent_listeners:
			for entry in te.permanent_listeners[timing]:
				if entry == null or not (entry is Dictionary):
					continue
				var bc: Dictionary = entry.get("binding_context", {})
				if String(bc.get("card_instance_id", &"")) != String(cid):
					continue
				var eff = entry.get("effect")
				if eff == null:
					continue
				# 通用显示增强：effect 级无 once_per_turn_key 时，扫描 conditions 里
				# EFFECT_ONCE_PER_TURN_AVAILABLE 的 once_per_turn_key/once_per_turn_max
				# （显式 MARK_EFFECT_ONCE_PER_TURN_USED 计次模式，亚林 pilot_052 等）。
				var ot_key: StringName = eff.once_per_turn_key
				var ot_max: int = int(eff.once_per_turn_max)
				if ot_key == &"" and eff.conditions != null:
					for c: Dictionary in eff.conditions:
						if String(c.get("op", &"")) != "EFFECT_ONCE_PER_TURN_AVAILABLE":
							continue
						var c_params: Dictionary = c.get("params", {})
						if c_params.get("once_per_turn_key", &"") == &"":
							continue
						ot_key = c_params.get("once_per_turn_key", &"")
						ot_max = int(c_params.get("once_per_turn_max", 1))
						break
				if ot_key == &"":
					continue
				var key: String = "%s:%s" % [String(cid), String(ot_key)]
				if _seen_keys.has(key):
					continue
				_seen_keys[key] = true
				var turn_map: Dictionary = te._once_per_turn_used.get(key, {})
				var used: int = int(turn_map.get(turn_id, 0))
				var color := "#9a9" if used < ot_max else "#c66"
				lines.append("• [color=%s]%s：%d/%d[/color]" % [color, String(eff.display_name), used, ot_max])
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
