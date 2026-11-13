# AIWorkbookKit

库入口是 `AIWorkbookView()`，包含 PDF 导入和已导入列表、全屏框选和预览、整页作答、逐题答题纸及续页。部署目标为 iPadOS 26.0。版本由 Git 标签提供。 [SwiftPM 的版本规则](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/)

## 产品路线图

目标是在 iPad 导入学校作业 PDF，用 Apple Pencil 逐题作答，再生成一份可上传到学校或课程网页的 PDF。

| 阶段 | 任务 | 当前状态与验收 |
| --- | --- | --- |
| 1 · PDF 与整页书写 | 本地导入、翻页、Apple Pencil、按原页保存并恢复笔迹 | 原型已在 iPad 验证。升级后在原工程打开旧作业，可检查原页笔迹。 |
| 2 · 逐题作答 | 手动框选、题目预览与编辑、独立答题纸、续页、本地保存 | `0.2.0` 可在原工程运行。`0.2.1` 的独立 iPad 工程已确认各项功能正常。原工程更新依赖后需复核旧作业。 |
| 2 · 书写体验 | PDFKit 清晰预览、横线纸、全屏与缩放、自定义钢笔 | `0.2.1` 已发布。实时压感、清晰轮廓和抬笔衔接的改进已通过 iOS SDK 编译，仍需 iPad 快写与缩放验收。 |
| 3 · 导出与手动提交 | 导出带题目和续页的作答 PDF，再到学校网页手动上传 | `2f733a4` 已通过 iOS 26 SDK 编译与 iPad 模拟器导出测试，待真机验收后发布。 |
| 4 · 辅助分题 | OCR 或版面识别提出题目范围，用户复核、调整并保存 | 待规划。先用实际作业评估扫描质量和分题准确率，继续提供手动框选。 |
| 5 · 提交流程改进 | 根据实际学校平台补充上传指引、命名规则和提交结果提示 | 待确定目标平台和可用接口。先以手动上传完成提交。 |

## 导出逐题作答 PDF

导出功能目前可在独立测试工程 `AIWorkbook Export Test.swiftpm` 中试用。模拟器已检查 A4 页尺寸、旋转页的偏移裁切、题目和续页顺序、笔迹位置以及笔迹读取失败提示。 [自动验证记录](https://github.com/Angeriu/AIWorkbookKit1/actions/runs/43380330469)

1. 打开一份样张，进入「逐题作答」。框选两道题，分别写几笔，再给其中一题加一张续页。
2. 回到题目列表，按提交顺序排列题目，点「导出作答 PDF」并选保存位置。
3. 在「文件」打开生成的 PDF，检查题序、旋转页裁切、续页和笔迹，再从学校网页选择文件，确认平台能接收。

导出采用 A4 纵向。每张答题纸占一页，显示对应的裁切题目、题名和答题纸页码，包含空白续页。整页书写区的笔迹仍可在原 PDF 查看。生成文件使用当前作答内容，源 PDF 和本地作答数据保持原样。

## 已发布版本 `0.2.1`

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

如果侧栏已经有 `AIWorkbookKit1`，打开软件包设置，选择要安装的 Git 标签，再运行原工程。若依赖固定在 `0.2.0`，请调整版本要求。App 入口继续调用 `AIWorkbookView()`。验收旧作业时使用原工程，独立测试工程适合导入样张。

## 发布现有 Git 标签

在已有本地 Git 仓库的情况下，用实际仓库 URL 替换下面的占位符，再推送分支与标签。Git bundle 可通过 `git clone <bundle 文件路径> AIWorkbookKit` 恢复这份带标签的仓库。

```text
git push --atomic <repository-url> main refs/tags/0.2.1
```

## 首次运行检查

1. 在原工程确认旧 PDF、旧题和整页笔迹能打开。用留有大白边的 PDF 放大并框选，再回答题页看上方题目。补测旋转、扫描和含批注的页面。
2. 在逐题和整页画布分别用 Apple Pencil 轻写、重写、快写。检查压感、撤销和重做，再切换到橡皮擦测试。深色系统模式下在浅色纸上检查默认黑色笔迹。
3. 在横线纸上写一笔，双指放大并移动，再进入和退出全屏。检查笔迹和横线仍对齐，且刚才的笔画仍可撤销。加一张续页并写入，退出重开后核对恢复。
