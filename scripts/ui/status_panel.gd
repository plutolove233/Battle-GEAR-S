## StatusPanel.gd - 机甲状态列表面板
##
## 集中显示场上所有机甲的当前状态（联合/锁定/聚能/折扣等）。
## 通用设计：遍历 game_state.mechs 所有机甲，不绑定具体玩家（PvP 多人类玩家可复用）。
extends PopupPanel
class_name StatusPanel

var _context = null  # type: GameContext
var _vbox: VBoxContainer


func _ready() -> void:
	_vbox = VBoxContainer.new()
	add_child(_vbox)


## 配置弹窗：从 GameContext 读取所有机甲状态
func configure(game_context) -> void:
	_context = game_context
	_refresh()


func _refresh() -> void:
	if _context == null or _vbox == null:
		return
	for child in _vbox.get_children():
		child.queue_free()

	var gs = _context.game_state
	if gs == null:
		return

	var title := Label.new()
	title.text = "── 机甲状态 ──"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 18)
	title.add_theme_color_override("font_color", Color(0.9, 0.85, 0.7))
	_vbox.add_child(title)

	# 遍历所有机甲（通用：不限定 player/enemy）
	var has_any: bool = false
	for mech_id: StringName in gs.mechs:
		var mech = gs.mechs[mech_id]
		if mech == null:
			continue
		var mech_name: String = mech.frame_def.display_name if (mech.frame_def != null) else String(mech_id)
		var owner_pid: StringName = mech.owner_player_id
		var owner_label: String = String(owner_pid) if owner_pid != &"" else "?"
		var mech_header := Label.new()
		mech_header.text = "■ %s (%s)" % [mech_name, owner_label]
		mech_header.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
		mech_header.add_theme_font_size_override("font_size", 15)
		_vbox.add_child(mech_header)

		# 聚能是武器状态（在装备面板武器详情显示），不在机甲状态面板列出
		var shown_statuses: Array = []
		for s: Dictionary in mech.statuses:
			if String(s.get("type", &"")) == "ENERGY_CHARGE":
				continue
			shown_statuses.append(s)
		if shown_statuses.is_empty():
			var none := Label.new()
			none.text = "  （无状态）"
			none.add_theme_color_override("font_color", Color(0.55, 0.55, 0.55))
			_vbox.add_child(none)
		else:
			has_any = true
			for s: Dictionary in shown_statuses:
				var line := Label.new()
				line.text = "  • " + _format_status(gs, s)
				line.add_theme_color_override("font_color", Color(0.75, 0.8, 0.75))
				_vbox.add_child(line)

		var sep := HSeparator.new()
		_vbox.add_child(sep)

	var close_btn := Button.new()
	close_btn.text = "关闭"
	close_btn.custom_minimum_size = Vector2(140, 32)
	close_btn.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	close_btn.pressed.connect(func(): visible = false)
	_vbox.add_child(close_btn)


## 格式化单个状态为可读文本
func _format_status(gs, s: Dictionary) -> String:
	var t: StringName = s.get("type", &"")
	match String(t):
		"UNITE":
			var u_mid: StringName = s.get("unite", &"")
			var u_mech = gs.mechs.get(u_mid) if u_mid != &"" else null
			var u_name: String = u_mech.frame_def.display_name if (u_mech != null and u_mech.frame_def != null) else String(u_mid)
			return "联合：被 %s 联合（可联合攻击1次）" % u_name
		"LOCKED":
			var locker_pid: StringName = s.get("source_player_id", &"")
			var locker_mech = gs.get_mech_for_player(locker_pid) if locker_pid != &"" else null
			var locker_name: String = locker_mech.frame_def.display_name if (locker_mech != null and locker_mech.frame_def != null) else String(locker_pid)
			return "锁定：被 %s 锁定（无法迎击其攻击）" % locker_name
		"ENERGY_CHARGE":
			return "聚能：下次武器攻击+威力"
		"DISCOUNT":
			return "折扣：购买打折"
		"POWER_MODIFIER":
			return "动力%+d" % int(s.get("delta", 0))
		"cannot_attack":
			return "不能攻击"
		"cannot_move":
			return "不能移动"
		"NEXT_ATTACK_POWER_BUFF":
			return "下次攻击威力增益"
		"swapped_attack_count":
			return "攻击次数/手牌上限已交换"
		"attack_count_modifier":
			return "攻击次数%+d" % int(s.get("delta", 0))
		_:
			var extra: String = ""
			if s.has("delta"):
				extra = "%+d" % int(s.get("delta", 0))
			elif s.has("duration"):
				extra = "持续%s" % str(s.get("duration"))
			return "%s%s" % [String(t), extra]
