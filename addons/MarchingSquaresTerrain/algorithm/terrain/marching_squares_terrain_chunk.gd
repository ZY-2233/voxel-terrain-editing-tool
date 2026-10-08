# ============================================================================
# MarchingSquaresTerrainChunk
# ----------------------------------------------------------------------------
# 基于 Marching Squares 的地形区块节点。
# 每个区块负责生成自己的网格、草地、碰撞体，并保存高度图、颜色图等数据。
# 通常作为 MarchingSquaresTerrain 的子节点存在。
#
# 注意：
# 本文件只是在原始源码基础上添加注释，未修改任何代码逻辑、变量名、
# 缩进结构、导出属性或函数行为。
# ============================================================================

@tool
extends MeshInstance3D
class_name MarchingSquaresTerrainChunk


# 地形合并模式。决定相邻高度点之间如何生成墙面。
enum Mode {CUBIC, POLYHEDRON, ROUNDED_POLYHEDRON, SEMI_ROUND, SPHERICAL}

# 每种合并模式对应的最大高度差阈值。
# 两个相邻点的高度差超过该阈值时，会在它们之间生成墙面。
const MERGE_MODE = {
	Mode.CUBIC: 0.6,
	Mode.POLYHEDRON: 1.3,
	Mode.ROUNDED_POLYHEDRON: 2.1,
	Mode.SEMI_ROUND: 5.0,
	Mode.SPHERICAL: 20.0,
}

# 这两个必须是普通导出变量，否则 Godot 内部逻辑会导致插件崩溃。
# terrain_system：所属的地形系统主节点。
# chunk_coords：该区块在地形网格中的坐标。
@export var terrain_system : MarchingSquaresTerrain
@export var chunk_coords : Vector2i = Vector2i.ZERO

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var merge_mode : Mode = Mode.POLYHEDRON: # The max height distance between points before a wall is created between them
	# setter：设置合并模式。如果节点已在场景树中且草地规划器可用，
	# 则更新草地材质的 is_merge_round 参数，并根据模式设置 merge_threshold，
	# 最后重新生成所有单元格。
	set(mode):
		merge_mode = mode
		if is_inside_tree() and grass_planter and grass_planter.multimesh:
			var grass_mat : ShaderMaterial = grass_planter.multimesh.mesh.material as ShaderMaterial
			if mode == Mode.SEMI_ROUND or mode == Mode.SPHERICAL:
				grass_mat.set_shader_parameter("is_merge_round", true)
			else:
				grass_mat.set_shader_parameter("is_merge_round", false)
			merge_threshold = MERGE_MODE[mode]
			regenerate_all_cells(true)
@export_storage var height_map : Array # Stores the heights from the heightmap
# 中文：存储高度图的高度值。二维数组，[z][x]。

#region cell_geometry storage
# 中文：单元格几何数据存储区域。
# 颜色图现在是临时的，在运行时创建。
# 通过 MSTDataHandler 持久化保存。
var color_map_0 : PackedColorArray # Stores the colors from vertex_color_0 (ground)
# 中文：存储 vertex_color_0（地面）的颜色。
var color_map_1 : PackedColorArray # Stores the colors from vertex_color_1 (ground)
# 中文：存储 vertex_color_1（地面）的颜色。
var wall_color_map_0 : PackedColorArray # Stores the colors for wall vertices (slot encoding channel 0)
# 中文：存储墙体顶点的颜色（槽位编码通道 0）。
var wall_color_map_1 : PackedColorArray # Stores the colors for wall vertices (slot encoding channel 1)
# 中文：存储墙体顶点的颜色（槽位编码通道 1）。
var grass_mask_map : PackedColorArray # Stores if a cell should have grass or not
# 中文：存储某个单元格是否应该生成草。
#endregion

# 合并阈值，默认使用 POLYHEDRON 模式的值。
var merge_threshold : float = MERGE_MODE[Mode.POLYHEDRON]

# 草地规划器，负责在该区块上生成草地。
var grass_planter : MarchingSquaresGrassPlanter

# 缓存的全局位置，避免频繁调用 global_position。
var global_position_cached : Vector3 = Vector3.ZERO

# 用于单元格生成时的互斥锁，保证多线程安全。
var cell_generation_mutex : Mutex = Mutex.new()

# 烘焙时使用的默认着色器材质。
var bake_material : ShaderMaterial = preload("uid://cbbvkbnwmr2em")

#region chunk variables
# 中文：区块变量区域。
# Size of the 2 dimensional cell array (xz value) and y scale (y value)
# 中文：二维单元格数组的大小（xz 值）以及 Y 轴缩放（y 值）。
var dimensions : Vector3i:
	get:
		return terrain_system.dimensions
# Unit XZ size of a single cell
# 中文：单个单元格在 XZ 平面上的单位大小。
var cell_size : Vector2:
	get:
		return terrain_system.cell_size
#endregion

# 用于构建当前地形的 SurfaceTool。
var st : SurfaceTool # The surfacetool used to construct the current terrain

# 存储所有已生成的单元格几何数据，以便快速复用。
var cell_geometry : Dictionary = {} # Stores all generated tiles so that their geometry can quickly be reused

# 存储哪些单元格需要更新，因为其某个角点的高度发生了变化。
var needs_update : Array[Array] # Stores which tiles need to be updated because one of their corners' heights was changed.
# 当区块被临时移除（撤销/重做）时设为 true。
var _skip_save_on_exit : bool = false # Set to true when chunk is removed temporarily (undo/redo)
# 当源数据变化时设为 true，触发 MSTDataHandler 中的保存。
var _data_dirty : bool = false # Set to true when source data changes, triggers save in MSTDataHandler

#region temporary storage vars
# 中文：临时存储变量区域。
# 场景保存期间用于临时保存临时资源。
var _temp_mesh : ArrayMesh
var _temp_grass_multimesh : MultiMesh
var _temp_collision_shapes : Array[ConcavePolygonShape3D] = []  # COMMENT: Old scenes may have duplicates
# 中文：注释：旧场景可能存在重复的碰撞形状。
var _temp_height_map : Array  # Source data - saved to external storage, not scene file
# 中文：源数据——保存到外部存储，而不是场景文件。
#endregion

#region blend option vars
# 中文：混合选项变量区域。
# Terrain blend options to allow for smooth color and height blend influence at transitions and at different heights 
# 中文：地形混合选项，允许在过渡处和不同高度处实现平滑的颜色与高度混合影响。
var lower_thresh : float = 0.3 # Sharp bands: < 0.3 = lower color
# 中文：锐利分带：< 0.3 使用下方颜色。
var upper_thresh : float = 0.7 #, > 0.7 = upper color, middle = blend
# 中文：> 0.7 使用上方颜色，中间为混合。
var blend_zone := upper_thresh - lower_thresh
# 中文：混合区域宽度。
#endregion

# Called by TerrainSystem parent
# 中文：由父级 TerrainSystem 调用。
func initialize_terrain(should_regenerate_mesh: bool = true):
	needs_update = []
	# Initally all cells will need to be updated to show the newly loaded height
	# 中文：初始时所有单元格都需要更新，以显示新加载的高度。
	for z in range(dimensions.z - 1):
		needs_update.append([])
		for x in range(dimensions.x - 1):
			needs_update[z].append(true)
	
	# 如果不存在 GrassPlanter 节点，则创建并初始化。
	if not get_node_or_null("GrassPlanter"):
		grass_planter = get_node_or_null("GrassPlanter")
		if not grass_planter:
			grass_planter = MarchingSquaresGrassPlanter.new()
			if not color_map_0 or not color_map_1:
				generate_color_maps()
			if not grass_mask_map:
				generate_grass_mask_map()
			add_child(grass_planter)
		grass_planter.name = "GrassPlanter"
		grass_planter._chunk = self
		grass_planter.setup(self)
		EngineWrapper.instance.set_owner_recursive(grass_planter)
	else:
		if not grass_planter:
			grass_planter = get_node_or_null("GrassPlanter")
		grass_planter.terrain_system = terrain_system
		grass_planter._chunk = self
	
	# 如果存在临时的草地 MultiMesh，则恢复。
	if _temp_grass_multimesh:
		grass_planter.multimesh = _temp_grass_multimesh
	if not grass_planter.multimesh:
		grass_planter.setup(self)
		grass_planter.regenerate_all_cells()
	grass_planter.multimesh.mesh = terrain_system.grass_mesh
	
	# Generate maps if not loaded from external storage (works for both editor and runtime)
	# 中文：如果未从外部存储加载，则生成各种映射图（编辑器和运行时均适用）。
	if not height_map:
		generate_height_map()
	if not color_map_0 or not color_map_1:
		generate_color_maps()
	if not wall_color_map_0 or not wall_color_map_1:
		generate_wall_color_maps()
	if not grass_mask_map:
		generate_grass_mask_map()
	
	# 如果网格不存在且需要重新生成，则重新生成网格。
	if not mesh and should_regenerate_mesh:
		regenerate_mesh(true)
	elif mesh:
		if terrain_system:
			mesh.surface_set_material(0, terrain_system.terrain_material)
		if not _temp_collision_shapes.is_empty():
			_recreate_collision_body()
		else:
			# 清理旧的碰撞体，并重新创建三角网格碰撞。
			for child in get_children():
				if child is StaticBody3D:
					child.free()
			create_trimesh_collision()
			for child in get_children():
				if child is StaticBody3D:
					child.collision_layer = 17
					child.set_collision_layer_value(terrain_system.extra_collision_layer, true)
					for _child in child.get_children():
						if _child is CollisionShape3D:
							_child.set_visible(false)
	
	# 如果不是编辑器且启用了运行时纹理烘焙，则启动几何纹理烘焙。
	if not EngineWrapper.instance.is_editor() and terrain_system.enable_runtime_texture_baking:
		var baker := MarchingSquaresGeometryBaker.new()
		baker.polygon_texture_resolution = terrain_system.polygon_texture_resolution
		baker.finished.connect(func(mesh_: Mesh, _original: MeshInstance3D, img: Image):
			mesh = mesh_
			var mat : Material
			if terrain_system.bake_material_override: 
				mat = terrain_system.bake_material_override.duplicate()
			else:
				mat = bake_material.duplicate()
			
			if mat is StandardMaterial3D:
				mat.albedo_texture = ImageTexture.create_from_image(img)
			elif mat is ShaderMaterial:
				mat.set_shader_parameter("texture_albedo", ImageTexture.create_from_image(img))
			mesh.surface_set_material(0, mat)
		, CONNECT_ONE_SHOT)
		baker.bake_geometry_texture(self, get_tree())


func _notification(what: int) -> void:
	# 仅在编辑器中处理通知。
	if not EngineWrapper.instance.is_editor():
		return
	
	match what:
		NOTIFICATION_EDITOR_PRE_SAVE:
			# Store height_map and clear - source data saved to external storage, not scene
			# 中文：保存 height_map 并清空——源数据保存到外部存储，而不是场景中。
			_skip_save_on_exit = _skip_save_on_exit # Surpress warning
			# 中文：抑制未使用警告。
			_temp_height_map = height_map
			height_map = []
			
			# Store mesh and clear to prevent serialization
			# 中文：保存网格并清空，防止被序列化。
			_temp_mesh = mesh
			mesh = null
			
			# Store grass multimesh and clear
			# 中文：保存草地 MultiMesh 并清空。
			if grass_planter and grass_planter.multimesh:
				_temp_grass_multimesh = grass_planter.multimesh
				grass_planter.multimesh = null
			
			# Handle ALL collision bodies (old scenes may have multiple duplicates!)
			# 中文：处理所有碰撞体（旧场景可能存在多个重复体！）。
			_temp_collision_shapes.clear()
			var bodies_to_free : Array[StaticBody3D] = []
			for child in get_children():
				if child is StaticBody3D:
					for shape_child in child.get_children():
						if shape_child is CollisionShape3D and shape_child.shape is ConcavePolygonShape3D:
							_temp_collision_shapes.append(shape_child.shape)
							shape_child.shape = null  # Clear to prevent sub_resource save
							# 中文：清空以防止保存为子资源。
						shape_child.owner = null
					child.owner = null
					bodies_to_free.append(child)
			# Free all bodies (after iteration to avoid modifying while iterating)
			# 中文：释放所有碰撞体（在迭代后释放，避免在迭代中修改）。
			for body in bodies_to_free:
				body.name += "_"
				body.queue_free()
		
		NOTIFICATION_EDITOR_POST_SAVE:
			# Restore height_map
			# 中文：恢复 height_map。
			if _temp_height_map:
				height_map = _temp_height_map
				_temp_height_map = []
			
			# Restore mesh
			# 中文：恢复网格。
			if _temp_mesh:
				mesh = _temp_mesh
				_temp_mesh = null
			
			# Restore grass multimesh
			# 中文：恢复草地 MultiMesh。
			if _temp_grass_multimesh and grass_planter:
				grass_planter.multimesh = _temp_grass_multimesh
				_temp_grass_multimesh = null
			
			# Recreate ONE collision body (only need one, even if old scene had duplicates)
			# 中文：重新创建一个碰撞体（即使旧场景有重复，也只需要一个）。
			if not _temp_collision_shapes.is_empty():
				_recreate_collision_body.call_deferred()
		
		NOTIFICATION_PREDELETE:
			# Safety cleanup - clear owner on ALL collision nodes
			# 中文：安全清理——清除所有碰撞节点的 owner。
			for child in get_children():
				if child is StaticBody3D:
					child.owner = null
					for shape_child in child.get_children():
						if shape_child is CollisionShape3D:
							shape_child.owner = null


func _enter_tree() -> void:
	# 进入场景树时，确保父节点是 terrain_system。
	if get_parent() != terrain_system:
		push_error("Chunk must remain within its parent!")
	# 将自身注册到地形系统的区块字典中。
	terrain_system.chunks[chunk_coords] = self


func _exit_tree() -> void:
	# Clear temp references
	# 中文：清理临时引用。
	_temp_height_map = []
	_temp_mesh = null
	_temp_grass_multimesh = null
	_temp_collision_shapes.clear()
	
	# Clear owner on ALL collision nodes to prevent serialization edge cases
	# 中文：清除所有碰撞节点的 owner，防止序列化边界情况。
	if EngineWrapper.instance.is_editor():
		for child in get_children():
			if child is StaticBody3D:
				child.owner = null
				for shape_child in child.get_children():
					if shape_child is CollisionShape3D:
						shape_child.owner = null
	
	# Only erase if terrain_system still has THIS chunk at chunk_coords
	# 中文：仅当地形系统在 chunk_coords 处仍然持有此区块时才移除。
	if terrain_system and terrain_system.chunks.get(chunk_coords) == self:
		terrain_system.chunks.erase(chunk_coords)


func regenerate_mesh(use_threads: bool = false):
	# 创建新的 SurfaceTool，如果已有网格则先复制其内容。
	st = SurfaceTool.new()
	if mesh:
		st.create_from(mesh, 0)
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 设置自定义顶点格式，用于传递额外数据。
	st.set_custom_format(0, SurfaceTool.CUSTOM_RGBA_FLOAT)
	st.set_custom_format(1, SurfaceTool.CUSTOM_RGBA_FLOAT)
	st.set_custom_format(2, SurfaceTool.CUSTOM_RGBA_FLOAT)
	
	var start_time : int = Time.get_ticks_msec()
	
	# 生成地形单元格。
	generate_terrain_cells(use_threads)
	
	# 生成法线并建立索引。
	st.generate_normals()
	st.index()
	# Create a new mesh out of floor, and add the wall surface to it
	# 中文：从地板创建一个新网格，并将墙面表面添加到其中。
	mesh = st.commit()
	
	if mesh and terrain_system:
		mesh.surface_set_material(0, terrain_system.terrain_material)
	
	# 清理旧的碰撞体，重新创建三角网格碰撞。
	for child in get_children():
		if child is StaticBody3D:
			child.free()
	create_trimesh_collision()
	for child in get_children():
		if child is StaticBody3D:
			child.collision_layer = 17
			child.set_collision_layer_value(terrain_system.extra_collision_layer, true)
			for _child in child.get_children():
				if _child is CollisionShape3D:
					_child.set_visible(false)
	
	var elapsed_time : int = Time.get_ticks_msec() - start_time
	print_verbose("Generated terrain in "+str(elapsed_time)+"ms")


func generate_terrain_cells(use_threads: bool):
	if not cell_geometry:
		cell_geometry = {}
	
	# 缓存全局位置，如果不在场景树中则使用局部位置。
	global_position_cached = global_position if is_inside_tree() else position
	var thread_pool := MarchingSquaresThreadPool.new(max(1, OS.get_processor_count()))
	
	for z in range(dimensions.z - 1):
		for x in range(dimensions.x - 1):
			var cell_coords = Vector2i(x, z)
			var work_load : Callable
			# If geometry did not change, copy already generated geometry and skip this cell
			# 中文：如果几何体没有变化，则复制已生成的几何体并跳过此单元格。
			if not needs_update[z][x]:
				work_load = func():
					cell_generation_mutex.lock()
					var verts = cell_geometry[cell_coords]["verts"]
					var uvs = cell_geometry[cell_coords]["uvs"]
					var uv2s = cell_geometry[cell_coords]["uv2s"]
					var color_0s = cell_geometry[cell_coords]["color_0s"]
					var color_1s = cell_geometry[cell_coords]["color_1s"]
					var custom_1_values = cell_geometry[cell_coords]["custom_1_values"]
					var mat_blend = cell_geometry[cell_coords]["mat_blend"]
					var is_floor = cell_geometry[cell_coords]["is_floor"]
					
					for i in range(len(verts)):
						st.set_smooth_group(0 if is_floor[i] == true else -1)
						st.set_uv(uvs[i])
						st.set_uv2(uv2s[i])
						st.set_color(color_0s[i])
						st.set_custom(0, color_1s[i])
						st.set_custom(1, custom_1_values[i])
						st.set_custom(2, mat_blend[i])
						st.add_vertex(verts[i])
					cell_generation_mutex.unlock()
				if use_threads:
					thread_pool.enqueue(work_load)
				else:
					work_load.call()
				continue
			
			# Cell is now being updated
			# 中文：此单元格现在正在更新。
			needs_update[z][x] = false
			
			# If geometry did change or none exists yet, 
			# Create an entry for this cell (will also override any existing one)
			# 中文：如果几何体发生变化或尚不存在，则为该单元格创建条目（也会覆盖现有条目）。
			cell_geometry[cell_coords] = {
				"verts": PackedVector3Array(),
				"uvs": PackedVector2Array(),
				"uv2s": PackedVector2Array(),
				"color_0s": PackedColorArray(),
				"color_1s": PackedColorArray(),
				"custom_1_values": PackedColorArray(),
				"mat_blend": PackedColorArray(),
				"is_floor": [],
			}
			
			var color_helper := MarchingSquaresTerrainVertexColorHelper.new()
			var cell := MarchingSquaresTerrainCell.new(self, color_helper, height_map[z][x], height_map[z][x+1], height_map[z+1][x], height_map[z+1][x+1], merge_threshold)
			color_helper.chunk = self
			color_helper.cell = cell
			
			work_load = func():
				cell.generate_geometry(cell_coords)
				if grass_planter and grass_planter.terrain_system:
					grass_planter.generate_grass_on_cell(cell_coords)
			if use_threads:
				thread_pool.enqueue(work_load)
			else:
				work_load.call()
	
	if use_threads:
		thread_pool.start()
		thread_pool.wait()


func add_polygons(
	cell_coords : Vector2i, 
	pts : PackedVector3Array,
	uvs : PackedVector2Array,
	uv2s : PackedVector2Array,
	color_0s : PackedColorArray,
	color_1s : PackedColorArray,
	custom_1_values : PackedColorArray,
	mat_blends : PackedColorArray,
	floors : PackedByteArray,
	):
		# 断言检查各数组长度一致。
		assert(pts.size() % 3 == 0)
		assert(pts.size() == uvs.size())
		assert(pts.size() == uv2s.size())
		assert(pts.size() == color_0s.size())
		assert(pts.size() == color_1s.size())
		assert(pts.size() == custom_1_values.size())
		assert(pts.size() == mat_blends.size())
		assert(pts.size() == floors.size())
		
		cell_generation_mutex.lock()
		var floor_mode : bool = true
		st.set_smooth_group(0)
		for i in range(pts.size()):
			# 根据是否是地板来切换平滑组。
			if floor_mode and not floors[i]:
				floor_mode = false
				st.set_smooth_group(-1)
			elif not floor_mode and floors[i]:
				floor_mode = true
				st.set_smooth_group(0)
			_add_point(cell_coords, pts[i], uvs[i], uv2s[i], color_0s[i], color_1s[i], custom_1_values[i], mat_blends[i], floors[i])
		cell_generation_mutex.unlock()


# Adds a point. Coordinates are relative to the top-left corner (not mesh origin relative)
# UV.x is closeness to the bottom of an edge. UV.Y is closeness to the edge of a cliff
# 中文：添加一个点。坐标相对于左上角（不是相对于网格原点）。
# UV.x 表示靠近边缘底部的程度。UV.Y 表示靠近悬崖边缘的程度。
func _add_point(cell_coords: Vector2i, vert: Vector3, uv: Vector2, uv2: Vector2, color_0: Color, color_1: Color, custom_1_value: Color, mat_blend: Color, is_floor: bool):
	st.set_color(color_0)
	st.set_custom(0, color_1)
	st.set_custom(1, custom_1_value)
	st.set_custom(2, mat_blend)
	st.set_uv(uv)
	st.set_uv2(uv2)
	st.add_vertex(vert)
	
	# 同时将数据存入 cell_geometry 以便复用。
	cell_geometry[cell_coords]["verts"].append(vert)
	cell_geometry[cell_coords]["uvs"].append(uv)
	cell_geometry[cell_coords]["uv2s"].append(uv2)
	cell_geometry[cell_coords]["color_0s"].append(color_0)
	cell_geometry[cell_coords]["color_1s"].append(color_1)
	cell_geometry[cell_coords]["custom_1_values"].append(custom_1_value)
	cell_geometry[cell_coords]["mat_blend"].append(mat_blend)
	cell_geometry[cell_coords]["is_floor"].append(is_floor)

#region cell_geometry generators (on being empty)
# 中文：单元格几何生成器（在为空时生成）。

func generate_height_map():
	# 初始化高度图，全部为 0。
	height_map = []
	height_map.resize(dimensions.z)
	for z in range(dimensions.z):
		height_map[z] = []
		height_map[z].resize(dimensions.x)
		for x in range(dimensions.x):
			height_map[z][x] = 0.0
	
	# 如果地形系统指定了噪声，则使用噪声生成初始高度。
	var noise := terrain_system.noise_hmap
	if noise:
		for z in range(dimensions.z):
			for x in range(dimensions.x):
				var noise_x = (chunk_coords.x * (dimensions.x - 1)) + x
				var noise_z = (chunk_coords.y * (dimensions.z -1)) + z
				var noise_sample = noise.get_noise_2d(noise_x, noise_z)
				height_map[z][x] = noise_sample * dimensions.y


func generate_color_maps():
	# 初始化地面颜色图，全部透明。
	color_map_0 = PackedColorArray()
	color_map_1 = PackedColorArray()
	color_map_0.resize(dimensions.z * dimensions.x)
	color_map_1.resize(dimensions.z * dimensions.x)
	for z in range(dimensions.z):
		for x in range(dimensions.x):
			color_map_0[z*dimensions.x + x] = Color(0,0,0,0)
			color_map_1[z*dimensions.x + x] = Color(0,0,0,0)


func generate_wall_color_maps():
	# 初始化墙体颜色图，默认纹理槽位 0。
	wall_color_map_0 = PackedColorArray()
	wall_color_map_1 = PackedColorArray()
	wall_color_map_0.resize(dimensions.z * dimensions.x)
	wall_color_map_1.resize(dimensions.z * dimensions.x)
	for z in range(dimensions.z):
		for x in range(dimensions.x):
			wall_color_map_0[z*dimensions.x + x] = Color(1,0,0,0)  # Default to texture slot 0
			# 中文：默认纹理槽位 0。
			wall_color_map_1[z*dimensions.x + x] = Color(1,0,0,0)


func generate_grass_mask_map():
	# 初始化草地遮罩图，默认全部为 1（生成草）。
	grass_mask_map = PackedColorArray()
	grass_mask_map.resize(dimensions.z * dimensions.x)
	for z in range(dimensions.z):
		for x in range(dimensions.x):
			grass_mask_map[z*dimensions.x + x] = Color(1.0, 1.0, 1.0, 1.0)

#endregion

#region cell_geometry getters
# 中文：单元格几何数据获取器。

func get_height(cc: Vector2i) -> float:
	return height_map[cc.y][cc.x]


func get_color_0(cc: Vector2i) -> Color:
	return color_map_0[cc.y*dimensions.x + cc.x]


func get_color_1(cc: Vector2i) -> Color:
	return color_map_1[cc.y*dimensions.x + cc.x]


func get_wall_color_0(cc: Vector2i) -> Color:
	return wall_color_map_0[cc.y*dimensions.x + cc.x]


func get_wall_color_1(cc: Vector2i) -> Color:
	return wall_color_map_1[cc.y*dimensions.x + cc.x]


func get_grass_mask(cc: Vector2i) -> Color:
	return grass_mask_map[cc.y*dimensions.x + cc.x]

#endregion

#region cell_geometry setters
# 中文：单元格几何数据设置器。

# Draw to height.
# Returns the coordinates of all additional chunks affected by this height change.
# Empty for inner points, neightoring edge for non-corner edges, and 3 other corners for corner points.
# 中文：绘制高度。
# 返回受此高度变化影响的所有其他区块的坐标。
# 内部点返回空，非角边缘返回相邻边缘，角点返回其他 3 个角。
func draw_height(x: int, z: int, y: float):
	# Contains chunks that were updated
	# 中文：包含已更新的区块。
	height_map[z][x] = y
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)


func draw_color_0(x: int, z: int, color: Color):
	color_map_0[z*dimensions.x + x] = color
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)


func draw_color_1(x: int, z: int, color: Color):
	color_map_1[z*dimensions.x + x] = color
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)


func draw_wall_color_0(x: int, z: int, color: Color):
	wall_color_map_0[z*dimensions.x + x] = color
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)


func draw_wall_color_1(x: int, z: int, color: Color):
	wall_color_map_1[z*dimensions.x + x] = color
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)


func draw_grass_mask(x: int, z: int, masked: Color):
	grass_mask_map[z*dimensions.x + x] = masked
	mark_dirty()
	notify_needs_update(z, x)
	notify_needs_update(z, x-1)
	notify_needs_update(z-1, x)
	notify_needs_update(z-1, x-1)

#endregion

func notify_needs_update(z: int, x: int):
	# 检查坐标是否在有效范围内，如果是则标记该单元格需要更新。
	if z < 0 or z >= terrain_system.dimensions.z-1 or x < 0 or x >= terrain_system.dimensions.x-1:
		return
	
	needs_update[z][x] = true


## Mark chunk as having modified source data - triggers save in MSTDataHandler.
## 中文：将区块标记为源数据已修改——触发 MSTDataHandler 中的保存。
func mark_dirty() -> void:
	_data_dirty = true


## Recreate collision body after scene save (deferred call for proper physics refresh).
## 中文：场景保存后重新创建碰撞体（延迟调用以正确刷新物理）。
func _recreate_collision_body() -> void:
	if not is_inside_tree() or _temp_collision_shapes.is_empty():
		_temp_collision_shapes.clear()
		return
		
	# 清理现有碰撞体。
	for child in get_children():
		if child is StaticBody3D:
			child.free()
	
	# Only create ONE body with the FIRST shape
	# 中文：只使用第一个形状创建一个碰撞体。
	var shape : ConcavePolygonShape3D = _temp_collision_shapes[0]
	_temp_collision_shapes.clear()
	
	var body := StaticBody3D.new()
	body.name = name + "_col"
	body.collision_layer = 17
	if terrain_system:
		body.set_collision_layer_value(terrain_system.extra_collision_layer, true)
	
	var col_shape := CollisionShape3D.new()
	col_shape.name = "CollisionShape3D"
	col_shape.shape = shape
	col_shape.visible = false
	body.add_child(col_shape)
	add_child(body)
	
	# Set owner for editor visibility at first, but we clear it later
	# 中文：先设置 owner 以便在编辑器中可见，但稍后会清除。
	if EngineWrapper.instance.is_editor():
		var scene_root = EngineWrapper.instance.get_root_for_node(self)
		if scene_root:
			body.owner = scene_root
			col_shape.owner = scene_root
		for group in get_groups():
			if group.begins_with("navmesh_"):
				body.add_to_group(group)


func regenerate_all_cells(use_threads: bool):
	# 将所有单元格标记为需要更新，然后重新生成网格。
	for z in range(dimensions.z-1):
		for x in range(dimensions.x-1):
			needs_update[z][x] = true
	
	regenerate_mesh(use_threads)


@export_tool_button("Export GLB") var bake = func():
	# 导出 GLB 的工具按钮回调。
	var tree := get_tree()
	
	var baker = MarchingSquaresGeometryBaker.new()
	baker.polygon_texture_resolution = terrain_system.polygon_texture_resolution
	
	var f := func(bakedMesh: Mesh, original: MeshInstance3D, bakedTexture: Image):
		# 创建文件保存对话框。
		var dialog := FileDialog.new()
		get_tree().root.add_child(dialog)
		dialog.file_mode = FileDialog.FILE_MODE_SAVE_FILE
		dialog.access = FileDialog.ACCESS_FILESYSTEM
		
		# 创建临时 MeshInstance3D 用于导出。
		var inst := MeshInstance3D.new()
		inst.mesh = bakedMesh
		var mat := StandardMaterial3D.new()
		mat.albedo_texture = ImageTexture.create_from_image(bakedTexture)
		inst.mesh.surface_set_material(0, mat)
		var file_selected := func(path: String):
			# 用户选择路径后，使用 GLTFDocument 导出。
			var state := GLTFState.new()
			var doc := GLTFDocument.new()
			doc.append_from_scene(inst, state)
			doc.write_to_filesystem(state, path)
			dialog.queue_free()
		dialog.add_filter("*.glb", "GLB file")
		dialog.connect("file_selected", file_selected)
		dialog.popup_centered()
	
	baker.finished.connect(f, CONNECT_ONE_SHOT)
	baker.bake_geometry_texture(self, tree)
