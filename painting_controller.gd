extends Sprite2D

@export var port: int = 8000
@export var pointing_cone_degrees: float = 45.0
@export var max_pixel_size: float = 15.0
@export var transition_speed: float = 6.0
@export var phone_axis_mode: int = 0 # 0: Cámara trasera (-Z) | 1: Borde superior (+Y)

var server: PacketPeerUDP = PacketPeerUDP.new()
var calibrated_target_dir: Vector3 = Vector3.ZERO
var is_calibrated: bool = false

var current_pixel_size: float = 1.0
var target_pixel_size: float = 1.0

func _ready() -> void:
	server.close()
	var error = server.bind(port)
	if error != OK:
		printerr("CRÍTICO: No se pudo abrir el puerto UDP %d." % port)
	else:
		print("Servidor UDP iniciado en puerto: ", port)

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		is_calibrated = false
		print(">> Recalibrando: apunta al lienzo...")

func _process(delta: float) -> void:
	while server.get_available_packet_count() > 0:
		var packet: PackedByteArray = server.get_packet()
		_process_raw_osc(packet)
	
	if material is ShaderMaterial:
		current_pixel_size = lerp(current_pixel_size, target_pixel_size, transition_speed * delta)
		(material as ShaderMaterial).set_shader_parameter("pixel_size", current_pixel_size)

func _process_raw_osc(data: PackedByteArray) -> void:
	if data.size() < 4:
		return

	if data.size() >= 16 and data.slice(0, 7).get_string_from_ascii() == "#bundle":
		var offset: int = 16
		var spb := StreamPeerBuffer.new()
		spb.data_array = data
		spb.big_endian = true

		while offset + 4 <= data.size():
			spb.seek(offset)
			var element_size: int = spb.get_32()
			offset += 4
			if offset + element_size <= data.size():
				_process_raw_osc(data.slice(offset, offset + element_size))
				offset += element_size
			else:
				break
		return

	var address_end: int = 0
	while address_end < data.size() and data[address_end] != 0:
		address_end += 1

	var address: String = data.slice(0, address_end).get_string_from_utf8()
	var offset: int = int(ceil((address_end + 1) / 4.0)) * 4

	if offset >= data.size() or data[offset] != 44:
		return

	var tags_end: int = offset
	while tags_end < data.size() and data[tags_end] != 0:
		tags_end += 1

	var type_tags: String = data.slice(offset + 1, tags_end).get_string_from_utf8()
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

func _get_phone_vector() -> Vector3:
	match phone_axis_mode:
		1:
			return Vector3(0, 1, 0)
		_:
			return Vector3(0, 0, -1)

func _evaluate_orientation(x: float, y: float, z: float, w: float) -> void:
	var current_quat := Quaternion(x, y, z, w).normalized()
	var forward_axis := _get_phone_vector()
	var current_dir: Vector3 = current_quat * forward_axis
	
	if not is_calibrated:
		calibrated_target_dir = current_dir
		is_calibrated = true
		print(">> ORIGEN FIJADO EN: ", calibrated_target_dir)
		return

	var alignment: float = clamp(current_dir.dot(calibrated_target_dir), -1.0, 1.0)
	var angle_degrees: float = rad_to_deg(acos(alignment))
	
	# Mapeo continuo [0.0, 1.0] dependiente del ángulo de desvío
	var intensity: float = 1.0 - clamp(angle_degrees / pointing_cone_degrees, 0.0, 1.0)
	
	target_pixel_size = lerp(1.0, max_pixel_size, intensity)
	
	print("Desvío: %.1f° | Intensidad Pincel: %.2f | Tamaño Pixel: %.1f" % [angle_degrees, intensity, target_pixel_size])
