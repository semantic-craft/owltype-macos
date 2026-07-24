//
//  FamoSkillsPage.swift
//  法墨输入法 (Famo) — 技能平台 (Skills) settings page + 辅助功能授权
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

// MARK: - 技能平台

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
    SettingsCard(title: "划词菜单", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "启用划词菜单",
          subtitle: "开启后，在任意 App 里选中文字会自动弹出菜单，菜单项就是下方已启用的技能；关闭后不再自动弹出，仍可用快捷键随时召唤。",
          isOn: state.selectionMenuEnabled,
          palette: palette,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.selectionMenuEnabled) {
              FamoSelectionMenuPreferences.isEnabled = $0
              // 用时申请：仅在用户开启划词菜单时请求授权，不在启动/更新时弹。
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
            Text("划词菜单需要读取当前选区。开启划词菜单时会请求系统授权；若已拒绝或需重新授权，点右侧按钮打开权限设置，授权后切回本窗口即自动更新。")
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
  /// because 技能平台 only does anything once 云端 AI is on: `enabledActions` returns an empty
  /// menu when it is off, and the 内置技能 rows below disable in lockstep.
  /// No separate 辅助功能权限 block: `selectionMenuCard` above already shows that status.
  private var cloudCard: some View {
    SettingsCard(title: "云端 AI（全局）", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
        SettingsToggleRow(
          title: "启用云端 AI",
          subtitle: "下方全部内置技能都要联网，都归这个开关管。关闭后技能列表整体停用，划词菜单里不会出现任何 AI 选项，「任意提问」的热键与菜单栏入口也一并停用。",
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
  private var builtInSkillsCard: some View {
    SettingsCard(title: "内置技能", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(spacing: 0) {
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
          title: "公文排版",
          subtitle: "选中正文，套用公文格式与字号字体",
          systemImage: "doc.text",
          isOn: state.documentFormattingSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.documentFormattingSkillEnabled) {
              FamoSelectionMenuPreferences.documentFormattingEnabled = $0
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
        // 三个润色的名字与副标题必须讲清两件事：改不改原文、样例谁来给。
        SettingsToggleRow(
          title: "润色·直接替换",
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
          title: "润色·多版本挑选",
          subtitle: "选中文本，一次给 3–5 个风格各异的版本让你挑；窗口显示、可复制，不改动原文",
          systemImage: "rectangle.stack",
          isOn: state.polishVariantsSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.polishVariantsSkillEnabled) {
              FamoSelectionMenuPreferences.polishVariantsEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "润色·仿我的范例",
          subtitle: "选中文本，你先补几条参考说法再发送，改写得贴近你的写法；窗口显示、可复制，不改动原文",
          systemImage: "quote.bubble",
          isOn: state.polishStyleMatchSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.polishStyleMatchSkillEnabled) {
              FamoSelectionMenuPreferences.polishStyleMatchEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        SettingsToggleRow(
          title: "提示词优化",
          subtitle: "选中写给 AI 的草稿提示词，改写成结构化提示词（补齐意图、目标、约束、产出形态）；预览确认后替换原文。用系统听写口述出草稿后选中即可",
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
          title: "结构化·加标签",
          subtitle: "选中写给 AI 的草稿，按语义加上成对 XML 标签（<instructions>、<context> 等，有层级就嵌套）；措辞一字不改、只插入标签。预览确认后替换原文",
          systemImage: "chevron.left.forwardslash.chevron.right",
          isOn: state.promptStructureSkillEnabled,
          palette: palette,
          isEnabled: state.cloudEnabled,
          onToggle: {
            FamoSettingsActions.toggle(state: state, keyPath: \.promptStructureSkillEnabled) {
              FamoSelectionMenuPreferences.promptStructureEnabled = $0
            }
          }
        )
        SettingsCardDivider(palette: palette)
        Text("打开划词菜单后，这些已启用的技能会出现在选中文本旁边。「任意提问」不在此列——它不处理选区，入口是划词菜单里的同名项，也可在「快捷键设置」里录一个热键随时召唤。")
          .font(.system(size: 12))
          .foregroundStyle(palette.ink3)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.top, 8)
      }
    }
  }
}
