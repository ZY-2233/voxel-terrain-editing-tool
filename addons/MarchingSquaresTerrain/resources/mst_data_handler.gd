# ============================================================================
# MSTDataHandler
# ----------------------------------------------------------------------------
# 地形外部数据存储的核心处理器。
# 负责生成数据目录、保存/加载区块数据、迁移内嵌数据、清理孤儿目录、
# 以及纹理索引与顶点颜色之间的编解码转换。
#
# 注意：
# 本文件只是在原始源码基础上添加注释，未修改任何代码逻辑、变量名、
# 缩进结构、导出属性或函数行为。
# ============================================================================

@tool
class_name MSTDataHandler
extends RefCounted
## Central handler for all external terrain data storage operations.
## 中文：所有地形外部数据存储操作的中央处理器。


# 预加载区块数据资源类，用于序列化/反序列化单个区块的数据。
const ChunkData = preload("res://addons/MarchingSquaresTerrain/resources/mst_chunk_data.gd")

## Generate a unique terrain ID (called once on first save).
## 中文：生成唯一的地形 ID（首次保存时调用一次）。
static func generate_terrain_uid() -> String:
	# 用随机数异或当前 Unix 时间戳，格式化为 8 位十六进制字符串。
	return "%08x" % (randi() ^ int(Time.get_unix_time_from_system()))

#region directory management
# 中文：目录管理区域。

## Ensure directory exists, create one if needed.
## 中文：确保目录存在，必要时创建它。
static func ensure_directory_exists(path: String) -> bool:
	# 如果目录已存在，直接返回成功。
	if DirAccess.dir_exists_absolute(path):
		return true
	
	# 递归创建目录。
	var err := DirAccess.make_dir_recursive_absolute(path)
	if err != OK:
		printerr("MSTDataHandler: Failed to create directory: ", path, " Error: ", err)
		return false
	
	return true


## Get the resolved data directory path for the terrain node.
## Path format: [SceneDir]/[SceneName]_TerrainData/[NodeName]_[data_UID]/
## 中文：获取地形节点的实际数据目录路径。
## 路径格式：[场景目录]/[场景名]_TerrainData/[节点名]_[数据UID]/
static func generate_data_directory(terrain: MarchingSquaresTerrain) -> String:
	# generate default path based on scene location with unique data_UID
	# 中文：基于场景位置和唯一 data_UID 生成默认路径。
	var tree := terrain.get_tree()
	if not tree:
		return ""  # Node not in scene tree yet
		# 中文：节点尚未加入场景树。
	var inst := EngineWrapper.instance
	var scene_root := inst.get_root_for_node(terrain)
	if not scene_root or scene_root.scene_file_path.is_empty():
		return ""
	
	# 解析场景路径，提取目录和场景名。
	var scene_path := scene_root.scene_file_path
	var scene_dir := scene_path.get_base_dir()
	var scene_name := scene_path.get_file().get_basename()
	# Include data_UID in path to prevent collisions when nodes are recreated with same name
	# 中文：路径中带上 data_UID，防止节点被同名重建时产生冲突。
	return scene_dir.path_join(scene_name + "_TerrainData").path_join(terrain.name + "_" + generate_terrain_uid())


# 递归复制目录内容。
static func copy_recursive(from_path: String, to_path: String) -> void:
	var dir := DirAccess.open(from_path)
	if dir == null:
		push_error("Cannot open source directory: " + from_path)
		return
	
	# 确保目标目录存在。
	DirAccess.make_dir_recursive_absolute(to_path)
	
	dir.list_dir_begin()
	var file_name = dir.get_next()
	
	# 遍历源目录中的所有条目。
	while file_name != "":
		if file_name == "." or file_name == "..":
			file_name = dir.get_next()
			continue
		
		# 构造源路径和目标路径。
		var src = from_path.path_join(file_name)
		var dst = to_path.path_join(file_name)
		
		# 目录递归复制，文件直接复制。
		if dir.current_is_dir():
			copy_recursive(src, dst)
		else:
			var err = DirAccess.copy_absolute(src, dst)
			if err != OK:
				push_error("Failed to copy file: %s -> %s" % [src, dst])
		file_name = dir.get_next()
	dir.list_dir_end()


## Check if a terrains data directory is unique
## 中文：检查某个地形的数据目录是否唯一（即没有其他地形共用同一目录）。
static func is_data_directory_unique(terrain: MarchingSquaresTerrain) -> bool:
	# 仅在编辑器且已入树时才需要检查。
	if not (EngineWrapper.instance.is_editor() and terrain.is_inside_tree()):
		return true
	var scene_root := EngineWrapper.instance.get_root_for_node(terrain)
	# 收集场景中所有地形使用数据目录的情况。
	var dirs := _collect_terrain_dirs_recursive(scene_root)

	# 简化路径后进行比较。
	var simplified_path := terrain.data_directory.simplify_path()
	if not dirs.has(simplified_path):
		return true
	match dirs[simplified_path].size():
		0: return true
		# 只有一个地形使用该目录，且就是当前地形，视为唯一。
		1: return dirs[simplified_path][0] == terrain
		# 多个地形共用同一目录，不唯一。
		_: return false


## Check if metadata.res exists for a chunk.
## 中文：检查某个区块的 metadata.res 文件是否存在。
static func metadata_exists(dir_path: String, coords: Vector2i) -> bool:
	if dir_path.is_empty():
		return false
	# 区块目录名格式为 chunk_X_Y。
	var chunk_dir := dir_path.path_join("chunk_%d_%d" % [coords.x, coords.y])
	return FileAccess.file_exists(chunk_dir.path_join("metadata.res"))

#endregion

#region save operations
# 中文：保存操作区域。

## Save all dirty chunks to external .res files.
## Called from terrain._notification(NOTIFICATION_EDITOR_PRE_SAVE).
## 中文：将所有脏区块保存到外部 .res 文件。
## 由 terrain._notification(NOTIFICATION_EDITOR_PRE_SAVE) 调用。
static func save_all_chunks(terrain: MarchingSquaresTerrain) -> void:
	
	var dir_path := terrain.data_directory
	if dir_path.is_empty():
		# No valid data directory - scene might not be saved yet
		# 中文：没有有效的数据目录——场景可能尚未保存。
		return
	
	# Ensure directory exists
	# 中文：确保目录存在。
	if not ensure_directory_exists(dir_path):
		printerr("MSTDataHandler: Failed to create data directory: ", dir_path)
		return
	
	# Calculate initial size
	# 中文：计算保存前目录总大小，用于后续报告变化。
	var initial_size : int = MarchingSquaresFileUtils.get_directory_size_recursive(dir_path)
	
	var saved_count := 0
	# 遍历地形所有区块。
	for chunk_coords in terrain.chunks:
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[chunk_coords]
		
		# Skip chunks being removed during undo/redo
		# 中文：跳过在撤销/重做期间被移除的区块。
		if chunk._skip_save_on_exit:
			continue
		
		# Determine if chunk needs saving:
		# 中文：判断区块是否需要保存：
		var needs_save : bool = chunk._data_dirty
		# 如果没标记为脏，但外部文件不存在，也需要保存。
		if not needs_save and not metadata_exists(dir_path, chunk_coords):
			needs_save = true
		
		if needs_save:
			save_chunk_resources(terrain, chunk)
			chunk._data_dirty = false
			saved_count += 1
	
	# 如果有任何区块被保存，则报告大小变化，并更新上次存储模式。
	if saved_count > 0:
		_report_storage_size_change(terrain, dir_path, initial_size, saved_count)
		terrain._last_storage_mode = terrain.storage_mode
	
	# Clean up orphaned chunk directories that no longer exist in scene
	# 中文：清理场景中已不存在的孤儿区块目录。
	cleanup_orphaned_chunk_files(terrain)
	
	# Clean up orphaned terrain directories (terrains that no longer exist in scene)
	# 中文：清理场景中已不存在的孤儿地形目录。
	cleanup_orphaned_terrain_directories(terrain)
	
	# 标记存储已初始化。
	terrain._storage_initialized = true


## Save chunk data to external file.
## 中文：将区块数据保存到外部文件。
static func save_chunk_resources(terrain: MarchingSquaresTerrain, chunk: MarchingSquaresTerrainChunk) -> void:
	var dir_path := terrain.data_directory
	if dir_path.is_empty():
		printerr("MSTDataHandler: Cannot save chunk - no valid data directory")
		return
	
	# 构建该区块的目录名与路径。
	var chunk_name := "chunk_%d_%d" % [chunk.chunk_coords.x, chunk.chunk_coords.y]
	var chunk_dir := dir_path.path_join(chunk_name)
	ensure_directory_exists(chunk_dir)
	
	# Export chunk data 
	# 中文：导出区块数据。
	var data : MSTChunkData = export_chunk_data(chunk)
	
	# Clear ephemeral data based on mode and config
	# 中文：根据存储模式和配置，清空临时/大体积数据。
	var is_baked_mode : bool = terrain.storage_mode == MarchingSquaresTerrain.StorageMode.BAKED
	
	# 非 BAKED 模式不保存网格（运行时重新生成）。
	if not is_baked_mode:
		data.mesh = null
	
	# 非 BAKED 模式或未开启烘焙草地时，不保存草地 MultiMesh。
	if not is_baked_mode or not terrain.bake_grass:
		data.grass_multimesh = null
	
	# 非 BAKED 模式或未开启烘焙碰撞时，不保存碰撞面。
	if not is_baked_mode or not terrain.bake_collision:
		data.collision_faces = PackedVector3Array()
	
	# 保存元数据资源文件（压缩）。
	var metadata_path := chunk_dir.path_join("metadata.res")
	var err := ResourceSaver.save(data, metadata_path, ResourceSaver.FLAG_COMPRESS)
	if err != OK:
		printerr("MSTDataHandler: Failed to save metadata to ", metadata_path)
	
	print_verbose("MSTDataHandler: Saved chunk ", chunk.chunk_coords)

#endregion

#region load operations
# 中文：加载操作区域。

## Load all terrain data from external files.
## 中文：从外部文件加载所有地形数据。
static func load_terrain_data(terrain: MarchingSquaresTerrain) -> void:
	var dir_path := terrain.data_directory
	print_verbose("MSTDataHandler: load_terrain_data")
	if dir_path.is_empty():
		return
	
	# Scan for chunk directories (format: chunk_X_Y/)
	# 中文：扫描目录，查找形如 chunk_X_Y 的区块子目录。
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	
	var chunk_dirs : Array[Vector2i] = []
	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and folder_name.begins_with("chunk_"):
			# Parse chunk coordinates from folder name: chunk_X_Y
			# 中文：从目录名 chunk_X_Y 中解析出区块坐标。
			var parts := folder_name.trim_prefix("chunk_").split("_")
			if parts.size() == 2:
				var coords := Vector2i(int(parts[0]), int(parts[1]))
				chunk_dirs.append(coords)
		folder_name = dir.get_next()
	dir.list_dir_end()
	
	# 若没有任何区块目录，直接返回。
	if chunk_dirs.is_empty():
		return
	
	print_verbose("MSTDataHandler: Loading ", chunk_dirs.size(), " chunk(s) from ", dir_path)
	
	# 逐个加载区块。
	for coords in chunk_dirs:
		load_chunk_from_directory(terrain, coords)


## Load a single chunk's source data from metadata file.
## 中文：从元数据文件加载单个区块的源数据。
static func load_chunk_from_directory(terrain: MarchingSquaresTerrain, coords: Vector2i) -> void:
	var dir_path := terrain.data_directory
	var chunk_name := "chunk_%d_%d" % [coords.x, coords.y]
	var chunk_dir := dir_path.path_join(chunk_name)
	
	# Mesh, collision, and grass are regenerated separately by the chunk
	# 中文：网格、碰撞和草由区块单独重新生成。
	var chunk : MarchingSquaresTerrainChunk = terrain.chunks.get(coords)
	if not chunk:
		return
	
	# Load metadata source data
	# 中文：加载元数据源数据。
	var metadata_path := chunk_dir.path_join("metadata.res")
	if ResourceLoader.exists(metadata_path):
		var data : MSTChunkData = load(metadata_path)
		if data:
			import_chunk_data(chunk, data)
	
	print_verbose("MSTDataHandler: Loaded chunk ", coords)

#endregion

#region data export 
# 中文：数据导出区域。

## Export chunk state to MSTChunkData for external storage.
## Converts color maps to compact byte arrays.
## 中文：将区块状态导出为 MSTChunkData，以便外部存储。
## 将颜色图转换为紧凑的字节数组。
static func export_chunk_data(chunk: MarchingSquaresTerrainChunk) -> MSTChunkData:
	var data := MSTChunkData.new()
	data.chunk_coords = chunk.chunk_coords
	data.merge_mode = chunk.merge_mode
	
	# Source data
	# 中文：源数据（高度图深拷贝）。
	data.height_map = chunk.height_map.duplicate(true)
	
	# Convert to new data model
	# 中文：转换为新的数据模型（紧凑数组）。
	var cell_count : int = chunk.color_map_0.size()
	data.ground_texture_idx.resize(cell_count)
	data.wall_texture_idx.resize(cell_count)
	data.grass_mask.resize(cell_count)
	
	# 将每个单元格的颜色对编码为纹理索引，并保存草地遮罩。
	for i in cell_count:
		data.ground_texture_idx[i] = _colors_to_texture_idx(chunk.color_map_0[i], chunk.color_map_1[i])
		data.wall_texture_idx[i] = _colors_to_texture_idx(chunk.wall_color_map_0[i], chunk.wall_color_map_1[i])
		data.grass_mask[i] = 1 if chunk.grass_mask_map[i].r > 0.5 else 0
	
	# Ephemeral data for BAKED mode
	# 中文：BAKED 模式下的临时数据（网格）。
	data.mesh = chunk.mesh
	
	# 若开启烘焙草地且有草地规划器，则保存 MultiMesh。
	if chunk.terrain_system.bake_grass and chunk.grass_planter:
		data.grass_multimesh = chunk.grass_planter.multimesh
	
	# 若开启烘焙碰撞，则找到碰撞形状并保存。
	if chunk.terrain_system.bake_collision:
		# Find collision shape
		# 中文：查找碰撞形状。
		for child in chunk.get_children():
			if child is StaticBody3D:
				for shape_child in child.get_children():
					if shape_child is CollisionShape3D and shape_child.shape is ConcavePolygonShape3D:
						data.set_collision_from_shape(shape_child.shape)
						break
	
	# Clear legacy arrays 
	# 中文：清空旧版颜色数组（已用紧凑索引替代）。
	data.color_map_0 = PackedColorArray()
	data.color_map_1 = PackedColorArray()
	data.wall_color_map_0 = PackedColorArray()
	data.wall_color_map_1 = PackedColorArray()
	data.grass_mask_map = PackedColorArray()
	
	return data

#endregion

#region data import 
# 中文：数据导入区域。

## Restore chunk state from MSTChunkData (loaded from external file).
## Expands compact byte arrays back to color arrays for runtime use.
## 中文：从 MSTChunkData（外部文件加载）恢复区块状态。
## 将紧凑字节数组展开为运行时使用的颜色数组。
static func import_chunk_data(chunk: MarchingSquaresTerrainChunk, data: MSTChunkData) -> void:
	if not data:
		printerr("MSTDataHandler: import_chunk_data called with null data")
		return
	
	# 恢复基本数据。
	chunk.chunk_coords = data.chunk_coords
	chunk.merge_mode = data.merge_mode as MarchingSquaresTerrainChunk.Mode
	chunk.height_map = data.height_map.duplicate(true)
	
	# Restore baked assets if present
	# 中文：如果数据中带烘焙资产，则恢复。
	if data.mesh:
		chunk.mesh = data.mesh
	elif chunk.terrain_system.storage_mode == MarchingSquaresTerrain.StorageMode.BAKED:
		# BAKED 模式下却没有网格数据，发出警告。
		push_warning("Baking enabled, but terrain-resource does not contain mesh data")
		
	# 开启烘焙草地但数据里没有草地 MultiMesh，发出警告。
	if chunk.terrain_system.bake_grass and not data.grass_multimesh:
		push_warning("Grass baking enabled, but terrain-resource does not contain grass data")
	
	# 开启烘焙碰撞但数据里没有碰撞面，发出警告。
	if chunk.terrain_system.bake_collision and data.collision_faces.is_empty():
		push_warning("Collision baking enabled, but terrain-resource does not contain collision data")
	
	# 将恢复的草地 MultiMesh 暂存到临时变量，稍后由区块应用。
	if data.grass_multimesh:
		chunk._temp_grass_multimesh = data.grass_multimesh
	
	# 将恢复的碰撞形状暂存到临时变量。
	if not data.collision_faces.is_empty():
		chunk._temp_collision_shapes = [data.get_collision_shape()]
	
	# Check format version
	# 中文：检查数据格式版本。
	var is_v2 : bool = data.is_v2_format()
	
	if is_v2:
		# if we use the new forma, we expand the compact arrays
		# 中文：如果使用新版格式，则展开紧凑索引数组为颜色数组。
		var cell_count : int = data.ground_texture_idx.size()
		chunk.color_map_0.resize(cell_count)
		chunk.color_map_1.resize(cell_count)
		chunk.wall_color_map_0.resize(cell_count)
		chunk.wall_color_map_1.resize(cell_count)
		chunk.grass_mask_map.resize(cell_count)
	
		# 逐个单元格展开。
		for i in cell_count:
			var ground_colors : Array = _texture_idx_to_colors(data.ground_texture_idx[i])
			chunk.color_map_0[i] = ground_colors[0]
			chunk.color_map_1[i] = ground_colors[1]
			
			var wall_colors : Array = _texture_idx_to_colors(data.wall_texture_idx[i])
			chunk.wall_color_map_0[i] = wall_colors[0]
			chunk.wall_color_map_1[i] = wall_colors[1]
			
			# 草地遮罩：1 表示有草（红色通道为 1），0 表示无草。
			chunk.grass_mask_map[i] = Color(1, 0, 0, 0) if data.grass_mask[i] > 0 else Color(0, 0, 0, 0)
	else:
		# V1. or v1.1 legacy format: direct copy
		# 中文：V1 或 V1.1 旧格式：直接拷贝。
		chunk.color_map_0 = data.color_map_0.duplicate()
		chunk.color_map_1 = data.color_map_1.duplicate()
		chunk.wall_color_map_0 = data.wall_color_map_0.duplicate()
		chunk.wall_color_map_1 = data.wall_color_map_1.duplicate()
		chunk.grass_mask_map = data.grass_mask_map.duplicate()
		# Mark dirty to force re-save 
		# 中文：标记为脏，强制重新保存为新格式。
		chunk._data_dirty = true

#endregion

#region migration
# 中文：数据迁移区域。

## Check if this terrain needs migration from embedded to external storage.
## 中文：检查该地形是否需要从内嵌数据迁移到外部存储。
static func needs_migration(terrain: MarchingSquaresTerrain) -> bool:
	# If already initialized with external storage, no migration needed
	# 中文：如果已用外部存储初始化，则无需迁移。
	if terrain._storage_initialized:
		return false
	
	# Check if any chunks have embedded data but no external files exist
	# 中文：检查是否有区块带有内嵌数据但外部文件不存在。
	var dir_path := terrain.data_directory
	if dir_path.is_empty():
		return false
	
	for chunk_coords in terrain.chunks:
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[chunk_coords]
		# Check if chunk has embedded data (height_map populated)
		# 中文：检查区块是否有内嵌数据（height_map 非空）。
		if chunk.height_map and not chunk.height_map.is_empty():
			if not metadata_exists(dir_path, chunk_coords):
				return true
	
	return false


## Migrate existing embedded data to external storage.
## Marks all chunks as dirty and triggers save.
## 中文：将已有的内嵌数据迁移到外部存储。
## 将所有区块标记为脏并触发保存。
static func migrate_to_external_storage(terrain: MarchingSquaresTerrain) -> void:
	print("MSTDataHandler: Migrating to external storage...")
	
	# Mark all chunks as dirty to force save
	# 中文：将所有区块标记为脏，强制保存。
	for chunk_coords in terrain.chunks:
		var chunk : MarchingSquaresTerrainChunk = terrain.chunks[chunk_coords]
		chunk._data_dirty = true
	
	# 执行保存。
	save_all_chunks(terrain)
	
	print("MSTDataHandler: Migration complete. External data saved to: ", terrain.data_directory)

#endregion

#region cleanup
# 中文：清理区域。

## Clean up orphaned chunk directories that no longer exist in the scene.
## 中文：清理场景中已不存在的孤儿区块目录。
static func cleanup_orphaned_chunk_files(terrain: MarchingSquaresTerrain) -> void:
	var dir_path := terrain.data_directory
	if dir_path.is_empty():
		return
	
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	
	var orphaned_dirs : Array[String] = []
	
	# 遍历地形数据目录，查找不再属于场景的区块目录。
	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir() and folder_name.begins_with("chunk_"):
			# Parse chunk coordinates from folder name: chunk_X_Y
			# 中文：从目录名解析出区块坐标。
			var parts := folder_name.trim_prefix("chunk_").split("_")
			if parts.size() == 2:
				var coords := Vector2i(int(parts[0]), int(parts[1]))
				# If chunk doesn't exist in scene, mark for deletion
				# 中文：若场景中不存在该区块，则标记为待删除。
				if not terrain.chunks.has(coords):
					orphaned_dirs.append(dir_path.path_join(folder_name))
		folder_name = dir.get_next()
	dir.list_dir_end()
	
	# Delete orphaned directories
	# 中文：删除孤儿目录。
	for orphaned_dir in orphaned_dirs:
		_delete_chunk_directory(orphaned_dir)
		print_verbose("MSTDataHandler: Cleaned up orphaned chunk at ", orphaned_dir)


## Delete a chunk directory and all its contents.
## 中文：删除区块目录及其所有内容。
static func _delete_chunk_directory(chunk_dir: String) -> void:
	var dir := DirAccess.open(chunk_dir)
	if not dir:
		return
	
	# Delete all files in directory
	# 中文：删除目录内所有文件。
	dir.list_dir_begin()
	var file_name := dir.get_next()
	var err : Error
	while file_name != "":
		if not dir.current_is_dir():
			err = dir.remove(file_name)
			if err != OK:
				printerr("MSTDataHandler: Failed to delete file ", file_name, " in ", chunk_dir)
		file_name = dir.get_next()
	dir.list_dir_end()
	
	# Remove the directory itself
	# 中文：删除目录本身。
	err = DirAccess.remove_absolute(chunk_dir.trim_suffix("/"))
	if err != OK:
		printerr("MSTDataHandler: Failed to delete directory ", chunk_dir)

#endregion

#region color conversion helpers
# 中文：颜色转换辅助函数区域。

## Convert Color pair to texture index (0-15).
## Uses the 4×4 vertex color channel encoding system.
## 中文：将颜色对转换为纹理索引（0-15）。
## 使用 4×4 顶点颜色通道编码系统。
static func _colors_to_texture_idx(c0: Color, c1: Color) -> int:
	# 找出 c0 中分量最大的通道（0=R, 1=G, 2=B, 3=A）。
	var c0_idx := 0
	var c0_max := c0.r
	if c0.g > c0_max: c0_max = c0.g; c0_idx = 1
	if c0.b > c0_max: c0_max = c0.b; c0_idx = 2
	if c0.a > c0_max: c0_idx = 3
	
	# 找出 c1 中分量最大的通道。
	var c1_idx := 0
	var c1_max := c1.r
	if c1.g > c1_max: c1_max = c1.g; c1_idx = 1
	if c1.b > c1_max: c1_max = c1.b; c1_idx = 2
	if c1.a > c1_max: c1_idx = 3
	
	# 4×4 编码：c0 通道号 * 4 + c1 通道号，范围 0-15。
	return c0_idx * 4 + c1_idx


## Convert texture index (0-15) to Color pair.
## Reverses the encoding: index / 4 = c0 channel, index % 4 = c1 channel.
## 中文：将纹理索引（0-15）转换为颜色对。
## 逆向编码：索引 / 4 = c0 通道，索引 % 4 = c1 通道。
static func _texture_idx_to_colors(idx: int) -> Array:
	var c0 := Color(0, 0, 0, 0)
	var c1 := Color(0, 0, 0, 0)
	# 关闭整数除法警告（此处确实需要整数除法）。
	@warning_ignore_start("integer_division") 
	var c0_ch := idx / 4
	var c1_ch := idx % 4
	@warning_ignore_restore("integer_division")
	
	# 根据通道号设置 c0 对应通道为 1.0。
	match c0_ch:
		0: c0.r = 1.0
		1: c0.g = 1.0
		2: c0.b = 1.0
		3: c0.a = 1.0
	
	# 根据通道号设置 c1 对应通道为 1.0。
	match c1_ch:
		0: c1.r = 1.0
		1: c1.g = 1.0
		2: c1.b = 1.0
		3: c1.a = 1.0
	
	return [c0, c1]

#endregion

#region terrain directory cleanup
# 中文：地形目录清理区域。

## Clean up terrain data directories for terrains that no longer exist in the scene.
## Called during save to prevent disk bloat from deleted terrains.
## 中文：清理场景中已不存在的地形数据目录。
## 在保存时调用，防止已删除地形占用磁盘空间。
static func cleanup_orphaned_terrain_directories(terrain: MarchingSquaresTerrain) -> void:
	var tree := terrain.get_tree()
	if not tree:
		return
	
	var scene_root := EngineWrapper.instance.get_root_for_node(terrain)
	if not scene_root or scene_root.scene_file_path.is_empty():
		return
	
	# Get the TerrainData folder for this scene
	# 中文：获取当前场景对应的 TerrainData 目录。
	var scene_path := scene_root.scene_file_path
	var scene_dir := scene_path.get_base_dir()
	var scene_name := scene_path.get_file().get_basename()
	var terrain_data_dir := scene_dir.path_join(scene_name + "_TerrainData")
	
	# 若目录不存在，直接返回。
	if not DirAccess.dir_exists_absolute(terrain_data_dir):
		return
	
	# Collect all terrain data_UID currently in the scene
	# 中文：收集场景中所有仍在使用的数据目录。
	var active_dirs : Dictionary[String, Array] = _collect_terrain_dirs_recursive(scene_root)
	
	# Scan terrain data directory for orphaned folders
	# 中文：扫描 TerrainData 目录，查找孤儿子目录。
	var dir := DirAccess.open(terrain_data_dir)
	if not dir:
		return
	
	var orphaned_dirs : Array[String] = []
	dir.list_dir_begin()
	var folder_name := dir.get_next()
	while folder_name != "":
		if dir.current_is_dir():
			var res_name := terrain_data_dir.path_join(folder_name).simplify_path()
			# 若场景中无人使用该目录，则为孤儿。
			if not active_dirs.has(res_name):
				orphaned_dirs.append(res_name)
		folder_name = dir.get_next()
	dir.list_dir_end()
	
	# Delete orphaned directories
	# 中文：删除孤儿目录。
	for orphaned_dir in orphaned_dirs:
		_delete_directory_recursive(orphaned_dir)
		print("MSTDataHandler: Cleaned up orphaned terrain data at ", orphaned_dir)


## Recursively collect terrain data dirs from scene tree.
## 中文：递归收集场景树中所有地形的数据目录。
static func _collect_terrain_dirs_recursive(node: Node, dirs: Dictionary[String, Array] = {}) -> Dictionary[String, Array]:
	# 若当前节点是地形且数据目录非空，则记录。
	var terrain := node as MarchingSquaresTerrain
	if terrain and not terrain.data_directory.is_empty():
		var simplified_path := terrain.data_directory.simplify_path()
		if not dirs.has(simplified_path):
			dirs.set(simplified_path, [terrain])
		else:
			dirs[simplified_path].append(terrain)
	# 递归子节点。
	for child in node.get_children():
		_collect_terrain_dirs_recursive(child, dirs)
	return dirs


## Delete a directory and all its contents recursively.
## 中文：递归删除目录及其所有内容。
static func _delete_directory_recursive(dir_path: String) -> void:
	var dir := DirAccess.open(dir_path)
	if not dir:
		return
	
	dir.list_dir_begin()
	var item_name := dir.get_next()
	while item_name != "":
		# 目录递归删除，文件直接删除。
		if dir.current_is_dir():
			_delete_directory_recursive(dir_path.path_join(item_name))
		else:
			dir.remove(item_name)
		item_name = dir.get_next()
	dir.list_dir_end()
	
	# 删除空目录本身。
	DirAccess.remove_absolute(dir_path.trim_suffix("/"))


## Report the storage size change after a save operation.
## 中文：保存后报告存储大小的变化。
static func _report_storage_size_change(terrain: MarchingSquaresTerrain, dir_path: String, initial_size: int, saved_count: int) -> void:
	# 计算保存后的总大小。
	var final_size : int = MarchingSquaresFileUtils.get_directory_size_recursive(dir_path)
	var size_difference_bytes : int = final_size - initial_size
	var percentage_change : float = 0.0
	
	# 计算百分比变化。
	if initial_size > 0:
		percentage_change = (float(size_difference_bytes) / float(initial_size)) * 100.0
	elif size_difference_bytes > 0:
		percentage_change = 100.0
	
	# 正数显示 + 号。
	var sign_string := "+" if size_difference_bytes >= 0 else ""
	
	# 获取上次和本次存储模式的名称。
	var previous_storage_mode_name : String = MarchingSquaresTerrain.StorageMode.keys()[terrain._last_storage_mode]
	var current_storage_mode_name : String = MarchingSquaresTerrain.StorageMode.keys()[terrain.storage_mode]
	
	# 输出保存信息与大小变化。
	print("MSTDataHandler: Saved ", saved_count, " chunk(s) to ", dir_path)
	print("MSTDataHandler: Storage Size: %s (%s) -> %s (%s) (%s%.2f%%)" % [
		String.humanize_size(initial_size), 
		previous_storage_mode_name,
		String.humanize_size(final_size), 
		current_storage_mode_name,
		sign_string, 
		percentage_change
	])

#endregion
