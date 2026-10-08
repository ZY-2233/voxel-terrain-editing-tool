# ============================================================================
# MarchingSquaresTerrain
# ----------------------------------------------------------------------------
# 【总览】
# 该节点是整个 Marching Squares 地形系统的“大脑”。
# 它本身不直接生成三角形，而是负责：
#   1. 管理所有子区块（MarchingSquaresTerrainChunk）；
#   2. 持有所有纹理、颜色、缩放等全局配置，并把这些值写进着色器；
#   3. 协调外部存储（BAKED / RUNTIME 两种模式）；
#   4. 与编辑器插件（UI、Gizmo、工具属性面板）交互。
#
# 【数据流（简版）】
#   height_map / color_map → Chunk → Cell → SurfaceTool → ArrayMesh
#   上述数据也可以通过 MSTDataHandler 落到磁盘，或在编辑器打开时从磁盘恢复。
#
# 【关键设计点】
#   - 每个 Terrain 节点都会 duplicate 一份材质和草网格，
#     这样多个 Terrain 之间不会互相污染（尤其是编辑器里复制节点时）。
#   - 属性 setter 都尽量“即时生效”，避免用户改一个值必须重启编辑器。
#   - 为了让编辑器流畅，某些 setter 会在 is_batch_updating 时被跳过，
#     由 force_batch_update() 统一写一次。
#
# 注意：
# 本文件只是在原始源码基础上添加注释，未修改任何代码逻辑、变量名、
# 缩进结构、导出属性或函数行为。
# ============================================================================

@tool
extends Node3D
class_name MarchingSquaresTerrain


# 当 chunk dimensions 变化时发出。
# 编辑器插件里的 Gizmo、UI 会监听它，用于重画边框、刷新尺寸显示。
signal chunk_dimensions_changed (value : Vector3i)

# 地形数据存储模式。
# 这一设置会影响：
#   - 保存时是否把 mesh / grass / collision 也写进 .res 文件；
#   - 加载时是否需要重新生成几何。
enum StorageMode {
	## Saves load time. Loads a pre-built visual mesh from disk.
	## The collision mesh, grass etc. are generated when the scene loads.
	## (faster load, slightly larger files).
	## 中文：加载更快。磁盘直接读取已烘焙的网格。
	## 碰撞网格、草等在场景加载时再生成。
	## 加载快，但文件略大。
	BAKED,
	## Saves disk space. Generates everything from heightmaps when the scene loads.
	## This is overkill for most games.
	## (slower load, smallest files).
	## 中文：省磁盘。加载时从高度图等数据重新生成所有几何。
	## 对多数游戏来说可能没必要。
	## 加载慢，但文件最小。
	RUNTIME,
}

@export_category("Storage Options")
## The storage mode for terrain data. 
## 中文：地形数据的存储模式。
@export var storage_mode : StorageMode = StorageMode.BAKED:
	# setter 逻辑说明：
	#   1. 只有当新值与旧值不同才执行；
	#   2. 把所有区块标记成脏（chunk._data_dirty = true），
	#      这样下一次保存时它们会重新写到外部存储；
	#   3. notify_property_list_changed() 用于让 Inspector 重新
	#      检查 _validate_property 的结果，从而显示/隐藏 bake_grass、
	#      bake_collision 这两个只在 BAKED 模式下有意义的选项。
	set(value):
		if storage_mode != value:
			storage_mode = value
			# Mark all chunks dirty to force re-save of data/meshes
			# 中文：标记所有区块为脏，强制重新保存数据/网格。
			if chunks:
				for chunk in chunks.values():
					chunk.mark_dirty()
			print_verbose("[MST] Storage mode changed. All chunks marked for save.")
		notify_property_list_changed()

## If true, storage will include grass data, ignored if storage_mode = RUNTIME
## 中文：是否把草数据也烘焙进外部文件。RUNTIME 模式下无效。
@export var bake_grass : bool = true:
	# setter：开关一改，就认为所有区块的数据都过期，需要重新保存。
	# 因为“是否保存草”这个决策是在保存时执行的。
	set(value):
		bake_grass = value
		for chunk : MarchingSquaresTerrainChunk in chunks.values():
			chunk.mark_dirty()

## If true, storage will include collision data, ignored if storage_mode = RUNTIME
## 中文：是否把碰撞数据也烘焙进外部文件。RUNTIME 模式下无效。
@export var bake_collision : bool = true:
	# setter：同上，只是针对碰撞数据。
	set(value):
		bake_collision = value
		for chunk : MarchingSquaresTerrainChunk in chunks.values():
			chunk.mark_dirty()

## The folder where this terrain's data is saved. 
## If left empty, it automatically fills with a folder name relative to your scene file.
## Note: Manually setting a path locks the save location even if you rename the terrain node later.
## 中文：地形数据保存的目录。
##   为空 → 根据场景文件自动生成：[SceneDir]/[SceneName]_TerrainData/[NodeName]_[UID]/
##   非空 → 用户手动指定，之后即使改名也不会自动迁移。
@export_dir var data_directory : String = "":
	# getter 里做“惰性初始化”：
	#   编辑器里第一次读取该属性时，如果为空，就尝试根据场景路径自动填一个。
	# 注意：在运行时（导出后的游戏）不会自动生成，只会返回用户填的值。
	get():
		if EngineWrapper.instance.is_editor() and data_directory.is_empty():
			var auto_path := MSTDataHandler.generate_data_directory(self)
			if not auto_path.is_empty():
				data_directory = auto_path
		return data_directory

@export_category("Runtime Baking")
## If this option is true, the textures will be baked into a texture atlas
## at runtime. This will improve rendering performance, but increase cost of generation
## slightly.
## 中文：运行时是否把所有小纹理烘焙成一张图集纹理，减少 draw call。
## 会略微增加生成耗时。
@export var enable_runtime_texture_baking : bool = true

## The resolution used per polygon when baking the texture atlas. Increase this value
## when using high-res textures. Higher values increase the baking time and memory usage.
## 中文：每个多边形烘焙到图集时使用的像素分辨率。
## 使用高分辨率纹理时可调大，但代价是烘焙时间和内存。
@export var polygon_texture_resolution : int = 32

## Used for overriding the material of the baked terrain texture.
## 中文：如果设置，会覆盖默认的 bake_material。方便用户自定义烘焙结果的显示效果。
@export var bake_material_override : Material

## True after external storage has been initialized.
## Used to detect when migration from embedded data is needed.
## 中文：外部存储是否已经初始化过。
## 若为 false 但存在内嵌数据，则说明是旧场景，需要迁移（见 needs_migration）。
@export_storage var _storage_initialized : bool = false

## Tracks the mode used during the last successful save for reporting purposes.
## 中文：上一次成功保存时使用的模式，仅用于打印日志（对比大小变化）。
@export_storage var _last_storage_mode : StorageMode = StorageMode.BAKED

#region global terrain settings
# ----------------------------------------------------------------------------
# 全局地形设置
# 这些参数同时影响：
#   1. 每个 chunk 生成 cell 时的采样/合并逻辑；
#   2. 地形 shader 的 uniform；
#   3. 一些参数还会影响 grass shader。
# 因此很多 setter 会“双写”——既写 terrain_material，也写 grass_material。
# ----------------------------------------------------------------------------

# 地形尺寸：x、z 是高度图的采样点数（不是单元格数），y 是高度范围（缩放）。
# 例：Vector3i(33,32,33) → 32×32 个单元格，y 方向 ×32。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var dimensions : Vector3i = Vector3i(33, 32, 33):
	set(value):
		dimensions = value
		# 把 xyz 直接传给 shader 的 chunk_size（shader 会用到 x/z 做 UV，y 做高度缩放）。
		terrain_material.set_shader_parameter("chunk_size", value)
		# 编辑器里 notify 一下，让 Gizmo/UI 重画。
		if EngineWrapper.instance.is_editor():
			emit_signal("chunk_dimensions_changed", value)

# 每个单元格在 XZ 平面的实际世界尺寸（米）。
# 例：cell_size=(2,2) → 每个 cell 是 2×2 米。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var cell_size : Vector2 = Vector2(2.0, 2.0):
	set(value):
		cell_size = value
		terrain_material.set_shader_parameter("cell_size", value)
		# 触发 grass_size 的 setter，让草地网格按新的 cell 尺寸重新缩放。
		# 这是一种“隐式刷新”，因为 grass_size 的 setter 里才会更新 multimesh.mesh.size。
		grass_size = grass_size

# 纹理混合模式：0=软混合，1/2=硬混合（更锐利、像素风）。
@export_custom(PROPERTY_HINT_RANGE, "0, 2", PROPERTY_USAGE_STORAGE) var blend_mode : int = 0:
	set(value):
		blend_mode = value
		if value == 1 or value == 2:
			terrain_material.set_shader_parameter("use_hard_textures", true)
		else:
			terrain_material.set_shader_parameter("use_hard_textures", false)
		terrain_material.set_shader_parameter("blend_mode", value)
		# 因为混合模式会影响顶点颜色计算（在 cell 生成阶段完成），所以必须全量重生成。
		for chunk: MarchingSquaresTerrainChunk in chunks.values():
			chunk.regenerate_all_cells(true)

# 额外的碰撞层编号（默认 9）。
# 地形碰撞会同时属于 base layer 17 和这个额外层。
@export_custom(PROPERTY_HINT_RANGE, "9, 32", PROPERTY_USAGE_STORAGE) var extra_collision_layer : int = 9:
	set(value):
		extra_collision_layer = value
		# 碰撞层改了需要重建 collision body → 重新生成所有 cell。
		for chunk: MarchingSquaresTerrainChunk in chunks.values():
			chunk.regenerate_all_cells(true)

# 墙判定阈值。
# Cell 生成时会根据相邻角点的高度差判断“这里是不是墙”，
# 超过 wall_threshold 的部分会被标记为 wall 顶点。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var wall_threshold : float = 0.0:
	set(value):
		wall_threshold = value
		terrain_material.set_shader_parameter("wall_threshold", value)
		# 墙体阈值同时影响草地 shader，因为它决定草要不要长在“悬崖面”上。
		var grass_mat := grass_mesh.material as ShaderMaterial
		grass_mat.set_shader_parameter("wall_threshold", value)
		# 重新撒草（不重建 mesh）。
		for chunk: MarchingSquaresTerrainChunk in chunks.values():
			chunk.grass_planter.regenerate_all_cells()

# 山脊阈值。仅 shader 使用，不需要重新生成几何。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var ridge_threshold: float = 1.0:
	set(value):
		ridge_threshold = value
		terrain_material.set_shader_parameter("ridge_threshold", value)

# 岩架/台阶阈值。仅 shader 使用。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var ledge_threshold: float = 1.0:
	set(value):
		ledge_threshold = value
		terrain_material.set_shader_parameter("ledge_threshold", value)

# 是否在山脊处使用山脊纹理。仅 shader 使用。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var use_ridge_texture: bool = true:
	set(value):
		use_ridge_texture = value
		terrain_material.set_shader_parameter("use_ridge_texture", value)

# 是否在岩架处使用岩架纹理。仅 shader 使用。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var use_ledge_texture: bool = true:
	set(value):
		use_ledge_texture = value
		terrain_material.set_shader_parameter("use_ledge_texture", value)

# 初始高度噪声。为 null 则所有高度为 0（平地）。
# 注意：噪声采样以 chunk 为单位拼贴，采样坐标是全局的，
# 因此相邻 chunk 的边界高度是连续的（见 generate_height_map）。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var noise_hmap : Noise

# Grass settings
# --- 草地动画 FPS。只影响 grass shader。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var animation_fps : int = 0:
	set(value):
		animation_fps = clamp(value, 0, 30)
		var grass_mat := grass_mesh.material as ShaderMaterial
		grass_mat.set_shader_parameter("fps", clamp(value, 0, 30))

# 每个 cell 内的草地细分数。N×N 表示每个 cell 撒 N² 簇草。
# 修改会同时改变 MultiMesh 的 instance_count 和生成逻辑。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_subdivisions : int = 3:
	set(value):
		grass_subdivisions = value
		# 注意这里用的是 dimensions（不是 chunk 的 dimensions），
		# 因为地形系统约定所有 chunk 尺寸一致。
		for chunk: MarchingSquaresTerrainChunk in chunks.values():
			chunk.grass_planter.multimesh.instance_count = (dimensions.x-1) * (dimensions.z-1) * grass_subdivisions * grass_subdivisions
			chunk.grass_planter.regenerate_all_cells()

# 草地网格的缩放（相对 cell 尺寸）。
# 实际上会乘上 (cell_size.x + cell_size.y)/4 作为 scale_factor。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_size : Vector2 = Vector2(1.0, 1.0):
	set(value):
		grass_size = value
		var scale_factor := (cell_size.x + cell_size.y) / 4.0
		var scaled_value := value * scale_factor
		for chunk: MarchingSquaresTerrainChunk in chunks.values():
			# 草地用一个 QuadMesh，这里改 QuadMesh 的 size 和中心偏移。
			chunk.grass_planter.multimesh.mesh.size = scaled_value
			chunk.grass_planter.multimesh.mesh.center_offset.y = scaled_value.y / 2.0
#endregion

#region vertex painting texture settings
# ----------------------------------------------------------------------------
# 顶点绘制（Vertex Color Painting）纹理槽 1..15。
#
# 【编码系统说明】
#   每个顶点的颜色由两部分组成：color_0 和 color_1（都是 RGBA）。
#   每个 RGBA 里只有 1 个通道为 1.0，其余为 0.0，相当于一个 2bit 的索引。
#   所以一个顶点最多能表达 4×4=16 种纹理槽（0..15）。
#   0 号槽不用，所以实际纹理是 1..15 共 15 张。
#
# 【地形 Shader 参数命名】
#   vc_tex_XY，XY 表示 color_0 通道、color_1 通道：
#     r/g/b/a 分别代表 R/G/B/A 通道为 1
#     例如 vc_tex_rg 表示 color_0=R、color_1=G 的纹理
#   共有 4×4=16 个，但 rr 是基础纹理（槽 1），aa 保留给 void_texture。
# ----------------------------------------------------------------------------

# 基础纹理（color_0=R、color_1=R → 索引 0）。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_1 : Texture2D = preload("uid://dbnc04k3n0sro"):
	set(value):
		texture_1 = value
		# 如果处于批量更新，跳过；因为 force_batch_update 会统一写一遍。
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_rr", value)
			# 当该槽纹理为空时，草地 shader 会 fallback 到 base_color。
			# 例如 texture_1 为空 → use_base_color_1 = true（草用 color 而不是纹理）。
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_1:
				grass_mat.set_shader_parameter("use_base_color_1", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_1", true)
			# 草地颜色是从地形纹理采样的，纹理改了草色也变 → 重新撒草。
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 2：vc_tex_rg
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_2 : Texture2D = preload("uid://dbnc04k3n0sro"):
	set(value):
		texture_2 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_rg", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_2:
				grass_mat.set_shader_parameter("use_base_color_2", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_2", true)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 3：vc_tex_rb
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_3 : Texture2D = preload("uid://dbnc04k3n0sro"):
	set(value):
		texture_3 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_rb", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_3:
				grass_mat.set_shader_parameter("use_base_color_3", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_3", true)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 4：vc_tex_ra
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_4 : Texture2D = preload("uid://dbnc04k3n0sro"):
	set(value):
		texture_4 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ra", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_4:
				grass_mat.set_shader_parameter("use_base_color_4", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_4", true)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 5：vc_tex_gr
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_5 : Texture2D = preload("uid://dbnc04k3n0sro"):
	set(value):
		texture_5 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_gr", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_5:
				grass_mat.set_shader_parameter("use_base_color_5", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_5", true)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 6：vc_tex_gg
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_6 : Texture2D = preload("uid://cv87twjgbqq0s"):
	set(value):
		texture_6 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_gg", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			if texture_6:
				grass_mat.set_shader_parameter("use_base_color_6", false)
			else:
				grass_mat.set_shader_parameter("use_base_color_6", true)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

# 槽 7..15：这些槽没有“对应草地纹理”的开关，
# 因为没有对应的 grass_sprite_tex_7..15，只更新地形材质参数。
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_7 : Texture2D:
	set(value):
		texture_7 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_gb", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_8 : Texture2D:
	set(value):
		texture_8 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ga", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_9 : Texture2D:
	set(value):
		texture_9 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_br", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_10 : Texture2D:
	set(value):
		texture_10 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_bg", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_11 : Texture2D:
	set(value):
		texture_11 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_bb", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_12 : Texture2D:
	set(value):
		texture_12 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ba", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_13 : Texture2D:
	set(value):
		texture_13 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ar", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_14 : Texture2D:
	set(value):
		texture_14 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ag", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_15 : Texture2D:
	set(value):
		texture_15 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("vc_tex_ab", value)
			for chunk: MarchingSquaresTerrainChunk in chunks.values():
				chunk.grass_planter.regenerate_all_cells()
#endregion

#region grass textures
# 6 张草地精灵图，对应槽 1..6 的地形纹理（即“在草地槽 1..6 上撒哪种草”）。
# 切换地形纹理 → 草地纹理也会跟着换；草的颜色由地形纹理采样得来，不在这里配置。
# ----------------------------------------------------------------------------

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_1 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_1 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_1", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_2 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_2 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_2", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_3 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_3 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_3", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_4 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_4 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_4", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_5 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_5 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_5", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var grass_sprite_tex_6 : Texture2D = preload("uid://cxvnfgy865wsk"):
	set(value):
		grass_sprite_tex_6 = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_texture_6", value)
#endregion

#region has grass variables
# 槽 2..6 是否生成草地。槽 1（基础纹理）永远生成草，不需要开关。
# ----------------------------------------------------------------------------

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var tex2_has_grass : bool = true:
	set(value):
		tex2_has_grass = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("use_grass_tex_2", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var tex3_has_grass : bool = true:
	set(value):
		tex3_has_grass = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("use_grass_tex_3", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var tex4_has_grass : bool = true:
	set(value):
		tex4_has_grass = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("use_grass_tex_4", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var tex5_has_grass : bool = true:
	set(value):
		tex5_has_grass = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("use_grass_tex_5", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var tex6_has_grass : bool = true:
	set(value):
		tex6_has_grass = value
		if not is_batch_updating:
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("use_grass_tex_6", value)
#endregion

#region texture albedos
# 槽 1..6 的基础颜色（当纹理为空时，用这个颜色；或作为纹理的调制色）。
# 同时写 terrain_material（tex_albedo_N）和 grass_material（grass_color_N）。
# ----------------------------------------------------------------------------

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_1 : Color = Color("647851ff"):
	set(value):
		texture_albedo_1 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_1", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_1", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_2 : Color = Color("527b62ff"):
	set(value):
		texture_albedo_2 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_2", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_2", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_3 : Color = Color("5f6c4bff"):
	set(value):
		texture_albedo_3 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_3", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_3", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_4 : Color = Color("647941ff"):
	set(value):
		texture_albedo_4 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_4", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_4", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_5 : Color = Color("4a7e5dff"):
	set(value):
		texture_albedo_5 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_5", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_5", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_albedo_6 : Color = Color("71725dff"):
	set(value):
		texture_albedo_6 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_albedo_6", value)
			var grass_mat := grass_mesh.material as ShaderMaterial
			grass_mat.set_shader_parameter("grass_color_6", value)
#endregion

#region texture scales
# 每张纹理的 UV 缩放系数。仅 shader 使用，不影响几何生成。
# ----------------------------------------------------------------------------

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_1 : float = 1.0:
	set(value):
		texture_scale_1 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_1", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_2 : float = 1.0:
	set(value):
		texture_scale_2 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_2", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_3 : float = 1.0:
	set(value):
		texture_scale_3 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_3", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_4 : float = 1.0:
	set(value):
		texture_scale_4 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_4", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_5 : float = 1.0:
	set(value):
		texture_scale_5 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_5", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_6 : float = 1.0:
	set(value):
		texture_scale_6 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_6", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_7 : float = 1.0:
	set(value):
		texture_scale_7 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_7", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_8 : float = 1.0:
	set(value):
		texture_scale_8 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_8", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_9 : float = 1.0:
	set(value):
		texture_scale_9 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_9", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_10 : float = 1.0:
	set(value):
		texture_scale_10 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_10", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_11 : float = 1.0:
	set(value):
		texture_scale_11 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_11", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_12 : float = 1.0:
	set(value):
		texture_scale_12 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_12", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_13 : float = 1.0:
	set(value):
		texture_scale_13 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_13", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_14 : float = 1.0:
	set(value):
		texture_scale_14 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_14", value)

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var texture_scale_15 : float = 1.0:
	set(value):
		texture_scale_15 = value
		if not is_batch_updating:
			terrain_material.set_shader_parameter("tex_scale_15", value)
#endregion

# 当前使用的纹理预设资源。
@export_storage var current_texture_preset : MarchingSquaresTexturePreset = null

# 没有快速绘制激活时使用的默认墙体纹理槽（0..15）。
# 5 → UI 上的 Texture 6（1-indexed）。
@export_storage var default_wall_texture : int = 5

# 信号：地形数据全部加载并初始化完成。
signal load_finished

# 以下 3 个 texture 用于 shader 兜底，防止某些 uniform 未赋值导致 shader 报错。
var void_texture := preload("uid://csvthlqhb8g5j")
var placeholder_wind_texture := preload("uid://dk1t5hy2tiil7")
var placeholder_rl_noise_texture := preload("uid://85iqlmnoua0e")

# 地形 shader 材质（duplicate 自公共资源）。
var terrain_material : ShaderMaterial = null
# 草地 QuadMesh（也会 duplicate）。
var grass_mesh : QuadMesh = null 

# 批量更新标志。为 true 时，纹理/颜色/缩放的 setter 会跳过即时刷新。
# 用途：编辑器加载地形时一次设置几十个属性，若不跳过会非常慢。
var is_batch_updating : bool = false

# 区块字典：key 是 Vector2i chunk_coords，value 是 MarchingSquaresTerrainChunk。
var chunks : Dictionary = {}


# 属性验证：根据条件控制 Inspector 里属性的可见性。
# 这里只做一件事：非 BAKED 模式下，bake_grass / bake_collision 是无效设置，直接隐藏。
func _validate_property(property: Dictionary) -> void:
	if property.name in ["bake_grass", "bake_collision"]:
		if storage_mode != StorageMode.BAKED:
			property.usage = PROPERTY_USAGE_NO_EDITOR


# 构造时执行：把共享的 shader/mesh 资源复制一份，避免污染。
# 因为 shader 的 uniform 是“资源级”的，如果多个 Terrain 节点共用一个材质，
# 在一个节点上改 color 会影响其他节点，这是不能接受的。
func _init() -> void:
	terrain_material = preload("uid://bahbybbjwkhlg").duplicate(true)
	var base_grass_mesh := preload("uid://h41fuxldpf1u")
	grass_mesh = base_grass_mesh.duplicate(true)
	grass_mesh.material = base_grass_mesh.material.duplicate(true)
	print_verbose("Last storage mode: ", _last_storage_mode)


# 编辑器通知回调：在场景保存前，把脏区块写到外部存储。
# 这一步非常关键：如果不在 PRE_SAVE 里保存，那么下次打开场景时区块数据就丢了。
func _notification(what: int) -> void:
	if what == NOTIFICATION_EDITOR_PRE_SAVE:
		if EngineWrapper.instance.is_editor():
			MSTDataHandler.save_all_chunks(self)


# 进入场景树：延迟一帧做初始化。
# 原因：_enter_tree 时子节点还没 ready，也不是所有区块都已经进树，
# 直接处理 chunks 会漏掉一部分。
func _enter_tree() -> void:
	_deferred_enter_tree.call_deferred()


# 初始化数据目录。
# 情况分析：
#   A. 编辑器 + 目录非空 + 不唯一 → 说明目录被挪用了，我们得把数据复制到新目录，然后改用自己的新目录（避免冲突）。
#   B. 编辑器 + 目录为空 → 自动生成一个默认目录。
#   C. 其他情况 → 不做任何事。
func _initialize_data_directory() -> void:
	var copy_from_dir := ""
	if EngineWrapper.instance.is_editor() and not data_directory.is_empty() and not MSTDataHandler.is_data_directory_unique(self):
		copy_from_dir = data_directory
		data_directory = ""
	
	if EngineWrapper.instance.is_editor() and (data_directory.is_empty()):
		var auto_path := MSTDataHandler.generate_data_directory(self)
		if not auto_path.is_empty():
			data_directory = auto_path
	if copy_from_dir:
		MSTDataHandler.copy_recursive(copy_from_dir, data_directory)


# 核心初始化流程。
# 步骤：
#   1. 初始化数据目录；
#   2. 从子节点收集 chunk 引用；
#   3. 根据 _storage_initialized / needs_migration 决定加载还是迁移；
#   4. 让每个 chunk 从数据重建网格、草地、碰撞；
#   5. 把属性刷进 shader（因为属性在 _init 时还没读入，只有经过这一步 uniform 才会填上）；
#   6. 发出 load_finished 信号，让编辑器 / 游戏脚本可以开始后续操作。
func _deferred_enter_tree() -> void:
	_initialize_data_directory()
	
	print_verbose("Terrain data dir: ", data_directory)
	
	# 收集子节点中的 chunks。
	# 注意这里先遍历一遍看有没有 _data_dirty 的区块：
	# 如果有，说明用户刚刚在编辑器里改过但还没保存，此时不接管 chunks，
	# 直接 return（交给下一次启动场景时再加载）。
	for chunk in get_children():
		if chunk is MarchingSquaresTerrainChunk:
			if chunk._data_dirty:
				return
	chunks.clear()
	for chunk in get_children():
		if chunk is MarchingSquaresTerrainChunk:
			chunks[chunk.chunk_coords] = chunk
			chunk.terrain_system = self
			# 先清空 grass_planter 引用，等 chunk.initialize_terrain 里重新建。
			chunk.grass_planter = null
	
	# 加载或迁移外部数据。
	if _storage_initialized:
		MSTDataHandler.load_terrain_data(self)
	elif EngineWrapper.instance.is_editor() and MSTDataHandler.needs_migration(self):
		# 旧场景：数据还在 .tscn 里（内嵌），需要迁出来。
		MSTDataHandler.migrate_to_external_storage(self)
	
	# 初始化所有区块。
	for chunk : MarchingSquaresTerrainChunk in chunks.values():
		chunk.initialize_terrain(true)
		
	# 关键一步：把属性刷进 shader。
	# 因为 _init() 时 terrain_material 是公共资源的副本，不包含场景里保存的属性值。
	# 只有在这里执行 force_batch_update() 才能把场景序列化的属性真正写入 shader uniform。
	force_batch_update()
	# 触发 grass_size 的 setter，把尺寸重新同步到 multimesh.mesh。
	grass_size = grass_size
	
	load_finished.emit()


# 是否包含指定坐标的 chunk。
func has_chunk(x: int, z: int) -> bool:
	return chunks.has(Vector2i(x, z))


# 新建一个 chunk，并同步邻接边界高度。
# 该函数由编辑器插件调用（用户点“加一块”）。
# 之所以要同步邻接边界：以免相邻 chunk 之间的高度出现“台阶”。
func add_new_chunk(chunk_x: int, chunk_z: int, plugin):
	var chunk_coords := Vector2i(chunk_x, chunk_z)
	var new_chunk := MarchingSquaresTerrainChunk.new()
	new_chunk.name = "Chunk "+str(chunk_coords)
	new_chunk.terrain_system = self
	new_chunk.mark_dirty()
	add_chunk(chunk_coords, new_chunk, plugin, false)
	
	# 左邻居：左邻居的最右列 → 新 chunk 的最左列。
	var chunk_left : MarchingSquaresTerrainChunk = chunks.get(Vector2i(chunk_x-1, chunk_z))
	if chunk_left:
		for z in range(0, dimensions.z):
			new_chunk.height_map[z][0] = chunk_left.height_map[z][dimensions.x - 1]
	
	# 右邻居：原文这里疑似有笔误（应该改 chunk_right 的最左列，
	# 却改了自己的最右列）。但按“不修改原码”原则，此处只注明，不修。
	var chunk_right : MarchingSquaresTerrainChunk = chunks.get(Vector2i(chunk_x+1, chunk_z))
	if chunk_right:
		for z in range(0, dimensions.z):
			chunk_right.height_map[z][dimensions.x - 1] = chunk_right.height_map[z][0]
	
	# 上邻居：上邻居的最下排 → 新 chunk 的最上排。
	var chunk_up : MarchingSquaresTerrainChunk = chunks.get(Vector2i(chunk_x, chunk_z-1))
	if chunk_up:
		for x in range(0, dimensions.x):
			new_chunk.height_map[0][x] = chunk_up.height_map[dimensions.z - 1][x]
	
	# 下邻居：新 chunk 的最下排 → 下邻居的最上排。
	var chunk_down : MarchingSquaresTerrainChunk = chunks.get(Vector2i(chunk_x, chunk_z+1))
	if chunk_down:
		for x in range(0, dimensions.x):
			new_chunk.height_map[dimensions.z - 1][x] = chunk_down.height_map[0][x]
	
	# 使用新高度重新生成 mesh。
	new_chunk.regenerate_mesh()


# 删除 chunk（不可撤销）。
func remove_chunk(x: int, z: int, plugin):
	var chunk_coords := Vector2i(x, z)
	var chunk : MarchingSquaresTerrainChunk = chunks[chunk_coords]
	chunks.erase(chunk_coords)  # 注意用的是 chunk_coords，不是 chunk 对象本身
	chunk.free()
	
	# 如果被删的正是当前选中的 chunk，需要重新选一个。
	if plugin.selected_chunk and plugin.selected_chunk.chunk_coords == chunk.chunk_coords:
		var temp_chunk := MarchingSquaresTerrainChunk.new()
		temp_chunk.chunk_coords = Vector2i(99999, 99999)
		plugin.selected_chunk = temp_chunk
		for child in get_children():
			if child is MarchingSquaresTerrainChunk:
				plugin.selected_chunk = child
				break
	# 刷新编辑器 UI 与 Gizmo。
	plugin.ui.tool_attributes.show_tool_attributes(plugin.TerrainToolMode.CHUNK_MANAGEMENT)
	plugin.gizmo_plugin.trigger_redraw(self)


# 从场景树移除 chunk，但仍保留在内存中以便 undo 恢复。
# 关键区别：
#   - 不 free()，只 remove_child()；
#   - 设 _skip_save_on_exit = true，防止 undo 期间被当作“删除”而触发外部存储清理。
func remove_chunk_from_tree(x: int, z: int, plugin):
	var chunk_coords := Vector2i(x, z)
	var chunk : MarchingSquaresTerrainChunk = chunks[chunk_coords]
	chunks.erase(chunk_coords)
	chunk._skip_save_on_exit = true
	remove_child(chunk)
	chunk.owner = null
	
	if plugin.selected_chunk and plugin.selected_chunk.chunk_coords == chunk.chunk_coords:
		var temp_chunk := MarchingSquaresTerrainChunk.new()
		temp_chunk.chunk_coords = Vector2i(99999, 99999)
		plugin.selected_chunk = temp_chunk
		for child in get_children():
			if child is MarchingSquaresTerrainChunk:
				plugin.selected_chunk = child
				break
	plugin.ui.tool_attributes.show_tool_attributes(plugin.TerrainToolMode.CHUNK_MANAGEMENT)
	plugin.gizmo_plugin.trigger_redraw(self)


# 把一个已经存在的 chunk 挂到地形系统里（常见于 undo 恢复）。
func add_chunk(coords: Vector2i, chunk: MarchingSquaresTerrainChunk, plugin, regenerate_mesh: bool = true):
	chunk.terrain_system = self
	chunk.chunk_coords = coords
	chunk._skip_save_on_exit = false
	add_child(chunk)
	chunks[coords] = chunk
	
	# 位置用 position（局部坐标）而不是 global_position。
	# 原因：编辑器里可以同时打开多个场景标签，global_position 在未入树时会报错。
	# 由于 chunk 是 terrain 的直接子节点，position == global_position。
	chunk.position = Vector3(
		coords.x * ((dimensions.x - 1) * cell_size.x),
		0,
		coords.y * ((dimensions.z - 1) * cell_size.y)
	)
	
	EngineWrapper.instance.set_owner_recursive(chunk)
	chunk.initialize_terrain(regenerate_mesh)
	print_verbose("[MST] Added new chunk to terrain system at ", chunk)
	if plugin:
		if plugin.selected_chunk and plugin.selected_chunk.chunk_coords == Vector2i(99999, 99999):
			plugin.selected_chunk = chunk
		plugin.ui.tool_attributes.show_tool_attributes(plugin.TerrainToolMode.CHUNK_MANAGEMENT)
		plugin.gizmo_plugin.trigger_redraw(self)

#region texture (set) functions
# 内部工具函数。

# 【已废弃】_ensure_textures 曾用于插件在新项目里第一次启动时填充默认纹理。
# 现在由于 _init 里已经 duplicate + 默认 preload，加 force_batch_update，
# 这个函数不再被调用。
func _ensure_textures() -> void:
	var grass_mat := grass_mesh.material as ShaderMaterial
	if not grass_mat.get_shader_parameter("use_base_color_1") and terrain_material.get_shader_parameter("vc_tex_rr") == null:
		terrain_material.set_shader_parameter("vc_tex_rr", texture_1)
	if not grass_mat.get_shader_parameter("use_base_color_2") and terrain_material.get_shader_parameter("vc_tex_rg") == null:
		terrain_material.set_shader_parameter("vc_tex_rg", texture_2)
	if not grass_mat.get_shader_parameter("use_base_color_3") and terrain_material.get_shader_parameter("vc_tex_rb") == null:
		terrain_material.set_shader_parameter("vc_tex_rb", texture_3)
	if not grass_mat.get_shader_parameter("use_base_color_4") and terrain_material.get_shader_parameter("vc_tex_ra") == null:
		terrain_material.set_shader_parameter("vc_tex_ra", texture_4)
	if not grass_mat.get_shader_parameter("use_base_color_5") and terrain_material.get_shader_parameter("vc_tex_gr") == null:
		terrain_material.set_shader_parameter("vc_tex_gr", texture_5)
	if not grass_mat.get_shader_parameter("use_base_color_6") and terrain_material.get_shader_parameter("vc_tex_gg") == null:
		terrain_material.set_shader_parameter("vc_tex_gg", texture_6)
	
	if grass_mat.get_shader_parameter("use_grass_tex_2") and terrain_material.get_shader_parameter("vc_tex_rg") == null:
		terrain_material.set_shader_parameter("vc_tex_rg", texture_2)
	if grass_mat.get_shader_parameter("use_grass_tex_3") and terrain_material.get_shader_parameter("vc_tex_rb") == null:
		terrain_material.set_shader_parameter("vc_tex_rb", texture_3)
	if grass_mat.get_shader_parameter("use_grass_tex_4") and terrain_material.get_shader_parameter("vc_tex_ra") == null:
		terrain_material.set_shader_parameter("vc_tex_ra", texture_4)
	if grass_mat.get_shader_parameter("use_grass_tex_5") and terrain_material.get_shader_parameter("vc_tex_gr") == null:
		terrain_material.set_shader_parameter("vc_tex_gr", texture_5)
	if grass_mat.get_shader_parameter("use_grass_tex_6") and terrain_material.get_shader_parameter("vc_tex_gg") == null:
		terrain_material.set_shader_parameter("vc_tex_gg", texture_6)
	
	if grass_sprite_tex_1 and grass_mat.get_shader_parameter("grass_texture_1") == null:
		grass_mat.set_shader_parameter("grass_texture_1", grass_sprite_tex_1)
	if grass_sprite_tex_2 and grass_mat.get_shader_parameter("grass_texture_2") == null:
		grass_mat.set_shader_parameter("grass_texture_2", grass_sprite_tex_2)
	if grass_sprite_tex_3 and grass_mat.get_shader_parameter("grass_texture_3") == null:
		grass_mat.set_shader_parameter("grass_texture_3", grass_sprite_tex_3)
	if grass_sprite_tex_4 and grass_mat.get_shader_parameter("grass_texture_4") == null:
		grass_mat.set_shader_parameter("grass_texture_4", grass_sprite_tex_4)
	if grass_sprite_tex_5 and grass_mat.get_shader_parameter("grass_texture_5") == null:
		grass_mat.set_shader_parameter("grass_texture_5", grass_sprite_tex_5)
	if grass_sprite_tex_6 and grass_mat.get_shader_parameter("grass_texture_6") == null:
		grass_mat.set_shader_parameter("grass_texture_6", grass_sprite_tex_6)
	
	if terrain_material.get_shader_parameter("vc_tex_aa") == null:
		terrain_material.set_shader_parameter("vc_tex_aa", void_texture)
	
	if grass_mat.get_shader_parameter("wind_texture") == null:
		grass_mat.set_shader_parameter("wind_texture", placeholder_wind_texture)
	if terrain_material.get_shader_parameter("rl_noise_texture") == null:
		terrain_material.set_shader_parameter("rl_noise_texture", placeholder_rl_noise_texture)


## 批量刷新：把当前所有属性一次性写入地形和草地的 shader。
##
## 【为什么需要它】
## 属性的 setter 里有 `if not is_batch_updating:` 的判断。
## 也就是说，当 is_batch_updating = true 时，属性变化不会立即写 shader。
## 适用于：
##   - 编辑器加载时批量赋默认值；
##   - 用户点“应用预设”时一次性改一大堆纹理/颜色。
## 而 force_batch_update() 就负责把这些改动一次性生效。
##
## 注意：本函数只刷 shader uniform，不重建 mesh。若需要重建，需要另外调用
## chunk.regenerate_all_cells()。
func force_batch_update() -> void:
	var grass_mat := grass_mesh.material as ShaderMaterial
	
	# --- 地形材质：核心参数 ---
	terrain_material.set_shader_parameter("chunk_size", dimensions)
	terrain_material.set_shader_parameter("cell_size", cell_size)
	
	# --- 地形材质：15 张地面纹理 ---
	terrain_material.set_shader_parameter("vc_tex_rr", texture_1)
	terrain_material.set_shader_parameter("vc_tex_rg", texture_2)
	terrain_material.set_shader_parameter("vc_tex_rb", texture_3)
	terrain_material.set_shader_parameter("vc_tex_ra", texture_4)
	terrain_material.set_shader_parameter("vc_tex_gr", texture_5)
	terrain_material.set_shader_parameter("vc_tex_gg", texture_6)
	terrain_material.set_shader_parameter("vc_tex_gb", texture_7)
	terrain_material.set_shader_parameter("vc_tex_ga", texture_8)
	terrain_material.set_shader_parameter("vc_tex_br", texture_9)
	terrain_material.set_shader_parameter("vc_tex_bg", texture_10)
	terrain_material.set_shader_parameter("vc_tex_bb", texture_11)
	terrain_material.set_shader_parameter("vc_tex_ba", texture_12)
	terrain_material.set_shader_parameter("vc_tex_ar", texture_13)
	terrain_material.set_shader_parameter("vc_tex_ag", texture_14)
	terrain_material.set_shader_parameter("vc_tex_ab", texture_15)
	
	# --- 地形材质：6 个地面颜色（用于地板和墙体，统一系统）---
	terrain_material.set_shader_parameter("tex_albedo_1", texture_albedo_1)
	terrain_material.set_shader_parameter("tex_albedo_2", texture_albedo_2)
	terrain_material.set_shader_parameter("tex_albedo_3", texture_albedo_3)
	terrain_material.set_shader_parameter("tex_albedo_4", texture_albedo_4)
	terrain_material.set_shader_parameter("tex_albedo_5", texture_albedo_5)
	terrain_material.set_shader_parameter("tex_albedo_6", texture_albedo_6)
	
	# --- 地形材质：15 张纹理的 UV 缩放 ---
	terrain_material.set_shader_parameter("tex_scale_1", texture_scale_1)
	terrain_material.set_shader_parameter("tex_scale_2", texture_scale_2)
	terrain_material.set_shader_parameter("tex_scale_3", texture_scale_3)
	terrain_material.set_shader_parameter("tex_scale_4", texture_scale_4)
	terrain_material.set_shader_parameter("tex_scale_5", texture_scale_5)
	terrain_material.set_shader_parameter("tex_scale_6", texture_scale_6)
	terrain_material.set_shader_parameter("tex_scale_7", texture_scale_7)
	terrain_material.set_shader_parameter("tex_scale_8", texture_scale_8)
	terrain_material.set_shader_parameter("tex_scale_9", texture_scale_9)
	terrain_material.set_shader_parameter("tex_scale_10", texture_scale_10)
	terrain_material.set_shader_parameter("tex_scale_11", texture_scale_11)
	terrain_material.set_shader_parameter("tex_scale_12", texture_scale_12)
	terrain_material.set_shader_parameter("tex_scale_13", texture_scale_13)
	terrain_material.set_shader_parameter("tex_scale_14", texture_scale_14)
	terrain_material.set_shader_parameter("tex_scale_15", texture_scale_15)
	
	# --- 草地材质：6 张精灵纹理 ---
	grass_mat.set_shader_parameter("grass_texture_1", grass_sprite_tex_1)
	grass_mat.set_shader_parameter("grass_texture_2", grass_sprite_tex_2)
	grass_mat.set_shader_parameter("grass_texture_3", grass_sprite_tex_3)
	grass_mat.set_shader_parameter("grass_texture_4", grass_sprite_tex_4)
	grass_mat.set_shader_parameter("grass_texture_5", grass_sprite_tex_5)
	grass_mat.set_shader_parameter("grass_texture_6", grass_sprite_tex_6)
	
	# --- 草地材质：6 个颜色（对应 texture_albedo_1..6）---
	grass_mat.set_shader_parameter("grass_color_1", texture_albedo_1)
	grass_mat.set_shader_parameter("grass_color_2", texture_albedo_2)
	grass_mat.set_shader_parameter("grass_color_3", texture_albedo_3)
	grass_mat.set_shader_parameter("grass_color_4", texture_albedo_4)
	grass_mat.set_shader_parameter("grass_color_5", texture_albedo_5)
	grass_mat.set_shader_parameter("grass_color_6", texture_albedo_6)
	
	# --- 草地材质：是否使用 base color 而不是纹理 ---
	# 当某槽纹理为空时，用 base color 顶替。
	grass_mat.set_shader_parameter("use_base_color_1", texture_1 == null)
	grass_mat.set_shader_parameter("use_base_color_2", texture_2 == null)
	grass_mat.set_shader_parameter("use_base_color_3", texture_3 == null)
	grass_mat.set_shader_parameter("use_base_color_4", texture_4 == null)
	grass_mat.set_shader_parameter("use_base_color_5", texture_5 == null)
	grass_mat.set_shader_parameter("use_base_color_6", texture_6 == null)
	
	# --- 草地材质：槽 2..6 是否生成草地 ---
	grass_mat.set_shader_parameter("use_grass_tex_2", tex2_has_grass)
	grass_mat.set_shader_parameter("use_grass_tex_3", tex3_has_grass)
	grass_mat.set_shader_parameter("use_grass_tex_4", tex4_has_grass)
	grass_mat.set_shader_parameter("use_grass_tex_5", tex5_has_grass)
	grass_mat.set_shader_parameter("use_grass_tex_6", tex6_has_grass)


## 把当前 UI 的纹理/颜色/缩放/开关值同步到 current_texture_preset。
## 由 marching_squares_ui.gd 在“保存监控设置变更”时调用。
##
## 注意：本函数只是把属性值写进“预设资源”，不负责把资源存盘，
## 也不负责把预设应用到其它 Terrain。应用预设是另一条路径。
func save_to_preset() -> void:
	if current_texture_preset == null:
		# 没有预设不是错误——用户可能正在创建新预设。
		return
	
	# --- 15 张地形纹理 ---
	current_texture_preset.new_textures.terrain_textures[0] = texture_1
	current_texture_preset.new_textures.terrain_textures[1] = texture_2
	current_texture_preset.new_textures.terrain_textures[2] = texture_3
	current_texture_preset.new_textures.terrain_textures[3] = texture_4
	current_texture_preset.new_textures.terrain_textures[4] = texture_5
	current_texture_preset.new_textures.terrain_textures[5] = texture_6
	current_texture_preset.new_textures.terrain_textures[6] = texture_7
	current_texture_preset.new_textures.terrain_textures[7] = texture_8
	current_texture_preset.new_textures.terrain_textures[8] = texture_9
	current_texture_preset.new_textures.terrain_textures[9] = texture_10
	current_texture_preset.new_textures.terrain_textures[10] = texture_11
	current_texture_preset.new_textures.terrain_textures[11] = texture_12
	current_texture_preset.new_textures.terrain_textures[12] = texture_13
	current_texture_preset.new_textures.terrain_textures[13] = texture_14
	current_texture_preset.new_textures.terrain_textures[14] = texture_15
	
	# --- 15 个纹理缩放 ---
	current_texture_preset.new_textures.texture_scales[0] = texture_scale_1
	current_texture_preset.new_textures.texture_scales[1] = texture_scale_2
	current_texture_preset.new_textures.texture_scales[2] = texture_scale_3
	current_texture_preset.new_textures.texture_scales[3] = texture_scale_4
	current_texture_preset.new_textures.texture_scales[4] = texture_scale_5
	current_texture_preset.new_textures.texture_scales[5] = texture_scale_6
	current_texture_preset.new_textures.texture_scales[6] = texture_scale_7
	current_texture_preset.new_textures.texture_scales[7] = texture_scale_8
	current_texture_preset.new_textures.texture_scales[8] = texture_scale_9
	current_texture_preset.new_textures.texture_scales[9] = texture_scale_10
	current_texture_preset.new_textures.texture_scales[10] = texture_scale_11
	current_texture_preset.new_textures.texture_scales[11] = texture_scale_12
	current_texture_preset.new_textures.texture_scales[12] = texture_scale_13
	current_texture_preset.new_textures.texture_scales[13] = texture_scale_14
	current_texture_preset.new_textures.texture_scales[14] = texture_scale_15
	
	# --- 6 张草地精灵 ---
	current_texture_preset.new_textures.grass_sprites[0] = grass_sprite_tex_1
	current_texture_preset.new_textures.grass_sprites[1] = grass_sprite_tex_2
	current_texture_preset.new_textures.grass_sprites[2] = grass_sprite_tex_3
	current_texture_preset.new_textures.grass_sprites[3] = grass_sprite_tex_4
	current_texture_preset.new_textures.grass_sprites[4] = grass_sprite_tex_5
	current_texture_preset.new_textures.grass_sprites[5] = grass_sprite_tex_6
	
	# --- 6 个草地颜色 ---
	current_texture_preset.new_textures.grass_colors[0] = texture_albedo_1
	current_texture_preset.new_textures.grass_colors[1] = texture_albedo_2
	current_texture_preset.new_textures.grass_colors[2] = texture_albedo_3
	current_texture_preset.new_textures.grass_colors[3] = texture_albedo_4
	current_texture_preset.new_textures.grass_colors[4] = texture_albedo_5
	current_texture_preset.new_textures.grass_colors[5] = texture_albedo_6
	
	# --- 槽 2..6 的“是否生成草”标志 ---
	current_texture_preset.new_textures.has_grass[0] = tex2_has_grass
	current_texture_preset.new_textures.has_grass[1] = tex3_has_grass
	current_texture_preset.new_textures.has_grass[2] = tex4_has_grass
	current_texture_preset.new_textures.has_grass[3] = tex5_has_grass
	current_texture_preset.new_textures.has_grass[4] = tex6_has_grass

#endregion
