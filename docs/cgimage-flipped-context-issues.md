# CGImage 翻转上下文拼接问题总结

## 背景

`StitchingEngine.finalize()` 负责将三部分（header chrome + 滚动内容 + footer chrome）合成为最终图片。合成上下文为 flipped 状态（`translateBy` + `scaleBy(x:1, y:-1)`）。

## 问题 1：标题栏/底栏上下颠倒

**现象**：header 和 footer 在拼接结果中是 180° 翻转的，但滚动内容显示正常。

**根因**：

- 滚动内容来自 buffer（flipped 上下文的 `makeImage()`）→ 经历一次翻转
- 再画入 `finalize()` 的 flipped 上下文 → 经历第二次翻转
- `makeImage()` 时再翻转一次 → 三次翻转、最终正确

- header/footer 直接从 raw frame crop → 未翻转
- 画入 flipped 上下文 → 一次翻转
- `makeImage()` 时再翻转 → 两次翻转、朝向颠倒

**解决**：在画入 header/footer 之前，通过 `flipImageVertically()` 预翻转一次，使其与 content 路径翻转次数对齐。

---

## 问题 2：标题栏在图片底部

**现象**：翻转问题解决后，header 出现在图片最底部而非最顶部。

**根因**：`makeImage()` 在 flipped 上下文中的行为认知有误。

经诊断确认：flipped 上下文的 `makeImage()` 产生的 CGImage，**row 索引 = user-space y 值**。即：

```
user y = 0        → CGImage row 0  → 图片显示时的最顶部
user y = totalH   → CGImage row 尾部 → 图片显示时的最底部
```

原代码图层顺序（自底向上）：

```
footer  @ user y = 0                    → CGImage row 0   → 显示顶部  ❌
content @ user y = footerH
header  @ user y = footerH + contentH   → CGImage 尾部     → 显示底部  ❌
```

**解决**：改为自顶向下：

```
header  @ user y = 0                    → CGImage row 0   → 显示顶部  ✅
content @ user y = headerH
footer  @ user y = headerH + contentH   → CGImage 尾部     → 显示底部  ✅
```

---

## 核心认知

`CGContext.makeImage()` 的行为依赖 CTM：

| CTM 状态 | `makeImage()` CGImage row 0 对应 |
|---|---|
| unflipped（默认） | device row 0（buffer 底部） |
| flipped（translateBy + scaleBy(-1)） | user-space y = 0（即视觉顶部） |

---

## 涉及文件

- `TermSnap/Screenshot/StitchingEngine.swift` — `finalize()` 图层顺序 + 预翻转逻辑
- `TermSnapTests/StitchingEngineTests.swift` — `testFinalizeCompositeOrientation` 断言修正
