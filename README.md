# AIWorkbookKit

库入口是 `AIWorkbookView()`，包含 PDF 导入和已导入列表、全屏框选和预览、整页作答、逐题答题纸及续页。部署目标为 iPadOS 26.0。版本由 Git 标签提供。 [SwiftPM 的版本规则](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/)

## 0.2.1

- 框选使用 PDFKit 缩放。打开时优先对准内容，选「适合整页」可查看页边。扫描件的细节取决于原始图像。
- 逐题作答上方显示题目，可全屏放大。遇到疑似空白选区，可以查看原页或重新框选。已写的答案随题目保留。
- 整页和逐题画布默认使用自定义黑色压感钢笔。点工具栏的钢笔可调粗细和压感。
- 逐题答题纸使用浅色横线纸，双指缩放和平移。点「全屏作答」扩大当前纸面，点「适合宽度」恢复比例。

## 首次接入原 iPad 工程

1. 在 iPad 上打开原来的 AI Workbook 工程。点侧栏的添加按钮，选「Swift 软件包」，粘贴 `https://github.com/Angeriu/AIWorkbookKit1.git`。 [Swift Playgrounds 软件包说明](https://developer.apple.com/documentation/swift-playgrounds/add-a-swift-package)
2. 选择 `0.2.1`，启用 `AIWorkbookKit` 产品，再添加到项目。若想接收 `0.2.x` 修订，版本规则可用「直到下一个次版本」。
3. 用 [Integration/ContentView.swift](Integration/ContentView.swift) 的全文替换原工程的 `ContentView`。如果现有文件名是 `ContentView 1`，就在那个文件里替换内容。继续使用原工程的 `MyApp` 入口和 App 标识。
4. 从原工程侧栏移除本地的 `QuestionStore`、`QuestionCropView`、`QuestionAnswerCanvas` 和 `QuestionWorkspace` Swift 源文件。工程里带 `1` 后缀的对应旧文件也可移除。运行时，`AIWorkbookView()` 会从原 App 的存储位置读取 PDF、题目和笔迹。

## 更新版本

如果侧栏已经有 `AIWorkbookKit1`，打开软件包设置，将依赖版本更新至 `0.2.1`，再运行原工程。固定在 `0.2.0` 的版本规则需要改到 `0.2.1`，或允许 `0.2.x`。App 入口继续调用 `AIWorkbookView()`。

## 发布现有 Git 标签

在已有本地 Git 仓库的情况下，用实际仓库 URL 替换下面的占位符，再推送分支与标签。Git bundle 可通过 `git clone <bundle 文件路径> AIWorkbookKit` 恢复这份带标签的仓库。

```text
git push --atomic <repository-url> main refs/tags/0.2.1
```

## 首次运行检查

1. 在原工程确认旧 PDF、旧题和整页笔迹能打开。用留有大白边的 PDF 放大并框选，再回答题页看上方题目。补测旋转、扫描和含批注的页面。
2. 在逐题和整页画布分别用 Apple Pencil 轻写、重写、快写。检查压感、撤销和重做，再切换到橡皮擦测试。深色系统模式下在浅色纸上检查默认黑色笔迹。
3. 在横线纸上写一笔，双指放大并移动，再进入和退出全屏。检查笔迹和横线仍对齐，且刚才的笔画仍可撤销。加一张续页并写入，退出重开后核对恢复。
