# ============================================================================
# MarchingSquaresGrassPlanter
# ----------------------------------------------------------------------------
# 【总览】
# 草地“播种器”。它本身是一个 MultiMeshInstance3D 节点，
# 挂在每个 MarchingSquaresTerrainChunk 下面，负责在区块的“地板”三角形上
# 撒下草丛实例（MultiMesh 的一个 instance = 一簇草）。
#
# 【为什么用 MultiMesh】
#   一个区块可能有 32×32 个单元格，每个单元格再撒 N² 簇草，
#   数量很容易上千上万。用 MultiMesh 可以让 GPU 一次 draw call 画完所有草。
#
# 【数据流（简版）】
#   chunk.cell_geometry（三角形 + uv + 顶点颜色 + 遮罩）
#      ↓ generate_grass_on_cell()
#   用重心坐标判断采样点落在哪个三角形内
#      ↓ 用纹理槽决定“此处该不该长草”
#      ↓ 从地形纹理上采样出该点颜色作为草的颜色
#   multimesh.set_instance_transform / set_instance_custom_data
#
# 【草地 shader 会用到的 instance_custom_data】
#   我们把从地形纹理采样得到的颜色写进 instance_custom_data，
#   grass shader 再根据它来着色，让草丛颜色跟地面纹理一致。
#
# 注意：
# 本文件只是在原始源码基础上添加注释，未修改任何代码逻辑、变量名、
# 缩进结构、导出属性或函数行为。
# ============================================================================

@tool
extends MultiMeshInstance3D
class_name MarchingSquaresGrassPlanter


# 按纹理 ID（1..6）查表得到的草地精灵 alpha 值。
# 索引 0 未用（表示无效），1..5 分别对应纹理槽 1..6。
# 越往后 alpha 越高，效果是不同草地纹理看起来“浓密程度”不同。
# 例：texture_id=1（基础草）alpha=0.2，texture_id=6 alpha=1.0。
const GRASS_ALPHA_VALUES := [0.0, 0.2, 0.4, 0.6, 0.8, 1.0]

# 反向引用：所属区块。
# 通过它可以访问 cell_geometry / dimensions / color_map 等。
var _chunk : MarchingSquaresTerrainChunk
# 反向引用：所属地形系统。
# 通过它可以访问 grass_size / grass_subdivisions / tex 属性 / color 属性等。
var terrain_system : MarchingSquaresTerrain


# ----------------------------------------------------------------------------
# setup
# 初始化 MultiMesh。
#
# redo 参数用途：
#   - true  ：丢弃旧 MultiMesh，重建一个新的（属性大幅变化时用）；
#   - false ：沿用已存在的 MultiMesh（只是想改 instance_count 或 mesh 时用）。
# ----------------------------------------------------------------------------
func setup(chunk: MarchingSquaresTerrainChunk, redo: bool = true):
	_chunk = chunk
	# 从 chunk 里取地形系统的引用（chunk 一定知道自己的 terrain_system）。
	terrain_system = _chunk.terrain_system
	
	# 防御性检查：如果 chunk 未设置或拿不到 terrain_system，
	# 后面的所有操作都会失败，所以直接报错返回。
	if not _chunk or not terrain_system:
		push_error("SETUP FAILED - no chunk or terrain system found for GrassPlanter")
		return
	
	# 决定是新建还是沿用 MultiMesh。
	# 注意这里用了 `!multimesh`（GDScript 里 non-null 判断），
	# 即当前还没有 MultiMesh 时也必须创建。
	if (redo and multimesh) or !multimesh:
		multimesh = MultiMesh.new()
	# 先把 instance_count 归零，避免设置 mesh 时因为旧 count 太大触发警告。
	multimesh.instance_count = 0
	
	# 每个实例需要完整的 3D 变换。
	# 如果用 TRANSFORM_2D，instance 的变换矩阵只有 2D，无法撑起草叶的竖直方向。
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	# 打开 per-instance custom data（RGBA 四通道），
	# 草地 shader 会从 instance_custom_data 里取颜色。
	multimesh.use_custom_data = true
	# 计算 instance 数量：
	#   (dim.x - 1) × (dim.z - 1) 是单元格数；
	#   每个单元格撒 grass_subdivisions² 簇草。
	multimesh.instance_count = (_chunk.dimensions.x-1) * (_chunk.dimensions.z-1) * terrain_system.grass_subdivisions * terrain_system.grass_subdivisions
	# 使用地形系统提供的草地网格（默认是一张 QuadMesh，草 shader 会用它做 billboard 效果）。
	# 若尚未配置，就临时用一个 QuadMesh，保证 MultiMesh 有合法 mesh。
	if terrain_system.grass_mesh:
		multimesh.mesh = terrain_system.grass_mesh
	else:
		multimesh.mesh = QuadMesh.new() # Create a temporary quad
		# 中文：创建一个临时四边形。
	# 根据 grass_size 和 cell_size 计算实际尺寸。
	# (cell_size.x + cell_size.y)/4 是“取平均半边长”，把草尺寸相对单元格归一化。
	multimesh.mesh.size = terrain_system.grass_size * (terrain_system.cell_size.x + terrain_system.cell_size.y) / 4.0
	
	# 草不投射阴影。原因：
	#   1) 草量巨大，投射阴影会显著拖慢渲染；
	#   2) 草通常很薄，阴影效果不明显；
	#   3) 草 shader 里一般会处理风动，会跟阴影冲突。
	cast_shadow = SHADOW_CASTING_SETTING_OFF


# ----------------------------------------------------------------------------
# regenerate_all_cells
# 遍历本区块的所有单元格，逐个调用 generate_grass_on_cell。
#
# 触发时机（都在别处调用）：
#   - 区块初次初始化；
#   - wall_threshold 变化；
#   - 单个纹理槽的纹理/颜色/开关变化；
#   - 草地尺寸/细分数变化。
#
# 注意本函数并不重建地形 mesh，它只重撒草。
# ----------------------------------------------------------------------------
func regenerate_all_cells() -> void:
	# Safety checks
	# 中文：安全检查。
	if not _chunk:
		push_error("_chunk not set while regenerating cells")
		return
	
	if not terrain_system:
		push_error("terrain_system not set while regenerating cells")
		return
	
	# 如果还没有 MultiMesh，先初始化一下（可能需要重新分配 instance_count）。
	if not multimesh:
		setup(_chunk)
	
	# 如果区块本身还没有生成单元格几何数据，那么草地没有三角形可以依靠，
	# 只能先让区块重建 mesh。这是一个隐式的“先建地形，再撒草”的依赖关系。
	if not _chunk.cell_geometry:
		_chunk.regenerate_mesh()
	
	# 双重循环遍历所有单元格坐标 (x, z)。
	# 注意用的是 terrain_system.dimensions 而不是 _chunk.dimensions，
	# 因为该地形系统约定所有 chunk 的尺寸一致。
	for z in range(terrain_system.dimensions.z-1):
		for x in range(terrain_system.dimensions.x-1):
			generate_grass_on_cell(Vector2i(x, z))


# ----------------------------------------------------------------------------
# generate_grass_on_cell
# 核心函数：在指定的一个单元格上撒 grass_subdivisions² 簇草。
#
# 算法步骤：
#   1. 先随机生成 count 个采样点（XZ 平面上的本地坐标）；
#   2. 遍历该单元格的所有三角形（只处理地板三角形）；
#   3. 对每个三角形，用重心坐标判断哪些采样点在三角形内部；
#   4. 采样点被“认领”后从 points 中删除，避免重复放置；
#   5. 在采样点位置，读取插值后的颜色、遮罩、UV，决定是否真的放草；
#   6. 若放草，就调用 _create_grass_instance；否则 _hide_grass_instance。
#
# 最后剩下的点（落在所有三角形之外，可能是空白区域）用隐藏实例填满，
# 保证 MultiMesh 的 index 布局稳定，不残留上一帧的草。
# ----------------------------------------------------------------------------
func generate_grass_on_cell(cell_coords: Vector2i) -> void:
	# Safety checks
	# 中文：安全检查。
	if not _chunk:
		push_error("Couldn't find a reference to _chunk")
		return
	
	if not terrain_system:
		push_error("Couldn't find a reference to terrain_system")
		return
	
	if not _chunk.cell_geometry:
		push_error("Couldn't find a reference to cell_geometry")
		return
	
	if not _chunk.cell_geometry.has(cell_coords):
		push_error("Couldn't find a reference to cell_coords")
		return
	
	var cell_geometry = _chunk.cell_geometry[cell_coords]
	
	# 检查必需字段是否齐全（verts / uvs / color_0s / color_1s / custom_1_values / is_floor）。
	# 这是防止上层重构改字段名后草地系统悄悄失效的保护。
	if not cell_geometry.has("verts") or not cell_geometry.has("uvs") or not cell_geometry.has("color_0s") or not cell_geometry.has("color_1s") or not cell_geometry.has("custom_1_values") or not cell_geometry.has("is_floor"):
		push_error("cell_geometry doesn't have one of the following required data: 1) verts, 2) uvs, 3) colors, 4) custom_1_values, 5) is_floor")
		return
	
	# ---- 1. 随机采样点 ----
	# 在一个单元格内撒 N×N 个点，每个点随机偏移一点（去掉网格感）。
	# 坐标是“本区块内、从原点算起”的世界米单位。
	# 因为后面重心插值用的是 verts 数组（也是本地坐标），所以这里只要保证同样坐标系即可。
	var points : PackedVector2Array = []
	var count = terrain_system.grass_subdivisions * terrain_system.grass_subdivisions
	
	for z in range(terrain_system.grass_subdivisions):
		for x in range(terrain_system.grass_subdivisions):
			points.append(Vector2(
				(cell_coords.x + (x + randf_range(0, 1)) / terrain_system.grass_subdivisions) * terrain_system.cell_size.x,
				(cell_coords.y + (z + randf_range(0, 1)) / terrain_system.grass_subdivisions) * terrain_system.cell_size.y
			))
	
	# ---- 2. 计算本单元格对应的 instance index 区间 ----
	# 本区块的 instance 布局是按 (cell 行 × cell 列 × 每 cell 的 count) 顺序，
	# 所以 index 起点 = (z × cell 列数 + x) × count。
	var index : int = (cell_coords.y * (_chunk.dimensions.x-1) + cell_coords.x) * count
	var end_index : int = index + count
	
	# ---- 3. 缓存 cell_geometry 中的引用 ----
	# 局部变量可以减少属性查找，同时不会不小心修改字典内容。
	var verts : PackedVector3Array = cell_geometry["verts"]
	var uvs : PackedVector2Array = cell_geometry["uvs"]
	var color_0s : PackedColorArray = cell_geometry["color_0s"]
	var color_1s : PackedColorArray = cell_geometry["color_1s"]
	var custom_1_values : PackedColorArray = cell_geometry["custom_1_values"]
	var is_floor : Array = cell_geometry["is_floor"]
	
	# ---- 4. 遍历所有三角形 ----
	# cell_geometry 的 verts 是三角形列表（每三个一组）。
	for i in range(0, len(verts), 3):
		if i+2 >= len(verts):
			continue # Skip incomplete triangle
			# 中文：跳过不完整的三角形。
		# 只在地板三角形上撒草，墙面/悬崖三角形跳过。
		# 这里的 is_floor[i] 是三角形第一个顶点的标记；
		# 因为 cell 生成时保证一个三角形的三个顶点 floor 属性一致，
		# 所以只检查第一个就够。
		if not is_floor[i]:
			continue
		
		var a := verts[i]
		var b := verts[i+1]
		var c := verts[i+2]
		
		# ---- 5. 三角形重心坐标（Barycentric）准备 ----
		# 把三角形投影到 XZ 平面处理（高度对“点在内部”判定没意义）。
		# 用经典的重心坐标公式，只需要预计算一次分母。
		var v0 := Vector2(c.x - a.x, c.z - a.z)
		var v1 := Vector2(b.x - a.x, b.z - a.z)
		
		# 预计算分母（等于 2 × 三角形有向面积）。
		var dot00 := v0.dot(v0)
		var dot01 := v0.dot(v1)
		var dot11 := v1.dot(v1)
		var invDenom := 1.0/(dot00 * dot11 - dot01 * dot01)
		
		# ---- 6. 遍历尚未被认领的采样点 ----
		# 一旦一个采样点被某个地板三角形认领，就从 points 中移除，
		# 这样后续三角形不用再检查它。
		var point_index := 0
		while (point_index < len(points)):
			var v2 = Vector2(points[point_index].x - a.x, points[point_index].y - a.z)
			var dot02 := v0.dot(v2)
			var dot12 := v1.dot(v2)
			
			# u、v 是重心坐标的两个分量（第三个是 1-u-v）。
			var u := (dot11 * dot02 - dot01 * dot12) * invDenom
			if u < 0:
				point_index += 1
				continue
			
			var v := (dot00 * dot12 - dot01 * dot02) * invDenom
			if v < 0:
				point_index += 1
				continue
			
			# u + v <= 1 表示点在三角形内（因为重心坐标 u,v,w 都 >= 0 且和为 1）。
			if u + v <= 1:
				# Point is inside triangle, won't be inside any other floor triangle
				# 中文：点位于三角形内部，不会落入其他地板三角形。
				points.remove_at(point_index)
				# 用重心坐标插值出世界位置（含高度）。
				var p := a*(1-u-v) + b*u + c*v
				
				# ---- 7. 检查是否位于岩架或山脊 ----
				# cell 生成时 UV.y 表示“靠近悬崖边缘”的程度，
				# UV.x > 0.5 表示靠近某条特定边。
				# 这里简单地认为：uv.y > 0 或 uv.x > 0.5 就是岩架/山脊，
				# 不撒草，避免草丛悬在悬崖边上。
				var uv := uvs[i]*u + uvs[i+1]*v + uvs[i+2]*(1-u-v)
				var on_ledge_or_ridge : bool = uv.y > 0.0 or uv.x > 0.5
				
				# ---- 8. 计算该点的纹理槽 ----
				# 顶点颜色里只存“哪个通道为 1”，是离散的编码。
				# 直接插值出小数没意义，所以先用 get_dominant_color
				# 把插值结果“归整”回某个 1.0 通道。
				var color_0 := MarchingSquaresTerrainVertexColorHelper.get_dominant_color(color_0s[i]*u + color_0s[i+1]*v + color_0s[i+2]*(1-u-v))
				var color_1 := MarchingSquaresTerrainVertexColorHelper.get_dominant_color(color_1s[i]*u + color_1s[i+1]*v + color_1s[i+2]*(1-u-v))
				
				# ---- 9. 读取草地遮罩 ----
				# 遮罩的编码约定：
				#   mask.r < 1  → 用户禁止此处生草（例如踩踏过的小路）
				#   mask.g ≥ 1  → 用户强制此处生草（预设覆盖）
				#   mask.b      → 目前未使用，保留扩展
				#   mask.a      → 目前未使用，保留扩展
				var mask := custom_1_values[i]*u + custom_1_values[i+1]*v + custom_1_values[i+2]*(1-u-v)
				var is_masked : bool = mask.r < 0.9999
				var force_grass_on : bool = mask.g >= 0.9999  # Preset override: force grass regardless of texture
				# 中文：预设覆盖：无论纹理如何都强制生成草。
				
				# ---- 10. 三连判定 ----
				# 判定 1：texture_id 对应的纹理是否允许生草；
				# 判定 2：是否位于岩架/山脊；
				# 判定 3：是否被遮罩屏蔽。
				var texture_id := _get_texture_id(color_0, color_1)
				var on_grass_tex := _has_grass_for_texture(texture_id, force_grass_on)
				
				if on_grass_tex and not on_ledge_or_ridge and not is_masked:
					_create_grass_instance(index, p, a, b, c, texture_id)
				else:
					_hide_grass_instance(index)
				index += 1
			else:
				point_index += 1
	
	# ---- 11. 用隐藏实例填补剩余槽位 ----
	# 未被任何三角形认领的采样点说明落在“无地板”的区域（理论上不该发生，
	# 但保险起见还是要把剩余槽位隐藏掉，防止上一帧的草残留）。
	# 之所以要填满到 end_index，是因为 MultiMesh 的 instance 是按固定槽位排布的：
	# 单元格 (x,z) 对应固定的一段 index，不能少填。
	while index < end_index:
		if index >= multimesh.instance_count:
			return
		_hide_grass_instance(index)
		index += 1

#region grass property getters
# ----------------------------------------------------------------------------
# 草地属性获取器。
# 这些函数的作用是把地形系统里的“全局属性”（纹理、缩放、alpha 等）
# 映射成草地生成时需要的局部参数。
# ----------------------------------------------------------------------------

# 根据纹理 ID 返回对应的地形纹理图像。
#
# 为什么需要把纹理转成 Image：
#   草地颜色要跟地形纹理同步。我们需要在 CPU 端从纹理上“逐像素采样”，
#   而 Texture2D 不直接支持按像素采样，所以先取 Image。
# 注意：大纹理在 CPU 上采样是开销，但因为只在生成草时批量执行一次，
# 所以整体可接受。若纹理是压缩格式（如 DXT、ETC），要先 decompress()。
func _get_terrain_image(texture_id: int) -> Image:
	var terrain_texture : Texture2D = null
	var material := terrain_system.terrain_material
	# 纹理 ID → shader uniform 名 的映射。
	# 1 没有 case，落到 default 拿 vc_tex_rr（基础草纹理）。
	match texture_id:
		2:
			terrain_texture = material.get_shader_parameter("vc_tex_rg")
		3:
			terrain_texture = material.get_shader_parameter("vc_tex_rb")
		4:
			terrain_texture = material.get_shader_parameter("vc_tex_ra")
		5:
			terrain_texture = material.get_shader_parameter("vc_tex_gr")
		6:
			terrain_texture = material.get_shader_parameter("vc_tex_gg")
		_: # Base grass
			# 中文：基础草地。
			terrain_texture = material.get_shader_parameter("vc_tex_rr")
	if terrain_texture == null:
		return null
	
	var img : Image = terrain_texture.get_image()
	if img:
		# 如果纹理是压缩格式，先解压到普通像素格式，才能 get_pixelv。
		img.decompress()
	return img


# 用 color_0 / color_1 两段编码还原出纹理 ID（1..16）。
#
# 编码规则（与 MSTDataHandler._colors_to_texture_idx 是互逆的）：
#   color_0 决定“行”，color_1 决定“列”。
#   行 = (R,G,B,A) → (1,2,3,4) 的偏移；
#   列 = (R,G,B,A) → (1,2,3,4) 的偏移。
#   最终 id = (行 - 1) * 4 + 列。
#   但这里用的是 if/elif 展开成 16 个分支，本质上就是查表。
#
# 判定 0.9999 是因为插值浮点误差，用 1.0 会漏。
func _get_texture_id(vc_col_0: Color, vc_col_1: Color) -> int:
	var id : int = 1;
	if vc_col_0.r > 0.9999:
		if vc_col_1.r > 0.9999:
			id = 1;
		elif vc_col_1.g > 0.9999:
			id = 2;
		elif vc_col_1.b > 0.9999:
			id = 3;
		elif vc_col_1.a > 0.9999:
			id = 4;
	elif vc_col_0.g > 0.9999:
		if vc_col_1.r > 0.9999:
			id = 5;
		elif vc_col_1.g > 0.9999:
			id = 6;
		elif vc_col_1.b > 0.9999:
			id = 7;
		elif vc_col_1.a > 0.9999:
			id = 8;
	elif vc_col_0.b > 0.9999:
		if vc_col_1.r > 0.9999:
			id = 9;
		elif vc_col_1.g > 0.9999:
			id = 10;
		elif vc_col_1.b > 0.9999:
			id = 11;
		elif vc_col_1.a > 0.9999:
			id = 12;
	elif vc_col_0.a > 0.9999:
		if vc_col_1.r > 0.9999:
			id = 13;
		elif vc_col_1.g > 0.9999:
			id = 14;
		elif vc_col_1.b > 0.9999:
			id = 15;
		elif vc_col_1.a > 0.9999:
			id = 16;
	return id;


## 判断指定纹理 ID 是否应该生草。
##
## 【决策逻辑】
##   1. force_grass_on（来自遮罩的绿通道）→ 无条件 true；
##   2. 纹理 ID = 1（基础草）→ true；
##   3. 纹理 ID 在 2..6 → 查 terrain_system 的 5 个开关；
##   4. 其他（7..16）→ false。
##
## 说明：
##   7..16 是扩展槽，目前草地系统不覆盖它们（没有对应的草地精灵纹理），
##   所以默认不生草。
func _has_grass_for_texture(texture_id: int, force_grass_on: bool) -> bool:
	if force_grass_on:
		return true
	if texture_id == 1:
		return true  # Base grass always has grass
		# 中文：基础草地始终有草。
	if texture_id < 2 or texture_id > 6:
		return false
	
	# 把 5 个开关塞进数组，用索引直接查表，比写 5 段 match 更清晰。
	var has_grass_flags := [
		terrain_system.tex2_has_grass,
		terrain_system.tex3_has_grass,
		terrain_system.tex4_has_grass,
		terrain_system.tex5_has_grass,
		terrain_system.tex6_has_grass
	]
	return has_grass_flags[texture_id - 2]


## 获取指定纹理 ID 的纹理缩放系数。
## texture_id 1..6 对应 terrain_system.texture_scale_1..6。
## 索引越界会被 clamp，保证不会越界访问。
func _get_texture_scale(texture_id: int) -> float:
	var scales := [
		terrain_system.texture_scale_1,
		terrain_system.texture_scale_2,
		terrain_system.texture_scale_3,
		terrain_system.texture_scale_4,
		terrain_system.texture_scale_5,
		terrain_system.texture_scale_6
	]
	var idx := clampi(texture_id - 1, 0, 5)
	return scales[idx]


## 获取指定纹理 ID 的草地精灵透明度。
## 通过 GRASS_ALPHA_VALUES 查表。clamp 保证越界安全。
func _get_grass_alpha(texture_id: int) -> float:
	var idx := clampi(texture_id - 1, 0, 5)
	return GRASS_ALPHA_VALUES[idx]


## 在给定世界位置采样地形纹理的颜色。
##
## 【UV 映射说明】
##   world_pos 是区块本地坐标（因为 verts 是本地坐标）。
##   这里除以“整块地形的实际尺寸”得到 0..1 的 UV。
##   然后再乘 tex_scale，再取小数部分，实现纹理平铺。
##   这就是为什么相邻区块能无缝拼贴：
##   因为每个区块都用自己的 world_pos 参与全局 UV 计算。
##
## 【色彩空间】
##   sRGB 纹理（如 PNG、JPG）解码后仍是 sRGB 颜色空间，
##   但 shader 里做光照计算需要线性空间，所以转一下。
##   如果纹理本来就是线性格式（如 EXR），就不转。
func _sample_terrain_texture_color(world_pos: Vector3, texture_id: int, tex_scale: float) -> Color:
	var terrain_image := _get_terrain_image(texture_id)
	if not terrain_image:
		# 拿不到纹理就返回白色，这样至少在视觉上有一个明确的“缺失”提示。
		return Color.WHITE
	
	# 归一化到 0..1。
	var uv_x : float = clamp(world_pos.x / ((terrain_system.dimensions.x - 1) * terrain_system.cell_size.x), 0.0, 1.0)
	var uv_y : float = clamp(world_pos.z / ((terrain_system.dimensions.z - 1) * terrain_system.cell_size.y), 0.0, 1.0)
	
	# 乘纹理缩放后取小数，得到循环 UV（平铺效果）。
	uv_x = abs(fmod(uv_x * tex_scale, 1.0))
	uv_y = abs(fmod(uv_y * tex_scale, 1.0))
	
	# 转成像素坐标。用 width-1 / height-1 避免边缘越界。
	var px := int(uv_x * (terrain_image.get_width() - 1))
	var py := int(uv_y * (terrain_image.get_height() - 1))
	var color := terrain_image.get_pixelv(Vector2(px, py))
	if _format_needs_conversion(terrain_image.get_format()):
		return color.srgb_to_linear()
	return color


# 判断图像格式是否属于“sRGB 编码”，需要转线性。
# 我们枚举常用的几种 sRGB 格式。列表外的（如 FORMAT_RF）就当是线性。
func _format_needs_conversion(fmt: Image.Format) -> bool:
	match(fmt):
		Image.FORMAT_RGB8, \
		Image.FORMAT_RGBA8, \
		Image.FORMAT_DXT1, \
		Image.FORMAT_DXT3, \
		Image.FORMAT_DXT5, \
		Image.FORMAT_BPTC_RGBA, \
		Image.FORMAT_ETC2_RGB8 , \
		Image.FORMAT_ETC2_RGBA8 , \
		Image.FORMAT_ETC2_RGB8A1 : return true
	return false

#endregion

#region grass placement helpers
# ----------------------------------------------------------------------------
# 草地实例放置辅助函数。
# ----------------------------------------------------------------------------

## 在指定位置创建一个草地实例。
##
## 【变换构造】
##   我们希望草叶朝向三角形法线（垂直于地表），因此要构建一个“以 normal 为 Y 轴”
##   的基向量。
##   做法：取一个参考向量 (FORWARD 或 RIGHT)，跟法线做叉乘，得到一条水平轴；
##   再用它跟法线叉乘，得到另一条轴。
##   最后用 -normal 作为基的 Z 轴（因为 Godot 的 QuadMesh 正面朝 +Z）。
##
## 【为什么要给 center_offset.y = size.y/2】
##   QuadMesh 的原点在中心。如果原点直接放在地表，草叶会“一半埋在地下”。
##   所以要向上偏移半高，让草叶根部正好落在地表。
##
## 【颜色采样】
##   从地形纹理采样出草根的纹理颜色，作为草丛颜色，
##   这样草丛的颜色能跟地面纹理自然过渡，不会出现突兀的颜色边界。
func _create_grass_instance(index: int, world_pos: Vector3, a: Vector3, b: Vector3, c: Vector3, texture_id: int) -> void:
	# 用两条边叉乘得到三角形法线。
	var edge1 := b - a
	var edge2 := c - a
	var normal := edge1.cross(edge2).normalized()
	
	# 构造 billboard 基向量。
	# Vector3.FORWARD 与 normal 叉乘得到水平右方向，
	# 然后 normal 与 FORWARD 叉乘得到另一个水平前方向。
	var right := Vector3.FORWARD.cross(normal).normalized()
	var forward := normal.cross(Vector3.RIGHT).normalized()
	# Basis 的三列分别是 X、Y、Z 轴。
	# 我们希望：
	#   Y 轴 = normal（草叶向上）；
	#   Z 轴 = -normal 的某个镜像（QuadMesh 正面朝向摄像机一侧）；
	#   这里实例的 X = right，Y = forward，Z = -normal。
	#   实际效果是让草叶的“正面”朝着法线的反方向，与 3D 显示方向对齐。
	var instance_basis := Basis(right, forward, -normal)
	
	# 设置实例变换：位置 + 朝向。
	multimesh.set_instance_transform(index, Transform3D(instance_basis, world_pos))
	# 让 QuadMesh 的中心上移半高，使草根落在地表。
	multimesh.mesh.center_offset.y = multimesh.mesh.size.y / 2
	
	# 采样地形纹理颜色作为草丛颜色。
	var tex_scale := _get_texture_scale(texture_id)
	var instance_color := _sample_terrain_texture_color(world_pos, texture_id, tex_scale)
	# 用表里查到的 alpha 覆盖，实现不同纹理槽不同的“草密度感”。
	instance_color.a = _get_grass_alpha(texture_id)
	
	# 写入 per-instance custom data，供 grass shader 读取。
	multimesh.set_instance_custom_data(index, instance_color)


## 通过把实例缩放为 0 来“隐藏”它。
##
## 为什么不用 scale 为 0 的 Basis 之外的方法？
##   - MultiMesh 没有“显示/隐藏”开关，只能靠变换伪装；
##   - 缩放到 0 会让三角形退化，GPU 直接丢弃，几乎零开销；
##   - 比每帧重建 instance_count 更稳定（索引布局不会变）。
func _hide_grass_instance(index: int) -> void:
	multimesh.set_instance_transform(index, Transform3D(Basis.from_scale(Vector3.ZERO), Vector3.ZERO))

#endregion
