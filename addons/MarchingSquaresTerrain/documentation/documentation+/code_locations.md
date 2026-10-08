# 代码位置

这篇小指南解释了在插件中你可以在哪里找到几个 (较小的) 功能的代码.

### 草与纹理混合

* **MarchingSquaresTerrainVertexColorHelper** (整个脚本)
* **MarchingSquaresChunk** 脚本 → `add_point(x: float, y: float, z: float, uv_x: float = 0, uv_y: float = 0, diag_midpoint: bool = false)` 函数.
* **mst_terrain** gdshader → 片段函数.

在这里你可以更改 color_0 和 color_1 变量如何计算的逻辑, 以更改草的外观和地板纹理混合的方式.

尽管这些变量被称为 _color_, 着色器逻辑使用这两个 vec4 变量并检查任何一个通道是 1 还是 0. 然后它根据两个变量中哪些通道被 "打开" 来计算它应该使用哪个纹理.

### 草动画

* **mst_grass** gdshader → 在顶点函数的顶部.

目前将 fps 设为 0 意味着着色器将使用噪声纹理来应用全局平滑的风效果. 在编辑器的 terrain_settings 工具模式中调高 fps 会使各个草精灵从左向右移动, 使其具有像素艺术外观.

随意更改这些动画为最适合你项目的效果! 目前存在的两种动画类型只是让人们开始的基础.

### 单元格法线计算

* **MarchingSquaresTerrainPlugin** 脚本 → `get_cell_normal(chunk: MarchingSquaresTerrainChunk, cell: Vector2i) -> Vector3:` 函数.
  
### 区块 UI 线条

* **MarchingSquaresTerrainGizmo** 脚本 → `try_add_chunk(terrain_system: MarchingSquaresTerrain, coords: Vector2i):` 函数.
* **MarchingSquaresTerrainGizmo** 脚本 → `add_chunk_lines(terrain_system: MarchingSquaresTerrain, coords: Vector2i, material: Material):` 函数.

### 地形 (三平面) 映射

* **mst_terrain** gdshaderinc → 片段函数.

### 山脊与凸缘纹理计算

* **mst_terrain** gdshaderinc → 片段函数的末尾.
* **MarchingSquaresTerrainVertexColorHelper** 脚本 → 在 `blend_colors(vertex: Vector3, uv: Vector2, diag_midpoint: bool = false) -> Dictionary[String, Color]:` 函数的开头





# Code Locations

This small guide explains where you can find the code for several (smaller) features inside the plugin.

### Grass and Texture Mixing

* **MarchingSquaresTerrainVertexColorHelper** (The whole script)
* **MarchingSquaresChunk** script → `add_point(x: float, y: float, z: float, uv_x: float = 0, uv_y: float = 0, diag_midpoint: bool = false)` function.
* **mst_terrain** gdshader → fragment function.

Here you can change the logic for how the color_0 and color_1 variables are calculated to change how the grass appears and floor textures get mixed.

Although the variables are called _color_, the shader logic uses these two vec4 variables and checks wether any of the channels are a 1 or 0. It then calculates which texture it should use based on which channels in both variables are "turned on".

### Grass Animations

* **mst_grass** gdshader → at the top of the vertex function.

Right now having the fps at 0 means that the shader will use a noise texture to apply a global smooth wind effect. Turning the fps up in the terrain_settings tool mode in the editor makes the individual grass sprites move from left to right giving it a pixel art look.

Feel free to change these animations to what looks best for your project! The two animation types present right now are only a base to get people started.

### Cell Normal Calculations

* **MarchingSquaresTerrainPlugin** script → `get_cell_normal(chunk: MarchingSquaresTerrainChunk, cell: Vector2i) -> Vector3:` function.
  
### Chunk UI Lines

* **MarchingSquaresTerrainGizmo** script → `try_add_chunk(terrain_system: MarchingSquaresTerrain, coords: Vector2i):` function.
* **MarchingSquaresTerrainGizmo** script → `add_chunk_lines(terrain_system: MarchingSquaresTerrain, coords: Vector2i, material: Material):` function.

### Terrain (Triplanar) Mapping

* **mst_terrain** gdshaderinc → fragment function.

### Ridge & Ledge Texture Calculations

* **mst_terrain** gdshaderinc → end of the fragment function.
* **MarchingSquaresTerrainVertexColorHelper** script → at the start of the `blend_colors(vertex: Vector3, uv: Vector2, diag_midpoint: bool = false) -> Dictionary[String, Color]:` function
