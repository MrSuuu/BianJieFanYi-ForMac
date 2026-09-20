#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 SelectionPopupController.poll() 的**弹出判定 / 抑制判定 / 收窗判定**逐行复刻成纯函数，
用时序仿真跑全部历史场景（含每一轮踩过的坑）。

复刻严格对照 Sources/main.swift，注意三处易错的细节：
  1. "切 App" 分支**不 return**，收窗后继续往下走这一轮判定
  2. hidePopup() 会清 lastText 并 resetPending()
  3. 两道闸门都要满足"选字动作发生在当前这个 App 成为前台之后"
"""

SELECT_WINDOW = 2.0
SETTLE = 0.3
UNREADABLE_GRACE = 2.5

class S:
    def __init__(self):
        self.lastDragSelect = -1e9
        self.lastKeySelect = -1e9
        self.modifierHeld = False
        self.popupBundle = ""
        self.lastAppSwitch = -1e9
        self.lastFrontBundle = ""
        self.suppressText = ""
        self.suppressBundle = ""
        self.suppressAt = -1e9
        self.lastText = ""
        self.pendingText = None
        self.pendingSince = -1e9
        self.panelVisible = False
        self.selectedText = ""
        self.unreadableSince = None

    @property
    def lsa(self):
        return max(self.lastDragSelect, self.lastKeySelect)

def reset_pending(st):
    st.pendingText = None
    st.pendingSince = -1e9

def hide_popup(st):
    st.lastText = ""
    reset_pending(st)
    st.panelVisible = False

def hide_naturally(st, now):
    t = st.selectedText.strip()
    if t:
        st.suppressText = t
        st.suppressBundle = st.popupBundle or st.lastFrontBundle
        st.suppressAt = now
    hide_popup(st)

def drag(st, t):
    st.lastDragSelect = t

def shift_sel(st, t, held=True):          # Shift 按下或松开都算一次
    was = st.modifierHeld
    st.modifierHeld = held
    if held or was:
        st.lastKeySelect = t

def click(st, t):
    pass                                   # 单击：什么都不记

def dismiss(st, t):                        # 点浮窗的 X
    st.suppressText = st.selectedText
    st.suppressBundle = st.popupBundle or st.lastFrontBundle
    st.suppressAt = t
    hide_popup(st)

def poll(st, now, bid, trimmed):
    # ---- 切 App（注意：不 return）----
    if bid != st.lastFrontBundle:
        st.lastFrontBundle = bid
        st.lastAppSwitch = now
        if st.panelVisible:
            hide_naturally(st, now)

    # ---- 读数中断（读不到选区）----
    if not trimmed:
        since = st.unreadableSince if st.unreadableSince is not None else now
        st.unreadableSince = since
        if now - since > UNREADABLE_GRACE and st.panelVisible:
            hide_naturally(st, now)
        return "skip"
    st.unreadableSince = None

    if trimmed == st.lastText:
        return "skip"

    # ---- 解除抑制 ----
    if st.suppressText and bid == st.suppressBundle \
       and st.lsa > st.suppressAt + 0.5 and st.lsa > st.lastAppSwitch:
        st.suppressText = ""
        st.suppressBundle = ""

    # ---- 抑制检查 ----
    if trimmed == st.suppressText and bid == st.suppressBundle:
        return "suppressed"

    # ---- 两道闸门 ----
    mouse_sel = (now - st.lastDragSelect) < SELECT_WINDOW and st.lastDragSelect > st.lastAppSwitch
    key_sel = (st.modifierHeld or (now - st.lastKeySelect) < SELECT_WINDOW) \
              and st.lastKeySelect > st.lastAppSwitch
    if not mouse_sel and not key_sel:
        return "noGesture"
    if not mouse_sel and len(trimmed) < 2:
        return "skipTiny"

    # ---- 防抖 ----
    if trimmed != st.pendingText:
        st.pendingText = trimmed
        st.pendingSince = now
        return "pending"
    if now - st.pendingSince < SETTLE - 1e-9:      # 容差：真实轮询间隔 0.2s，不会踩边界
        return "skip"

    st.lastText = trimmed
    st.popupBundle = bid
    st.panelVisible = True
    st.selectedText = trimmed
    return "POPUP"


results = []
def case(name, got, want):
    ok = got == want
    results.append(ok)
    print(f"{'✅' if ok else '❌'} {name}\n     得到={got}  期望={want}")

def warm(st, bid="A"):
    poll(st, -1.0, bid, "")

def steps(st, *specs):
    """specs: (t, bid, text[, 动作])；动作 = drag/shift/click/dismiss"""
    out = []
    for sp in specs:
        t, bid, text = sp[0], sp[1], sp[2]
        act = sp[3] if len(sp) > 3 else None
        if act == "drag": drag(st, t)
        elif act == "shift": shift_sel(st, t)
        elif act == "click": click(st, t)
        elif act == "dismiss": dismiss(st, t)
        out.append(poll(st, t, bid, text))
    return out

print("=" * 52)
# ① QQ 点击会话：原生 App 把自己的 UI 状态报成 1 字符"选区"
st = S(); warm(st, "com.tencent.qq"); click(st, 0.0)
case("① QQ 点会话（单击 + 1字符伪选区）→ 不该弹",
     poll(st, 0.2, "com.tencent.qq", "x"), "noGesture")

# ② 正常拖动选字
st = S(); warm(st)
r = steps(st, (0.2, "A", "hello world", "drag"), (0.4, "A", "hello world"),
              (0.8, "A", "hello world"))
case("② 拖动选字 → 防抖后弹出", r, ["pending", "skip", "POPUP"])

# ③ 点 X → 切到 B → 切回 A（A 的选区还在）
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (1.0, "A", "hello", "dismiss"), (2.0, "B", ""))
case("③ 点X后切到B再切回A → 不该弹",
     poll(st, 3.0, "A", "hello"), "suppressed")

# ④ 没点 X，直接切 App（浮窗可见）
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (2.0, "B", ""))
case("④ 切App时浮窗可见 → 切回A → 不该弹",
     poll(st, 3.0, "A", "hello"), "suppressed")

# ⑤ 在 B 里选过字，1 秒内切回 A ← 新增 lastAppSwitch 限定针对的就是它
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (2.0, "B", ""),
         (2.6, "B", "world", "drag"), (2.8, "B", "world"), (3.0, "B", "world"))
case("⑤ 在B里选字后立刻切回A → 不该弹",
     poll(st, 3.2, "A", "hello"), "noGesture")

# ⑥ 抑制之后在同一个 App 里重新拖选同一段 → 应该弹
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (1.0, "A", "hello", "dismiss"),
         (2.0, "B", ""), (3.0, "A", "hello"))       # 确认被抑制
r = steps(st, (4.0, "A", "hello", "drag"), (4.2, "A", "hello"), (4.6, "A", "hello"))
case("⑥ 抑制后在本App重选同一段 → 应该弹", r, ["pending", "skip", "POPUP"])

# ⑦ 键盘选字（Shift+方向键，5 字符）
st = S(); warm(st)
r = steps(st, (0.3, "A", "hello", "shift"), (0.5, "A", "hello"), (0.9, "A", "hello"))
case("⑦ 键盘 Shift 选 5 字符 → 弹出", r, ["pending", "skip", "POPUP"])

# ⑧ 键盘只选中 1 个字符 → 挡住
st = S(); warm(st); shift_sel(st, 0.3)
case("⑧ 键盘只选 1 个字符 → 不该弹",
     poll(st, 0.5, "A", "x"), "skipTiny")

# ⑨ 跨 App：在 A 忽略过的文字，到 B 里选中照样该弹
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (1.0, "A", "hello", "dismiss"), (2.0, "B", ""))
r = steps(st, (2.6, "B", "hello", "drag"), (2.8, "B", "hello"), (3.2, "B", "hello"))
case("⑨ 在A忽略过的文字，到B里选中 → 应该弹", r, ["pending", "skip", "POPUP"])

# ⑩ 悬停阅读：选中后长期不动，轮询一直读到同一段 → 浮窗必须保留
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"))
case("⑩ 选中后读译文 30 秒不动 → 浮窗保留",
     poll(st, 30.0, "A", "hello"), "skip")

# ⑪ 闪断：浏览器重建无障碍树，空一拍又恢复 → 不能收窗
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (1.0, "A", ""), (1.2, "A", ""))              # 闪断两拍
case("⑪ 闪断两拍（<2.5s）→ 浮窗不该被收 + 恢复后仍可用",
     (st.panelVisible, poll(st, 1.6, "A", "hello")), (True, "skip"))

# ⑫ 真正的读数中断（>2.5s 读不到）→ 应该收窗
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (1.0, "A", ""), (2.0, "A", ""), (4.0, "A", ""))
case("⑫ 连续 2.5s 以上读不到选区 → 收窗",
     st.panelVisible, False)

# ⑬ 切 App 到 B 后，在 B 里拖选文字 → 新 App 里必须能正常弹
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"),
         (2.0, "B", ""))
r = steps(st, (2.6, "B", "world", "drag"), (2.8, "B", "world"), (3.2, "B", "world"))
case("⑬ 切到B后在新App里拖选 → 应该弹", r, ["pending", "skip", "POPUP"])

# ⑭ 选中后不动 → 单靠"选区还在"应保留（用户可能正在读）
st = S(); warm(st)
steps(st, (0.2, "A", "hello", "drag"), (0.4, "A", "hello"), (0.8, "A", "hello"))
case("⑭ 选区仍在时，时间再久也不该自己消失",
     poll(st, 120.0, "A", "hello"), "skip")

print("=" * 52)
print(f"通过 {sum(results)}/{len(results)}")
