//
//  ModelContainer.swift
//  IClick
//
//  Created by 李旭 on 2024/10/3.
//
//  SharedDataManager 已随 SwiftData 图层一并移除，原因见 Models.swift 顶部说明。
//  简言之：没有任何代码查询过该容器，却要在每次启动时创建它，
//  并且创建失败会 fatalError 崩溃、还会在 ~/Documents 留下无人使用的数据库文件。
//
