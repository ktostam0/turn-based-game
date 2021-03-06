extends Node

var queue : Array = [] # List of entities in the queue
var current : int = 0 # Index of entity currently performing it's turn

var current_action = null # Action type selected
var current_entity : Dictionary # Variable storing current entity dictionary for easier access

var valid_targets : Array = [] # Array recieved from targeting, stores bools for valid/invalid
var target_died : bool = false

var objects : Array = []

var effects_queued : Array = [] # Effects queued to be decreased at the end of the turn

export var board_system_path : NodePath # Path to board system

onready var board = get_node(board_system_path) # Actual board system refference
onready var signals = Signals
onready var temp = board.entity_temp # Temprorary variables which require to be exchanged with other systems

func _ready():
	signals.connect("action_changed", self, "on_action_changed")
	signals.connect("field_pressed", self, "on_field_pressed")
	signals.connect("entity_added", self, "add_entity")
	signals.connect("queue_clear_requested", self, "clear_queue")
	signals.connect("turn_passed", self, "next")
	signals.connect("targets_changed", self, "on_targets_changed")
	signals.connect("action_triggered", self, "on_action_triggered")
	signals.connect("entity_removed", self, "on_entity_removed")


func init_entity_variables() -> void: # Initialize temporary variables which are not stored in the enity itself
	current_entity = board.get_entity(queue[current])
	apply_effects()
	temp["ap"] = board.get_entity(queue[current])["ap"]
	temp["actions_usages"] = {}
	for i in board.get_entity(queue[current])["actions"]:
		temp["actions_usages"][i] = board.get_entity(queue[current])["actions"][i]["usage_limit"]
	current_action = ""
	signals.emit_signal("current_entity_changed", queue[current])
	signals.emit_signal("targeting_called", {"target": ["", ""]}) # Telling targeting system to reset


func add_entity(index : int) -> void:
	queue.append(index)
	if len(queue) == 1: # If this is the only entity in queue, set all variables for using it as the active one
		init_entity_variables()


func remove_entity(index : int) -> void:
	queue.remove(index)


func shuffle_queue() -> void:
	queue.shuffle()


func clear_queue() -> void:
	queue = []
	current = 0


func next() -> void:
	decrease_effects()
	decrease_cooldowns()
	if current < len(queue) - 1:
		current += 1
		
	else:
		current = 0
		handle_objects()
	init_entity_variables()


func on_action_changed(action : String) -> void:
	current_action = action
	print("INFO: Action changed: ", action)
	signals.emit_signal("targeting_called", current_entity["actions"][action])


func on_field_pressed(position : Vector2) -> void: # Handle actions triggered by pressing a field
	if current_action == "": # If player hasn't chosen any action yet.
		return
	if not validate_action():
		return
	if not valid_targets[position.x][position.y]:
		return
	
	var action : Dictionary = current_entity["actions"][current_action]
	
	if action["target"][0] == "entity":
		var target : int = board.get_entity_index(position)
		if "damage" in action:
			var damage : int = int(rand_range(action["damage"][0] + current_entity["effects"]["damage"][0],
								action["damage"][1] + 1 + current_entity["effects"]["damage"][0]))
			signals.emit_signal("attack_requested", target, damage, action["pierce"])
		if target_died:
			end_action()
			return
		if "heal" in action:
			var heal : int = int(rand_range(action["heal"][0] + current_entity["effects"]["healing"][0],
								action["healing"][1] + 1 + current_entity["effects"]["healing"][0]))
			signals.emit_signal("regeneration_requested", target, heal)
		if target_died:
			end_action()
			return
		if "effects" in action:
			signals.emit_signal("effects_addition_requested", target, action["effects"])
	
	if action["target"][0] == "field":
		if "move" in action:
			var entity_pos : Vector2 = board.get_entity_position(queue[current])
			board.move(Vector3(1, entity_pos.x, entity_pos.y), Vector3(1, position.x, position.y))
			signals.emit_signal("entity_moved", queue[current], position)
	
	end_action()


func on_targets_changed(targets : Array) -> void:
	valid_targets = targets # Put targets recieved from the Targeting system into local variable


func on_action_triggered() -> void: # Handle actions which doesn't require manual aiming
	if not validate_action():
		return
	match current_action:
		"pass":
			print("INFO: Turn passed")
			next()
			return
		_: # If incorrect action type was chosen, should never happen
			print("***Incorrect action type was triggered***")
			return
	end_action()


func validate_action() -> bool: # Returns true if action is valid
	var action : Dictionary = current_entity["actions"][current_action]
	if action["cost"] > temp["ap"]:
		return false
	if temp["actions_usages"][current_action] < 1:
		return false
	if "cooldown" in action and action["cooldown"][0] < action["cooldown"][1]:
		return false
	return true


func end_action() -> void:
	if "cooldown" in current_entity["actions"][current_action]:
		current_entity["actions"][current_action]["cooldown"][0] = 0
	target_died = false
	temp["ap"] -= current_entity["actions"][current_action]["cost"]
	temp["actions_usages"][current_action] -= 1
	current_action = ""
	if temp["ap"] < 1:
		next()
		signals.emit_signal("action_succeeded")
	else:
		signals.emit_signal("action_succeeded")
		signals.emit_signal("targeting_called", {"target": ["", ""]})


func apply_effects() -> void:
	for i in current_entity["effects"].keys():
		var effect : Array = current_entity["effects"][i]
		if effect[1] > 0:
			match i:
				"regen":
					signals.emit_signal("regeneration_requested", queue[current], effect[0])
					effect[1] -= 1
				"armor", "hp", "damage", "healing", "move":
					pass
				_:
					print("***Unimplemented effect***")
	decrease_effects()


func decrease_effects():
	for i in current_entity["effects"]:
		if i in effects_queued:
			current_entity["effects"][i][1] -= 1
			effects_queued.erase(i)
		else:
			if current_entity["effects"][i][1] > 0:
				effects_queued.append(i)


func on_entity_removed(index_original : int) -> void:
	# Changing indexes if necessary and finding local index
	target_died = true
	var index : int = 0 # index stores position in a local queue, while index_original stores the board index
	for i in range(len(queue)):
		if queue[i] > index_original:
			queue[i] -= 1
		elif queue[i] == index_original:
			index = i
	
	queue.remove(index) # Removing entity from the queue
	
	# Correcting current entity value
	if current > index:
		current -= 1
		signals.emit_signal("current_entity_changed", queue[current])
	elif current == index:
		init_entity_variables()


func handle_objects() -> void: # Handling objects requiring automatic respawn/removal
	var i : int = 0 # Index of a current object
	while i < board.get_object_count():
		var object : Dictionary = board.get_object(i)["object"] # Currently handled object
		if object["time"] != -1: # If object isn't set to permanent
			if object["current_time"] > 0: # If there is still time left for object to peacefully exist
				object["current_time"] -= 1
			else: # On object timeout
				if object["respawns"]: # If object should respawn
					board.replace_object(i)
					object["current_time"] = object["time"]
				else: # If object should be deleted
					board.remove_object(i)
					i -= 1
		i += 1


func decrease_cooldowns() -> void: # Decreasing cooldowns in every action which requires it
	for action in current_entity["actions"].values():
		if "cooldown" in action and action["cooldown"][0] < action["cooldown"][1]:
			action["cooldown"][0] += 1
