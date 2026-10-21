#!/bin/bash
# WorkBuddy 每日签到领积分（Buddy加油站 · 每日可领100通用积分）
# 原理：激活 WorkBuddy 客户端，模拟点击左下角「立即领取」按钮，截图供视觉核验。
# 输出：单行 JSON，字段见 SKILL.md
set -u

OUT_DIR="/tmp/workbuddy-checkin"
mkdir -p "$OUT_DIR"
TS=$(date +%Y%m%d-%H%M%S)
BUBBLE_SHOT="$OUT_DIR/bubble-$TS.png"
FULL_SHOT="$OUT_DIR/full-$TS.png"

json_out() { # status detail
  printf '{"status":"%s","detail":"%s","bubble_shot":"%s","full_shot":"%s","ts":"%s"}\n' \
    "$1" "$2" "$BUBBLE_SHOT" "$FULL_SHOT" "$TS"
}

# ---- Quartz 绕行流程（不依赖 System Events，只需屏幕录制+辅助功能权限） ----
# 2026-10-19 实测验证：TCC 自动化授权对命令宿主进程不生效(-10004)时的可用路径。
# 固定偏移（相对窗口左下角头像基准 AX=X+26, AY=Y+H-31）：
#   头像 (AX, AY) → 菜单「Buddy加油站」行 (X+140, AY-372) → 气泡「立即领取」(X+215, AY-62)
quartz_fallback() {
  open -a WorkBuddy
  sleep 5
  BOUNDS_PY=$(/usr/bin/python3 - <<'PY'
import Quartz, json
wl = Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionOnScreenOnly | Quartz.kCGWindowListExcludeDesktopElements, Quartz.kCGNullWindowID)
best = None
for w in wl:
    if 'WorkBuddy' in str(w.get('kCGWindowOwnerName','')):
        b = w.get('kCGWindowBounds')
        area = b['Width'] * b['Height']
        if best is None or area > best[0]:
            best = (area, b['X'], b['Y'], b['Width'], b['Height'])
if best:
    print(f"{best[1]:.0f} {best[2]:.0f} {best[3]:.0f} {best[4]:.0f}")
PY
)
  if [ -z "$BOUNDS_PY" ]; then
    json_out "failed" "Quartz绕行也无法读取 WorkBuddy 窗口（客户端可能未运行或被遮挡）"
    return
  fi
  X=$(echo "$BOUNDS_PY" | awk '{print $1}')
  Y=$(echo "$BOUNDS_PY" | awk '{print $2}')
  W=$(echo "$BOUNDS_PY" | awk '{print $3}')
  H=$(echo "$BOUNDS_PY" | awk '{print $4}')
  AX=$((X + 26)); AY=$((Y + H - 31))
  ROW_Y=$((AY - 372))    # 菜单「Buddy加油站」行
  CLAIM_Y=$((AY - 62))   # 气泡「立即领取」
  BOTTOM=$((Y + H))
  /usr/bin/python3 - "$X" "$BOTTOM" "$AX" "$AY" "$ROW_Y" "$CLAIM_Y" "$BUBBLE_SHOT" <<'PY'
import sys, time, Quartz, subprocess
X, BOTTOM, AX, AY, ROW_Y, CLAIM_Y, SHOT = [float(v) if i < 6 else v for i, v in enumerate(sys.argv[1:])]
def click(x, y, pre=0.15, post=0.06):
    mv = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, mv); time.sleep(pre)
    for t in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
        e = Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonLeft)
        Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(post)
# 1. 点头像打开菜单（动作紧凑，防 Chrome 等窗口抢前台）
click(AX, AY)
time.sleep(1.5)
# 2. 点菜单「Buddy加油站」行
click(X + 140, ROW_Y)
time.sleep(1.2)
# 3. 点气泡「立即领取」（点击前留证，点击后立即核验）
subprocess.run(['screencapture', '-x', '-R', f'{X:.0f},{CLAIM_Y - 210:.0f},520,340', SHOT + '.pre.png'])
click(X + 215, CLAIM_Y)
time.sleep(2)
subprocess.run(['screencapture', '-x', '-R', f'{X:.0f},{BOTTOM - 560:.0f},520,560', SHOT])
PY
  if [ ! -s "$BUBBLE_SHOT" ]; then
    screencapture -x "$FULL_SHOT" 2>/dev/null
    BUBBLE_SHOT=""
  fi
  [ -s "$FULL_SHOT" ] || FULL_SHOT=""
  json_out "clicked" "Quartz绕行流程已完成（头像→Buddy加油站→立即领取），核验截图见 bubble_shot（另有同名 .pre.png 为点击前留证），请确认出现「领取成功/今日已签到」"
}

# ---- 1. 辅助功能权限探测 ----
PERM_CHECK=$(osascript -e 'tell application "System Events" to tell process "WorkBuddy" to get name of front window' 2>&1)
if echo "$PERM_CHECK" | grep -q "权限违例\|not allowed assistive\|-10004\|-25211"; then
  # System Events 不可用时不再直接放弃，走 Quartz 绕行（2026-10-19 验证有效）
  quartz_fallback
  exit 0
fi

# ---- 2. 确保客户端运行并置于前台 ----
RUNNING=$(osascript -e 'tell application "System Events" to (name of processes) contains "WorkBuddy"' 2>/dev/null)
if [ "$RUNNING" != "true" ]; then
  open -a WorkBuddy
  sleep 8
fi
osascript -e 'tell application "WorkBuddy" to activate' 2>/dev/null
sleep 2

# ---- 3. 获取主窗口位置尺寸 ----
BOUNDS=$(osascript -e 'tell application "System Events" to tell process "WorkBuddy" to get {position, size} of window 1' 2>&1)
if ! echo "$BOUNDS" | grep -q ","; then
  # System Events 能探测但读不到窗口（TCC 部分生效），同样转 Quartz 绕行
  quartz_fallback
  exit 0
fi
X=$(echo "$BOUNDS" | awk -F', ' '{print $1}')
Y=$(echo "$BOUNDS" | awk -F', ' '{print $2}')
W=$(echo "$BOUNDS" | awk -F', ' '{print $3}')
H=$(echo "$BOUNDS" | awk -F', ' '{print $4}')

# ---- 4. 点击左下角签到气泡的「立即领取」按钮（2026-10-19 实测偏移：按钮中心 X+215, Y+H-93） ----
BX=$((X + 215))
BY=$((Y + H - 93))
/usr/bin/python3 - "$BX" "$BY" <<'PY'
import sys, time, Quartz
x, y = float(sys.argv[1]), float(sys.argv[2])
move = Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (x, y), Quartz.kCGMouseButtonLeft)
Quartz.CGEventPost(Quartz.kCGHIDEventTap, move); time.sleep(0.15)
for t in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp):
    e = Quartz.CGEventCreateMouseEvent(None, t, (x, y), Quartz.kCGMouseButtonLeft)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e); time.sleep(0.1)
PY
sleep 3

# ---- 5. 截图核验区（左下角气泡区域 + 全屏兜底） ----
screencapture -x -R "$X,$((Y + H - 160)),280,160" "$BUBBLE_SHOT" 2>/dev/null
if [ ! -s "$BUBBLE_SHOT" ]; then
  screencapture -x "$FULL_SHOT" 2>/dev/null
fi
[ -s "$BUBBLE_SHOT" ] || BUBBLE_SHOT=""
[ -s "$FULL_SHOT" ] || FULL_SHOT=""

json_out "clicked" "已在坐标($BX,$BY)点击「立即领取」，请用截图核验结果（今日已签到=已完成 / 领取成功=成功 / 无变化=失败，走头像菜单兜底流程）"
