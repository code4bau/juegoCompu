extends Node3D

@export var port: int = 8000
@export var pointing_cone_degrees: float = 40.0 # Grados para recorrer la pantalla de borde a borde
@export var brush_radius: int = 2 # Tamaño del pincel en celdas
@export var phone_axis_mode: int = 0

@onready var paredes: MeshInstance3D = $Paredes
@onready var pixel_overlay: ColorRect = $CanvasLayer/ColorRect
@onready var cuadro_completo: Node3D = $Cuadro_Completo

var server: PacketPeerUDP = PacketPeerUDP.new()
var transicion_disparada: bool = false
var origin_quat: Quaternion = Quaternion.IDENTITY

# Puntero 2D y trayectoria del pincel
var current_pointer_uv: Vector2 = Vector2(0.5, 0.5)
var last_pointer_uv: Vector2 = Vector2(0.5, 0.5)
var is_pointing_active: bool = false

# --- Autómata Celular (AC) ---
const CA_WIDTH: int = 32
const CA_HEIGHT: int = 32
const TOTAL_CELLS: int = CA_WIDTH * CA_HEIGHT

var ca_grid: PackedFloat32Array = PackedFloat32Array()
var ca_grid_next: PackedFloat32Array = PackedFloat32Array()
var ca_texture: ImageTexture
var ca_image: Image

func _ready() -> void:
	server.close()
	var err: Error = server.bind(port)
	if err != OK:
		printerr("CRÍTICO: No se pudo abrir el puerto UDP %d." % port)

	_init_ca_grid()

	if pixel_overlay and pixel_overlay.material is ShaderMaterial:
		var mat := pixel_overlay.material as ShaderMaterial
		mat.set_shader_parameter("ca_texture", ca_texture)
		mat.set_shader_parameter("pixel_size", 15.0)

func _init_ca_grid() -> void:
	ca_grid.resize(TOTAL_CELLS)
	ca_grid_next.resize(TOTAL_CELLS)
	ca_grid.fill(0.0)
	ca_grid_next.fill(0.0)
	ca_image = Image.create_empty(CA_WIDTH, CA_HEIGHT, false, Image.FORMAT_RGBA8)
	ca_texture = ImageTexture.create_from_image(ca_image)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		origin_quat = Quaternion.IDENTITY
		is_pointing_active = false
		transicion_disparada = false
		_init_ca_grid()
		print(">> RECALIBRADO: Puntero reseteado al centro de pantalla.")

func _process(delta: float) -> void:
	while server.get_available_packet_count() > 0:
		var packet: PackedByteArray = server.get_packet()
		_process_raw_osc(packet)

	# 1. Trazado continuo entre la posición previa y la actual del celular
	if is_pointing_active:
		_paint_line(last_pointer_uv, current_pointer_uv)
		last_pointer_uv = current_pointer_uv

	# 2. Evaluación de reglas del Autómata Celular y conteo de cobertura
	var covered_cells := _step_ca(delta)
	var coverage := float(covered_cells) / float(TOTAL_CELLS)

	# 3. Disparo al cubrir el 90% de la pantalla
	if coverage >= 0.90 and not transicion_disparada:
		iniciar_caida_paredes()

# Interpola puntos entre cuadros para que el trazo no se corte al mover rápido el móvil
func _paint_line(from_uv: Vector2, to_uv: Vector2) -> void:
	var dist := from_uv.distance_to(to_uv)
	var steps := int(maxf(1.0, dist * float(CA_WIDTH)))
	for i in range(steps + 1):
		var t := float(i) / float(steps)
		var interp_uv := from_uv.lerp(to_uv, t)
		_apply_brush_stroke(interp_uv)

func _apply_brush_stroke(uv: Vector2) -> void:
	var center_x := int(uv.x * float(CA_WIDTH))
	var center_y := int(uv.y * float(CA_HEIGHT))

	for dy in range(-brush_radius, brush_radius + 1):
		for dx in range(-brush_radius, brush_radius + 1):
			if (dx * dx + dy * dy) <= (brush_radius * brush_radius):
				var nx := center_x + dx
				var ny := center_y + dy
				if nx >= 0 and nx < CA_WIDTH and ny >= 0 and ny < CA_HEIGHT:
					var idx := ny * CA_WIDTH + nx
					ca_grid[idx] = 1.0 # Guarda el pixelado de forma permanente

# Regla local de Autómata Celular: Persistencia + Relleno automático de huecos
func _step_ca(_delta: float) -> int:
	var active_count: int = 0

	for y in range(CA_HEIGHT):
		for x in range(CA_WIDTH):
			var idx := y * CA_WIDTH + x
			var current_val := ca_grid[idx]

			# Si la celda ya fue pintada, PERMANECE pintada
			if current_val > 0.5:
				ca_grid_next[idx] = 1.0
				active_count += 1
			else:
				# Regla de vecindad de Moore: si tiene 4 o más vecinos pintados, el AC la autocompleta
				var active_neighbors: int = 0
				for dy in range(-1, 2):
					for dx in range(-1, 2):
						if dx == 0 and dy == 0:
							continue
						var nx := x + dx
						var ny := y + dy
						if nx >= 0 and nx < CA_WIDTH and ny >= 0 and ny < CA_HEIGHT:
							if ca_grid[ny * CA_WIDTH + nx] > 0.5:
								active_neighbors += 1

				if active_neighbors >= 4:
					ca_grid_next[idx] = 1.0
					active_count += 1
				else:
					ca_grid_next[idx] = 0.0

	# Swap de buffers
	var temp := ca_grid
	ca_grid = ca_grid_next
	ca_grid_next = temp

	# Actualización del buffer de imagen para el shader
	for i in range(TOTAL_CELLS):
		var val: float = ca_grid[i]
		ca_image.set_pixelv(Vector2i(i % CA_WIDTH, i / CA_WIDTH), Color(val, val, val, 1.0))

	ca_texture.update(ca_image)
	return active_count

func _process_raw_osc(data: PackedByteArray) -> void:
	if data.size() < 4:
		return

	if data.size() >= 16 and data.slice(0, 7).get_string_from_ascii() == "#bundle":
		var bundle_offset: int = 16
		var spb := StreamPeerBuffer.new()
		spb.data_array = data
		spb.big_endian = true

		while bundle_offset + 4 <= data.size():
			spb.seek(bundle_offset)
			var element_size: int = spb.get_32()
			bundle_offset += 4
			if bundle_offset + element_size <= data.size():
				_process_raw_osc(data.slice(bundle_offset, bundle_offset + element_size))
				bundle_offset += element_size
			else:
				break
		return

	var address_end: int = 0
	while address_end < data.size() and data[address_end] != 0:
		address_end += 1

	var address: String = data.slice(0, address_end).get_string_from_utf8()
	var msg_offset: int = int(ceil((address_end + 1) / 4.0)) * 4

	if msg_offset >= data.size() or data[msg_offset] != 44:
		return

	var tags_end: int = msg_offset
	while tags_end < data.size() and data[tags_end] != 0:
		tags_end += 1

	var type_tags: String = data.slice(msg_offset + 1, tags_end).get_string_from_utf8()
	var data_offset: int = int(ceil((tags_end + 1) / 4.0)) * 4

	var values: Array = []
	var buffer := StreamPeerBuffer.new()
	buffer.data_array = data
	buffer.big_endian = true
	buffer.seek(data_offset)

	for i in range(type_tags.length()):
		match type_tags[i]:
			"f": values.append(buffer.get_float())
			"i": values.append(buffer.get_32())

	if address == "/rotationvector" and values.size() >= 4:
		_evaluate_orientation(values[0], values[1], values[2], values[3])

func _evaluate_orientation(x: float, y: float, z: float, w: float) -> void:
	var current_quat := Quaternion(x, y, z, w).normalized()
	
	if origin_quat == Quaternion.IDENTITY:
		origin_quat = current_quat
		return

	var rel_quat := origin_quat.inverse() * current_quat
	var forward := Vector3(0, 0, -1) if phone_axis_mode == 0 else Vector3(0, 1, 0)
	var rel_dir := rel_quat * forward

	var max_rad := deg_to_rad(pointing_cone_degrees)
	var u := clampf(0.5 + (rel_dir.x / tan(max_rad * 0.5)) * 0.5, 0.0, 1.0)
	var v := clampf(0.5 - (rel_dir.y / tan(max_rad * 0.5)) * 0.5, 0.0, 1.0)

	if not is_pointing_active:
		last_pointer_uv = Vector2(u, v)

	current_pointer_uv = Vector2(u, v)
	is_pointing_active = true

func iniciar_caida_paredes() -> void:
	transicion_disparada = true
	print(">> PANTALLA COMPLETAMENTE BARRIDA: Caída iniciada.")
	var tween: Tween = create_tween().set_parallel(true)

	tween.tween_property(paredes, "position:y", -10.0, 2.5)\
		.set_trans(Tween.TRANS_SINE)\
		.set_ease(Tween.EASE_IN)

	tween.tween_property(cuadro_completo, "position:y", -10.0, 2.3)\
		.set_delay(0.2)\
		.set_trans(Tween.TRANS_QUAD)\
		.set_ease(Tween.EASE_IN)

	tween.chain().tween_callback(func() -> void:
		paredes.visible = false
		cuadro_completo.visible = false
	)
