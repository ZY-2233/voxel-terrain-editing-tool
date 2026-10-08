# 代码风格指南

如果你想通过打开一个 PR 来为插件做贡献, 那么所有参与插件工作的人都遵循一个预定的代码风格会很有帮助. 这篇简短的指南将给出几个代码示例, 帮助你在为插件创建出色新增内容的路上前进!

## 示例

### 基本脚本设置

插件中的所有脚本在设置时都遵循以下约定:
* 被扩展的节点类型放在类名之前.
* 类名应该附加 **MarchingSquares** 或 **MST** 前缀.
  * 如果类名非常长, 首选 **MST**.
* 变量/函数/等等... 应该使用 snakecase.
* 私有函数应该在其函数名前有一个 '_'.
  * 普通变量不遵循此规则.
* 脚本范围的变量部分和所有函数之间应该有 2 个空行.
* 变量的类型标注应该在 ':' 前有一个空格.
  * (例如 "variable_name : float" 而不是 "variable_name: float")
  * 然而, 函数, 字典等的类型标注应该遵循常规约定.
* 导出变量应该遵循下面的结构.
* 代码部分之间应该使用制表符而不是空格. 与 gdshaders 相反.
  * 这些制表符应该一直到下一行的起始制表符.
* 区域彼此之间可以相隔一个空格, 函数以及区域的顶部和底部也可以.
  * 除上述例外情况外, 区域内或区域外的所有其他函数之间应该有两个空格.
  * 区域名称中不应包含大写字母.
* 仅对解释导出变量, 函数或类功能的编辑器可见注释使用双井号.
* 所有注释都应以大写字母开头.

```
@tool
extends ExampleNode3D
class_name MarchingSquaresExampleClass
## 这是一个示例类, 它展示了如何在此插件中为你的代码设置风格.

enum Enum_Variable {1, 2, 3, 4, 5}

const CONSTANT_VARIABLE : int = 1

# 这是关于该变量如何工作的普通注释
var variable : float = 1.0

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var export_variable : String = "example":
	set(value):
		export_variable = value
		# 其他影响例如地形着色器的代码


#region example functions

func _example_private_function(parameter_variable: int) -> int:
	var mult_val := 5
	return parameter_variable * mult_val


func example_public_function(parameter_variable: float) -> void:
	variable = parameter_variable

#endregion

#region one more example region

#endregion
```




# Code Style Guide

If you want to contribute to the plugin by opening a PR then it is helpfull that everyone who works on the plugin follows a predetermined code style. This short guide will give several code examples to help you on your way to create awesome additions to the plugin!

## Examples

### Basic script setup

All the scripts in the plugin follow the following conventions when setting up:
* The node type that gets extended is placed before the class name.
* Class names should have the **MarchingSquares** or **MST** prefix attached to them.
  * **MST** is prefered if the class name is very long.
* Variables/Functions/etc... should use snakecase.
* Private functions should have a '_' in front of their function name.
  * Normal variables do not follow this rule.
* The script_wide variable section and all functions should have 2 whitelines between them.
* Typing for variables should have a space in front of the ':'. 
  * (e.g. "variable_name : float" instead of "variable_name: float")
  * However, typing for functions, dictionaries, etc. should follow normal conventions.
* Exported variables should follow the below structure.
* There should be tabs instead of blanks between code parts. The opposite of gdshaders.
  * These tabs should go until the next line's starting tab. 
* Regions can be one space apart from each other as can functions and the top and bottom of regions.
  * All the other functions inside or outside regions except for the above exceptions should have two spaces between them.
  * Regions shouldn't contain capitalization in their names.
* Only use double hashtags for editor visible comments that explain the functionality of export variables, functions or classes.
* All comments should start with a capital.

```
@tool
extends ExampleNode3D
class_name MarchingSquaresExampleClass
## This is an example class that shows how to style your code in this plugin.

enum Enum_Variable {1, 2, 3, 4, 5}

const CONSTANT_VARIABLE : int = 1

# This is a normal comment on how the variable works
var variable : float = 1.0

@export_custom(PROPERTY_HINT_NONE, "", PROPERTY_USAGE_STORAGE) var export_variable : String = "example":
	set(value):
		export_variable = value
		# other code that affects e.g. the terrain shader


#region example functions

func _example_private_function(parameter_variable: int) -> int:
	var mult_val := 5
	return parameter_variable * mult_val


func example_public_function(parameter_variable: float) -> void:
	variable = parameter_variable

#endregion

#region one more example region

#endregion
```
