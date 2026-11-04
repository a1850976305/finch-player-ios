# 默认源状态（2026-11-04，起步包 v1）

“默认名字和源”指的是：名字 Finch Player，首批 5 个站 17RIP、低端影视、
MissAVt、JAVDAY、18JAV。但这 5 个在 Yingxia iOS 上的就绪程度不一样，
下面逐个写清楚，不要把“列在默认清单里”当成“都已能装能播”。

| 站 | 本包里的形态 | 在 Hawk/AIBOX/Dreamby 的验证 | 在 Yingxia iOS 上的状态 |
|---|---|---|---|
| 17RIP | Py，sources/finch_17rip_drpy.py，原文件未改 | Hawk 确认可用；AIBOX 确认可用 | 订阅里已放（type 3）。真机 Py 运行时待上游正式版，见下 |
| 低端影视 | Py，sources/ddys_drpy.py，原文件未改（文件名本身就是 ddys_drpy.py） | Hawk/Dreamby/AIBOX 都确认可用；VM 网络下曾 403，需用户网络复测 | 订阅里已放（type 3），同上 |
| MissAVt | Py，sources/finch_missavt_drpy.py，原文件未改 | Hawk/AIBOX 确认可用 | 订阅里已放（type 3），同上 |
| JAVDAY | 无 Py 文件 | AIBOX JS、Dreamby JS 确认可用；Rex 确认可用 | 订阅里未放。没有凭空编 TVBox Py/JS，等 TVBox 格式转换 |
| 18JAV | 无 Py 文件 | AIBOX JS、Dreamby JS 确认可用；Rex 确认可用 | 订阅里未放，同上 |

## Py 在 iPhone 真机上为什么要单独说明

Yingxia README 现在写的是 Python 只在 Mac 上；iOS 内嵌 Python 在计划里做，
模拟器上测过、真机还没测。所以上面 3 个 Py 源在真机上第一次导入时，
如果 App 提示“需要 Python 运行时，本平台不可用”，那是上游还没正式放出，
不是订阅 JSON 写错了，也不是 Py 文件坏了。先用 JS、JAR、CMS 这类
真机已跑的源顶着，Py 那条线等上游正式版或真机实测后再开。

## 订阅格式说明

subscription/finch-subscription.json 里每个站的写法，跟你以前低端那个
TVBox 示例配置一致：sites 数组里 name、key、type、api、searchable、
quickSearch。Py 站的 type 是 3，api 是 Py 文件的 raw 地址。
api 里的 REPLACE_ME 必须换成你自己的 GitHub 用户名，否则 raw 地址是错的。
