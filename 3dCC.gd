extends KinematicBody

enum State {IDLE, RUN, JUMP, FALL}

const JUMP_SPEED = 5
const JUMP_FRAMES = 5
const HOP_FRAMES = 3

export var mouse_y_sens = .1
export var mouse_x_sens = .1
export var move_speed = 10
export var acceleration = .5
export var gravity = -10
export var friction = 1.15
export var max_climb_angle = .6
export var angle_of_freedom = 80

# Called when the node enters the scene tree for the first time.
func _ready():
	$Tween.connect("tween_all_completed", self, "_on_tween_all_completed")


func _physics_process(delta):
	_process_input(delta)
	_process_movement(delta)
	_update_hud()


# Handles mouse movement
func _input(event):
	if event is InputEventMouseMotion && Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(deg2rad(event.relative.x * mouse_y_sens * -1))
		$UpperCollider/Camera.rotate_x(deg2rad(event.relative.y * mouse_x_sens * -1))
		
		var camera_rot = $UpperCollider/Camera.rotation_degrees
		camera_rot.x = clamp(camera_rot.x, 90 + angle_of_freedom * -1, 90 + angle_of_freedom)
		$UpperCollider/Camera.rotation_degrees = camera_rot


var inbetween = false
func _on_tween_all_completed():
	inbetween = false


var state = State.FALL
var on_floor = false
var frames = 0
var crouching = false
var input_dir = Vector3(0, 0, 0)
func _process_input(delta):
	# Toggle mouse capture
	if Input.is_action_just_pressed("ui_cancel"):
			if Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
				Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
			else:
				Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	
	# Jump
	if Input.is_action_pressed("jump") && on_floor && state != State.FALL && (frames == 0 || frames > JUMP_FRAMES + 1):
		frames = 0
		state = State.JUMP
	
	# Crouch
	if Input.is_action_just_pressed("crouch"):
		crouching = true
		$Tween.interpolate_property($LowerCollider, "translation", 
				Vector3(0, -.25, 0), Vector3(0,.25, 0), .1, Tween.TRANS_LINEAR)
		$Tween.start()
		inbetween = true
	if Input.is_action_just_released("crouch"):
		crouching = false
		$Tween.interpolate_property($LowerCollider, "translation", 
				Vector3(0, .25, 0), Vector3(0, -.25, 0), .1, Tween.TRANS_LINEAR)
		$Tween.start()
		inbetween = true
	
	# WASD
	input_dir = Vector3(Input.get_action_strength("right") - Input.get_action_strength("left"), 
			0,
			Input.get_action_strength("back") - Input.get_action_strength("forward"))


var collision : KinematicCollision  # Stores the collision from move_and_collide
var velocity := Vector3(0, 0, 0)
var rotation_buf = rotation  # used to calculate rotation delta for air strafing
func _process_movement(delta):
	# state management
	if !collision:
		on_floor = false
		if state != State.JUMP:
			state = State.FALL
	else:
		if state == State.JUMP:
			pass
		elif Vector3.UP.dot(collision.normal) < max_climb_angle:
			state = State.FALL
		else:
			on_floor = true
			if input_dir.length() > .1 && (frames > JUMP_FRAMES+HOP_FRAMES || frames == 0):
				state = State.RUN
			else:
				state = State.IDLE

	#jump state
	if state == State.JUMP && frames < JUMP_FRAMES:
		velocity.y = JUMP_SPEED
		frames += 1 * delta * 60
	elif state == State.JUMP:
		state = State.FALL

	#fall state
	if state == State.FALL:
		if velocity.y > gravity:
			velocity.y += gravity * delta * 4
	
	#run state
	if state == State.RUN:
		if !crouching:
			velocity += input_dir.rotated(Vector3(0, 1, 0), rotation.y) * acceleration
			if Vector2(velocity.x, velocity.z).length() > move_speed:
				velocity = input_dir.rotated(Vector3(0, 1, 0), rotation.y) * move_speed
			velocity.y = ((Vector3(velocity.x, 0, velocity.z).dot(collision.normal)) * -1)
			velocity.y -= 1 + (1+int(velocity.y < 0) * .3)
		else:
			velocity += input_dir.rotated(Vector3(0, 1, 0), rotation.y) * acceleration
			if Vector2(velocity.x, velocity.z).length() > move_speed/2:
				velocity = input_dir.rotated(Vector3(0, 1, 0), rotation.y) 
			velocity.y = ((Vector3(velocity.x, 0, velocity.z).dot(collision.normal)) * -1)
			velocity.y -= 1 + (1+int(velocity.y < 0) * .3)
			

	#idle state
	if state == State.IDLE && frames < HOP_FRAMES + JUMP_FRAMES:
		frames += 1 * delta * 60
	elif state == State.IDLE:
		if velocity.length() > .5:
			velocity /= friction
			velocity.y = ((Vector3(velocity.x, 0, velocity.z).dot(collision.normal)) * -1) - .0001

	#air strafe
	if state > 2:
		#x axis movement
		var rotation_d = rotation - rotation_buf
		if input_dir.x > .1 && rotation_d.y < 0:
			velocity = velocity.rotated(Vector3.UP, rotation_d.y ) 
		if input_dir.x < -.1 && rotation_d.y > 0:
			velocity = velocity.rotated(Vector3.UP, rotation_d.y ) 
		
		if abs(input_dir.x) < .1 && on_floor:
			#z axis movement
			var movement_vector = Vector3(0,0,input_dir.z).rotated(Vector3(0, 1, 0), rotation.y) * move_speed /2
			if movement_vector.length() < .1:
				velocity = velocity
			elif Vector2(velocity.x, velocity.z).length() < move_speed:
				var xy = Vector2(movement_vector.x , movement_vector.z).normalized()
				velocity += Vector3(xy.x, 0, xy.y) * acceleration
				
			
		rotation_buf = rotation
			
	#apply
	if velocity.length() >= .5 || inbetween:
		collision = move_and_collide(velocity * delta)
	else:
		velocity = Vector3(0, velocity.y, 0)
	if collision:
		if Vector3.UP.dot(collision.normal) < .5:
			velocity.y = gravity
			velocity = velocity.slide(collision.normal)

		else:
			velocity = velocity


func _update_hud():
	var cursor_object = $UpperCollider/Camera/RayCast.get_collider()
	if cursor_object == null:
		$HUD/Crosshair.material.set_shader_param("color_id", 0)
	elif cursor_object.is_in_group("enemy"):
		$HUD/Crosshair.material.set_shader_param("color_id", 1)
	elif cursor_object.is_in_group("friend"):
		$HUD/Crosshair.material.set_shader_param("color_id", 2)
	else:
		$HUD/Crosshair.material.set_shader_param("color_id", 0)
	
	$HUD/Crosshair.material.set_shader_param("spread", velocity.length()/4 + 1)
		
		
