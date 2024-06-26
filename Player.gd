extends KinematicBody

signal card_collected

enum State {IDLE, RUN, JUMP, FALL, DASH}
enum Attacks {NONE, ATTACK, DEFEND, DASH}
enum Curves {LINEAR, EXPONENTIAL, INV_S}

var CURVES_RES = [
	load("res://addons/GodotSimpleFPSController/Curves/Linear.tres"),
	load("res://addons/GodotSimpleFPSController/Curves/Exponential.tres"),
	load("res://addons/GodotSimpleFPSController/Curves/Inverse_S.tres")
]

export var mouse_sens = Vector2(.1,.1) # sensitivities for each
export var gamepad_sens = Vector2(2,2) # axis + input
export var gamepad_curve = Curves.INV_S # curve analog inputs map to
export var base_move_speed = 7 # max move speed
export var base_acceleration = 1.0 # ground acceleration
export var base_air_speed = 7 # max move speed in air
export var base_air_acceleration = .5 # air acceleration
export var jump_speed = 5 # length in frames to reach apex
export var jump_height = 1.3 # apex in meters of jump
export var coyote_factor = 3 # jump forgiveness after leaving platform in frames
export var gravity_accel = -12 # how fast fall speed increases
export var gravity_max = -24 # max falling speed
export var friction = 1.15 # how fast player stops when idle
export var max_climb_angle = 0.6 # 0.0-1.0 based on normal of collision .5 for 45 degree slope
export var angle_of_freedom = 80 # amount player may look up/down
export var sprint_factor = 6
export var fov_multiplier := 1.5

export var fov_distortion_velocity_in := 0.2
export var fov_distortion_velocity_out := 8
export var jump_levels = 0 # amount of jump over jump, 1 means double, 2 means triple, etc.
var current_jump_level = 0

# sprint feature
var move_speed = base_move_speed
var acceleration = base_acceleration
var air_speed = base_air_speed
var air_acceleration = base_air_acceleration

var light_stream_jump = false
var light_stream_jump_counter = 0
var old_velocity_x = 0.0
var old_velocity_z = 0.0

# fov distortion feature
onready var cam: Camera = $Collider/Camera
onready var normal_fov: float = cam.fov
onready var fov_target = normal_fov

var current_fov_distortion_velocity = fov_distortion_velocity_in

var platform_velocity = Vector3.ZERO

# Multiplayer variables

export var mouse_control = true # only works for lowest viewport (first child)

onready var audio_jump = $Audio_jump
onready var audio_collect1 = $Audio_collect_card_1
onready var audio_collect2 = $Audio_collect_card_2

var state = State.FALL
var on_floor = false
var frames = 0 # frames jumping
var input_dir = Vector3(0, 0, 0)
var currentState = 0

var collision : KinematicCollision  # Stores the collision from move_and_collide
var velocity := Vector3(0, 0, 0)
var coyote_frames = 0

func _physics_process(delta):
	_process_input(delta)
	_process_movement(delta)

func _ready():
	print("\nplayer _ready\n")
	Globals.Player = self
	if Globals.steam_detected and Globals.steam_info["is_online"]:
		print("player _ready: waiting for steam stats")
	else:
		if Globals._savegame.started_game:
			print("player _ready: load local _savegame position")
			Globals.update_player_position()
		else:
			print("player _ready: reset to initial position")
			Globals.reset_player_position()

# Handles mouse movement
func _input(event):
	if event is InputEventMouseMotion && Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		if mouse_control: # only do mouse control if enabled for this instance
			cam_rotate(Vector2(event.relative.x, event.relative.y), mouse_sens)

func _process_input(delta):
	if currentState != Globals.gameState:
		if Globals.gameState == 3:
			move_lock_x = false
			move_lock_y = false
			move_lock_z = false
		else:
			move_lock_x = true
			move_lock_y = true
			move_lock_z = true
		currentState = Globals.gameState
		
	if currentState == 3:
		# sprint
		if on_floor and Input.is_action_just_pressed("sprint"):
			move_speed = base_move_speed * sprint_factor
			acceleration = base_acceleration * sprint_factor
			air_speed = base_air_speed * sprint_factor
			air_acceleration = base_air_acceleration * sprint_factor
			fov_target = normal_fov * fov_multiplier
			current_fov_distortion_velocity = fov_distortion_velocity_in
		if Input.is_action_just_released("sprint"):
			move_speed = base_move_speed
			acceleration = base_acceleration
			air_speed = base_air_speed
			air_acceleration = base_air_acceleration
			fov_target = normal_fov
			current_fov_distortion_velocity = fov_distortion_velocity_out
		
		# cam fov changes
		var fov_value = lerp(cam.fov, fov_target, delta * current_fov_distortion_velocity)
		#print("%s / %s" % [fov_value, fov_target])
		cam.set_fov(fov_value)
	
		# Jump
		if Input.is_action_just_pressed("jump") and can_jump():
			frames = 0
			state = State.JUMP
			current_jump_level += 1
			audio_jump.play()
#			Globals.emit_light_stream_burst()

		var right_input = Input.get_action_strength("right")
		if right_input < 0.02:
			right_input = 0
		var left_input = Input.get_action_strength("left")
		if left_input < 0.02:
			left_input = 0
		var back_input = Input.get_action_strength("back")
		if back_input < 0.02:
			back_input = 0
		var forward_input = Input.get_action_strength("forward")
		if forward_input < 0.02:
			forward_input = 0
		# WASD
		input_dir = Vector3(right_input - left_input, 0,
				back_input - forward_input).normalized()
		
		# Look
		var look_vec = Vector2(
			Input.get_action_strength("look_right") - Input.get_action_strength("look_left"),
			Input.get_action_strength("look_down") - Input.get_action_strength("look_up")
		)
	
		# Map gamepad look to curves
		var signs = Vector2(sign(look_vec.x),sign(look_vec.y))
		var sens_curv = CURVES_RES[gamepad_curve]
		look_vec = look_vec.abs() # Interpolate input on the curve as positives
		look_vec.x = sens_curv.interpolate_baked(look_vec.x)
		look_vec.y = sens_curv.interpolate_baked(look_vec.y)
		look_vec *= signs # Return inputs to original signs
		
		cam_rotate(look_vec, gamepad_sens)
	else:
		move_lock_x = true
		move_lock_y = true
		move_lock_z = true

func _process_movement(delta):
	# state management
	if !collision:
		on_floor = false
		coyote_frames += 1 * delta * 60
		if state != State.JUMP:
			state = State.FALL
			if platform_velocity != Vector3.ZERO:
				on_floor = true
				coyote_frames = 0
				current_jump_level = 0
				if input_dir.length() > .1 && (frames > jump_speed || frames == 0):
					state = State.RUN
				else:
					state = State.IDLE
	else:
		if state == State.JUMP:
			on_floor = false # fixes wall climbing due to walls having y1 normal sometimes
			coyote_frames = coyote_factor + 1
		elif collision.normal.y < max_climb_angle:
			state = State.FALL
		else:
			on_floor = true
			coyote_frames = 0
			current_jump_level = 0
			if input_dir.length() > .1 && (frames > jump_speed || frames == 0):
				state = State.RUN
			else:
				state = State.IDLE
	
#	print(State.keys()[state])
	
	# jump state
	if state == State.JUMP && frames < jump_speed:
		platform_velocity = Vector3.ZERO
		velocity.y = jump_height/(jump_speed * delta)
		frames += 1 * delta * 60
	elif state == State.JUMP:
		state = State.FALL
	
	# light stream jump back
	if light_stream_jump == true:
		light_stream_jump_counter += delta
		if old_velocity_x == 0.0:
			old_velocity_x = velocity.x
			velocity.x = 0.0
			old_velocity_z = velocity.z
			velocity.z = 0.0
			# sequence to disable sprint
			move_speed = base_move_speed
			acceleration = base_acceleration
			air_speed = base_air_speed
			air_acceleration = base_air_acceleration
			fov_target = normal_fov
			current_fov_distortion_velocity = fov_distortion_velocity_out
			state = State.FALL
		velocity.y = jump_height/(jump_speed * delta)
		velocity.x -= old_velocity_x * 100
		velocity.z -= old_velocity_z * 100
		if state != State.FALL or light_stream_jump_counter > 30:
			light_stream_jump = false
			light_stream_jump_counter = 0
			old_velocity_x = 0.0
			old_velocity_z = 0.0
#		else:
#			print("jump back")
		


	# fall state
	if state == State.FALL:
		velocity.y += gravity_accel * delta * 4
		velocity.y = clamp(velocity.y, gravity_max, 9999)
	# run state
	if state == State.RUN:
		velocity += input_dir.rotated(Vector3(0, 1, 0), rotation.y) * acceleration
		if Vector2(velocity.x, velocity.z).length() > move_speed:
			velocity = velocity.normalized() * move_speed # clamp move speed
		if collision:
			velocity.y = ((Vector3(velocity.x, 0, velocity.z).dot(collision.normal)) * -1)
		
		# fake gravity to keep character on the ground
		# increase if player is falling down slopes instead of running
		velocity.y -= .0001 + (int(velocity.y < 0) * 1.1) 

	# idle state
	if state == State.IDLE && frames < jump_speed:
		frames += 1 * delta * 60
	elif state == State.IDLE:
		if velocity.length() > .5:
			velocity /= friction
			if collision:
				velocity.y = ((Vector3(velocity.x, 0, velocity.z).dot(collision.normal)) * -1) - .0001
	
	# air movement
	if state == 2 or state == 3:
		if light_stream_jump == false:
			velocity += input_dir.rotated(Vector3(0, 1, 0), rotation.y) * air_acceleration # add acceleration
		if Vector2(velocity.x, velocity.z).length() > air_speed: # clamp speed to max airspeed
			var velocity2d = Vector2(velocity.x, velocity.z).normalized() * air_speed
			velocity.x = velocity2d.x
			velocity.z = velocity2d.y
	
	if platform_velocity != Vector3.ZERO:
		velocity.y = platform_velocity.y
	
	#apply
	if velocity.length() >= .5:
		collision = move_and_collide(velocity * delta)
	else:
		velocity = Vector3(0, velocity.y, 0)
	if collision:
		if collision.normal.y < .5: # if collision is 50% not from below aka if on slope
			velocity.y += delta * gravity_accel
			clamp(velocity.y, gravity_max, 9999)
			velocity = velocity.slide(collision.normal).normalized() * velocity.length()
		else:
			velocity = velocity

func enable_mouse():
	mouse_control = true
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func cam_rotate(vect, sens):
	rotate_y(deg2rad(vect.x * sens.y * -1))
	$Collider/Camera.rotate_x(deg2rad(vect.y * sens.x * -1))
	
	var camera_rot = $Collider/Camera.rotation_degrees
	camera_rot.x = clamp(camera_rot.x, 90 + angle_of_freedom * -1, 90 + angle_of_freedom)
	$Collider/Camera.rotation_degrees = camera_rot 
	# This function clamps the x rotation of the camera to the angle of freedom limits,
	# to avoid gimbal lock problems

func can_jump():
	if on_floor && state != State.FALL && (frames == 0 || frames > jump_speed):
		return true
	elif current_jump_level <= jump_levels && (frames > jump_speed):
		return true
	elif state != State.JUMP && coyote_frames < coyote_factor:
		return true # allows the player to jump after leaving platforms
	else:
		return false

func collect_card(index) -> void:
	Globals._savegame.set_card_as_collected(index)
	emit_signal("card_collected")
	audio_collect1.play()
	Globals.rumble(0.3, 0)

func collect_next():
	var collected = Globals._savegame.collected_cards
	for i in range (54):
		if !collected.has(i):
			print("collecting %s" % i)
			collect_card(i)
			Globals.gameScene.remove_collected_cards()
			return
	print("no more cards to collect")

func collect_all():
	if Globals._savegame.collected_cards.size() < 10:
		for i in range(33):
			if i%3 == 0:
				if !Globals._savegame.is_card_collected(i):
					collect_card(i)
	elif Globals._savegame.collected_cards.size() < 20:
		for i in range(33):
			if i%2 == 0:
				if !Globals._savegame.is_card_collected(i):
					collect_card(i)
	elif Globals._savegame.collected_cards.size() < 33:
		for i in range(33):
			if !Globals._savegame.is_card_collected(i):
				collect_card(i)
	elif Globals._savegame.collected_cards.size() == 33:
		for i in range(34):
			if !Globals._savegame.is_card_collected(i):
				collect_card(i)
	## SECOND LEVEL
	elif Globals._savegame.collected_cards.size() < 44:
		for i in range(53):
			if i%2 == 0:
				if !Globals._savegame.is_card_collected(i):
					collect_card(i)
	elif Globals._savegame.collected_cards.size() < 53:
		for i in range(53):
			if !Globals._savegame.is_card_collected(i):
				collect_card(i)
	elif Globals._savegame.collected_cards.size() == 53:
		for i in range(54):
			if !Globals._savegame.is_card_collected(i):
				collect_card(i)
	Globals.gameScene.remove_collected_cards()
		
func make_sound() -> void:
	audio_collect1.play()
	yield(get_tree().create_timer(0.5), "timeout")
	audio_jump.play()

func save_player_location() -> void:
	Globals._savegame.player_position = translation
	Globals._savegame.player_rotation = rotation
