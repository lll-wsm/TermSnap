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

4. **绘制策略**：

   **统一绘制策略**：不再区分滚动方向，始终绘制**整个帧**。
   - 移除原有的 15% 盲区裁剪及仅绘制新增像素的复杂逻辑。
   - 得益于精准的滚动区域识别（Accessibility API），捕获区域不再包含静态的窗口标题栏。
   - 重叠区域利用 `.normal` 混合模式直接覆盖，确保拼接无缝。
   - 绘制位置：`currentOffset`（由 Vision 计算出的当前帧虚拟文档位置）。

5. **边界扩展**：
   - `minY = min(minY, currentOffset)`
   - `maxY = max(maxY, currentOffset + frameHeight)`

6. **最终裁剪**（`finalize()`）：
   - 从缓冲区 CGImage 裁剪 `[minY, maxY]` 范围
   - `minY` 和 `maxY` 在 CGImage 空间中近似等于虚拟文档坐标

### OverlayView.swift — 滚动状态管理

- `mouseMoved(with:)`：集成了 `AccessibilityEngine.findScrollArea`，当鼠标悬停在窗口上时，自动识别并精准高亮其中的滚动区域。
- `enterScrollingState(with:)`：将选中区域（Flipped 坐标）转换为 SCK Display 坐标。
  - `convertToSCK()`：OverlayView Flipped → AppKit Global → SCK Global Top-Left。
  - 调用 `ContentRectDetector.axContentRectInPoints` 进行最终区域精调，确保只捕获纯净的内容区。
- 显示边框窗口标记捕获区域，显示 `ScrollingPreviewPanel` 实时预览。
- `finishScrolling()`：停止流，裁取最终图像，打开标注窗口。
- `cancel()`：停止流，关闭所有窗口。

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

1. **Accessibility 权限**：精准识别滚动区域依赖系统的辅助功能权限。如果未授予权限，应用将回退到普通矩形选择。

2. **非标准滚动控件**：对于未实现标准 Accessibility 协议的自定义滚动控件，识别可能不够精准。

3. **缓冲区大小**：当前固定 20000px，超长文档可能截断。

4. **内存使用**：20000px 高的 RGBA 缓冲区 ≈ 20000 × width × 4 字节。对于 1420px 宽的截图约 113 MB。

5. **累积误差**：Vision 帧间对齐的微小误差会随帧数累积，可能在长文档中表现为接缝。

6. **仅支持主显示器**：多显示器场景下 SCK ↔ Display 坐标转换可能不正确。

## 未来优化方向

- 动态扩展缓冲区支持任意长度
- 在上/下边界处做像素级融合，消除累积误差造成的接缝
- 支持双向滚动（先上后下或在中间任意位置开始）
- 添加重采样/压缩减少内存占用
