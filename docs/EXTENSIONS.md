# 扩展接口 v1

`LumaUI` 是唯一导出的 Lua 命名空间。扩展插件在自己的 TOC 中声明 `## Dependencies: LumaUI`。模块应使用独立实现和游戏公开 API，不能依赖其他 UI 套件的内部对象。

## 注册组件

```lua
local app = LumaUI
local component = app:RegisterComponent({
    id = "encounterNotes",
    label = "Encounter notes",
    defaultEnabled = false,
    requires = {},
    Supported = function(self, capabilities)
        return capabilities.retail
    end,
    Enable = function(self)
        self.frame = self.frame or CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
        self.frame:SetSize(280, 90)
        app.Layout:Register("encounterNotes", self.frame, 0, 180, "Encounter notes")
        app.Theme:PaintSurface(self.frame, "window")
        self.title = self.title or app.Theme:TextRole(self.frame, "label")
        self.title:SetPoint("TOPLEFT", app.Theme:Space("md"), -app.Theme:Space("sm"))
        self.title:SetText("Encounter notes")
        self.frame:Show()
        self:Listen("PLAYER_ENTERING_WORLD", function(owner)
            -- Refresh only information available through the public API.
        end)
    end,
    Refresh = function(self)
        app.Theme:PaintSurface(self.frame, "window")
    end,
    Disable = function(self)
        if self.frame then self.frame:Hide() end
    end,
})
```

`id` 必须唯一且匹配 `^[%a][%w_]*$`。开关按配置方案保存；未加载的扩展开关也会保留。`requires` 中列出的组件必须已注册且启用。依赖未满足、能力缺失或启用失败时，诊断会显示相应状态，其他组件继续运行。

运行时增加组件会立即重新协调，组件页会在下次刷新时补充开关；建议在 `PLAYER_LOGIN` 前注册。扩展的复杂数据目前由扩展自己的 SavedVariables 保存；核心 v1 只管理开关、统一外观和位置。不要直接写 `Store.data`。

## 生命周期与资源

| 方法 | 契约 |
| --- | --- |
| `Enable(self)` | 在非战斗时创建或恢复自己的框体，可以再次调用 |
| `Refresh(self)` | 将当前配置应用到自己的框体，不重复分配永久对象 |
| `Disable(self)` | 隐藏自己的框体，撤销自有资源；即使启用只完成一半也应安全 |
| `self:Listen(event, fn, unit?)` | 回调签名 `fn(self, event, ...)`；一个组件每种事件只有一个处理器 |
| `self:Every(seconds, fn)` | 回调签名 `fn(self)`；停用自动取消，避免空闲逐帧工作 |
| `app:Subscribe(owner, message, fn)` | 同一 owner 与 message 最多一个订阅，组件停用自动解除 |
| `app.Queue:Run(key, fn)` | 非战斗立即执行，战斗中同 key 的最新任务覆盖旧任务；非战斗不代表能绕过其他游戏限制 |
| `app.Layout:Register(id, frame, x, y, label, scale?)` | 独立布局项：位置按框体自身坐标保存，框体可复用；受保护对象必须仅在非战斗时注册或布局 |
| `app.Layout:RegisterGroup(id, frame?, x, y, label)` / `EnsureGroup` | 组容器作为一项列出；容器可以自己创建，也可由扩展提供 |
| `app.Layout:Join(groupId, id, frame, defaultX, defaultY, spec)` | 把框体加入组：成员随组移动/缩放、不单独列出；旧绝对位置会一次性转换为相对偏移；战斗中拒绝 |
| `app.Layout:SetEntryDefault(id, x, y)` / `SetGroupSize(id, w, h)` | 更新默认中心或组尺寸；不要直接写 `Layout.entries` |
| `app.Layout:RegisterPlaceholder(id, label, x, y, width, height)` | 预留第三方区域：只在布局编辑时显示轮廓，不接管任何外部框体 |
| `app.Layout:PreviewPreset(name)` / `ApplyPreset(name)` / `CancelPresetPreview()` / `UndoPreset()` | 16:9 预设：预览只画轮廓；应用显式写入当前方案并保存快照；撤销恢复快照 |

统一外观从 `app.Theme` 获取，只有自己的窗口可使用 `app.Transitions`。动画只作用于自有表现对象，生命、资源、冷却等战斗信息应立即显示。

### 过渡契约（0.15.0）

| 接口 | 用途 |
| --- | --- |
| `app.Transitions:Fade(owner, frame, toAlpha, duration, onDone?, channel?)` | 从当前 alpha 淡入/淡出；`owner` 与 `channel` 决定替换关系 |
| `app.Transitions:Animate(owner, channel, { from, to, duration, apply(value, progress), onDone })` | 数值/装饰颜色插值；只用于非战斗装饰 |
| `app.Transitions:Settle(owner[, channel])` / `SettleAll()` | 立即到终态并各触发一次 `onDone(true)`；停用、隐藏、切配置时调用 |
| `app.Transitions:Cancel(owner[, channel])` | 丢弃任务、不改画面、不触发回调；用于已被替换的意图 |
| `app.Transitions:Reveal(frame)` | 旧的一次性淡入适配器，保留兼容 |
| `app.Transitions:Count()` / `HasDriver()` / `MotionEnabled()` | 诊断与测试用 |

同一 `owner`+`channel` 同时只有一个任务：新请求从当前值接续并让旧请求的完成回调永远失效。被替换的请求不触发回调；`Settle` 会触发一次。关闭“窗口过渡”或启用减少动态效果时，请求会立即落定而不是排队。`IsForbidden()` 为真的框体不会被写入 alpha 或创建动画组；不要把受保护框体交给过渡系统，也不要用过渡延迟战斗数值。

### 控件（0.15.0）

| 接口 | 用途 |
| --- | --- |
| `app.Controls:Button(parent, text, width, callback, options?)` | 普通按钮；`options.kind = "primary"` 为主操作，`options.mutedWhenIdle` 让未选中时文字变次要色 |
| `app.Controls:Navigation(parent, text, width, callback)` / `Controls:Tab(...)` | 导航/页签，选中状态由 `SetSelected` 控制 |
| `app.Controls:Toggle(parent, text, y, getter, setter)` | 开关行（真实轨道与滑块），保留旧签名与 `Update(component)` |
| `app.Controls:Input(parent, width)` | 输入框；`SetValidator(fn)`、`IsValid()`、`Validate()`、`SetValidateHandler(fn)` |
| `app.Controls:Range(parent, title, y, low, high, step, getter, setter)` | 滑条行：拖动只更新标签，松开或滚轮才提交 |
| `app.Controls:FoldHeader(parent, text, width, onToggle)` | 折叠头，`SetFolded(boolean)` |
| `app.Controls:Scroll(parent, width, height)` | 滚动区 + 自绘滚动条；内容高度变化后调用 `scroll:UpdateRange()` |

所有控件都有 `Refresh`、`SetSelected`、`SetFocusState`、`SetEnabled`、`IsEnabled`，外观由 `hover/pressed/selected/disabled/focus` 共同解析，不要在外部直接 `SetBackdrop*` 覆盖状态。回调经框架隔离调用，异常只进入诊断而不破坏整页。旧的按钮/开关/滑条/输入调用签名保持可用。

### 表面与文字角色（0.15.0）

| 接口 | 用途 |
| --- | --- |
| `app.Theme:PaintSurface(frame, role)` | 按语义角色绘制背景：`window`、`embedded`（窗口内嵌区，无边框）、`button`、`hud`（低不透明度承托）、`chat`、`chatActive`。细边按当前有效缩放的物理像素计算，不要自己写 `edgeSize = 1` |
| `app.Theme:TextRole(parent, role)` | 语义文字：`title`、`body`、`label`、`value`、`muted`；对齐、宽度与换行仍由调用方决定 |
| `app.Theme:Space(name)` | 间距刻度 `xs/sm/md/lg/xl`（4/8/12/20/28） |
| `app.Theme:Opacity(token)` | 读取语义透明度（`windowOpacity`、`hudOpacity`、`chatOpacity`、`chatActiveOpacity`），未知 token 回退旧 `opacity` |
| `app.Pixel:Pixels(n)` / `app.Pixel:Unit()` | 物理像素换算；不要修改 `UIParent` 的缩放来获得细边 |

旧接口 `Theme:Panel(frame, raised)`、`Theme:Surface(frame, raised)`、`Theme:Text(parent, size, muted)` 保持可用并继续跟随旧 `appearance.opacity`，未迁移的模块不需要一次改完。不要通过 `Store.data` 写透明度；扩展自己的外观值应放在自己的 SavedVariables。

`app.Capabilities.Plain(value, expectedType)` 返回非秘密且类型正确的值，否则返回 nil。`pcall` 不会把秘密值变成普通值。需要显示秘密数值时，必须使用游戏允许的原生绘制 API；不能计算、拼接、比较、作为表键或保存。

`app.Capabilities.Snapshot()` 提供 `retail`、`containers`、`containerActions`、`containerSort`、`units`、`cast`、`auras`、`raidTargets`、`namePlates`、`taskTime`、`questItems`、`itemIcon`、`settings`、`privateAuras` 等能力快照。扩展应把缺失能力视为降级条件，而不是假定界面已在该客户端验收。

## 战斗组件接入顺序

先做公开能力探测和普通数据模型，再做安全框体初始化、战斗事件绘制和非战斗配置队列。单位交互使用安全模板及状态驱动；不能在事件里用普通 Lua 改受保护属性。私有光环只交给客户端锚点绘制，不读取其内容。接管原生单位、队伍或光环框体前，必须完成对等能力和私有光环验收。

`PROFILE_CHANGED` 表示配置意图更新；若发生在战斗中，实际框体可能尚未变化。`RUNTIME_UPDATED` 表示本轮协调完成。不要在这两个回调里无条件再次调用 `Reconcile`，以免形成循环。
