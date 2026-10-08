# 内部工具系统指南

本指南旨在解释内部工具系统及其相关代码是如何设置和运作的. 它将首先介绍工具背后的数学和代码如何工作, 之后将解释你如何添加自己的工具. 然而, 如果你想理解这些工具, 首先有必要理解地形在底层是如何构建的.

## 地形解释 (简单版本)

地形是由 marching squares 算法构建的, 这意味着与 marching cubes 算法不同, 它只能在 Y 轴上变化. 由于这个原因, 地形是由一个细胞网格构建的 (可在插件的地形设置选项卡中调整) 并且所有地形行为都是根据存储在这些单元格中或引用这些单元格的值计算的. 例如, 增加地形高度的过程如下: 1. 选择你想要更改高度值的单元格; 2. 选择一个更高的数字; 3. 将这些新数字存储在一个高度图中. 插件中几乎所有内容都以此方式工作, 草和地板颜色值, 纹理 id's, 等等...

## 工具解释

工具是一种在插件内切换功能的简便方式. 工具本质上是可以通过检查器设置的资源. 最重要的 @export 工具设置是 **MarchingSquaresToolAttributeSettings** 资源. 这是一个列表, 目前包含以下供工具使用的属性类别:

### 笔刷属性

这些属性理论上可用于用户想要创建的任何类型的笔刷.

* brush_type → square 或 round
* size  → 笔刷的大小
* ease_value → 如果值增加或减少, 会使 bridge 工具生成的地形更圆润
* height → 控制 level 工具创建的地形高度
* strength → 控制 smooth 工具效果的大小
* flatten → 会使所有选中的地形与第一个选中的单元格高度相同
* falloff → 会使某些笔刷的效果随着选中的地形单元格离选择中心越远而减弱
* quick_paint_selection → 允许基于高度的笔刷立即应用纹理, 而无需使用顶点绘制工具. 当 quick_paint_selection 设置为 "none" 时, smooth 工具会跳过跳过此行为. 其他工具将改为应用基础墙壁和地板纹理.

### 笔刷特定属性

这些属性是专门为某个特定笔刷工作而制作的, 在这些笔刷之外不提供任何价值:

* mask_mode → 控制选中的地形是否应该在上面生成草
* material → 用于选择在顶点绘制地形时使用哪个纹理
* texture_name → 用于更改插件界面中的材质名称
* texture_preset → 用于通过预先保存的资源更改所有顶点绘制设置. 这允许在美学风格之间快速切换.
* paint_walls → 不言自明.

### 非笔刷相关属性

这些通常保留给地形设置, 并且也有偏离上述属性的内部代码:

* chunk_management → 目前只有一个更改 merge_mode 阈值值的选项, 不过这可以扩展
* terrain_settings → 包含所有全局地形设置以及一些 (全局) 草设置

### ________

上述设置包含在每个工具的布尔数组中, 可以在检查器中设置. 启用数组中的某个设置会使它在选中该工具时弹出在插件窗口中. 当将所有 UI 添加到屏幕时, 插件将读取一个 **MarchingSquaresToolAttributesList** 资源以获取所有必要数据, 例如标签名称, 它应该是什么类型的 UI 元素, 默认值, 等等. 该资源还包含顶点绘制工具中纹理名称的导出变量.

## 如何创建新工具?

要开始制作你自己的工具, 你首先需要在 tools 文件夹中创建一个新的 **MarchingSquaresTool** 资源. 只需在文件夹中右键单击并选择 _Create New_ → _Resource..._. 你应该会看到一个带有扳手图标的选项. 确保还将新创建的工具作为预加载放入 **MarchingSquaresToolbox** 脚本中. 然而, 这样做只允许你创建可以使用上面列出的所有现有属性的工具. 但是, 如果你想制作新属性 (如果你正在阅读本文, 你很可能想这样做) 呢?

### 制作新属性

要创建新属性, 你首先需要进入 **MarchingSquaresToolAttributeSettings** 脚本, 并为你希望创建的属性添加一个导出布尔值.

* _(属性 UI 是从上到下创建的, 所以如果你希望复选框或滑块等在相邻位置上保持一致, 那么请确保你在这里考虑到这一点.)_

为了使属性在代码中真正可读, 你需要做几件事. 首先, 你需要进入 **MarchingSquaresToolAttributes** 脚本, 找到 `new_attributes` 变量, 并使用以下格式将新属性放入其数组中:
```
	if tool_attributes.example:
		new_attributes.append(attribute_list.example)
```
接下来是创建包含所有属性相关数据的实际字典. 为此, 你需要在 **MarchingSquaresToolAttributesList** 脚本中创建一个新字典. 在这里你至少需要指定 _name_, UI _type_, _label_ 文本和 _default_ 值. 一些工具, 比如已经可用的顶点绘制工具, 需要额外的属性数据, 例如下拉菜单中有多少个 _options_, 但这取决于你添加到插件窗口的 UI 元素类型. 以下是一个字典条目应该 (并且可以) 看起来如何的示例:
```
var example : Dictionary = {
	"name": "example",
	"type": "option",
	"label": "Example",
	"options": ["Grass", "Sand", "Rock"],
	"default": 0, # 你需要为像 options 这样的索引值使用整数.
}
```
当前的 _type_ 字段选项有:
1. CHECKBOX,
2. SLIDER,
3. OPTION,
4. TEXT,
5. CHUNK,
6. TERRAIN,
7. PRESET,
8. QUICK_PAINT,
9. ERROR, _# 这个被用作内部逻辑失败时的故障保护._

如果你有一个使用与笔刷无关的自定义逻辑的工具, 那么建议为它创建自己的选项, 比如 CHUNK 或 TERRAIN. 添加新选项可以在 **MarchingSquaresToolAttributes** 脚本中的 `enum SettingType` 变量下完成. 确保还要在 `show_tool_attributes(tool_index: int) -> void` 函数中的 `type_map` 变量里包含新的设置类型.

### 设置属性代码

在你创建了新属性并在工具资源的检查器中选中它之后, 是时候逐步编写实际属性行为了:

* 在 **MarchingSquaresToolAttributes** 脚本中, 你会找到 `add_setting(p_params: Dictionary) -> void:` 函数, 并在其中找到 `match setting_type:` 操作.
  * 如果你创建了一个新的 _type_ 设置, 那么你应该在这里为它创建一个新的 match 语句.
  * 像 CHECKBOX 这样的设置类型不需要任何修改, 你就能在编辑器中看到并使用它们. 然而, 其他类型如 slider 需要你指定它是什么类型的滑块. 你可以通过使用 if 语句并检查 setting_name 变量来轻松检查这些差异.
* 接下来, 你需要在 **MarchingSquaresTerrainPlugin** 脚本中为你的属性创建一个匹配变量, 并转到 **MarchingSquaresToolAttributes** 脚本中的 `_get_setting_value(p_setting_name: String) -> Variant:` 函数, 将你的属性和变量添加到其中.
* 最后, 转到 **MarchingSquareUI** 脚本, 并在 `_on_setting_changed(p_setting_name: String, p_value: Variant) -> void:` 函数中做同样的事情.

### 实现工具功能

[免责声明] 某些工具功能, 比如在某些工具使用期间禁用某些变量, 在这里解释起来太复杂, 并且需要本指南解释插件中的所有代码. 如果你发现自己卡在编写新行为上并且无法找到好的解决方案, 请考虑加入 [discord](https://discord.gg/ZSeYkTCgft) 来提问并获得反馈!

要让你的工具真正做些什么, 你需要在 **MarchingSquaresTerrainPlugin** 脚本中编写行为. 首先, 找到 `TerrainToolMode` 变量, 并将你的新工具放入枚举列表中. 如果你的新工具是基于笔刷的, 并且以任何方式与更改高度有关, 那么下一节会很简单, 否则你将需要做更多工作才能让你的工具工作:

* 对于笔刷相关工具, 首先你需要转到 `draw_pattern(terrain: MarchingSquaresTerrain)` 函数, 并在 `for draw_cell_coords: Vector2i in draw_chunk_dict:` 循环中创建一个与你的工具匹配的新 if 语句.
* 如果你的笔刷是基于高度的, 那么你可以通过将 restore_value (用于撤销操作的值) 变量设置为 `restore_value = chunk.get_height(draw_cell_coords)`, 并将 draw_value 变量设置为你用新行为计算出的实际新高度, 来编写笔刷的行为. 你现在可以跳过其他步骤并测试你的新工具, 但如果你对你的工具有其他愿望, 请继续阅读.
* 如果你的工具是基于笔刷的并且不修改高度, 你将需要创建一个新的 undo_redo 操作. 它们应该位于你到目前为止一直在处理的函数的末尾. 确保创建一个与你的工具模式匹配的新 elif 语句. 在同一个脚本中, 你将需要创建一个处理新行为的新函数. 根据预期的行为, 你需要在几个脚本中编写多个新函数, 以修改, 检索和存储各种新变量. 要很好地了解如何做到这一点, 你可以浏览插件中与 VERTEX_PAINT 工具模式相关的函数和变量.
* 如果你的工具不是基于笔刷的, 并且根据鼠标位置在世界中做事, 那么你可以在 `handle_mouse(camera: Camera3D, event: InputEvent) -> int` 函数中的 `if intersection:` 语句下编写新行为. 查看 CHUNK_MANAGEMENT 工具模式的代码是如何设置的以获取示例.
* 对于所有其他工具类型, 你将需要想出新的方式来实现行为. 这些只占少数情况, 但其中一个这样的工具是 TERRAIN_SETTINGS 工具模式, 它只允许你与编辑器交互, 并将存储地形数据 (如墙壁颜色) 的 @export 变量连接到 UI.

## 添加地形设置

由于添加地形设置与添加新工具属性几乎相同, 本节只涵盖新信息. 你首先需要在 **MarchingSquaresTerrain** 脚本中创建一个新的 @export 变量. 如果你想将该变量从普通检查器中隐藏, 你将需要使用以下格式: `@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE)`. 之后你可以设置你的普通变量数据, 如类型和默认值. 确保为新变量创建一个 setter 函数, 如下所示:
```
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var example : int = 1:
	set(value):
		example = value
		# 这里你需要为你的变量设置自定义行为. 例如. 如果该变量在着色器内部使用, 你可以在这里设置它, 而不是制作一个复杂的函数数组, 每次你想更改值时都互相调用.
```
接下来, 我们进入 **MarchingSquaresToolAttributes** 脚本, 并将我们新创建的变量放入 `terrain_settings_data` 字典变量中. 还要确保在 **MarchingSquaresUI** 脚本中的 `_on_terrain_setting_changed(p_setting_name: String, p_value: Variant) -> void:` 函数中将地形变量和 UI 值相互链接. 该过程的所有其他部分, 比如编写应该出现什么类型的 UI 元素等, 都与上面的工具属性部分相同, 并且可以在相同的代码部分中找到, 只是位置稍微靠下.



# Internal Tool System Guide

This guide serves to explain how the internal tool system and its related code is setup and functions. It will first go over how the math and code behind the tools work and afterwards will explain how you can add your own tools. However, if you want to understand the tools its first necessary to understand how the terrain is structured under the hood.

## Terrain Explained (SIMPLE VERSION)

The terrain is built from the marching squares algorithm, which means that unlike the marching cubes algorithm it can only have variation in the Y axis. For this reason, the terrain is built from a cellular grid (adjustable in the terrain settings tab in the plugin) and all the terrain behaviour is calculated from values stored in or referencing to those cells. For example, the process for increasing terrain height works as follows: 1. select the cells you want to change the height value for; 2. pick a higher number; 3. store those new numbers in a height map. Almost everything in the plugin works this way, color values for the grass and floor, texture id's, etc...

## Tools Explained

Tools are an easy way to switch between functionalilty within the plugin. Tools are inherently resources that can be set via the inspector. The most important of the @export tool settings is the **MarchingSquaresToolAttributeSettings** resource. This is a list currently containing the following attribute categories for tools to use:

### Brush Attributes

These attributes can theoretically be used for any type of brush the user wants to create.

* brush_type → square or round
* size  → size of the brush
* ease_value → makes terrain made by the bridge tool more rounded if the value is increased or decreased
* height → controls the height of the terrain created by the level tool
* strength → controls how big the effect of the smooth tool is
* flatten → will make all the selected terrain the same height as the first selected cell
* falloff → will make the effect of certain brushes decrease the further the selected terrain cells are from the center of the selection
* quick_paint_selection → allows for height based brushes to instantly apply textures without having to use the vertex paint tool. The smooth tool skips skips this behaviour when the quick_paint_selection is set to "none". Other tools will apply the base wall and floor textures instead.

### Brush Specific Attributes

These are attributes specifically made to work for a singular specific brush and don't provide any value outside of those brushes:

* mask_mode → controls if selected terrain should have grass spawn on it or not
* material → used for selecting which texture to use while vertex painting the terrain
* texture_name → used to change the material names in the plugin interface
* texture_preset → used to change all the vertex painting settings via pre-saved resources. This allows for quick swapping between aesthetics.
* paint_walls → self explanatory.

### Non-Brush Related Attributes

These are usually reserved for terrain settings and also have interal code that deviates from the above attributes:

* chunk_management → right now only has an option to change the merge_mode threshold value, however this can be expanded upon
* terrain_settings → features all the global terrain settings as well as some (global) grass settings

### ________
The above settings are contained in an array of booleans per tool which can be set in the inspector. Enabling a setting in the array makes it popup in the plugin window when the tool is selected. When adding all the UI to the screen the plugin will read a **MarchingSquaresToolAttributesList** resource for all the necessary data such as label names, what type of UI element it should be, default values, etc. This resource also contains the export variable for the texture names in the vertex paint tool.

## How to Create New Tools?

To start making your own tools you need to first create a new **MarchingSquaresTool** resource in the tools folder. Simply right click in the folder and select _Create New_ → _Resource..._. You should see an option with a wrench icon. Make sure to also put the newly created tool in the **MarchingSquaresToolbox** script as a preload. Doing this, however, only allows you to create tools which can make use of all the pre-existing attributes listed above. But, what if you want to make new attributes (which you probably do if you are reading this)?

### Making New Attributes

To create new attributes you first need to go into the **MarchingSquaresToolAttributeSettings** script and add an export boolean value for the attribute you wish to create.

* _(Attribute UI gets created from top to bottom so if you wish to have consistency in whether checkboxes or sliders etc. are next to each other, then make sure that you account for that here.)_

To make the attribute actually readable in the code you need to do a couple of things. First, you need to go into the **MarchingSquaresToolAttributes** script and find the `new_attributes` variable and place the new attribute in its array with the following formatting:
```
	if tool_attributes.example:
		new_attributes.append(attribute_list.example)
```
Next up is creating the actual dictionary with all the attribute related data. To do this you need to create a new dictionary in the **MarchingSquaresToolAttributesList** script. Here you need to at least specify the _name_, UI _type_, _label_ text and _default_ value. Some tools like the already available vertex paint tool require extra attribute data like how many _options_ there are in the dropdown menu, but this depends on the type of UI element you are adding to the plugin window. Here is an example of what a dictionary entry should (and could) look like:
```
var example : Dictionary = {
	"name": "example",
	"type": "option",
	"label": "Example",
	"options": ["Grass", "Sand", "Rock"],
	"default": 0, # You need to use an integer for indexed values like options.
}
```
The current _type_ field options are:
1. CHECKBOX,
2. SLIDER,
3. OPTION,
4. TEXT,
5. CHUNK,
6. TERRAIN,
7. PRESET,
8. QUICK_PAINT,
9. ERROR, _# This one is used as a failsafe if the internal logic fails._

If you have a tool that uses custom logic that has nothing to do with brushes, then it is recommended to make its own option for it like CHUNK or TERRAIN. Adding new options can be done in the **MarchingSquaresToolAttributes** script under the `enum SettingType` variable. Make sure to also include the new setting type in the `type_map` variable in the `show_tool_attributes(tool_index: int) -> void` function.

### Setting up the Attribute Code

After you have created your new attribute and selected it in the inspector for the tool resource, its time for coding in the actual attribute behaviour step by step:

* In the **MarchingSquaresToolAttributes** script you will find the `add_setting(p_params: Dictionary) -> void:` function and within it the `match setting_type:` operation. 
  * If you created a new _type_ setting then you should create a new match statement for it here.
  * Setting types like CHECKBOX will not need any modifications for you to see and use them in the editor. However, other types like slider will need you to specify what kind of slider it is. You can easily check for these differences by using an if statement and checking for the setting_name variable.
* Next up you need to create a matching variable for your attribute in the **MarchingSquaresTerrainPlugin** script and go to the `_get_setting_value(p_setting_name: String) -> Variant:` function in the **MarchingSquaresToolAttributes** script and add your attribute and variable to it.
* Finally, go to the **MarchingSquareUI** script and do the same in the `_on_setting_changed(p_setting_name: String, p_value: Variant) -> void:` function.

### Implementing Tool Functionality

[DISCLAIMER] Some tool functionality like disabling certain variables during certain tool uses is too complex to explain here and would require this guide to explain all the code in the plugin. If you find yourself stuck coding in new behaviour and can't figure out a good solution, please consider joining the [discord](https://discord.gg/ZSeYkTCgft) to ask questions and get feedback!

To actually make your tools do something, you need to code in the behaviour in the **MarchingSquaresTerrainPlugin** script. First up, find the `TerrainToolMode` variable and place your new tool in the enum list. If your new tool is brush based and has to do with changing the height in any sort of way the next section will be easy, otherwise you will need to do a lot more work to make your tool work:

* For brush related tools, first up you need to go to the `draw_pattern(terrain: MarchingSquaresTerrain)` function and create a new if statement in the `for draw_cell_coords: Vector2i in draw_chunk_dict:` loop matching your tool.
* If your brush is height based, then you can code in the behaviour of the brush by setting the restore_value (value that gets used to undo an action) variable to `restore_value = chunk.get_height(draw_cell_coords)`, and the draw_value variable to the actual new height you calculated with the new behaviour. You can now skip the other steps and test your new tool, but if you have other wishes for your tools, keep reading.
* If your tool is brush based and does not modify the height you will need to create a new undo_redo action. They should be at the end of the function where you have been working in up until now. Make sure to create a new elif statement that matching your tool mode. In the same script you will need to create a new function that handles the new behaviour. Depending on the intended behaviour you will need to write multiple new functions in several scripts that modify, retrieve and store all sorts of new variables. To get a good idea of how to do this you can look through the plugin for the functions and variables related to the VERTEX_PAINT tool mode.
* If your tool is non-brush based and does things in the world based on the position of your mouse, then you can code in new behaviour in the `handle_mouse(camera: Camera3D, event: InputEvent) -> int` function under the `if intersection:` statement. Look at how the code for the CHUNK_MANAGEMENT tool mode is set up for examples.
* For all the other tool types you will need to think of new ways to implement the behaviour. These make up the minority of the cases but one such tool is the TERRAIN_SETTINGS tool mode that only lets you interact with the editor and connects @export variables that store terrain data like wall color to the UI.

## Adding Terrain Settings

As adding terrain settings works almost the same as adding new tool attributes, this section will only cover new information. You will first need to create a new @export variable in the **MarchingSquaresTerrain** script. If you want to have the variable be hidden from the normal inspector you will need to use the following format: `@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE)`. After which you can set your normal variable data like type and default value. Make sure to create a setter function for the new variable like so:
```
@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var example : int = 1:
	set(value):
		example = value
		# Here you will need to set the custom behaviour for your variable. E.g. if the variable is used inside a shader you can set it here instead of making a complicated array of functions calling each other everytime you want to change a value.
```
Next, we go into the **MarchingSquaresToolAttributes** script and place our newly created variable in the `terrain_settings_data` dictionary variable. Also make sure to link the terrain variable and the UI value to each other in the `_on_terrain_setting_changed(p_setting_name: String, p_value: Variant) -> void:` function in the **MarchingSquaresUI** script. All the other parts of the process like coding in what kind of UI element should appear etc. are the same as the tool attributes section above and can be found in the same sections of code but a little bit lower down.
