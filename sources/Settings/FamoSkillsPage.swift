//
//  FamoSkillsPage.swift
//  法墨输入法 (Famo) — 划词工具箱页 (Skills) settings page + 辅助功能授权
//
//  Boundary (ADR-0001 / 0002 / 0003): SwiftUI settings UI only; not @MainActor-isolated.
//

import Foundation
import AppKit
import ApplicationServices
import Combine
import SwiftUI

enum FamoAccessibilitySettings {
  /// 当前进程是否已获辅助功能授权（静默查询，绝不弹窗）。
  static var isTrusted: Bool { AXIsProcessTrusted() }

  /// 主动申请授权：仅首次会弹出系统授权框（每个签名只弹一次），之后静默无效。
  /// 在用户开启划词菜单时调用——这是"用时申请"而非启动/更新时申请。
  /// ponytail: 系统弹窗每签名一次的限制无法绕过；已拒绝/需重授权时走 `open()` 打开设置面板。
  static func request() {
    guard !isTrusted else { return }
    let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
    _ = AXIsProcessTrustedWithOptions(options)
  }

  static func open() {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
      NSWorkspace.shared.open(url)
    }
  }
}

// MARK: - 划词工具箱页

/// Selection-menu skill platform. This page only writes preferences and opens the
/// macOS Accessibility pane; the global selection watcher owns runtime permission checks.
struct FamoSkillsPage: View {
  @Bindable var state: FamoSettingsState
  let palette: FamoCandidatePalette
  let theme: FamoCandidateTheme
  let reduceTransparency: Bool
  @State private var accessibilityTrusted = FamoAccessibilitySettings.isTrusted

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        selectionMenuCard
        cloudCard
        builtInSkillsCard
      }
      .padding(20)
    }
    // 授权态刷新：打开设置页时查一次，且每次窗口重新变为前台时再查一次——
    // 用户去「系统设置」授权后切回本窗口即自动翻绿，无需重开设置页。
    .onAppear { accessibilityTrusted = FamoAccessibilitySettings.isTrusted }
    .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
      accessibilityTrusted = FamoAccessibilitySettings.isTrusted
    }
  }

  private var selectionMenuCard: some View {
    SettingsCard(title: "启用与权限", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "启用划词工具箱",
          subtitle: "开启后，在任意 App 里选中文字、快速双击 ⌥（Option）键即可呼出工具箱：用下方技能加工选中文本，或直接下指令。不会一选中就自动弹出；关闭后双击不响应，仍可用录制的召唤快捷键呼出。",
          isOn: state.selectionMenuEnabled,
          palette: palette,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.selectionMenuEnabled) {
              FamoSelectionMenuPreferences.isEnabled = $0
              // 用时申请：仅在用户开启划词工具箱时请求授权，不在启动/更新时弹。
              if $0 { FamoAccessibilitySettings.request() }
            }
          }
        )
        SettingsCardDivider(palette: palette)
        HStack(spacing: 10) {
          Image(systemName: "accessibility")
            .foregroundStyle(palette.accent)
          VStack(alignment: .leading, spacing: 2) {
            Text("辅助功能权限")
              .font(.system(size: 13.5, weight: .medium))
              .foregroundStyle(palette.ink)
            Text("划词工具箱需要读取当前选区。开启工具箱时会请求系统授权；若已拒绝或需重新授权，点右侧按钮打开权限设置，授权后切回本窗口即自动更新。")
              .font(.system(size: 12))
              .foregroundStyle(palette.ink3)
              .fixedSize(horizontal: false, vertical: true)
          }
          Spacer(minLength: 8)
          // 单一按钮同时显示状态并作为授权入口：未授权（点开系统设置）/ 已授权（绿勾）。
          Button {
            FamoAccessibilitySettings.open()
          } label: {
            HStack(spacing: 4) {
              Image(systemName: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
              Text(accessibilityTrusted ? "已授权" : "未授权 · 去授权")
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(accessibilityTrusted ? Color.green : palette.accent)
          }
          .buttonStyle(.borderless)
          .accessibilityLabel(accessibilityTrusted ? "辅助功能已授权，点此打开权限设置" : "辅助功能未授权，点此前往授权")
        }
        .padding(.top, 10)
      }
    }
  }

  // MARK: - 云端 AI（全局）

  /// The single global on/off for every cloud-AI feature. Lives here (not on the AI 配置 page)
  /// because 划词工具箱页 only does anything once 云端 AI is on: `enabledActions` returns an empty
  /// menu when it is off, and the 内置技能 rows below disable in lockstep.
  /// No separate 辅助功能权限 block: `selectionMenuCard` above already shows that status.
  private var cloudCard: some View {
    SettingsCard(title: "云端 AI（全局）", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "启用云端 AI",
          subtitle: "下方全部内置技能都要联网，都归这个开关管。关闭后技能列表整体停用，双击 ⌥ 与召唤快捷键都不再打开工具箱，「任意提问」也一并停用。",
          isOn: state.cloudEnabled,
          palette: palette,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.cloudEnabled) {
              FamoCloudPreferences.isEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("🔒 AI 只在你主动触发时工作：划词技能发送你选中的文本，任意提问发送你输入的问题；打字时的主候选始终来自本地 Rime，绝不上云。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }

  /// 内置技能 rows. Every row is disabled while 云端 AI is off — these all need the network, and
  /// `enabledActions` hides them wholesale in that state, so a live-looking toggle would lie.
  /// 「任意提问」置顶成独立一段：它是全部技能的兜底（固定功能，2026-07-26 起有真开关、默认开），
  /// 与下面按需启停的具体技能用分隔线隔开。
  private var builtInSkillsCard: some View {
    SettingsCard(title: "内置技能", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "任意提问",
          subtitle: "全部技能的兜底，也是工具箱的输入框：对选中文本直接下指令（改写、排版、拟回复…）或提问；只回结果、一键复制，不改动原文",
          systemImage: "text.bubble",
          isOn: state.askAnythingSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.askAnythingSkillEnabled) {
              FamoSelectionMenuPreferences.askEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "来源核验",
          subtitle: "选中引文或法条，核验来源与版本是否一致",
          systemImage: "checkmark.shield",
          isOn: state.sourceVerificationSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.sourceVerificationSkillEnabled) {
              FamoSelectionMenuPreferences.sourceVerificationEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "辅助检索",
          subtitle: "选中关键词，生成检索式与可查线索",
          systemImage: "magnifyingglass",
          isOn: state.researchAssistSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.researchAssistSkillEnabled) {
              FamoSelectionMenuPreferences.researchAssistEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "规范排版",
          subtitle: "选中从 PDF/网页复制的中文，修正冗余换行、引号与全半角，规范为大陆出版排版；内容一字不改",
          systemImage: "text.justify",
          isOn: state.publishFormattingSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.publishFormattingSkillEnabled) {
              FamoSelectionMenuPreferences.publishFormattingEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "划词翻译",
          subtitle: "选中文本，意译成中/英，结果在窗口显示、可复制，不改动原文",
          systemImage: "globe",
          isOn: state.translationSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.translationSkillEnabled) {
              FamoSelectionMenuPreferences.translationEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "润色",
          subtitle: "选中文本，AI 改写一版并直接替换原文；宿主不允许替换时改为复制到剪贴板",
          systemImage: "wand.and.stars",
          isOn: state.polishSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.polishSkillEnabled) {
              FamoSelectionMenuPreferences.polishEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "提示词优化",
          subtitle: "选中写给 AI 的草稿提示词，改写成结构化提示词：补齐意图、目标、约束、产出形态，并按语义加上成对 XML 标签；预览确认后替换原文。用系统听写口述出草稿后选中即可",
          systemImage: "sparkles",
          isOn: state.promptOptimizeSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.promptOptimizeSkillEnabled) {
              FamoSelectionMenuPreferences.promptOptimizeEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "任务书",
          subtitle: "选中口述的模糊需求，按「目标七问」整理成 AI Agent 可独立执行的目标任务书：目的、完成态、证据、反作弊、边界、取舍逐节补齐，说不清的列进「未知」待你裁决；预览确认后替换原文",
          systemImage: "checklist",
          isOn: state.goalBriefSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.goalBriefSkillEnabled) {
              FamoSelectionMenuPreferences.goalBriefEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("召唤工具箱（双击 ⌥ 或快捷键）后，这些已启用的技能是窗口顶部的按钮。没有现成技能可用的个性化加工需求（多版本挑选、仿写、公文语体…），在输入框对选中文本直接下指令兜住。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }
}
