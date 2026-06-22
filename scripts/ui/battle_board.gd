extends Control
class_name BattleBoard

signal hex_clicked(hex: Dictionary)

const HEX_SIZE := 38.0
const TILE_COLOR := Color(0.16, 0.19, 0.22)
const TILE_HOVER_COLOR := Color(0.24, 0.32, 0.38)
const TILE_BORDER_COLOR := Color(0.42, 0.48, 0.52)
const PLAYER_COLOR := Color(0.2, 0.62, 0.95)
const ENEMY_COLOR := Color(0.94, 0.26, 0.24)
const TEXT_COLOR := Color(0.94, 0.96, 0.98)

var tiles: Array[Dictionary] = []
var units: Dictionary = {}
var hovered_hex: Dictionary = {}

func configure(new_tiles: Array, new_units: Dictionary) -> void:
	tiles = []
	for tile in new_tiles:
		if typeof(tile) == TYPE_DICTIONARY:
			tiles.append(_copy_hex(tile))
	units = new_units.duplicate(true)
	queue_redraw()

func _draw() -> void:
	for tile in tiles:
		var center := _hex_to_pixel(tile)
		var points := _hex_points(center)
		var color := TILE_HOVER_COLOR if _same_hex(tile, hovered_hex) else TILE_COLOR
		draw_colored_polygon(points, color)
		draw_polyline(points + PackedVector2Array([points[0]]), TILE_BORDER_COLOR, 2.0)
		_draw_hex_label(tile, center)
	for side in units.keys():
		var unit = units[side]
		if typeof(unit) == TYPE_DICTIONARY:
			_draw_unit(String(side), unit)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		var next_hover := _valid_hex_at(event.position)
		if not _same_hex(next_hover, hovered_hex):
			hovered_hex = next_hover
			queue_redraw()
	elif event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var clicked := _valid_hex_at(event.position)
			if not clicked.is_empty():
				hex_clicked.emit(clicked)

func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_EXIT:
		if not hovered_hex.is_empty():
			hovered_hex = {}
			queue_redraw()

func _draw_hex_label(hex: Dictionary, center: Vector2) -> void:
	var font := _draw_font()
	if font == null:
		return
	var text := "%d,%d" % [int(hex.get("q", 0)), int(hex.get("r", 0))]
	var text_size := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	draw_string(font, center - text_size * 0.5 + Vector2(0, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.62, 0.68, 0.72))

func _draw_unit(side: String, unit: Dictionary) -> void:
	var position = unit.get("position", {})
	if typeof(position) != TYPE_DICTIONARY:
		return
	var center := _hex_to_pixel(position)
	var color := PLAYER_COLOR if side == "player" else ENEMY_COLOR
	draw_circle(center, 18.0, color)
	draw_arc(center, 18.0, 0.0, TAU, 48, Color.BLACK, 2.0)
	var font := _draw_font()
	if font == null:
		return
	var label := "我" if side == "player" else "敌"
	var text_size := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18)
	draw_string(font, center - text_size * 0.5 + Vector2(0, 6), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TEXT_COLOR)

func _draw_font() -> Font:
	var font := get_theme_default_font()
	if font != null:
		return font
	return ThemeDB.fallback_font

func _hex_points(center: Vector2) -> PackedVector2Array:
	var points := PackedVector2Array()
	for index in range(6):
		var angle := deg_to_rad(60.0 * index - 30.0)
		points.append(center + Vector2(cos(angle), sin(angle)) * HEX_SIZE)
	return points

func _hex_to_pixel(hex: Dictionary) -> Vector2:
	var q := float(hex.get("q", 0))
	var r := float(hex.get("r", 0))
	var x := HEX_SIZE * sqrt(3.0) * (q + r / 2.0)
	var y := HEX_SIZE * 1.5 * r
	return _board_origin() + Vector2(x, y)

func _pixel_to_hex(point: Vector2) -> Dictionary:
	var local := point - _board_origin()
	var q := (sqrt(3.0) / 3.0 * local.x - local.y / 3.0) / HEX_SIZE
	var r := (2.0 / 3.0 * local.y) / HEX_SIZE
	return _round_axial(q, r)

func _round_axial(q: float, r: float) -> Dictionary:
	var x := q
	var z := r
	var y := -x - z
	var rounded_x: float = round(x)
	var rounded_y: float = round(y)
	var rounded_z: float = round(z)
	var x_diff: float = abs(rounded_x - x)
	var y_diff: float = abs(rounded_y - y)
	var z_diff: float = abs(rounded_z - z)
	if x_diff > y_diff and x_diff > z_diff:
		rounded_x = -rounded_y - rounded_z
	elif y_diff > z_diff:
		rounded_y = -rounded_x - rounded_z
	else:
		rounded_z = -rounded_x - rounded_y
	return {"q": int(rounded_x), "r": int(rounded_z)}

func _valid_hex_at(point: Vector2) -> Dictionary:
	var hex := _pixel_to_hex(point)
	for tile in tiles:
		if _same_hex(tile, hex):
			return _copy_hex(tile)
	return {}

func _same_hex(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty():
		return a.is_empty() and b.is_empty()
	return int(a.get("q", 0)) == int(b.get("q", 0)) and int(a.get("r", 0)) == int(b.get("r", 0))

func _copy_hex(hex: Dictionary) -> Dictionary:
	return {"q": int(hex.get("q", 0)), "r": int(hex.get("r", 0))}

func _board_origin() -> Vector2:
	return size * 0.5
