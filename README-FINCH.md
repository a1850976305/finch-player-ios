# Finch Player for iOS — 基于 Yingxia 的自有壳（v1 起步包）

你提需求、我来实现：这个包就是第一步的成果。你不用写代码、不用装 Xcode、不用在本地编。
你只需要在手机上做两件账号相关的事（下面第 1、4 步），其余构建、改名、打包都由云 Mac 和这个包里的工作流完成。

## 这是什么

- 底座：jo32/tvbox-silicon（Yingxia），原生 SwiftUI 的 TVBox 播放器，GPL-3.0。
  本包不复制 Yingxia 的全部代码，构建时才从上游克隆它，再套上 Finch 的改名补丁。
  所以这个包很小，上传到 GitHub 也方便。
- 可见名字：Finch Player（只改显示名和 iOS Bundle ID，不改内部的 yingxia:// 链接和
  _yingxia._tcp 发现标识，避免改坏跨设备传送和登录回跳）。
- iOS Bundle ID（改后）：com.finch.player.ios（原：com.jo32.yingxia.ios）
- 协议：Yingxia 原代码 GPL-3.0，LICENSE 和第三方声明要保留。自己用没问题；
  以后要是把改过的版本发给别人，按 GPL 得同样提供源码。

## 手机上要做的事（只有这些）

1. 在手机浏览器上建一个 GitHub 仓库，名字建议 finch-player-ios，把这个包里的
   所有文件原样传上去（GitHub 网页上传即可，不用 git 命令）。
2. 打开这个包里的 subscription/finch-subscription.json，把里面的
   `REPLACE_ME` 换成你第 1 步那个仓库的 GitHub 用户名（网页上直接点文件、点编辑就能改）。
   改完之后，Py 源的 raw 地址才真正指向你的仓库。
3. 到仓库的 Actions 页，点 run workflow，选 ios.yml，跑一次云编译。
   第一次跑就是测试：云 Mac 上缺工具、Xcode 版本不对、签名不对，都会在日志里露出来，
   把日志发给我，我按日志修工作流，不用你自己调。
4. 编译成功后，在 Actions 的 Artifacts 里下载 FinchPlayer-unsigned.ipa，
   用你习惯的侧载工具装到 iPhone 上（免费 Apple ID 一般 7 天续签一次；
   有开发者账号的话，改成签名后走 TestFlight 会顺得多，那一步也得你本人在苹果侧操作）。
5. 装好后，在 App 里导入订阅，地址就是你仓库里
   subscription/finch-subscription.json 的 raw 地址：
   https://raw.githubusercontent.com/<你的用户名>/finch-player-ios/main/subscription/finch-subscription.json
   先测 17RIP，再测 MissAVt、低端，按这个顺序报结果。

## 默认源状态（老实写，不夸大）

见 SOURCES-STATUS.md。简单说：

- Py 文件现成的有 3 个：17RIP、低端、MissAVt，都是你在 Hawk 里验证过的原文件，
  本包原样复制，没有改解析逻辑。
- JAVDAY、18JAV 没有 Hawk Py 文件，只有 AIBOX JS 和 Dreamby JS，
  本包没有凭空编一个 TVBox Py/JS 文件给它们，订阅里先不放它们，
  等 TVBox 格式转换做完再加。不要把“默认 5 个”理解成“5 个都已能装”。
- Py 在 iPhone 真机上的情况：Yingxia 官方 README 现在写的是 Python 只在 Mac 上，
  iOS 内嵌 Python 在计划里做、模拟器上测过，真机还没测。
  所以这 3 个 Py 源在真机上第一次装，可能会提示“需要 Python 运行时，本平台不可用”，
  那不是订阅写错了，是 Yingxia 这边还没正式放出来。真机上先能跑的会是
  JS、JAR、CMS 这类源，Py 那条线要等上游正式版或模拟器之外的实测。

## 文件说明

- .github/workflows/ios.yml — 云 Mac 编 iOS 的流程（本包新增，上游原来没有）。
- patch/apply-finch.sh — 构建时自动跑的改名脚本，你不用手动跑。
- subscription/finch-subscription.json — 默认订阅（3 个 Py 源，见上）。
- sources/*.py — 上面 3 个 Py 源的原文件。
- SOURCES-STATUS.md — 5 个默认源逐个的状态。
- LICENSE-NOTE.md — 协议说明。
