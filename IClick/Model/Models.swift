//
//  Models.swift
//  IClick
//
//  Created by 李旭 on 2024/10/3.
//
//  这里原本定义了 SwiftData 的 @Model PermDir，以及配套的 SharedDataManager。
//  但整个项目没有任何一处真正查询过这个模型：PermDir 只在 ModelContainer 创建时被引用，
//  而 PermissiveDir 走的是 SharedSettings plist 持久化。
//
//  保留它的代价是真实的：
//  1. 应用启动时会创建 ModelContainer，一旦失败就是 fatalError 直接崩溃；
//  2. 没有 App Group 权限时会落到 ~/Documents/IClickDatabase.sqlite，产生一个没人读的数据库文件。
//
//  因此该图层已移除。若将来确实要引入 SwiftData，请重新设计模型与迁移策略，
//  并且不要把容器创建失败写成 fatalError（启动路径上的崩溃点）。
//
