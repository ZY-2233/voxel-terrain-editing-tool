# NavigationMesh 指南

由于该插件目前生成密集, 复杂的几何体 它有时可能很难烘焙一个标准的 NavigationMesh. 这篇小指南展示了一个简单的分步流程 它将为你的地形和游戏制作一个可用的 NavigationMesh!

(本指南由 [DanTrz](https://github.com/DanTrz) 提供)

## 设置!

1. 创建一个 NavigationRegion3D 并将其移动到你的场景的根节点.
2. 在 NavigationRegion3D 内设置以下设置属性:
   * Parsed Geometry Type → Static Colliders
   * Source Geometry Mode → Group Explicit
   * Cells (Cell Size) → 1.0
   * Cells (Cell Height) → 0.5
   * Agents (Height) → 2.0
   * Agents (Radius) → 1.0
   * Agents (Max Climb) → 0.5
3. 在 Source Group Name (位于 NavigationMesh 内), 你现在需要指定要为哪些组生成 NavigationMesh 数据. 这将避免 godot 扫描所有内容. 我们刚刚应用的新设置将减少此过程所需的数据. 确保组名以 *navmesh_* 开头, 否则区块的 "StaticBody3D" 子节点在 (重新)创建时将不会复制这些组.
4. 最后, 确保 **Terrain Chunk** 节点被添加到你在 "Source Group Name" 设置中列出的组中. 我们将组放在区块本身上而不是 "StaticBody3D" 上 因为它们会在每次保存后被删除并重新创建.
- 通过这样做, 你将只为添加到该组中的特定区块的 "StaticBody3D" 生成 NavMeshData. 并且借助新的 NavigationMesh 资源设置, 你将降低生成的 NavData 的复杂度.



# NavigationMesh Guide

As the plugin currently generates dense, complex geometry it can sometimes be hard to bake a standard NavigationMesh. This small guide shows a simple step-by-step process that will make a working NavigationMesh for your terrain and games!

(This guide is courtesy of [DanTrz](https://github.com/DanTrz))

## Setting up!

1. Create a NavigationRegion3D and move it to the root of your scene.
2. Within the NavigationRegion3D set the following setting attributes:
   * Parsed Geometry Type → Static Colliders
   * Source Geometry Mode → Group Explicit
   * Cells (Cell Size) → 1.0
   * Cells (Cell Height) → 0.5
   * Agents (Height) → 2.0
   * Agents (Radius) → 1.0
   * Agents (Max Climb) → 0.5
3. In the Source Group Name (within NavigationMesh), you will now need to specify what groups to generate the NavigationMesh data for. This will avoid godot scanning everything. The new settings we just applied will reduce the data required for this process. Make sure that the group name starts with *navmesh_*, otherwise the "StaticBody3D" children of the chunks will not copy the groups upon (re)creation.
4. Finally, make sure that the **Terrain Chunk** nodes are added to the group you listed in "Source Group Name" setting. We put the group on the chunk itself instead of the "StaticBody3D" as they get deleted and recreated after every save.
- By doing this, you will only generate NavMeshData for the specific chunks' "StaticBody3D" that you added to the group. And with the new NavigationMesh resource settings, you will reduce the complexity in the NavData generated.
