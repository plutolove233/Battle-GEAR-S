extends Control
class_name BattleBoard

signal hex_clicked(hex: Dictionary)  # 返回 q/r axial 坐标供战斗系统使用

# 网格参数 - flat-top 坐标系
# 参照样例图放大格子以填满背景区域
# 24列填满1536像素宽度：STEP_X = 1536/24 = 64，HEX_RADIUS = STEP_X/1.5 ≈ 42.7
# 但样例图格子更大，使用更大的半径
const HEX_RADIUS := 64.0  # 六边形外接圆半径（放大到64以匹配样例图）
const HEX_WIDTH := HEX_RADIUS * 2.0        # flat-top 宽度 = 128
const HEX_HEIGHT := sqrt(3.0) * HEX_RADIUS  # flat-top 高度 ≈ 110.85
const STEP_X := HEX_WIDTH * 0.75           # flat-top 水平步长 = 96
const STEP_Y := HEX_HEIGHT                 # flat-top 垂直步长 ≈ 110.85

# 网格尺寸：24列 x 8行
const GRID_COLS := 24
const GRID_ROWS := 8
const GRID_ORIGIN := Vector2(HEX_RADIUS, HEX_HEIGHT * 0.5)  # 左上角第一个格子中心

# 颜色规格
const NORMAL_FILL := Color(0.08, 0.13, 0.20, 0.08)
const NORMAL_BORDER := Color(0.75, 0.82, 0.95, 0.42)
const PLAYER_START_FILL := Color(0.0, 0.85, 0.65, 0.35)
const ENEMY_START_FILL := Color(0.9, 0.05, 0.15, 0.35)
const RESOURCE_FILL := Color(0.9, 0.75, 0.1, 0.28)
const EVENT_FILL := Color(0.35, 0.55, 1.0, 0.25)
const BLOCKED_FILL := Color(0.45, 0.05, 0.08, 0.42)
const SPECIAL_BORDER := Color(0.75, 0.82, 0.95, 0.75)
const HOVER_FILL := Color(0.16, 0.19, 0.22, 0.15)
const HOVER_BORDER := Color(0.24, 0.32, 0.38, 0.6)
const HIGHLIGHT_FILL := Color(0.2, 0.6, 0.3, 0.25)
const HIGHLIGHT_BORDER := Color(0.3, 0.8, 0.4, 0.7)
# 可攻击格（范围内有机甲的格）红色闪烁层
const ATTACK_TARGET_FILL := Color(0.9, 0.15, 0.15, 0.45)
const ATTACK_TARGET_BORDER := Color(1.0, 0.3, 0.3, 0.9)
const TEXT_COLOR := Color(0.62, 0.68, 0.72)

# ── 地形格（绿/红）：不透明实色填充，遮盖背景图，与攻击范围绿/可攻击红明显区分 ──
const GREEN_TILE_FILL := Color(0.06, 0.32, 0.13, 0.92)
const GREEN_TILE_BORDER := Color(0.16, 0.58, 0.26, 0.85)
const RED_TILE_FILL := Color(0.42, 0.06, 0.09, 0.92)
const RED_TILE_BORDER := Color(0.72, 0.18, 0.20, 0.85)

# ── 地图标记点（常驻贴图，淡色小图标）+ 活动标记（亮色大图标+光）──
# 金币=金黄色，事件=草绿色
const GOLD_POINT_COLOR := Color(0.96, 0.80, 0.13, 0.38)
const GOLD_MARKER_COLOR := Color(1.0, 0.84, 0.16, 0.96)
const EVENT_POINT_COLOR := Color(0.40, 0.78, 0.28, 0.40)
const EVENT_MARKER_COLOR := Color(0.52, 0.92, 0.34, 0.96)
const MARKER_GLOW := Color(1.0, 1.0, 0.85, 0.55)

const BORDER_WIDTH := 2.0
const ICON_RADIUS := HEX_RADIUS * 0.32

var tiles: Dictionary = {}  # key: Vector2i(col, row), value: Dictionary
var units: Dictionary = {}
var hovered_hex: Dictionary = {}
# 悬停移动路径预览（鼠标悬停可达格时画最短路线连线）
var _context = null  # GameContext（find_optimal_path 用）
var _local_mech_id: StringName = &""  # 本地玩家机甲 id（路径起点）
var _local_mech_pos: Dictionary = {}  # 本地机甲当前位置（axial q/r），移动中画"当前位置->目标"线用
var _hover_move_path: Array = []  # 悬停预览路径 center 列表，空=不画
# 逐格移动进行中标志 + 目标格。移动中不画悬停路径（避免误导），改画"当前位置->目标"实时连线。
var _move_active: bool = false
var _move_destination: Dictionary = {}  # axial {"q","r"}，本次移动终点
var _move_path_centers: Array = []  # 当前位置->目标的逐格 center 列表（实时更新）
# 移动开始时规划的原定路线（axial cells，含起点+各格）。移动中只显示其剩余尾巴，
# 不重新寻路--保证路线始终是同一条、越来越短（用户要求）。
var _planned_path_cells: Array = []
var background_texture: Texture2D  # 网格背景
var base_background_texture: Texture2D  # 底层地图背景
var highlighted_hexes: Dictionary = {}  # key: "q,r" → true
# 可攻击格高亮层（红色闪烁）：key "q,r" → true
var attack_target_hexes: Dictionary = {}
# 闪烁动画累计时间与开关
var _blink_accum: float = 0.0
var _blink_enabled: bool = false
# 闪烁重绘节流累计：闪烁是视觉脉冲，无需 60fps 全速重画整块棋盘。
# D3D12 下持续高频 queue_redraw 会反复创建顶点/索引缓冲，长会话耗尽显存描述符堆，
# 报 buffer_create E_OUTOFMEMORY(0x8007000e) -> vertex_array null -> vertex format
# 不匹配 / free invalid ID 级联。降频到 ~15Hz 重绘，缓冲创建削减数倍，脉冲观感仍流畅。
var _blink_redraw_accum: float = 0.0
const _BLINK_REDRAW_INTERVAL: float = 1.0 / 15.0

# 缩放适配：将 2368×942 的网格缩放到控件实际大小
var _grid_scale: float = 1.0
var _grid_offset: Vector2 = Vector2.ZERO  # 居中偏移

func configure(new_tiles: Array, new_units: Dictionary) -> void:
	# 直接使用战斗系统的 axial 地图，转换为 odd-q 显示
	# tiles（地形）在一场战斗中不变，仅在数量变化（新战斗/地图切换）时重建，
	# 避免每次 _refresh_battle 都清空重建 192 格字典导致移动循环卡顿。
	var tiles_changed: bool = tiles.size() != new_tiles.size()
	if tiles_changed:
		tiles.clear()
		for tile in new_tiles:
			if typeof(tile) != TYPE_DICTIONARY:
				continue
			var q: int = int(tile.get("q", 0))
			var r: int = int(tile.get("r", 0))
			var grid_pos := _axial_to_grid(q, r)
			var key := Vector2i(grid_pos.col, grid_pos.row)
			var tile_type := "normal"
			# 地形优先：绿/红格由 map_state.terrain 决定（PvP 配置）
			var terrain: String = String(tile.get("terrain", "NORMAL"))
			if terrain == "GREEN":
				tile_type = "green"
			elif terrain == "RED":
				tile_type = "red"
			elif tile.has("blocked") and tile.blocked:
				tile_type = "blocked"
			tiles[key] = {
				"col": grid_pos.col,
				"row": grid_pos.row,
				"q": q,
				"r": r,
				"type": tile_type,
				"enabled": true
			}
	units.clear()
	for side in new_units.keys():
		var unit: Dictionary = new_units[side]
		if typeof(unit) != TYPE_DICTIONARY:
			continue
		var pos = unit.get("position", {})
		if typeof(pos) == TYPE_DICTIONARY:
			var q: int = int(pos.get("q", 0))
			var r: int = int(pos.get("r", 0))
			var grid_pos := _axial_to_grid(q, r)
			units[side] = unit.duplicate(true)
			units[side]["position"] = {"col": grid_pos.col, "row": grid_pos.row}
		else:
			units[side] = unit.duplicate(true)
	_load_background()
	_update_grid_transform()
	queue_redraw()

## 仅更新单位数据并重绘（不重建地形、不重算 _grid_scale/_grid_offset）。
## 用于逐格移动轻量刷新：地形与控件尺寸在一场战斗中不变，逐格重算 _update_grid_transform
## 会在全量面板重建导致布局抖动时读到瞬态 get_rect()，使 _grid_scale 变形放大。
func update_units(new_units: Dictionary) -> void:
	units.clear()
	for side in new_units.keys():
		var unit: Dictionary = new_units[side]
		if typeof(unit) != TYPE_DICTIONARY:
			continue
		var pos = unit.get("position", {})
		if typeof(pos) == TYPE_DICTIONARY:
			var q: int = int(pos.get("q", 0))
			var r: int = int(pos.get("r", 0))
			var grid_pos := _axial_to_grid(q, r)
			units[side] = unit.duplicate(true)
			units[side]["position"] = {"col": grid_pos.col, "row": grid_pos.row}
		else:
			units[side] = unit.duplicate(true)
	queue_redraw()

## 设置移动开始时规划的原定路线（axial cells，含起点+各格）。移动中只显示其剩余尾巴。
func set_planned_path(cells: Array) -> void:
	_planned_path_cells = cells.duplicate(true)
	_update_move_path_tail()

## 根据机甲当前位置（_local_mech_pos），从原定路线中取出"当前位置->终点"的剩余尾巴，
## 存为 _move_path_centers。不重新寻路--沿原路线取尾巴，保证路线始终是同一条、越来越短。
func _update_move_path_tail() -> void:
	_move_path_centers.clear()
	if _planned_path_cells.is_empty():
		return
	# 找到本地机甲当前所在格在原定路线中的索引
	var start_idx: int = 0
	if not _local_mech_pos.is_empty():
		var cq: int = int(_local_mech_pos.get("q", 0))
		var cr: int = int(_local_mech_pos.get("r", 0))
		for i in range(_planned_path_cells.size()):
			var c = _planned_path_cells[i]
			if int(c.get("q", 0)) == cq and int(c.get("r", 0)) == cr:
				start_idx = i
				break
	# 从当前位置到终点的各格 center
	for i in range(start_idx, _planned_path_cells.size()):
		var c = _planned_path_cells[i]
		var cg := _axial_to_grid(int(c.get("q", 0)), int(c.get("r", 0)))
		_move_path_centers.append(_grid_to_world(cg.col, cg.row))

func _axial_to_grid(q: int, r: int) -> Dictionary:
	# axial to odd-q 转换 (flat-top)
	# col = q（列号就是 axial 的 q）
	# row = r + floor((q + 1) / 2) 或 row = r + (q + (q&1)) / 2
	var col := q
	var row := r + (q + (q % 2)) / 2
	return {"col": col, "row": row}

## 网格自然（未缩放）尺寸
func _grid_natural_size() -> Vector2:
	var w := GRID_COLS * STEP_X + HEX_RADIUS
	var h := GRID_ROWS * STEP_Y + STEP_Y * 0.5
	return Vector2(w, h)

## 根据控件实际大小计算缩放因子和居中偏移
func _update_grid_transform() -> void:
	var control_size := get_rect().size
	if control_size.x <= 0 or control_size.y <= 0:
		_grid_scale = 1.0
		_grid_offset = Vector2.ZERO
		return
	var natural := _grid_natural_size()
	var sx := control_size.x / natural.x
	var sy := control_size.y / natural.y
	_grid_scale = minf(sx, sy)
	# 居中放置
	_grid_offset = (control_size - natural * _grid_scale) * 0.5

## 鼠标屏幕坐标 → 网格自然坐标（逆变换）
func _screen_to_grid_coords(screen_pos: Vector2) -> Vector2:
	return (screen_pos - _grid_offset) / _grid_scale

func _load_background() -> void:
	# 纹理只需加载一次（load 有缓存但仍非零开销），避免每次 configure 重建都重复 load
	# 导致移动循环卡顿。已加载则直接复用。
	if background_texture != null and base_background_texture != null:
		return
	# 加载网格背景
	var grid_path := "res://asset/BattleField/hex_grid_redrawn_crisp_1536x768.png"
	if background_texture == null and ResourceLoader.exists(grid_path):
		background_texture = load(grid_path)
	# 加载底层地图背景
	var base_path := "res://asset/BattleField/图层1-最底背景图/地图背景图.png"
	if base_background_texture == null and ResourceLoader.exists(base_path):
		base_background_texture = load(base_path)

func _draw() -> void:
	# 不在 _draw 里调 _update_grid_transform()：每次重绘都重算 _grid_scale 会读到瞬态
	# get_rect().size（布局抖动时），致整片棋盘闪一下/变形。缩放仅在 configure 与
	# NOTIFICATION_RESIZED（窗口尺寸变化）时重算，_draw 用缓存的 _grid_scale/_grid_offset。
	draw_set_transform(_grid_offset, 0.0, Vector2(_grid_scale, _grid_scale))
	_draw_background()
	# 地图标记叠加层查找表（标记点常驻 + 活动标记），每帧从 _context 读取（标记会变化）
	var marker_lookup := _build_marker_lookup()
	# 绘制所有格子
	for key in tiles.keys():
		var tile: Dictionary = tiles[key]
		var center := _grid_to_world(tile.col, tile.row)
		var points := _hex_points(center)
		var fill_color: Color = _get_fill_color(tile.type)
		var border_color: Color = _get_border_color(tile.type)
		# 悬停高亮 - 比较 q/r 坐标
		var tile_axial := {"q": tile.q, "r": tile.r}
		if _same_hex(tile_axial, hovered_hex):
			fill_color = HOVER_FILL
			border_color = HOVER_BORDER
		# 范围高亮（攻击/移动范围）
		var tile_key := "%s,%s" % [tile.q, tile.r]
		if highlighted_hexes.has(tile_key):
			fill_color = HIGHLIGHT_FILL
			border_color = HIGHLIGHT_BORDER
		draw_colored_polygon(points, fill_color)
		draw_polyline(points + PackedVector2Array([points[0]]), border_color, BORDER_WIDTH / _grid_scale)
		# 可攻击格红色闪烁叠加（压在绿色范围之上）
		if attack_target_hexes.has(tile_key):
			var blink_t: float = (sin(_blink_accum * 5.0) * 0.5 + 0.5) if _blink_enabled else 1.0
			var red_fill := Color(ATTACK_TARGET_FILL.r, ATTACK_TARGET_FILL.g, ATTACK_TARGET_FILL.b, ATTACK_TARGET_FILL.a * blink_t)
			var red_border := Color(ATTACK_TARGET_BORDER.r, ATTACK_TARGET_BORDER.g, ATTACK_TARGET_BORDER.b, ATTACK_TARGET_BORDER.a * blink_t)
			draw_colored_polygon(points, red_fill)
			draw_polyline(points + PackedVector2Array([points[0]]), red_border, (BORDER_WIDTH * 1.6) / _grid_scale)
		_draw_hex_label(tile, center)
		_draw_special_icon(tile, center)
		_draw_marker_overlay(tile, center, marker_lookup)
	# 移动路径预览线：逐格移动进行中画"当前位置->目标"的逐格路径（实时更新，随机甲逐格推进缩短）；
	# 否则画悬停预览路径（鼠标悬停可达格的最短路线）。线/圆点用白色边缘高光增强清晰度。
	var _path_centers: Array = []
	if _move_active and _move_path_centers.size() >= 2:
		_path_centers = _move_path_centers
	elif not _move_active and _hover_move_path.size() >= 2:
		_path_centers = _hover_move_path
	if _path_centers.size() >= 2:
		var line_color := Color(0.5, 0.5, 0.5, 0.55)
		var edge_color := Color(1.0, 1.0, 1.0, 0.6)
		# 白色边缘：先画稍宽白线，再叠灰线 -> 灰线带白边，清晰度提升
		for i in range(_path_centers.size() - 1):
			draw_line(_path_centers[i], _path_centers[i + 1], edge_color, 3.5 / _grid_scale)
			draw_line(_path_centers[i], _path_centers[i + 1], line_color, 2.0 / _grid_scale)
		# 节点圆点：灰色填充 + 白色描边
		for c in _path_centers:
			draw_circle(c, 7.0 / _grid_scale, line_color)
			draw_arc(c, 7.0 / _grid_scale, 0.0, TAU, 24, edge_color, 1.5 / _grid_scale)
	# 绘制单位
	for side in units.keys():
		var unit = units[side]
		if typeof(unit) == TYPE_DICTIONARY:
			_draw_unit(String(side), unit)

func _draw_background() -> void:
	# 背景纹理按网格自然尺寸绘制，缩放由 draw_set_transform 处理
	var natural := _grid_natural_size()
	if base_background_texture != null:
		draw_texture_rect(base_background_texture, Rect2(Vector2.ZERO, natural), false)
	if background_texture != null:
		draw_texture_rect(background_texture, Rect2(Vector2.ZERO, natural), false)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var grid_pos := _screen_to_grid_coords(event.position)
		var next_hover := _valid_hex_at(grid_pos)
		if not _same_hex(next_hover, hovered_hex):
			hovered_hex = next_hover
			_update_hover_move_path()
			queue_redraw()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var grid_pos := _screen_to_grid_coords(event.position)
			var clicked := _valid_hex_at(grid_pos)
			if not clicked.is_empty():
				hex_clicked.emit(clicked)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_update_grid_transform()
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT:
		if not hovered_hex.is_empty():
			hovered_hex = {}
			_hover_move_path.clear()
			queue_redraw()

# 闪烁动画：累计时间并触发重绘（节流到 ~15Hz，避免每帧重画整块棋盘耗尽 D3D12 显存）
func _process(delta: float) -> void:
	if not _blink_enabled:
		return
	_blink_accum += delta
	_blink_redraw_accum += delta
	if _blink_redraw_accum >= _BLINK_REDRAW_INTERVAL:
		_blink_redraw_accum = 0.0
		queue_redraw()

func _draw_hex_label(hex: Dictionary, center: Vector2) -> void:
	var font := _draw_font()
	if font == null:
		return
	var font_size := int(12.0 / _grid_scale)
	if font_size <= 0:
		return
	var text := "%d,%d" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center - text_size * 0.5 + Vector2(0, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, TEXT_COLOR)

func _draw_special_icon(tile: Dictionary, center: Vector2) -> void:
	var tile_type: String = tile.get("type", "normal")
	if tile_type == "normal":
		return
	var icon_r := ICON_RADIUS / _grid_scale
	var line_w := 2.0 / _grid_scale
	# 绘制特殊点图标
	match tile_type:
		"resource":
			# 黄色菱形
			var diamond := PackedVector2Array([
				Vector2(center.x, center.y - icon_r),
				Vector2(center.x + icon_r, center.y),
				Vector2(center.x, center.y + icon_r),
				Vector2(center.x - icon_r, center.y)
			])
			draw_colored_polygon(diamond, Color(0.9, 0.75, 0.1, 0.8))
		"event":
			# 蓝色圆环
			draw_arc(center, icon_r, 0.0, TAU, 24, Color(0.35, 0.55, 1.0, 0.8), line_w)
		"start_player", "start_enemy":
			# 白色虚线圆环效果（简化为实线）
			var color := Color(1.0, 1.0, 1.0, 0.7)
			draw_arc(center, icon_r, 0.0, TAU, 24, color, line_w)

# ═══════════════════════════════════════════
# 地图标记叠加层（标记点常驻 + 活动标记）
# ═══════════════════════════════════════════

## 从 _context.game_state.map_state 构建 "q,r" -> {point_type, marker_types[]} 查找表
func _build_marker_lookup() -> Dictionary:
	var lookup: Dictionary = {}
	if _context == null:
		return lookup
	var gs = _context.game_state
	if gs == null:
		return lookup
	var ms = gs.map_state
	if ms == null:
		return lookup
	# 标记点（常驻贴图）
	for p in ms.marker_points:
		var k := "%s,%s" % [int(p.get("q", 0)), int(p.get("r", 0))]
		if not lookup.has(k):
			lookup[k] = {"point_type": &"", "marker_types": []}
		lookup[k]["point_type"] = p.get("type", &"")
	# 活动标记
	for m in ms.markers:
		var k := "%s,%s" % [int(m.get("q", 0)), int(m.get("r", 0))]
		if not lookup.has(k):
			lookup[k] = {"point_type": &"", "marker_types": []}
		lookup[k]["marker_types"].append(m.get("type", &""))
	return lookup

## 绘制某格的标记点（淡色小图标）+ 活动标记（亮色大图标+光晕）
func _draw_marker_overlay(tile: Dictionary, center: Vector2, lookup: Dictionary) -> void:
	if lookup.is_empty():
		return
	var k := "%s,%s" % [int(tile.get("q", 0)), int(tile.get("r", 0))]
	var overlay = lookup.get(k)
	if overlay == null:
		return
	var icon_r := ICON_RADIUS / _grid_scale
	var line_w := 2.0 / _grid_scale
	var point_type: StringName = overlay.get("point_type", &"")
	var marker_types: Array = overlay.get("marker_types", [])
	# 标记点：淡色小图标（金币金黄菱形 / 事件草绿圆环）
	match point_type:
		&"GOLD":
			_draw_diamond(center, icon_r * 0.65, GOLD_POINT_COLOR, line_w * 0.5)
		&"EVENT":
			draw_arc(center, icon_r * 0.65, 0.0, TAU, 20, EVENT_POINT_COLOR, line_w * 0.5)
	# 活动标记：亮色大图标 + 光晕
	for mtype in marker_types:
		match mtype:
			&"GOLD":
				draw_arc(center, icon_r * 1.55, 0.0, TAU, 24, MARKER_GLOW, line_w * 0.8)
				_draw_diamond(center, icon_r * 1.05, GOLD_MARKER_COLOR, line_w)
			&"EVENT":
				draw_arc(center, icon_r * 1.55, 0.0, TAU, 24, MARKER_GLOW, line_w * 0.8)
				draw_arc(center, icon_r * 1.05, 0.0, TAU, 24, EVENT_MARKER_COLOR, line_w * 1.6)
			&"TRAP":
				_draw_trap_icon(center, icon_r, line_w)

## 菱形图标
func _draw_diamond(center: Vector2, radius: float, fill_color: Color, line_w: float) -> void:
	var diamond := PackedVector2Array([
		Vector2(center.x, center.y - radius),
		Vector2(center.x + radius, center.y),
		Vector2(center.x, center.y + radius),
		Vector2(center.x - radius, center.y)
	])
	draw_colored_polygon(diamond, fill_color)
	if line_w > 0.0:
		draw_polyline(diamond + PackedVector2Array([diamond[0]]), Color(1, 1, 1, fill_color.a * 0.6), line_w)

## 陷阱标记：橙色三角警告（橙色系，与攻击范围绿/可攻击红区分）
func _draw_trap_icon(center: Vector2, radius: float, line_w: float) -> void:
	var tri := PackedVector2Array([
		Vector2(center.x, center.y - radius),
		Vector2(center.x + radius * 0.9, center.y + radius * 0.7),
		Vector2(center.x - radius * 0.9, center.y + radius * 0.7)
	])
	draw_colored_polygon(tri, Color(0.95, 0.45, 0.08, 0.94))
	draw_polyline(tri + PackedVector2Array([tri[0]]), Color(1.0, 0.78, 0.2, 0.95), line_w)

func _draw_unit(side: String, unit: Dictionary) -> void:
	var unit_pos = unit.get("position", {})
	if typeof(unit_pos) != TYPE_DICTIONARY:
		return
	var col: int = int(unit_pos.get("col", 0))
	var row: int = int(unit_pos.get("row", 0))
	var center := _grid_to_world(col, row)
	var color := PLAYER_START_FILL if side == "player" else ENEMY_START_FILL
	var unit_r := 18.0 / _grid_scale
	draw_circle(center, unit_r, color)
	draw_arc(center, unit_r, 0.0, TAU, 48, Color.BLACK, 2.0 / _grid_scale)
	var font := _draw_font()
	if font == null:
		return
	var label := "我" if side == "player" else "敌"
	var font_size := int(18.0 / _grid_scale)
	if font_size <= 0:
		return
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center - text_size * 0.5 + Vector2(0, 6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.94, 0.96, 0.98))
	# 联合状态标记：被联合的机甲下方显示 "联×N"（N=与之联合的 unite 机甲数）。
	# 详细 unite 机甲名见 unit.unite_statuses；棋盘格空间有限只标数量。
	var unite_list: Array = unit.get("unite_statuses", [])
	if not unite_list.is_empty():
		var unite_label := "联×%d" % unite_list.size()
		var unite_size := font.get_string_size(unite_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
		draw_string(font, center - unite_size * 0.5 + Vector2(0, 6 + font_size + 2), unite_label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(1.0, 0.85, 0.2))

func _draw_font() -> Font:
	var font := get_theme_default_font()
	if font != null:
		return font
	return ThemeDB.fallback_font

func _get_fill_color(tile_type: String) -> Color:
	match tile_type:
		"start_player": return PLAYER_START_FILL
		"start_enemy": return ENEMY_START_FILL
		"resource": return RESOURCE_FILL
		"event": return EVENT_FILL
		"blocked": return BLOCKED_FILL
		"green": return GREEN_TILE_FILL
		"red": return RED_TILE_FILL
		_: return NORMAL_FILL

func _get_border_color(tile_type: String) -> Color:
	match tile_type:
		"green": return GREEN_TILE_BORDER
		"red": return RED_TILE_BORDER
	if tile_type != "normal":
		return SPECIAL_BORDER
	return NORMAL_BORDER

func _grid_to_world(col: int, row: int) -> Vector2:
	# 动态计算网格起点，使地图居中
	var origin := _calculate_grid_origin()
	var x := origin.x + col * STEP_X
	var y := origin.y + row * STEP_Y
	# flat-top odd-q: 奇数列向下偏移半个高度
	if col % 2 == 1:
		y += STEP_Y * 0.5
	return Vector2(x, y)

func _calculate_grid_origin() -> Vector2:
	# 网格从左上角开始，匹配放大的背景图
	return GRID_ORIGIN

func _world_to_grid(point: Vector2) -> Dictionary:
	# 反向转换 - 找到最近的格子
	var best_col: int = -1
	var best_row: int = -1
	var best_dist: float = INF
	for key in tiles.keys():
		var tile: Dictionary = tiles[key]
		var center := _grid_to_world(tile.col, tile.row)
		var dist := point.distance_to(center)
		if dist < best_dist:
			best_dist = dist
			best_col = tile.col
			best_row = tile.row
	if best_dist < HEX_RADIUS and best_col >= 0:
		var tile_key := Vector2i(best_col, best_row)
		if tiles.has(tile_key):
			return {"q": tiles[tile_key].q, "r": tiles[tile_key].r}
	return {}

func _hex_points(center: Vector2) -> PackedVector2Array:
	# flat-top 六边形顶点（顶部平边）
	var points := PackedVector2Array()
	for i in range(6):
		var angle := deg_to_rad(60.0 * i)  # 从 0° 开始，使顶部为平边
		var point := Vector2(
			center.x + HEX_RADIUS * cos(angle),
			center.y + HEX_RADIUS * sin(angle)
		)
		points.append(point)
	return points

func _valid_hex_at(point: Vector2) -> Dictionary:
	return _world_to_grid(point)

func _same_hex(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return a.is_empty() and b.is_empty()
	# 比较 axial 坐标 (q/r)
	return int(a.get("q", 0)) == int(b.get("q", 0)) and int(a.get("r", 0)) == int(b.get("r", 0))


## 悬停可达格时，计算从本地机甲到悬停格的最短路径，存 center 列表供 _draw 画连线。
## 仅己方回合、机甲可移动、悬停格可达时画；否则清空（避免误导）。
## 逐格移动进行中（_move_active）不画悬停路径--改由 _draw 画"当前位置->目标"实时连线，
## 避免移动中鼠标晃动显示到其它格的误导路径。
func _update_hover_move_path() -> void:
	_hover_move_path.clear()
	if _move_active:
		return
	if _context == null or _local_mech_id == &"" or hovered_hex.is_empty():
		return
	var gs = _context.game_state
	if gs == null or _context.map_service == null:
		return
	var mech = gs.mechs.get(_local_mech_id)
	if mech == null or not mech.can_move() or mech.power <= 0:
		return
	# 仅当前回合方预览（敌方回合/无动力不画线）
	if mech.owner_player_id != gs.active_player_id:
		return
	var path: Array = _context.map_service.find_optimal_path(_local_mech_id, hovered_hex, mech.power)
	if path.is_empty():
		return
	# 起点（机甲当前格）+ 路径各格 -> center 列表
	var centers: Array = []
	var start_grid := _axial_to_grid(int(mech.position.get("q", 0)), int(mech.position.get("r", 0)))
	centers.append(_grid_to_world(start_grid.col, start_grid.row))
	for cell in path:
		var cg := _axial_to_grid(int(cell.get("q", 0)), int(cell.get("r", 0)))
		centers.append(_grid_to_world(cg.col, cg.row))
	_hover_move_path = centers

## 高亮指定hex列表（攻击/移动范围）
func highlight_hexes(hexes: Array[Dictionary]) -> void:
	highlighted_hexes.clear()
	for hex: Dictionary in hexes:
		var key: String = "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
		highlighted_hexes[key] = true
	queue_redraw()

## 清除高亮
func clear_highlight() -> void:
	highlighted_hexes.clear()
	clear_attack_targets()
	queue_redraw()

## 高亮可攻击格（红色闪烁层）。与绿色范围层叠加显示。
func highlight_attack_targets(hexes: Array[Dictionary]) -> void:
	attack_target_hexes.clear()
	for hex: Dictionary in hexes:
		var key: String = "%s,%s" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
		attack_target_hexes[key] = true
	_blink_enabled = not attack_target_hexes.is_empty()
	_blink_accum = 0.0
	_blink_redraw_accum = 0.0
	set_process(_blink_enabled)
	queue_redraw()

## 清除可攻击格红色高亮层（停止闪烁）
func clear_attack_targets() -> void:
	attack_target_hexes.clear()
	_blink_enabled = false
	_blink_accum = 0.0
	_blink_redraw_accum = 0.0
	set_process(false)
	queue_redraw()
