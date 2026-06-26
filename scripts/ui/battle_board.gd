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
const TEXT_COLOR := Color(0.62, 0.68, 0.72)

const BORDER_WIDTH := 2.0
const ICON_RADIUS := HEX_RADIUS * 0.32

var tiles: Dictionary = {}  # key: Vector2i(col, row), value: Dictionary
var units: Dictionary = {}
var hovered_hex: Dictionary = {}
var background_texture: Texture2D  # 网格背景
var base_background_texture: Texture2D  # 底层地图背景
var highlighted_hexes: Dictionary = {}  # key: "q,r" → true

# 缩放适配：将 2368×942 的网格缩放到控件实际大小
var _grid_scale: float = 1.0
var _grid_offset: Vector2 = Vector2.ZERO  # 居中偏移

func configure(new_tiles: Array, new_units: Dictionary) -> void:
	# 直接使用战斗系统的 axial 地图，转换为 odd-q 显示
	tiles.clear()
	for tile in new_tiles:
		if typeof(tile) != TYPE_DICTIONARY:
			continue
		var q: int = int(tile.get("q", 0))
		var r: int = int(tile.get("r", 0))
		var grid_pos := _axial_to_grid(q, r)
		var key := Vector2i(grid_pos.col, grid_pos.row)
		var tile_type := "normal"
		# 检查是否为阻挡格
		if tile.has("blocked") and tile.blocked:
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
	# 加载网格背景
	var grid_path := "res://asset/BattleField/hex_grid_redrawn_crisp_1536x768.png"
	if ResourceLoader.exists(grid_path):
		background_texture = load(grid_path)
	# 加载底层地图背景
	var base_path := "res://asset/BattleField/图层1-最底背景图/地图背景图.png"
	if ResourceLoader.exists(base_path):
		base_background_texture = load(base_path)

func _draw() -> void:
	_update_grid_transform()
	# 应用缩放变换：所有后续绘制自动缩放+居中
	draw_set_transform(_grid_offset, 0.0, Vector2(_grid_scale, _grid_scale))
	_draw_background()
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
		_draw_hex_label(tile, center)
		_draw_special_icon(tile, center)
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
			queue_redraw()

func _draw_hex_label(hex: Dictionary, center: Vector2) -> void:
	var font := _draw_font()
	if font == null:
		return
	var font_size := int(12.0 / _grid_scale)
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
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	draw_string(font, center - text_size * 0.5 + Vector2(0, 6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.94, 0.96, 0.98))

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
		_: return NORMAL_FILL

func _get_border_color(tile_type: String) -> Color:
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
	queue_redraw()