@tool
class_name _ModLoaderModHookPreProcessor
extends RefCounted


# This class is used to process the source code from a script at a given path.
# Currently all of the included functions are internal and should only be used by the mod loader itself.

const LOG_NAME := "ModLoader:ModHookPreProcessor"

const REQUIRE_EXPLICIT_ADDITION := false
const METHOD_PREFIX := "vanilla_"
const HASH_COLLISION_ERROR := \
	"MODDING HOOKS ERROR: Hash collision between %s and %s. The collision can be resolved by renaming one of the methods or changing their script's path."
const MOD_LOADER_HOOKS_START_STRING := \
	"\n# ModLoader Hooks - The following code has been automatically added by the Godot Mod Loader."

static var engine_version_string := "%s.%s" % [Engine.get_version_info().major, Engine.get_version_info().minor]

## finds function names used as setters and getters (excluding inline definitions)
## group 2 and 4 contain the xetter names
var regex_getter_setter := RegEx.create_from_string("(.*?[sg]et\\s*=\\s*)(\\w+)(\\g<1>)?(\\g<2>)?")

## finds every instance where super() is called
## returns only the super word, excluding the (, as match to make substitution easier
var regex_super_call := RegEx.create_from_string("\\bsuper(?=\\s*\\()")

## Matches the indented function body.
## Needs to start from the : of a function declaration to work (.search() offset param)
## The body of a function is every line that is empty or starts with an indent or comment
var regex_func_body := RegEx.create_from_string("(?smn)\\N*(\\n^(([\\t #]+\\N*)|$))*")

## Just await between word boundaries
var regex_keyword_await := RegEx.create_from_string("\\bawait\\b")

var hashmap := {}
var script_paths_hooked := {}


func process_begin() -> void:
	hashmap.clear()


func process_script_verbose(path: String, enable_hook_check := false) -> String:
	var start_time := Time.get_ticks_msec()
	ModLoaderLog.debug("Start processing script at path: %s" % path, LOG_NAME)
	var processed := process_script(path, enable_hook_check)
	ModLoaderLog.debug("Finished processing script at path: %s in %s ms" % [path, Time.get_ticks_msec() - start_time], LOG_NAME)
	return processed


func process_script(path: String, enable_hook_check := false) -> String:
	var current_script := load(path) as GDScript

	var source_code := current_script.source_code

	var source_code_additions := ""

	# We need to stop all vanilla methods from forming inheritance chains,
	# since the generated methods will fulfill inheritance requirements
	var class_prefix := str(hash(path))
	var method_store: Array[String] = []

	var getters_setters := collect_getters_and_setters(source_code)

	var moddable_methods := current_script.get_script_method_list().filter(
		is_func_moddable.bind(source_code, getters_setters)
	)

	var methods_hooked := {}

	for method in moddable_methods:
		if method.name in method_store:
			continue

		var prefix := "%s%s_" % [METHOD_PREFIX, class_prefix]

		# Check if the method name starts with the prefix added by `edit_vanilla_method()`.
		# This indicates that the method was previously processed, possibly by the export plugin.
		# If so, store the method name (excluding the prefix) in `methods_hooked`.
		if method.name.begins_with(prefix):
			var method_name_vanilla: String = method.name.trim_prefix(prefix)
			methods_hooked[method_name_vanilla] = true
			continue

		# This ensures we avoid creating a hook for the 'imposter' method, which
		# is generated by `build_mod_hook_string()` and has the vanilla method name.
		if methods_hooked.has(method.name):
			continue

		var type_string := get_return_type_string(method.return)
		var is_static := true if method.flags == METHOD_FLAG_STATIC + METHOD_FLAG_NORMAL else false

		var func_def: RegExMatch = match_func_with_whitespace(method.name, source_code)
		if not func_def: # Could not regex match a function with that name
			continue # Means invalid Script, should never happen

		# Processing does not cover methods in subclasses yet.
		# If a function with the same name was found in a subclass,
		# try again until we find the top level one
		var max_loop := 1000
		while not is_top_level_func(source_code, func_def.get_start(), is_static): # indent before "func"
			func_def = match_func_with_whitespace(method.name, source_code, func_def.get_end())
			if not func_def or max_loop <= 0: # Couldn't match any func like before
				break # Means invalid Script, should never happen
			max_loop -= 1

		var func_body_start_index := get_func_body_start_index(func_def.get_end(), source_code)
		if func_body_start_index == -1: # The function is malformed, opening ( was not closed by )
			continue # Means invalid Script, should never happen

		var func_body := match_method_body(method.name, func_body_start_index, source_code)
		if not func_body: # No indented lines found
			continue # Means invalid Script, should never happen

		var is_async := is_func_async(func_body.get_string())
		var method_arg_string_with_defaults_and_types := get_function_parameters(method.name, source_code, is_static)
		var method_arg_string_names_only := get_function_arg_name_string(method.args)

		var hook_id := _ModLoaderHooks.get_hook_hash(path, method.name)
		var hook_id_data := [path, method.name, true]
		if hashmap.has(hook_id):
			push_error(HASH_COLLISION_ERROR%[hashmap[hook_id], hook_id_data])
		hashmap[hook_id] = hook_id_data

		var mod_loader_hook_string := build_mod_hook_string(
			method.name,
			method_arg_string_names_only,
			method_arg_string_with_defaults_and_types,
			type_string,
			method.return.usage,
			is_static,
			is_async,
			hook_id,
			METHOD_PREFIX + class_prefix,
			enable_hook_check
		)

		# Store the method name
		# Not sure if there is a way to get only the local methods in a script,
		# get_script_method_list() returns a full list,
		# including the methods from the scripts it extends,
		# which leads to multiple entries in the list if they are overridden by the child script.
		method_store.push_back(method.name)
		source_code = edit_vanilla_method(
			method.name,
			source_code,
			func_def,
			func_body,
			METHOD_PREFIX + class_prefix
		)
		source_code_additions += "\n%s" % mod_loader_hook_string

		script_paths_hooked[path] = true

	# If we have some additions to the code, append them at the end
	if source_code_additions != "":
		source_code = "%s\n%s\n%s" % [source_code, MOD_LOADER_HOOKS_START_STRING, source_code_additions]

	return source_code


static func is_func_moddable(method: Dictionary, source_code: String, getters_setters := {}) -> bool:
	if getters_setters.has(method.name):
		return false

	var method_first_line_start := _ModLoaderModHookPreProcessor.get_index_at_method_start(method.name, source_code)
	if method_first_line_start == -1:
		return false

	if not _ModLoaderModHookPreProcessor.is_func_marked_moddable(method_first_line_start, source_code):
		return false

	return true


func is_func_async(func_body_text: String) -> bool:
	if not func_body_text.contains("await"):
		return false

	var lines := func_body_text.split("\n")
	var in_multiline_string := false
	var current_multiline_delimiter := ""

	for _line in lines:
		var line: String = _line
		var char_index := 0
		while char_index < line.length():
			if in_multiline_string:
				# Check if we are exiting the multiline string
				if line.substr(char_index).begins_with(current_multiline_delimiter):
					in_multiline_string = false
					char_index += 3
				else:
					char_index += 1
				continue

			# Comments: Skip the rest of the line
			if line.substr(char_index).begins_with("#"):
				break

			# Check for multiline string start
			if line.substr(char_index).begins_with('"""') or line.substr(char_index).begins_with("'''"):
				in_multiline_string = true
				current_multiline_delimiter = line.substr(char_index, 3)
				char_index += 3
				continue

			# Check for single-quoted strings
			if line[char_index] == '"' or line[char_index] == "'":
				var delimiter = line[char_index]
				char_index += 1
				while char_index < line.length() and line[char_index] != delimiter:
					# Skip escaped quotes
					if line[char_index] == "\\":
						char_index += 1
					char_index += 1
				char_index += 1  # Skip the closing quote
				continue

			# Check for the "await" keyword
			if not line.substr(char_index).begins_with("await"):
				char_index += 1
				continue

			# Ensure "await" is a standalone word
			var start := char_index -1 if char_index > 0 else 0
			if regex_keyword_await.search(line.substr(start)):
				return true # Just return here, we don't need every occurence
				# i += 5  # Normal parser: Skip the keyword
			else:
				char_index += 1

	return false


static func get_function_arg_name_string(args: Array) -> String:
	var arg_string := ""
	for x in args.size():
		if x == args.size() -1:
			arg_string += args[x].name
		else:
			arg_string += "%s, " % args[x].name

	return arg_string


static func get_function_parameters(method_name: String, text: String, is_static: bool, offset := 0) -> String:
	var result := match_func_with_whitespace(method_name, text, offset)
	if result == null:
		return ""

	# Find the index of the opening parenthesis
	var opening_paren_index := result.get_end() - 1
	if opening_paren_index == -1:
		return ""

	if not is_top_level_func(text, result.get_start(), is_static):
		return get_function_parameters(method_name, text, is_static, result.get_end())

	# Shift the func_def_end index back by one to start on the opening parentheses.
	# Because the match_func_with_whitespace().get_end() is the index after the opening parentheses.
	var closing_paren_index := get_closing_paren_index(opening_paren_index - 1, text)
	if closing_paren_index == -1:
		return ""

	# Extract the substring between the parentheses
	var param_string := text.substr(opening_paren_index + 1, closing_paren_index - opening_paren_index - 1)

	# Clean whitespace characters (spaces, newlines, tabs)
	param_string = param_string.strip_edges()\
		.replace(" ", "")\
		.replace("\t", "")\
		.replace(",", ", ")\
		.replace(":", ": ")

	return param_string


static func get_closing_paren_index(opening_paren_index: int, text: String) -> int:
	# Use a stack counter to match parentheses
	var stack := 0
	var closing_paren_index := opening_paren_index
	while closing_paren_index < text.length():
		var char := text[closing_paren_index]
		if char == '(':
			stack += 1
		elif char == ')':
			stack -= 1
			if stack == 0:
				break
		closing_paren_index += 1

	# If the stack is not empty, that means there's no matching closing parenthesis
	if stack != 0:
		return -1

	return closing_paren_index


func edit_vanilla_method(
	method_name: String,
	text: String,
	func_def: RegExMatch,
	func_body: RegExMatch,
	prefix := METHOD_PREFIX,
) -> String:
	text = fix_method_super(method_name, func_body, text)
	text = text.erase(func_def.get_start(), func_def.get_end() - func_def.get_start())
	text = text.insert(func_def.get_start(), "func %s_%s(" % [prefix, method_name])

	return text


func fix_method_super(method_name: String, func_body: RegExMatch, text: String) -> String:	
	if engine_version_string == "4.1":
		return fix_method_super_4_1(method_name, func_body, text)
	
	return regex_super_call.sub(
		text, "super.%s" % method_name,
		true, func_body.get_start(), func_body.get_end()
	)


# For unknown reasons, RegEx.sub() erases everything after the function body in 4.1,
# leaving only the first function in the script.
func fix_method_super_4_1(method_name: String, func_body: RegExMatch, text: String) -> String:
	var super_matches := regex_super_call.search_all(text, func_body.get_start(), func_body.get_end())

	for super_match in super_matches:
		text = text.erase(super_match.get_start(), super_match.get_end() - super_match.get_start())
		text = text.insert(super_match.get_start(), "super.%s" % method_name)

	return text


static func get_func_body_start_index(func_def_end: int, source_code: String) -> int:
	# Shift the func_def_end index back by one to start on the opening parentheses.
	# Because the match_func_with_whitespace().get_end() is the index after the opening parentheses.
	var closing_paren_index := get_closing_paren_index(func_def_end - 1, source_code)
	if closing_paren_index == -1:
		return -1
	return source_code.find(":", closing_paren_index) +1


func match_method_body(method_name: String, func_body_start_index: int, text: String) -> RegExMatch:
	return regex_func_body.search(text, func_body_start_index)


static func match_func_with_whitespace(method_name: String, text: String, offset := 0) -> RegExMatch:
	# Dynamically create the new regex for that specific name
	var func_with_whitespace := RegEx.create_from_string("func\\s+%s[\\\\\\s]*\\(" % method_name)
	return func_with_whitespace.search(text, offset)


static func build_mod_hook_string(
	method_name: String,
	method_arg_string_names_only: String,
	method_arg_string_with_defaults_and_types: String,
	method_type: String,
	return_prop_usage: int,
	is_static: bool,
	is_async: bool,
	hook_id: int,
	method_prefix := METHOD_PREFIX,
	enable_hook_check := false,
) -> String:
	var type_string := " -> %s" % method_type if not method_type.is_empty() else ""
	var static_string := "static " if is_static else ""
	var await_string := "await " if is_async else ""
	var async_string := "_async" if is_async else ""
	var return_var := "var %s = " % "return_var" if not method_type.is_empty() or return_prop_usage == 131072 else ""
	var method_return := "return " if not method_type.is_empty() or return_prop_usage == 131072 else ""
	var hook_check := "if ModLoaderStore.any_mod_hooked:\n\t\t" if enable_hook_check else ""
	var hook_check_else := get_hook_check_else_string(
			method_return, await_string, method_prefix, method_name, method_arg_string_names_only
		) if enable_hook_check else ""


	return """
{STATIC}func {METHOD_NAME}({METHOD_PARAMS}){RETURN_TYPE_STRING}:
	{HOOK_CHECK}{METHOD_RETURN}{AWAIT}_ModLoaderHooks.call_hooks{ASYNC}({METHOD_PREFIX}_{METHOD_NAME}, [{METHOD_ARGS}], {HOOK_ID}){HOOK_CHECK_ELSE}
""".format({
		"METHOD_PREFIX": method_prefix,
		"METHOD_NAME": method_name,
		"METHOD_PARAMS": method_arg_string_with_defaults_and_types,
		"RETURN_TYPE_STRING": type_string,
		"METHOD_ARGS": method_arg_string_names_only,
		"METHOD_RETURN_VAR": return_var,
		"METHOD_RETURN": method_return,
		"STATIC": static_string,
		"AWAIT": await_string,
		"ASYNC": async_string,
		"HOOK_ID": hook_id,
		"HOOK_CHECK": hook_check,
		"HOOK_CHECK_ELSE": hook_check_else
	})


static func get_previous_line_to(text: String, index: int) -> String:
	if index <= 0 or index >= text.length():
		return ""

	var start_index := index - 1
	# Find the end of the previous line
	while start_index > 0 and text[start_index] != "\n":
		start_index -= 1

	if start_index == 0:
		return ""

	start_index -= 1

	# Find the start of the previous line
	var end_index := start_index
	while start_index > 0 and text[start_index - 1] != "\n":
		start_index -= 1

	return text.substr(start_index, end_index - start_index + 1)


static func is_func_marked_moddable(method_start_idx, text) -> bool:
	var prevline := get_previous_line_to(text, method_start_idx)

	if prevline.contains("@not-moddable"):
		return false
	if not REQUIRE_EXPLICIT_ADDITION:
		return true

	return prevline.contains("@moddable")


static func get_index_at_method_start(method_name: String, text: String) -> int:
	var result := match_func_with_whitespace(method_name, text)

	if result:
		return text.find("\n", result.get_end())
	else:
		return -1


static func is_top_level_func(text: String, result_start_index: int, is_static := false) -> bool:
	if is_static:
		result_start_index = text.rfind("static", result_start_index)

	var line_start_index := text.rfind("\n", result_start_index) + 1
	var pre_func_length := result_start_index - line_start_index

	if pre_func_length > 0:
		return false

	return true


static func get_return_type_string(return_data: Dictionary) -> String:
	if return_data.type == 0:
		return ""
	var type_base: String
	if return_data.has("class_name") and not str(return_data.class_name).is_empty():
		type_base = str(return_data.class_name)
	else:
		type_base = get_type_name(return_data.type)

	var type_hint: String = "" if return_data.hint_string.is_empty() else ("[%s]" % return_data.hint_string)

	return "%s%s" % [type_base, type_hint]


func collect_getters_and_setters(text: String) -> Dictionary:
	var result := {}
	# a valid match has 2 or 4 groups, split into the method names and the rest of the line
	# (var example: set = )(example_setter)(, get = )(example_getter)
	# if things between the names are empty or commented, exclude them
	for mat in regex_getter_setter.search_all(text):
		if mat.get_string(1).is_empty() or mat.get_string(1).contains("#"):
			continue
		result[mat.get_string(2)] = true

		if mat.get_string(3).is_empty() or mat.get_string(3).contains("#"):
			continue
		result[mat.get_string(4)] = true

	return result


static func get_hook_check_else_string(
	method_return: String,
	await_string: String,
	method_prefix: String,
	method_name: String,
	method_arg_string_names_only: String
) -> String:
	return "\n\telse:\n\t\t{METHOD_RETURN}{AWAIT}{METHOD_PREFIX}_{METHOD_NAME}({METHOD_ARGS})".format(
			{
				"METHOD_RETURN": method_return,
				"AWAIT": await_string,
				"METHOD_PREFIX": method_prefix,
				"METHOD_NAME": method_name,
				"METHOD_ARGS": method_arg_string_names_only
			}
		)


# This function was taken from
# https://github.com/godotengine/godot/blob/7e67b496ff7e35f66b88adcbdd5b252d01739cbb/modules/gdscript/tests/scripts/utils.notest.gd#L69
# It is used instead of type_string because type_string does not exist in Godot 4.1
static func get_type_name(type: Variant.Type) -> String:
	match type:
		TYPE_NIL:
			return "Nil" # `Nil` in core, `null` in GDScript.
		TYPE_BOOL:
			return "bool"
		TYPE_INT:
			return "int"
		TYPE_FLOAT:
			return "float"
		TYPE_STRING:
			return "String"
		TYPE_VECTOR2:
			return "Vector2"
		TYPE_VECTOR2I:
			return "Vector2i"
		TYPE_RECT2:
			return "Rect2"
		TYPE_RECT2I:
			return "Rect2i"
		TYPE_VECTOR3:
			return "Vector3"
		TYPE_VECTOR3I:
			return "Vector3i"
		TYPE_TRANSFORM2D:
			return "Transform2D"
		TYPE_VECTOR4:
			return "Vector4"
		TYPE_VECTOR4I:
			return "Vector4i"
		TYPE_PLANE:
			return "Plane"
		TYPE_QUATERNION:
			return "Quaternion"
		TYPE_AABB:
			return "AABB"
		TYPE_BASIS:
			return "Basis"
		TYPE_TRANSFORM3D:
			return "Transform3D"
		TYPE_PROJECTION:
			return "Projection"
		TYPE_COLOR:
			return "Color"
		TYPE_STRING_NAME:
			return "StringName"
		TYPE_NODE_PATH:
			return "NodePath"
		TYPE_RID:
			return "RID"
		TYPE_OBJECT:
			return "Object"
		TYPE_CALLABLE:
			return "Callable"
		TYPE_SIGNAL:
			return "Signal"
		TYPE_DICTIONARY:
			return "Dictionary"
		TYPE_ARRAY:
			return "Array"
		TYPE_PACKED_BYTE_ARRAY:
			return "PackedByteArray"
		TYPE_PACKED_INT32_ARRAY:
			return "PackedInt32Array"
		TYPE_PACKED_INT64_ARRAY:
			return "PackedInt64Array"
		TYPE_PACKED_FLOAT32_ARRAY:
			return "PackedFloat32Array"
		TYPE_PACKED_FLOAT64_ARRAY:
			return "PackedFloat64Array"
		TYPE_PACKED_STRING_ARRAY:
			return "PackedStringArray"
		TYPE_PACKED_VECTOR2_ARRAY:
			return "PackedVector2Array"
		TYPE_PACKED_VECTOR3_ARRAY:
			return "PackedVector3Array"
		TYPE_PACKED_COLOR_ARRAY:
			return "PackedColorArray"
		38: # TYPE_PACKED_VECTOR4_ARRAY
			return "PackedVector4Array"
	push_error("Argument `type` is invalid. Use `TYPE_*` constants.")
	return "<invalid type>"
