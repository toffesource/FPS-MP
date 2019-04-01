extends KinematicBody

onready var health setget set_health
signal health_changed

var cmd = {
	move_forward = false,
	move_backward = false,
	move_left = false,
	move_right = false,
	jump = false,
	sprint = false,
	crouch = false
}

var vel = Vector3()
var dir = Vector3()
var input_movement_vector = Vector2()

const GRAVITY = -24.8
const MAX_SPEED = 5
const MAX_SPRINT_SPEED = 9
const MAX_CROUCH_SPEED = 5
const JUMP_SPEED = 10
const ACCEL = 5
const SPRINT_ACCEL = 10
const CROUCH_ACCEL = 2.5
const DEACCEL = 5
const MAX_SLOPE_ANGLE = 40

# sprint
const MAX_SPRINT_TIME = 2
const SPRINT_TIMEOUT = 3
var can_sprint = true
var time_sprinting = 0
var sprint_timeout = 0

var is_crouching = false
var is_sprinting = false
var is_in_air = false
var is_dead = false
var is_landing = false
var is_landed = false

# footsteps
var footstep_timer = 0
const TIME_BETWEEN_FOOTSTEP = 0.5

# crouch
#onready var INITIAL_COLSHAPE = $collision.shape.height
#var CROUCH_COLSHAPE = 0.01

var camera
var head

var MOUSE_SENSITIVITY = 0.05

# bob
const BOB_SPEED = 0.2
const BOB_AMT = 0.15
var bob_timer = 0.0
onready var midpoint = $head.translation.y

# fov
onready var INITIAL_FOV = $head/camera.fov
const SPRINT_FOV = 95

# shooting
var ray_length = 1000
var shoot_delay = 0

# ammo
const AMMO_COUNT = 16
onready var ammo = 0 setget set_ammo
onready var ammo_supply = 0 setget set_ammo_supply
signal ammo_changed
var is_reloading = false

# gibs
onready var scn_gib_1 = preload("res://models/gibs/gib_1.tscn")
onready var scn_gib_2 = preload("res://models/gibs/gib_2.tscn")

onready var scn_impact = preload("res://scenes/impact.tscn")
onready var scn_wound = preload("res://scenes/wound.tscn")
onready var scn_impact_fx = preload("res://scenes/impact_fx.tscn")
onready var scn_blood_fx = preload("res://scenes/blood_fx.tscn")
onready var scn_muzzle_flash_fx = preload("res://scenes/muzzle_flash_fx.tscn")

func _ready():
	connect("health_changed", self, "_on_health_changed")
	connect("ammo_changed", self, "_on_ammo_changed")
	
	$timer_respawn.connect("timeout", self, "respawn")
	set_health(100)
	set_ammo(16)
	
	camera = $head/camera
	head = $head
	$hud/sprint.max_value = MAX_SPRINT_TIME
	$hud/sprint.value = MAX_SPRINT_TIME
	
	if(is_network_master()):
		camera.current = true
		$hud/health.visible = true
		$hud/ammo.visible = true
		$hud/sprint.visible = true
		$hud/cross.visible = true
		$mesh.visible = false
		$head/gun_holder/gun.visible = true
		
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta):
	pass

func _physics_process(delta):
	if(is_network_master()):
		process_input(delta)
		process_movement(delta)
		process_footsteps(delta)
		process_fov(delta)
		process_headbob(delta)
		process_blindness(delta)
		#process_crouch(delta)

slave func update_trans_rot(pos, rot, head_rotation):
	translation = pos
	rotation = rot
	$head.rotation = head_rotation

func process_input(delta):
    # Walking
	dir = Vector3()
	#var cam_xform = camera.get_global_transform()
	var cam_xform = get_global_transform()

	input_movement_vector = Vector2()

	if Input.is_action_pressed("move_forward"):
		input_movement_vector.y += 1
	if Input.is_action_pressed("move_backward"):
		input_movement_vector.y -= 1
	if Input.is_action_pressed("move_left"):
		input_movement_vector.x -= 1
	if Input.is_action_pressed("move_right"):
		input_movement_vector.x = 1

	input_movement_vector = input_movement_vector.normalized()

	dir += -cam_xform.basis.z.normalized() * input_movement_vector.y
	dir += cam_xform.basis.x.normalized() * input_movement_vector.x

	# Jumping
	if is_on_floor() and is_dead == false:
		if Input.is_action_pressed("jump"):
			is_in_air = true
			vel.y = JUMP_SPEED
			if has_node("audio/jump"):
				$audio/jump.play()
		else:
			is_in_air = false
	
	# Landing
	if !is_in_air and is_landing and !is_landed:
		if has_node("audio/land"):
			$audio/land.play()
	if is_on_floor():
		is_landed = true
		is_landing = false
	if is_in_air and !is_on_floor():
		is_landing = true
		is_landed = false

	# Crouching
	if Input.is_action_pressed("crouch"):
		is_crouching = true
	else:
		is_crouching = false

	# Sprinting
	if get_node("col_mouth").disabled:
		can_sprint = false
	else:
		can_sprint = true
	
	if Input.is_action_pressed("sprint") and can_sprint:
		is_sprinting = true
		var sprint_bar = MAX_SPRINT_TIME
		time_sprinting += delta
		sprint_bar -= time_sprinting
		$hud/sprint.value = sprint_bar
	else:
		is_sprinting = false
	
	if time_sprinting >= MAX_SPRINT_TIME:
		can_sprint = false
		sprint_timeout += delta
		$hud/sprint.value = sprint_timeout
	
	if sprint_timeout >= SPRINT_TIMEOUT:
		sprint_timeout = 0
		time_sprinting = 0
		can_sprint = true
	
	# capturing/freeing the cursor
	if Input.is_action_just_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_VISIBLE:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)

	# shooting
	if !is_dead and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		shoot_delay += delta
		if Input.is_action_pressed("shoot") and shoot_delay > 0.1 and !is_reloading:
			rpc("shoot")
			shoot_delay = 0

	if Input.is_action_just_pressed("reload") and ammo < AMMO_COUNT and ammo_supply > 0 and is_reloading != true:
		rpc("reload")
		
	if Input.is_action_pressed("kill") and !is_dead:
		rpc("die")

sync func reload():
	is_reloading = true
	$head/gun_holder/gun/animation_player.play("reload")
	$audio/reload.play()
	
	# FIX THIS SHIT
	var ammo_required = AMMO_COUNT - ammo
	if ammo_supply >= ammo_required:
		ammo_supply -= ammo_required
		set_ammo(ammo + ammo_required)
	else:
		set_ammo(ammo + ammo_supply)
		ammo_supply = 0
	
	yield($head/gun_holder/gun/animation_player, "animation_finished")
	is_reloading = false

func _input(event):
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED and is_network_master():
		head.rotate_x(deg2rad(event.relative.y * MOUSE_SENSITIVITY * -1))
		self.rotate_y(deg2rad(event.relative.x * MOUSE_SENSITIVITY * -1))

		var camera_rot = head.rotation_degrees
		camera_rot.x = clamp(camera_rot.x, -70, 70)
		head.rotation_degrees = camera_rot

sync func shoot():
	if ammo > 0:
		set_ammo(ammo - 1)
		$audio/shot.play()
		$head/gun_holder/gun/animation_player.play("shoot")
		
		camera.shake(0.008, 0.1)
		
		# muzzle flash
		var muzzle_flash_fx = scn_muzzle_flash_fx.instance()
		var muzzle = $head/gun_holder/gun/muzzle
		muzzle.add_child(muzzle_flash_fx)
		
		var from = camera.global_transform.origin
		var to = from + -camera.global_transform.basis.z * ray_length
		var space_state = get_world().direct_space_state
		var result = space_state.intersect_ray(from, to, [self])
		if not result.empty():
			if result.collider is KinematicBody:
				$audio/hit.play()
				result.collider.hit(10, (result.position - global_transform.origin).normalized() * 15)
				create_impact(scn_wound, scn_blood_fx, result)
			if result.collider is RigidBody:
				var position = result.position - result.collider.global_transform.origin
				var impulse = (result.position - global_transform.origin).normalized()
				result.collider.apply_impulse(position, impulse * 10)
				create_impact(scn_impact, scn_impact_fx, result)
			if result.collider is KinematicBody and result.shape == 0:
				result.collider.get_node("mesh/ear_L").visible = false
				result.collider.get_node("col_ear_L").disabled = true
			if result.collider is KinematicBody and result.shape == 1:
				result.collider.get_node("mesh/eye_L").visible = false
				result.collider.get_node("col_eye_L").disabled = true
			if result.collider is KinematicBody and result.shape == 2:
				result.collider.get_node("mesh/eye_R").visible = false
				result.collider.get_node("col_eye_R").disabled = true
			if result.collider is KinematicBody and result.shape == 3:
				result.collider.get_node("mesh/ear_R").visible = false
				result.collider.get_node("col_ear_R").disabled = true
			if result.collider is KinematicBody and result.shape == 4:
				pass
			if result.collider is KinematicBody and result.shape == 5:
				result.collider.get_node("mesh/mouth").visible = false
				result.collider.get_node("col_mouth").disabled = true
			else:
				create_impact(scn_impact, scn_impact_fx, result)

func create_impact(scn_impact, scn_impact_fx, result):
	var impact = scn_impact.instance()
	result.collider.add_child(impact)
	impact.global_transform.origin = result.position
	impact.global_transform = utils.look_at_with_y(impact.global_transform, result.normal, camera.global_transform.basis.y)
	
	var impact_fx = scn_impact_fx.instance()
	get_tree().root.add_child(impact_fx)
	impact_fx.global_transform.origin = result.position
	impact_fx.emitting = true
	impact_fx.global_transform = utils.look_at_with_z(impact_fx.global_transform, result.normal, camera.global_transform.basis.y)


#func process_crouch(delta):
#	if has_node("collision"):
#		if is_crouching:
#			$collision.shape.height = CROUCH_COLSHAPE
#		else:
#			$collision.shape.height = INITIAL_COLSHAPE

# head bob
func process_headbob(delta):
	if has_node("head") and !is_in_air and !is_crouching and !is_dead:
		var waveslice = 0.0
		var bob_speed = BOB_SPEED
		if input_movement_vector.x == 0 and input_movement_vector.y == 0:
		   bob_timer = 0.0
		else:
			waveslice = sin(bob_timer)
			if is_sprinting:
				bob_speed = BOB_SPEED * 2
			else:
				bob_speed = BOB_SPEED
			bob_timer = bob_timer + bob_speed
			if bob_timer > PI * 2:
				bob_timer = bob_timer - PI * 2
		if waveslice != 0:
			var translate_change = waveslice * BOB_AMT
			var total_axes = abs(input_movement_vector.x) + abs(input_movement_vector.y)
			total_axes = clamp(total_axes, 0.0, 1.0)
			translate_change = total_axes * translate_change
			$head.transform.origin.y = midpoint + translate_change
		else:
			$head.transform.origin.y += (midpoint - $head.transform.origin.y) * 5 * delta
	else:
		return
	pass

# fov
func process_fov(delta):
	camera.fov += (INITIAL_FOV - camera.fov) * 5 * delta
	if is_sprinting and dir.dot(vel) > 0:
		camera.fov += (SPRINT_FOV - camera.fov) * 5 * delta

func process_movement(delta):
	if !is_dead:
		dir.y = 0
		dir = dir.normalized()
	
		vel.y += delta * GRAVITY
	
		var hvel = vel
		hvel.y = 0
	
		var target = dir
		if is_sprinting:
			target *= MAX_SPRINT_SPEED
		elif is_crouching:
			target *= MAX_CROUCH_SPEED
		else:
			target *= MAX_SPEED
	
		var accel
		if dir.dot(hvel) > 0:
			if is_sprinting:
				accel = SPRINT_ACCEL
			elif is_crouching:
				accel = CROUCH_ACCEL
			else:
				accel = ACCEL
		else:
			accel = DEACCEL
	
		hvel = hvel.linear_interpolate(target, accel*delta)
		vel.x = hvel.x
		vel.z = hvel.z
		vel = move_and_slide(vel,Vector3(0,1,0), 0.05, 4, deg2rad(MAX_SLOPE_ANGLE))
		
		rpc_unreliable("update_trans_rot", translation, rotation, $head.rotation)

func set_health(value):
	health = value
	emit_signal("health_changed", health)
	if health <= 0 and !is_dead:
		rpc("die")

func _on_health_changed(health):
	if has_node("hud/health"):
		$hud/health.text = "HEALTH: " + str(health)

sync func die():
	
	if !is_dead:
		if has_node("audio/hurt"):
			$audio/hurt.play()
		# gibs
		var gib_1 = scn_gib_1.instance()
		get_tree().root.add_child(gib_1)
		gib_1.global_transform.origin = global_transform.origin
		gib_1.rotation = rotation
		var gib_2 = scn_gib_2.instance()
		get_tree().root.add_child(gib_2)
		gib_2.global_transform.origin = global_transform.origin
		gib_2.rotation = rotation
		
		visible = false
		$timer_respawn.start()
	
	is_dead = true

func hit(damage, knockback):
	set_health(health - damage)
	vel = knockback
	if has_node("audio/hurt"):
		$audio/hurt.play()
	# displace effect
	$hud/displace.get_material().set_shader_param('dispAmt', knockback.x / 250)
	$hud/displace.get_material().set_shader_param('abberationAmtX', knockback.x / 250)
	$hud/displace.get_material().set_shader_param('abberationAmtY', knockback.y / 250)

func respawn():
	is_dead = false
	set_health(100)
	vel = Vector3()
	global_transform.origin = get_tree().root.get_node("world").get_node("spawn_points").get_child(randi() % get_tree().root.get_node("world").get_node("spawn_points").get_child_count()).global_transform.origin
	visible = true
	get_node("mesh/ear_L").visible = true
	get_node("col_ear_L").disabled = false
	get_node("mesh/eye_L").visible = true
	get_node("col_eye_L").disabled = false
	get_node("mesh/eye_R").visible = true
	get_node("col_eye_R").disabled = false
	get_node("mesh/ear_R").visible = true
	get_node("col_ear_R").disabled = false
	get_node("mesh/mouth").visible = true
	get_node("col_mouth").disabled = false
	

# footsteps
func process_footsteps(delta):
	if !is_dead:
		if (abs(input_movement_vector.x) > 0 or abs(input_movement_vector.y) > 0) and !is_in_air and $audio/footsteps:
			var time_between_footstep
			if is_sprinting:
				time_between_footstep = TIME_BETWEEN_FOOTSTEP / 2
			elif is_crouching:
				time_between_footstep = TIME_BETWEEN_FOOTSTEP * 1.5
			else:
				time_between_footstep = TIME_BETWEEN_FOOTSTEP
			if footstep_timer > time_between_footstep:
				get_node("audio/footsteps/footstep" + str(randi() % get_node("audio/footsteps").get_child_count() + 1)).play()
				footstep_timer = 0
			footstep_timer += delta

func set_ammo(value):
	ammo = value
	emit_signal("ammo_changed", ammo)

func set_ammo_supply(value):
	ammo_supply = value
	emit_signal("ammo_changed", ammo)

func _on_ammo_changed(ammo):
	$hud/ammo.text = "AMMO: " + str(ammo) + "/" + str(ammo_supply)
	
func process_blindness(delta):
	if $col_eye_L.disabled or $col_eye_R.disabled:
		$hud/displace.get_material().set_shader_param('dispAmt', 0.005)
		$hud/displace.get_material().set_shader_param('abberationAmtX', 0.005)
		$hud/displace.get_material().set_shader_param('abberationAmtY', 0.005)
	else:
		$hud/displace.get_material().set_shader_param('dispAmt', 0)
		$hud/displace.get_material().set_shader_param('abberationAmtX', 0)
		$hud/displace.get_material().set_shader_param('abberationAmtY', 0)