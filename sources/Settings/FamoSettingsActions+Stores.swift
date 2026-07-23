//
//  FamoSettingsActions+Stores.swift
//  Famo
//
//  Store-backed button actions for the settings window.
//

import Foundation

extension FamoSettingsActions {
  static func selectProject(_ project: FamoProject)
    -> (selectedID: String, renameDraft: String, wordsDraft: String, status: String)
  {
    (
      project.id,
      project.name,
      project.normalizedWords.joined(separator: "\n"),
      ""
    )
  }

  static func createProject(
    name: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, newProjectName: String, status: String) {
    let project = try store.create(name: name)
    return (project, "", "已新建场景词库「\(project.name)」。")
  }

  static func activateProject(
    _ project: FamoProject,
    store: FamoProjectStore
  ) throws -> (activeID: String?, status: String) {
    try store.activate(id: project.id)
    return (store.activeProjectID, "已激活「\(project.name)」。")
  }

  static func renameProject(
    _ project: FamoProject,
    to name: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
    let updated = try store.rename(id: project.id, to: name)
    return (updated, "已重命名为「\(updated.name)」。")
  }

  static func saveProjectWords(
    _ project: FamoProject,
    wordsText: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
    let words = wordsText
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { String($0) }
    let updated = try store.setWords(id: project.id, words: words)
    return (updated, "已保存 \(updated.normalizedWords.count) 个词条。")
  }

  static func deleteProject(
    _ project: FamoProject,
    selectedID: String?,
    store: FamoProjectStore
  ) throws -> (selectedID: String?, status: String) {
    try store.delete(id: project.id)
    return (selectedID == project.id ? nil : selectedID, "已删除「\(project.name)」。")
  }

  static func addProjectTermRule(
    to project: FamoProject,
    preferred: String,
    allowedText: String,
    forbiddenText: String,
    store: FamoProjectStore
  ) throws -> (project: FamoProject?, preferred: String, allowed: String, forbidden: String, status: String) {
    let trimmed = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      return (nil, preferred, allowedText, forbiddenText, "首选术语不能为空。")
    }
    let rule = FamoTermRule(
      preferred: trimmed,
      allowedVariants: splitTermVariants(allowedText),
      forbiddenVariants: splitTermVariants(forbiddenText)
    )
    let updated = try store.setTermRules(id: project.id, termRules: project.termRules + [rule])
    return (updated, "", "", "", "已添加术语规则「\(rule.preferred)」（共 \(updated.termRules.count) 条）。")
  }

  static func removeProjectTermRule(
    _ rule: FamoTermRule,
    from project: FamoProject,
    store: FamoProjectStore
  ) throws -> (project: FamoProject, status: String) {
    let remaining = project.termRules.filter { $0.id != rule.id }
    let updated = try store.setTermRules(id: project.id, termRules: remaining)
    return (updated, "已删除术语规则「\(rule.preferred)」。")
  }

  static func splitTermVariants(_ raw: String) -> [String] {
    raw
      .split(whereSeparator: { $0 == "," || $0 == "，" })
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }

  @discardableResult
  static func selectSchemaRow(
    _ schema: SchemaItem,
    currentSchemaID: String,
    onSelectSchema: (String) -> Void
  ) -> Bool {
    guard schema.id != currentSchemaID else { return false }
    onSelectSchema(schema.id)
    return true
  }

}
