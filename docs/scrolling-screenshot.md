# 滚动截图实现

## 整体流程

```
用户选择区域 → OverlayView.enterScrollingState()
  → 隐藏遮罩层，显示边框窗口 + 预览面板
  → CaptureEngine.startStream() 启动 SCStream (10 FPS)
  → AsyncStream<CGImage> 逐帧输出
  → StitchingEngine.addFrame() 处理每一帧
  → Vision 计算帧间位移 → 绘制到大缓冲区
  → StitchingEngine.finalize() 裁剪有效区域
  → 用户按 Enter → finishScrolling()
  → 打开 StitchedAnnotationWindow 进行标注 & 导出
```

## 核心组件

### CaptureEngine.swift — 屏幕流捕获

- `startStream(display:area:excluding:)` 启动 ScreenCaptureKit 流
  - `sourceRect`：Display 坐标系（Top-Left 原点），单位为 point
  - `config.width/height`：像素尺寸 = point × backingScaleFactor
  - `minimumFrameInterval`：CMTime(value: 1, timescale: 10) → 10 FPS
  - `excluding`：排除预览面板和边框窗口，避免捕获自身 UI
  - `StreamOutput` 将 CVPixelBuffer → CIImage → CGImage 通过 AsyncStream 输出

### StitchingEngine.swift — 帧拼接核心

#### 虚拟文档空间

- 预分配 20000px 高的 CGContext 缓冲区
- 初始偏移 `initialY = 10000`，允许向两个方向增长
- `minY` / `maxY` 跟踪实际使用的区域

#### 坐标系转换

```
CGContext（Bottom-Left, Y-Up）  →  CGImage（Top-Left, Y-Down）
  destY = bufferMaxHeight - virtualY - imageHeight
  
CGImage Y ≈ virtualY （近似），故 finalize() 裁剪可直接用 minY/maxY
```

#### 帧处理流程

1. **第一帧**：绘制整个帧到 `initialY = 10000`，初始化 `minY/maxY`

2. **后续帧**：Vision 计算帧间位移
   - `VNTranslationalImageRegistrationRequest` 比较 `lastFrame` 和 `newFrame`
   - `alignmentTransform` 将 floating image (newFrame) 映射到 reference image (lastFrame)
   - 向下滚动（内容上移）→ `transform.ty < 0`（负值）
   - 向上滚动（内容下移）→ `transform.ty > 0`（正值）
   - **关键**：`transform.ty` 已经是像素坐标（非归一化），直接使用，无需乘以 frameHeight

3. **位移累加**：`dy = -transform.ty`（取反，使 dy > 0 表示向下滚动）
   - `currentOffset += dy` → 累加得到当前帧在虚拟文档中的位置
   - 过滤：`|dy| < 1.0`（噪声）或 `|dy| > frameHeight`（Vision 错误）→ 丢弃

4. **绘制策略**（上下滚动不同）：

   **向下滚动（dy > 0）**：只绘制帧的**底部 dy 像素**（新增内容）
   - 如果绘制整个帧，每帧顶部的静态元素（如窗口标题栏）会覆盖前帧的内容
   - 裁剪：`newFrame.cropping(to: 底部 dy 像素)`
   - 绘制位置：`prevBottom = currentOffset + frameHeight - dy`（紧接已有内容底部）

   **向上滚动（dy < 0）**：绘制**整个帧**
   - 向上滚动时帧顶部是滚回缓冲区中的新终端内容
   - 与已有内容的重叠区域是相同的终端内容（只是位移），覆盖无影响
   - 绘制位置：`currentOffset`（新计算的位置）

5. **边界扩展**：
   - `minY = min(minY, currentOffset)`
   - `maxY = max(maxY, currentOffset + frameHeight)`

6. **最终裁剪**（`finalize()`）：
   - 从缓冲区 CGImage 裁剪 `[minY, maxY]` 范围
   - `minY` 和 `maxY` 在 CGImage 空间中近似等于虚拟文档坐标

### OverlayView.swift — 滚动状态管理

- `enterScrollingState(with:)`：将选中区域（Flipped 坐标）转换为 SCK Display 坐标
  - `convertToSCK()`：OverlayView Flipped → AppKit Global → SCK Global Top-Left
  - 各屏幕坐标空间转换通过 `screen.frame.maxY` 和 `primaryScreenHeight` 完成
- 显示边框窗口标记捕获区域，显示 `ScrollingPreviewPanel` 实时预览
- `finishScrolling()`：停止流，裁取最终图像，打开标注窗口
- `cancel()`：停止流，关闭所有窗口

### ScrollingPreviewPanel.swift — 实时预览面板

- NSPanel 浮窗，显示拼接结果的滚动预览 + 原始帧缩略图 + 调试信息
- 调试信息：帧数、拼接高度、最新 dy、捕获区域坐标

### StitchedAnnotationWindow.swift — 标注窗口

- 接收拼接后的完整长图，提供 `AnnotationView` + `AnnotationToolbar` 进行标注
- `renderFinalImage()` 将标注合成到原图后导出

## Vision 对齐精度

- `VNTranslationalImageRegistrationRequest` 计算纯平移变换
- 对纯文本终端界面效果较好（大量水平线条特征）
- `regionOfInterest = (0, 0, 1, 1)` 使用全图对齐
- 限制：对纯色/渐变区域对齐不准，可能产生累积误差

## 已知限制

1. **标题栏干扰**（向下滚动）：如果捕获区域包含窗口标题栏，向下滚动时每帧顶部的标题栏会覆盖前帧的终端内容。当前方案通过只绘制底部新增内容来规避。

2. **向上滚动的标题栏**：如果捕获区域包含标题栏，向上滚动时帧顶部会包含标题栏而非终端内容。

3. **缓冲区大小**：当前固定 20000px，超长文档可能截断。

4. **内存使用**：20000px 高的 RGBA 缓冲区 ≈ 20000 × width × 4 字节。对于 1420px 宽的截图约 113 MB。

5. **累积误差**：Vision 帧间对齐的微小误差会随帧数累积，可能在长文档中表现为接缝。

6. **仅支持主显示器**：多显示器场景下 SCK ↔ Display 坐标转换可能不正确。

## 未来优化方向

- 动态扩展缓冲区支持任意长度
- 在上/下边界处做像素级融合，消除累积误差造成的接缝
- 支持双向滚动（先上后下或在中间任意位置开始）
- 添加重采样/压缩减少内存占用
