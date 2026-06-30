# LiveActivityDemo — 调试工具说明

本目录包含两套调试工具，均可独立使用：

| 工具 | 路径 | 适用场景 |
|---|---|---|
| **后端服务器** | `server/` | 主推荐，有 Dashboard，一键 start/update/end |
| **push.sh** | `push.sh` | 轻量，无服务器，手动粘贴 token 直接推 |

---

## 整体架构

### Token 三兄弟

| token | 来源 | 用途 |
|---|---|---|
| `device_token` | `didRegisterForRemoteNotificationsWithDeviceToken` | 发 silent push 唤醒 App |
| `push_to_start_token` | `Activity<>.pushToStartTokenUpdates` 流 | `event=start`，App 没运行也能创建 LA |
| `activity_token` | `activity.pushTokenUpdates` 流 | `event=update` / `event=end`，操作已有 LA |

> `push_to_start_token` 和 `activity_token` 都会定期轮换，App 端循环监听并实时上报到服务器。

### 活动完整生命周期

```
[创建] push-to-start token → APNs event=start
         └─ 设备系统创建 Activity
              ├─ App 在前台：activityUpdates 流触发 → reconcile() → observe() → 上报 activity_token
              └─ App 在后台/被杀：
                   device_token → APNs silent push → 唤醒 App ~30s
                   → didReceiveRemoteNotification → reconcile() → observe() → 上报 activity_token

[更新] activity_token → APNs event=update → 系统直接刷新 LA（App 无需运行）

[结束] activity_token → APNs event=end   → 系统结束 LA，60s 后消失
     或 App 内调用 LiveActivityUtils.end() → 立即消失 + 通知服务器清理 token
```

---

## 方式一：后端服务器（推荐）

### 启动

```bash
cd demo-tools/server
./run.sh
```

浏览器打开 `http://<Mac局域网IP>:8000`，Dashboard 自动每 3s 刷新状态。

> 真机调试需把 `Info.plist` 里 `LADemoServerBaseURL` 改成 Mac 的局域网 IP，例如 `http://192.168.0.233:8000`。

### Dashboard 操作流程

```
1. 打开 App（真机）→ device_token 和 push_to_start_token 自动出现在 Dashboard

2. 点 [start]
   → 后端发 event=start 到 push_to_start_token，设备创建 LA
   → 200 成功后自动跟发 silent push 唤醒 App
   → App 上报 activity_token，Dashboard 约 30s 内刷出

3. 输入比分/时间，点 [update]
   → 后端发 event=update 到 activity_token，LA 实时刷新

4. 点 [end]
   → 后端发 event=end 到 activity_token，LA 消失
   → 服务器自动清除 activity_token

5. [silent] 按钮：手动唤醒 App（正常 start 流程无需手动点）
```

### API 端点一览

```
POST /api/push/start              发 event=start，成功后自动跟发 silent
POST /api/push/update  {home, away, minute, alert?}
POST /api/push/end     {home?, away?}
POST /api/push/silent             手动发 silent push

POST /api/tokens/device           {token}
POST /api/tokens/push-to-start    {token}
POST /api/tokens/activity         {activity_id, token, match_id?}
POST /api/tokens/activity/clear   {activity_id?}

GET  /api/state                   查看当前 token + 事件日志
GET  /                            Dashboard
```

---

## 方式二：push.sh（无服务器手动模式）

### 一次性准备

**APNs Auth Key（.p8）**

在 [Apple Developer → Certificates, Identifiers & Profiles → Keys](https://developer.apple.com/account/resources/authkeys/list) 申请一个勾选 **Apple Push Notifications service (APNs)** 的 Key，下载 `.p8`，记下 10 位 Key ID。

```bash
mkdir -p ~/.apns
mv ~/Downloads/AuthKey_<KEY_ID>.p8 ~/.apns/
chmod 600 ~/.apns/AuthKey_<KEY_ID>.p8
```

**脚本顶部 4 个值**（也可 `export` 覆盖）：

```bash
TEAM_ID="TG5E95RU8K"
KEY_ID="9TLPL9K79A"
AUTH_KEY="$HOME/.apns/AuthKey_${KEY_ID}.p8"
BUNDLE_ID="com.zhu.LiveActivityDemo"
APNS_HOST="api.development.push.apple.com"   # 上线/TF 用 api.push.apple.com
```

### 命令格式

```bash
./push.sh <token> <event> [home] [away] [minute]
```

### 手动调试完整流程
  1. Xcode 重新 Build & Run（安装到真机）                                                                                                                                                                
  2. App 装好后，按 Home 键退到后台（不要强制 kill）
  3. 发 push-to-start：./push.sh <push-to-start-token> start ...                                                                                                                                         
  4. 发 silent push：./push.sh <device-token> silent                                                                                                                                                     
  5. idevicesyslog 里按顺序应能看到：                                                                                                                                                                    
    - [LA] didReceiveRemoteNotification userInfo:                                                                                                                                                        
    - [LA] reconcile: 1 activities found                                                                                                                                                                 
    - [LA] observe id=...                                                                                                                                                                                
    - [LA] activity push token ... token=...                                                                                                                                                                                     
```bash
# Step 1 真机启动 App，从 Xcode 控制台拿三类 token

# Step 2 创建 LA（App 可以是被杀状态）
./push.sh 80fef09973eeea965cae5cc2483082d345fb9598370e24bca29608b39fabc9bed1cc134fdaf3d00aa202013f2b13ba4b264e26c280e2f7af23de88dc825a2ddaa8a2c82525adf12b546929e6be542388 start 0 0 "0'"

# Step 3 唤醒 App 拿 activity_token（控制台看到 "activity push token: ..."）
./push.sh b6d6010590a5f9252b528de684fe9fbab6848c052a1a96bf726f627600df083e silent

# Step 4 更新比分（用 Step 3 拿到的 activity_token）
./push.sh 80927e38180638a25ad8407cf845bc5fa9d0c45148f7ce73f27497c5f4db6a33342430e06c3fbff17574221914cc1678898837f76344fbb5c6de57636caa8b5db55338bf2c8b8d15a8f59a8aab006754 update 1 0 "45'"

# Step 5 结束
./push.sh 80927e38180638a25ad8407cf845bc5fa9d0c45148f7ce73f27497c5f4db6a33342430e06c3fbff17574221914cc1678898837f76344fbb5c6de57636caa8b5db55338bf2c8b8d15a8f59a8aab006754 end
```

### 三类 token 速查

| event | 用哪个 token | 打印时机 |
|---|---|---|
| `start` | push-to-start token | App 一启动就打印 |
| `update` / `end` | activity push token | 开启 LA 后打印，每次轮换重新打印 |
| `silent` | device token | App 一启动就打印 |

> ⚠️ activity push token 约 96 字节 hex，push-to-start token 更长，别用错。

---

## 查看真机日志

```bash
# 过滤 App + Widget Extension 日志
idevicesyslog | grep -E "LiveActivityDemo|MyWidgetExtension"

# 或用 macOS 控制台.app，按 subsystem 过滤：
# com.zhu.LiveActivityDemo
```

关键日志关键词：

| 日志关键词 | 含义 |
|---|---|
| `push-to-start token:` | p2s token 刷新 |
| `activityUpdates: new activity` | 前台时系统创建了新 LA |
| `reconcile:` | 启动/silent push 触发了收敛 |
| `observe id=` | 开始监听某个 Activity |
| `activity push token id=` | activity token 拿到并上报 |
| `state id= → ended/dismissed` | LA 结束，触发服务器清理 |
| `sync activity → 200` | token 上报服务器成功 |

---

## APNs 响应码速查

| HTTP | 原因 | 处理 |
|---|---|---|
| 200 | 成功 | — |
| 400 `BadDeviceToken` | token 错 / 环境不匹配 | 检查 token；debug 包对应 development host |
| 400 `TopicDisallowed` | apns-topic 错 | LA 推送必须是 `<BundleID>.push-type.liveactivity` |
| 400 `BadCertificateEnvironment` | JWT 环境不对 | TestFlight/App Store 包用 `api.push.apple.com` |
| 403 `InvalidProviderToken` | JWT 签名错 | KEY_ID 和 .p8 不匹配，或 TEAM_ID 错 |
| 410 `Unregistered` | token 已失效 | 重启 App 拿新 token；服务器收到 410 会自动清理 activity_token |

---

## 常见问题

**Q: start 发出去 LA 创建了，但 activity_token 没上来**

- App 被杀时：silent push 需要 ~30s 才能唤醒 App。服务器在 start 后会自动跟发 silent，耐心等待。
- App 在前台时：`activityUpdates` 流触发，应立即上报。若没上报，检查 `observeNewActivities()` 是否在 `didFinishLaunching` 调用。

**Q: 队徽显示空白**

push-to-start 创建 LA 时 App 没有运行，`TeamBadgeCache` 没有提前下载图片。推一条 update 或打开一次 App 后自动恢复。

**Q: 更新/结束发出 200 但手机没反应**

大概率是用了已失效的 activity_token（上一次 LA 的 token）。从 Dashboard 或 Xcode 控制台确认最新 token。

**Q: 实时活动更新很慢**

检查 iPhone 设置 → 通知 → LiveActivityDemo → **更频繁的实时活动更新** 是否已开启（需 `NSSupportsLiveActivitiesFrequentUpdates = YES`）。未开启时系统会对推送频率做较严格的节流。
