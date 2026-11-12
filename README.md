# AIWorkbookKit

`0.2.0` 是 AI Workbook 第二阶段的首个 Swift Package 版本。库入口是 `AIWorkbookView()`，包含 PDF 导入和已导入列表、全屏框选和预览、整页作答、逐题答题纸及续页。部署目标沿用原工程的 iPadOS 26.0。版本由 Git 标签提供。 [SwiftPM 的版本规则](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/)

## 首次接入原 iPad 工程

1. 将此 Git 仓库及 `0.2.0` 标签发布到 Swift Playgrounds 可访问的远程 Git 仓库。Apple 文档演示的是公开可读取的仓库。 [Swift Playgrounds 软件包说明](https://developer.apple.com/documentation/swift-playgrounds/add-a-swift-package)
2. 在 iPad 上打开原来的 AI Workbook 工程。点侧栏的添加按钮，选「Swift 软件包」，粘贴仓库 URL。选择 `0.2.0`，启用 `AIWorkbookKit` 产品，再添加到项目。若想接收 `0.2.x` 修订，版本规则可用「直到下一个次版本」。
3. 用 [Integration/ContentView.swift](Integration/ContentView.swift) 的全文替换原工程的 `ContentView`。如果现有文件名是 `ContentView 1`，就在那个文件里替换内容。继续使用原工程的 `MyApp` 入口和 App 标识。
4. 从原工程侧栏移除本地的 `QuestionStore`、`QuestionCropView`、`QuestionAnswerCanvas` 和 `QuestionWorkspace` Swift 源文件。工程里带 `1` 后缀的对应旧文件也可移除。运行时，`AIWorkbookView()` 会从原 App 的存储位置读取 PDF、题目和笔迹。

## 更新版本

在 Swift Playgrounds 的软件包设置中，选择版本规则允许的新版本并重新运行 App。以后模块内的修复可随 `0.2.1`、`0.2.2` 等新标签分发。原工程保留一次性接入的 `ContentView`。

## 发布现有 Git 标签

在已有本地 Git 仓库的情况下，用实际仓库 URL 替换下面的占位符，再推送分支与标签。Git bundle 可通过 `git clone <bundle 文件路径> AIWorkbookKit` 恢复这份带标签的仓库。

```text
git push <repository-url> main
git push <repository-url> 0.2.0
```

## 首次运行检查

先用独立测试工程添加 `AIWorkbookKit` 并运行，确认库可被 Swift Playgrounds 解析和编译。接入原工程后，检查此前导入的 PDF 和整页笔迹能恢复，再验证全屏框选、钢笔书写、切换续页和退出重开。旧题目和笔迹依赖原 App 容器，验收已有数据时请使用原工程。
