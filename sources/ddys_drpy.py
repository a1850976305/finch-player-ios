# -*- coding: utf-8 -*-
"""
低端影视 —— dr_py 版候选源（按 LibriVox / NASA / IA 三个可正常使用的源的格式重写）
目标站：https://m.ddys.net
形态：服务端渲染静态 HTML 站，非空壳 JS 应用
  首页      /
  频道      /class/{频道ID}.html，分页 /class/{频道ID}-{页码}.html
  详情      /html/{影片ID}.html
  播放页    /play/{影片ID}/{线路}/{集数}.html
  搜索      /so/{URL编码关键词}-------------.html
  排行榜    /label/top.html，分榜 /label/top{dy,ds,dm,zy}.html
  播放层    播放页 -> 同站 /static/player/artplayer.html?url=<m3u8 形态>，
            点 Play 前已在 iframe 属性中，未在本机实测解码与可播性。
注意：这是 dr_py 签名，不是上一版 TVBox BaseSpider 签名。
  旧版问题：class BaseSpider、homeContent 返回嵌套 [[...]]、searchContent 签名是 (key, quick, pg)、
  playerContent 的 header 是字符串、detail 的 vod_id 是完整路径，这些在 dr_py 环境里都对不上。
  本版按三个 OK 源统一改成：from base.spider import Spider、class Spider(Spider)、
  homeContent(filter=False)、categoryContent(tid, pg, filter=False, content=None)、
  detailContent(ids 四态兼容)、searchContent(key, pg, filter=False)、
  playerContent(flag, id, vipFlags=None)、header 用 dict、vod_play_url 用 # 分隔集、$$$ 分隔线路。
实测状态：只做了 py_compile，未在可稳定访问本站的网络上做 L2/L3 实测，
  播放层 url 参数是否需要二次解码、是否需要补头，仍未验证。不要宣称已验证可播。
"""

import re
import time
from urllib.parse import quote, unquote, urljoin, urlparse, parse_qs

import requests
from base.spider import Spider


class Spider(Spider):
    name = "Finch·低端影视"
    host = "https://m.ddys.net"
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "Referer": "https://m.ddys.net/",
    }
    timeout = 20
    limit = 20
    # 频道 ID 已验证，注意短剧是 26，不是顺序编号。
    classes = [
        {"type_name": "电影", "type_id": "1"},
        {"type_name": "连续剧", "type_id": "2"},
        {"type_name": "短剧", "type_id": "26"},
        {"type_name": "综艺", "type_id": "3"},
        {"type_name": "动漫", "type_id": "4"},
    ]

    # ---------- 工具 ----------
    def _get(self, path):
        # 先开首页建立会话，再走站内链接，不要冷启动直打深链。
        # dr_py 环境用 requests，本机直接抓曾被 403，实测需在可稳定访问本站的网络上做。
        url = path if path.startswith("http") else urljoin(self.host + "/", path.lstrip("/"))
        for attempt in range(3):
            try:
                r = requests.get(url, headers=self.headers, timeout=self.timeout)
                r.encoding = "utf-8"
                return r.text
            except Exception:
                if attempt < 2:
                    time.sleep(0.5 * (attempt + 1))
        return ""

    @staticmethod
    def _clean(text):
        text = re.sub(r"<[^>]+>", " ", text or "")
        import html as html_lib
        text = html_lib.unescape(text)
        return re.sub(r"\s+", " ", text).strip()

    @staticmethod
    def _pic_from_inner(inner):
        # 封面 <a> 里通常是 <img>：优先懒加载属性，再看 src；过滤欢迎/占位图
        for attr in ("data-original", "data-src", "src"):
            m = re.search(r'<img[^>]+' + attr + r'="([^"]+)"', inner or "", re.S)
            if m:
                u = m.group(1).strip()
                if u and "welcome" not in u and "loading" not in u and "placeholder" not in u:
                    if u.startswith("//"):
                        return "https:" + u
                    if u.startswith("/"):
                        return "https://m.ddys.net" + u
                    return u
        return ""

    @staticmethod
    def _pic_from_segment(segment):
        # 一段列表项 HTML 里找封面，取离标题最近、且不是占位图的那张。
        # 覆盖：img 的 data-original/data-src/data-lazy/src/srcset、<source> srcset、
        # background-image、data-bg，以及 data-pic/data-cover/data-image/data-poster、
        # 脚本里的 "pic"/"cover"/"vod_pic" 字段。相对路径一律补成绝对地址，
        # 否则壳（尤其 iOS）不一定会自己补，图就会显示不出来。
        segment = segment or ""
        candidates = []  # (position, url)
        def _norm(u):
            u = (u or "").strip()
            if not u or u.startswith("data:"):
                return ""
            if "welcome" in u or "loading" in u or "placeholder" in u:
                return ""
            if u.startswith("//"):
                return "https:" + u
            if u.startswith("http"):
                return u
            if u.startswith("/"):
                return "https://m.ddys.net" + u
            return "https://m.ddys.net/" + u.lstrip("/")
        for m in re.finditer(r'<img[^>]+>', segment, re.S):
            tag = m.group(0)
            for attr in ("data-original", "data-src", "data-lazy", "data-lazy-src", "data-echo", "src"):
                mm = re.search(attr + r'="([^"]+)"', tag)
                if mm:
                    candidates.append((m.start(), mm.group(1).strip()))
                    break
            else:
                mm = re.search(r'srcset="([^"]+)"', tag)
                if mm:
                    candidates.append((m.start(), mm.group(1).split(",")[0].split()[0].strip()))
        for m in re.finditer(r'<source[^>]+srcset="([^"]+)"', segment, re.S):
            candidates.append((m.start(), m.group(1).split(",")[0].split()[0].strip()))
        for m in re.finditer(r'background-image\s*:\s*url\(\s*["\']?([^"\)\'\s]+)', segment, re.S):
            candidates.append((m.start(), m.group(1).strip()))
        for m in re.finditer(r'data-(?:bg|pic|cover|image|img|poster|thumb|original)="([^"]+)"', segment):
            candidates.append((m.start(), m.group(1).strip()))
        for m in re.finditer(r'"(?:pic|cover|vod_pic|poster)"\s*:\s*"([^"]+)"', segment):
            candidates.append((m.start(), m.group(1).replace("\\/", "/").strip()))
        # 取最后一个候选（离本项标题最近的，通常就是本项封面），并过滤 .gif 占位
        for _, u in reversed(candidates):
            if u.endswith(".gif"):
                continue
            n = _norm(u)
            if n:
                return n
        return ""

    @staticmethod
    def _safe_title(text):
        # 集名里的 # $ 会破坏播放串结构，替换成空格（三个 OK 源的铁律）
        return (text or "").replace("#", " ").replace("$", " ").strip()

    def _detail_items(self, html):
        """列表页关键修正（2026-10-24 浏览器复核）：
        每项有两个指向同一详情页的并列 <a>：一个是封面链接，文本是“正片”/“抢先版”这类状态，
        另一个是 <h4> 包裹的标题链接，文本才是片名。上一版按第一个 <a> 取名，
        就会把所有片名都写成“正片”，这就是“有数据但不太对”的最可能根因。
        所以：片名只取 <h4><a href="/html/{id}.html">片名</a></h4>，状态取同 id 的另一个 <a> 文本。
        封面：浏览器工具未暴露列表项 <img> 节点，src / data-src / 懒加载属性均未验证，
        这里不硬编 img 正则，vod_pic 留空，等原始源码确认后再补，不要给错图。"""
        html = html or ""
        # 状态：同 id 的非标题 <a> 文本，如 正片 / 抢先版
        # 状态：封面 <a> 的 inner 可能含 <img>，所以先用 (.*?) 再去标签取文本，
        # 且只收短状态词，不收片名本身（片名在下面 h4 里再取）
        titles_tmp = {}
        for m in re.finditer(r'<h4[^>]*>\s*<a[^>]+href="/html/(\d+)\.html"[^>]*>([^<]+)</a>\s*</h4>', html, re.S):
            titles_tmp[m.group(1)] = self._clean(m.group(2))
        remarks, pics = {}, {}
        for m in re.finditer(r'<a[^>]+href="/html/(\d+)\.html"[^>]*>(.*?)</a>', html, re.S):
            vid, inner = m.group(1), m.group(2)
            text = self._clean(inner)
            if text and text != titles_tmp.get(vid) and len(text) <= 10 and vid not in remarks:
                remarks[vid] = text
            pic = self._pic_from_inner(inner)
            if pic and vid not in pics:
                pics[vid] = pic
        out, seen = [], set()
        # 片名：只取 h4 包裹的标题链接；封面：取本项 h4 之前的这一段 HTML 里的最后一个图片，
        # 这样封面即使不在 <a> 里、而是单独的 <img>、<picture> 或 background-image，也能取到。
        # 上一版只在封面 <a> 的 inner 里找 img，封面在 <a> 外时 vod_pic 就会一直空，这就是无封面的最可能原因。
        prev_end = 0
        for m in re.finditer(r'<h4[^>]*>\s*<a[^>]+href="/html/(\d+)\.html"[^>]*>([^<]+)</a>\s*</h4>', html, re.S):
            vid, title = m.group(1), self._clean(m.group(2))
            segment = html[prev_end:m.end()]
            prev_end = m.end()
            if vid in seen or not title:
                continue
            seen.add(vid)
            pic = self._pic_from_segment(segment) or pics.get(vid, "")
            if not pic:
                # 封面在标题之后的情况：再看标题后 3000 字内有没有图
                after = html[m.end():m.end() + 3000]
                # 只取到下一个 <h4> 之前，避免拿到下一项的图
                nxt = after.find("<h4")
                if nxt != -1:
                    after = after[:nxt]
                pic = self._pic_from_segment(after)
            out.append({
                "vod_id": vid,
                "vod_name": title[:80],
                "vod_pic": pic,
                "vod_remarks": remarks.get(vid, ""),
            })
        if out:
            return out
        # 兜底（无 h4 时才用）：跳过纯状态词的 <a>，不要把“正片”当片名
        for m in re.finditer(r'<a[^>]+href="/html/(\d+)\.html"[^>]*>([^<]+)</a>', html, re.S):
            vid, title = m.group(1), self._clean(m.group(2))
            if vid in seen or not title or title in ("正片", "抢先版"):
                continue
            seen.add(vid)
            out.append({
                "vod_id": vid,
                "vod_name": title[:80],
                "vod_pic": pics.get(vid, ""),
                "vod_remarks": remarks.get(vid, ""),
            })
        return out

    def _paged(self, items, pg):
        # 本站列表页不给总数：满页就报还有下一页，空页就报本页是最后一页，诚实分页，不写 9999。
        if items:
            pagecount = int(pg) + 1
        else:
            pagecount = max(int(pg) - 1, 1)
        return {
            "list": items[:self.limit],
            "page": int(pg),
            "pagecount": pagecount,
            "limit": self.limit,
            "total": 0,
        }

    # ---------- 五接口（dr_py 签名） ----------
    def homeContent(self, filter=False):
        result = {"class": self.classes, "list": []}
        self._get("/")
        html = self._get("/class/1-1.html")
        result["list"] = self._detail_items(html)[:self.limit]
        return result

    def categoryContent(self, tid, pg, filter=False, content=None):
        pg = int(pg) if str(pg).isdigit() else 1
        tid = str(tid or "1")
        # 分页已验证：/class/1-1.html、/class/1-2.html、尾页 /class/1-1835.html，统一用 -页码 形式
        path = f"/class/{tid}-{pg}.html"
        html = self._get(path)
        return self._paged(self._detail_items(html), pg)

    def detailContent(self, ids):
        # ids 四态兼容：str / list / tuple，逗号分隔时取第一个。
        if isinstance(ids, (list, tuple)):
            vid = str(ids[0]) if ids else ""
        else:
            vid = str(ids or "").split(",")[0].strip()
        # 兼容上一版传完整路径的情况：/html/274004.html -> 274004
        m_id = re.search(r"/html/(\d+)\.html", vid)
        if m_id:
            vid = m_id.group(1)
        if not vid:
            return {"list": []}
        html = self._get(f"/html/{vid}.html")
        if not html:
            return {"list": []}
        title = ""
        # 详情标题已验证是 <h1>，文本如“异变：辐射（2026）”，年份在括号里，不是独立字段。
        # <title> 带站点后缀，上一版直接用它会把片名写长，h1 优先。
        m_title = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S)
        if m_title:
            title = self._clean(m_title.group(1))
        if not title:
            m_title = re.search(r"<title>(.*?)</title>", html, re.S)
            if m_title:
                title = self._clean(m_title.group(1)).split("_")[0].split("-")[0].strip()
        # 选集：按线路分组，链接均为 /play/{id}/{line}/{ep}.html，集名取链接文本。
        lines = {}
        for m in re.finditer(r'<a[^>]+href="(/play/(\d+)/(\d+)/(\d+)\.html)"[^>]*>([^<]{1,40})</a>', html, re.S):
            path, _vid, line_no, _ep, text = m.group(1), m.group(2), m.group(3), m.group(4), m.group(5)
            ep_name = self._safe_title(self._clean(text)) or f"第{_ep}集"
            item = f"{ep_name}${self.host}{path}"
            if item not in lines.setdefault(line_no, []):
                lines[line_no].append(item)
        if not lines:
            lines = {"1": [f"正片${self.host}/play/{vid}/1/1.html"]}
        line_keys = sorted(lines.keys(), key=lambda x: int(x))
        # 详情封面：og:image 优先，否则取详情页第一张非欢迎/非占位的 jpg/png/webp 图
        pic = ""
        m_og = re.search(r'<meta[^>]+property="og:image"[^>]+content="([^"]+)"', html, re.S)
        if not m_og:
            m_og = re.search(r'<meta[^>]+content="([^"]+)"[^>]+property="og:image"', html, re.S)
        if m_og:
            pic = m_og.group(1).strip()
        if not pic:
            for mm in re.finditer(r'<img[^>]+(?:data-original|data-src|src)="([^"]+)"', html, re.S):
                u = mm.group(1).strip()
                if u and "welcome" not in u and not u.endswith(".gif") and any(u.lower().split("?")[0].endswith(ext) for ext in (".jpg", ".jpeg", ".png", ".webp")):
                    pic = u
                    break
        if pic:
            if pic.startswith("//"):
                pic = "https:" + pic
            elif pic.startswith("/"):
                pic = "https://m.ddys.net" + pic
            elif not pic.startswith("http"):
                pic = "https://m.ddys.net/" + pic
        vod = {
            "vod_id": vid,
            "vod_name": title,
            "vod_pic": pic,
            "type_name": "",
            "vod_year": "",
            "vod_area": "",
            "vod_actor": "",
            "vod_director": "",
            "vod_content": "",
            "vod_remarks": "",
            "vod_play_from": "$$$".join(f"线路{k}" for k in line_keys),
            "vod_play_url": "$$$".join("#".join(lines[k]) for k in line_keys),
        }
        return {"list": [vod]}

    def searchContent(self, key, pg, filter=False):
        pg = int(pg) if str(pg).isdigit() else 1
        if not key:
            return {"list": [], "page": pg, "pagecount": 0, "limit": self.limit, "total": 0}
        # 搜索形态已验证：/so/{编码关键词}-------------.html，表单 action 未暴露，不要硬编成 ?q=。
        path = f"/so/{quote(str(key))}-------------.html"
        html = self._get(path)
        return self._paged(self._detail_items(html), pg)

    def playerContent(self, flag, id, vipFlags=None):
        # 播放失败最可能的三个原因，逐一兜底：
        #  1) 壳传来的 id 可能是 "正片$/play/..."（OK 式），也可能是直接的播放页地址（dr_py 式），
        #     上一版按后者处理，前者就会把 "正片$..." 当成路径去抓，必然 404/失败。
        #     这里先按 $ 拆，取最后一段当地址；如果最后一段本身就是 m3u8/mp4，直接返回。
        #  2) 播放页 iframe 的 src 模式未验证，artplayer 只是早期的文件名推测，
        #     所以不再只认 artplayer，改成：所有 iframe src 都试，src 本身是 m3u8 就用，
        #     否则取 url 参数解码；iframe 指向的播放器页再抓一层，在里面找 m3u8。
        #  3) 播放页里还可能有 video 标签、player_aaaa 变量、或裸的 m3u8 链接，通用正则也兜一遍。
        #  全部找不到时回落 parse=1（让壳自己再解析一次播放页），而不是 parse=0 配一个 HTML 播放页，
        #  后者壳一定会当成流去播、一定失败。parse=1 仍失败，说明需要原始播放页源码才能定稿。
        raw = str(id or "")
        play_url = raw.split("$")[-1].strip() if "$" in raw else raw.strip()
        if not play_url:
            return {"parse": 0, "url": "", "header": {}}
        if ".m3u8" in play_url or ".mp4" in play_url:
            return {"parse": 0, "url": play_url, "header": {"User-Agent": self.headers["User-Agent"], "Referer": self.host + "/"}}
        if not play_url.startswith("http"):
            play_url = urljoin(self.host + "/", play_url.lstrip("/"))
        header = {"User-Agent": self.headers["User-Agent"], "Referer": play_url}
        html = self._get(play_url)
        if not html:
            return {"parse": 1, "url": play_url, "header": header}

        def _decode_stream(s):
            s = s or ""
            for _ in range(3):
                d = unquote(s)
                if d == s:
                    break
                s = d
            return s

        def _find_m3u8(text):
            if not text:
                return ""
            # 裸 m3u8 / mp4 链接
            m = re.search(r'(https?://[^\s"\'<>]+?\.(?:m3u8|mp4)[^\s"\'<>]*)', text)
            if m:
                return _decode_stream(m.group(1))
            # player_aaaa = {"url": "..."} 这类变量
            m = re.search(r'"url"\s*:\s*"([^"]+\.(?:m3u8|mp4)[^"]*)"', text)
            if m:
                return _decode_stream(m.group(1).replace("\\/", "/"))
            return ""

        stream = _find_m3u8(html)
        if stream:
            return {"parse": 0, "url": stream, "header": header}
        # iframe：逐个试 src 本身、url 参数、以及 iframe 指向的播放器页
        for m in re.finditer(r'<iframe[^>]+src="([^"]+)"', html, re.S):
            src = m.group(1).strip()
            if not src or src.startswith("javascript:"):
                continue
            if not src.startswith("http"):
                src = urljoin(play_url, src)
            # 先取 url 参数：iframe src 里含 .m3u8 很可能是 ?url=...m3u8，本身不是流，
            # 直接把整个 iframe 地址当流返回一定播失败。src 本身以 .m3u8/.mp4 结尾时才是流。
            qs = parse_qs(urlparse(src).query)
            for raw_u in qs.get("url") or []:
                stream = _decode_stream(raw_u)
                if ".m3u8" in stream or ".mp4" in stream:
                    return {"parse": 0, "url": stream, "header": header}
            if urlparse(src).path.endswith((".m3u8", ".mp4")):
                return {"parse": 0, "url": _decode_stream(src), "header": header}
            # iframe 本身是播放器页：再抓一层找流
            inner = self._get(src)
            stream = _find_m3u8(inner)
            if stream:
                return {"parse": 0, "url": stream, "header": header}
        # video 标签
        m = re.search(r'<video[^>]+src="([^"]+)"', html, re.S)
        if m and (".m3u8" in m.group(1) or ".mp4" in m.group(1)):
            return {"parse": 0, "url": _decode_stream(m.group(1)), "header": header}
        # 回落：parse=1，让壳再解析一次播放页，不要用 parse=0 配 HTML 页去播。
        return {"parse": 1, "url": play_url, "header": header}
