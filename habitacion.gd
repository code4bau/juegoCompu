extends Node3D

@export var port: int = 8000
@export var pointing_cone_degrees: float = 45.0
@export var phone_axis_mode: int = 0

@onready var paredes: MeshInstance3D = $Paredes
@onready var pixel_overlay: ColorRect = $CanvasLayer/ColorRect
@onready var cuadro_completo: Node3D = $Cuadro_Completo

var server: PacketPeerUDP = PacketPeerUDP.new()
var transicion_disparada: bool = false
var origin_quat: Quaternion = Quaternion.IDENTITY
var pointing_intensity: float = 0.0

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

	# Vincular el recurso ImageTexture al shader UNA SOLA VEZ en el pipeline
	if pixel_overlay and pixel_overlay.material is ShaderMaterial:
		var mat := pixel_overlay.material as ShaderMaterial
		mat.set_shader_parameter("ca_texture", ca_texture)
		mat.set_shader_parameter("pixel_size", 15.0)

func _init_ca_grid() -> void:
	ca_grid.resize(TOTAL_CELLS)
	ca_grid_next.resize(TOTAL_CELLS)
	ca_grid.fill(0.0)
	ca_grid_next.fill(0.0)
	ca_image = Image.create(CA_WIDTH, CA_HEIGHT, false, Image.FORMAT_RGBA8)
	ca_texture = ImageTexture.create_from_image(ca_image)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		origin_quat = Quaternion.IDENTITY
		pointing_intensity = 0.0
		transicion_disparada = false
		_init_ca_grid()
		print(">> ORIGEN RECALIBRADO EN EL CUADRO.")

func _process(delta: float) -> void:
	while server.get_available_packet_count() > 0:
		var packet: PackedByteArray = server.get_packet()
		_process_raw_osc(packet)

	_seed_ca_center(pointing_intensity, delta)
	var fully_pixelated_cells := _step_ca(delta)

	var coverage := float(fully_pixelated_cells) / float(TOTAL_CELLS)

	if pointing_intensity > 0.2 and not transicion_disparada:
		print("Progreso de propagación AC: %.1f%%" % (coverage * 100.0))

	if coverage >= 0.90 and not transicion_disparada:
		iniciar_caida_paredes()

func _seed_ca_center(intensity: float, delta: float) -> void:
	if intensity < 0.2:
		return

	var cx := CA_WIDTH / 2
	var cy := CA_HEIGHT / 2
	# Semilla inicial reducida a 2x2 celdas en el lienzo
	for dy in range(-1, 1):
		for dx in range(-1, 1):
			var idx := (cy + dy) * CA_WIDTH + (cx + dx)
			ca_grid[idx] = clampf(ca_grid[idx] + intensity * 1.5 * delta, 0.0, 1.0)

func _step_ca(delta: float) -> int:
	var saturated_count: int = 0

	for y in range(CA_HEIGHT):
		for x in range(CA_WIDTH):
			var idx := y * CA_WIDTH + x
			var current_val := ca_grid[idx]

			if current_val > 0.7:
				saturated_count += 1

			# Evaluación de vecindad de Moore
			var active_neighbors: int = 0
			var neighbor_sum: float = 0.0

			for dy in range(-1, 2):
				for dx in range(-1, 2):
					if dx == 0 and dy == 0:
						continue
					var nx := x + dx
					var ny := y + dy
					if nx >= 0 and nx < CA_WIDTH and ny >= 0 and ny < CA_HEIGHT:
						var n_val: float = ca_grid[ny * CA_WIDTH + nx]
						if n_val > 0.3:
							active_neighbors += 1
						neighbor_sum += n_val

			var avg_neighbor := neighbor_sum / 8.0

			# Multiplicador de velocidad: aceleración al salir del centro (paredes)
			var dist_from_center := maxf(absf(float(x) - CA_WIDTH / 2.0), absf(float(y) - CA_HEIGHT / 2.0))
			var speed_multiplier := 1.0
			if dist_from_center > 5.0:
				speed_multiplier = 2.8 # Aceleración al tocar las paredes

			if pointing_intensity > 0.2:
				if active_neighbors >= 2 or current_val > 0.05:
					ca_grid_next[idx] = clampf(current_val + (0.5 + avg_neighbor) * speed_multiplier * delta, 0.0, 1.0)
				else:
					ca_grid_next[idx] = current_val
			else:
				ca_grid_next[idx] = maxf(0.0, current_val - 2.0 * delta)

	# Swap de buffers
	var temp := ca_grid
	ca_grid = ca_grid_next
	ca_grid_next = temp

	# Renderizado de la textura de control para el Shader
	for i in range(TOTAL_CELLS):
		var val: float = ca_grid[i]
		ca_image.set_pixelv(Vector2i(i % CA_WIDTH, i / CA_WIDTH), Color(val, val, val, 1.0))

	ca_texture.update(ca_image)
	return saturated_count

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

	var forward := Vector3(0, 0, -1) if phone_axis_mode == 0 else Vector3(0, 1, 0)
	var target_dir := origin_quat * forward
	var current_dir := current_quat * forward

	var alignment := clampf(current_dir.dot(target_dir), -1.0, 1.0)
	var angle_deg := rad_to_deg(acos(alignment))

	pointing_intensity = 1.0 - clampf(angle_deg / pointing_cone_degrees, 0.0, 1.0)

func iniciar_caida_paredes() -> void:
	transicion_disparada = true
	print(">> COBERTURA TOTAL ALCANZADA: Iniciando caída de estructura.")
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
