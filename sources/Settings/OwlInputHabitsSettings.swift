import AppKit
import SwiftUI

struct OwlAppModeControls: View {
  @Bindable private var memory = OwlAppInputMemory.shared
  @State private var showMemory = false
  let palette: OwlCandidatePalette

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Toggle(isOn: $memory.enabled) { Text("记住每个应用的中英文状态") }
        .toggleStyle(.switch)
        .accessibilityIdentifier("settings.rememberAppMode")
      HStack {
        Text("回到应用时恢复上次选择；没有记录时使用初始状态。")
          .font(.system(size: 12)).foregroundStyle(palette.ink3)
        Spacer(minLength: 8)
        Button("管理记忆…") { showMemory = true }
          .accessibilityIdentifier("settings.manageAppMemory")
      }
    }
    .padding(.bottom, 10)
    .sheet(isPresented: $showMemory) {
      VStack(alignment: .leading, spacing: 16) {
        Text("应用状态记忆").font(.title2)
        Text("只保存中英文选择，重启后仍保留；不记录输入内容。")
          .font(.callout).foregroundStyle(.secondary)
        List {
          if memory.modes.isEmpty { Text("还没有记录。在应用中切换一次中英文后会出现在这里。") }
          ForEach(memory.modes.keys.sorted(), id: \.self) { app in
            HStack {
              VStack(alignment: .leading) {
                Text(appName(app))
                Text(app).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(memory.modes[app] == true ? "英文" : "中文")
              Button("忘记") { memory.forget(app) }
            }
          }
        }
        Text("忘记后，下次进入该应用使用初始状态。").font(.caption).foregroundStyle(.secondary)
        HStack { Spacer(); Button("完成") { showMemory = false } }
      }
      .padding(24).frame(width: 560, height: 400)
    }
  }

  private func appName(_ bundleID: String) -> String {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
      .map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID
  }
}

struct OwlPinnedWordsSettings: View {
  @Bindable private var pins = OwlPinnedWords.shared
  @State private var showWords = false
  let palette: OwlCandidatePalette
  let theme: OwlCandidateTheme
  let reduceTransparency: Bool

  var body: some View {
    SettingsCard(title: "候选词置顶", palette: palette, theme: theme, reduceTransparency: reduceTransparency) {
      VStack(alignment: .leading, spacing: 10) {
        OwlHotKeyRecorderRow(slot: .pinCandidate, palette: palette)
        Text("全拼组字时，置顶当前选中的词；再次按下取消。也可以右键候选词操作。仅影响相同完整拼音和简繁状态，简拼、双拼、五笔不受影响。")
          .font(.system(size: 12)).foregroundStyle(palette.ink3)
        HStack {
          Text("已置顶 \(pins.words.count) 个词").font(.system(size: 13))
          Spacer()
          Button("管理置顶词…") { showWords = true }
            .accessibilityIdentifier("settings.managePinnedWords")
        }
        if !OwlPinnedWordsDeployment.available {
          Text("置顶通道尚未就绪。重新部署后生效；自定义方案或过滤器由你的配置管理。")
            .font(.system(size: 12)).foregroundStyle(palette.ink3)
        }
      }
    }
    .sheet(isPresented: $showWords) {
      VStack(alignment: .leading, spacing: 16) {
        Text("置顶词").font(.title2)
        Text("取消后，下次组字恢复普通排序。").font(.callout).foregroundStyle(.secondary)
        List {
          if pins.words.isEmpty { Text("还没有置顶词。输入完整拼音后，右键一个候选试试。") }
          ForEach(pins.words) { word in
            HStack {
              Text(word.text)
              Spacer()
              Text("\(word.code) · \(word.traditional ? "繁体" : "简体")").foregroundStyle(.secondary)
              Button("取消置顶") { pins.remove(word) }
            }
          }
        }
        HStack { Spacer(); Button("完成") { showWords = false } }
      }
      .padding(24).frame(width: 560, height: 400)
    }
  }
}
