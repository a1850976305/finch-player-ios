# Finch·MissAVt dr_py 源
# 站点：https://missavt.com（MissAVt）
# 结构（2026-10-26 原始 HTML 实测）：
#   列表 /category/{slug}/，翻页 /category/{slug}/{pg}/，每页 24 条，实测 p1/p2 无重合。
#   卡片：.video-item 内 a[href=/watch/{slug}/]；标题取 line-clamp-2 的 <a> 文本（兜底 img alt）；
#   封面不要用 img data-src：那是 image.cpckgr.cn 的签名 jpeg，服务器返回的 Content-Type 是 binary/octet-stream，
#   浏览器里站方 JS 会把它取下来转成 blob: 才显示，壳直接拿这个地址当图片加载会空白。
#   改用详情页 og:image 同款规律地址 https://missavt.com/video/webp/{slug}.webp（实测多部均为 200 image/webp，
#   且详情封面用的就是这个，壳里能显示）；备注取右下角时长（如 3:19:40）。
#   详情与播放合在 /watch/{slug}/：标题 <h1>，封面 og:image（/video/webp/{slug}.webp），标签 video:tag，简介 meta description。
#   详情页主 <video> 的 webm 只是预览性质，不用；正片流在 /embed/{slug}/ 页的 <video><source src="...m3u8?auth_key=..."> 里，
#   所以详情只给一条“正片”，地址就是 /embed/{slug}/，playerContent 现抓 embed 页取 source，parse=0，查询参数原样保留（签名有时效）。
#   注意：不要碰详情页里相关推荐卡片的 poster data-url（那是悬停预览流，不是正片），也不要去解详情页里那段 eval 打包脚本——embed 页已经是干净的。
#   搜索：/search/{关键词小写}/，翻页 /search/{关键词小写}/{pg}/（实测大写关键词的第 2 页会 404，所以统一小写）。
#   注意：不要加显式“推荐”分类、不要加显式“全部”筛选值，Hawk 自己会加（17RIP 教训）。
from base.spider import Spider
import re
from urllib.parse import quote

try:
    import requests
except Exception:
    requests = None


class Spider(Spider):
    name = "Finch·MissAVt"
    siteUrl = "https://missavt.com"
    headers = {
        "User-Agent": "Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1",
        "Referer": "https://missavt.com/",
    }
    categories = [
        {"type_id": "censored", "type_name": "有码AV"},
        {"type_id": "chinese-subtitle", "type_name": "中文字幕"},
        {"type_id": "renqishunv", "type_name": "人妻熟女"},
        {"type_id": "zhifuyouhuo", "type_name": "制服诱惑"},
        {"type_id": "tiaojiaoSM", "type_name": "调教SM"},
        {"type_id": "jiatingluanlun", "type_name": "家庭乱伦"},
        {"type_id": "madou", "type_name": "麻豆传媒"},
        {"type_id": "swag", "type_name": "swag"},
        {"type_id": "sweet-heart-vlog", "type_name": "糖心vlog"},
        {"type_id": "ed-mosaic", "type_name": "ed mosaic"},
        {"type_id": "douyin", "type_name": "抖阴"},
        {"type_id": "91-studio", "type_name": "91制片厂"},
        {"type_id": "mr-rabbit", "type_name": "兔子先生"},
        {"type_id": "domestic-media", "type_name": "国产传媒"},
        {"type_id": "xingbatanhua", "type_name": "杏吧探花"},
        {"type_id": "uncensored-leak", "type_name": "无码流出"},
        {"type_id": "fc2", "type_name": "FC2"},
        {"type_id": "tokyohot", "type_name": "东京热"},
        {"type_id": "marriedslash", "type_name": "人妻斩"},
        {"type_id": "heyzo", "type_name": "HEYZO"},
        {"type_id": "reducing-mosaic", "type_name": "无码破解"},
        {"type_id": "caribbeancom", "type_name": "Caribbeancom"},
        {"type_id": "xxx-av", "type_name": "xxx-av"},
        {"type_id": "pacopacomama", "type_name": "pacopacomama"},
        {"type_id": "caribbeancompr", "type_name": "Caribbeancompr"},
        {"type_id": "1pondo", "type_name": "一本道"},
        {"type_id": "10musume", "type_name": "10musume"},
        {"type_id": "siro", "type_name": "SIRO"},
        {"type_id": "luxu", "type_name": "lulu"},
        {"type_id": "gana", "type_name": "gana"},
        {"type_id": "prestige-premium", "type_name": "PRESTIGE PREMIUM"},
        {"type_id": "s-cute", "type_name": "S-CUTE"},
        {"type_id": "ara", "type_name": "ARA"},
        {"type_id": "aiduanju", "type_name": "AI成人短剧"},
        {"type_id": "amateur", "type_name": "素人"},
    ]

    def _fetch(self, url):
        if requests is None:
            import urllib.request
            req = urllib.request.Request(url, headers=self.headers)
            with urllib.request.urlopen(req, timeout=20) as r:
                return r.read().decode("utf-8", "ignore")
        r = requests.get(url, headers=self.headers, timeout=20)
        r.encoding = "utf-8"
        return r.text

    def _abs(self, u):
        if not u:
            return ""
        u = u.strip()
        if u.startswith("//"):
            return "https:" + u
        if u.startswith("/"):
            return self.siteUrl + u
        return u

    def _clean(self, s):
        if not s:
            return ""
        s = re.sub(r"<[^>]+>", "", s)
        return s.replace("#", " ").replace("$", " ").strip()

    # ---------- 列表 ----------
    def _parse_list(self, html):
        out = []
        seen = set()
        for block in re.split(r'<div class="video-item">', html)[1:]:
            m = re.search(r'href="/watch/([^"/]+)/"', block)
            if not m:
                continue
            slug = m.group(1)
            if slug in seen:
                continue
            seen.add(slug)
            title = ""
            mt = re.search(r'class="my-1[^"]*line-clamp-2"[^>]*>([^<]+)</a>', block)
            if mt:
                title = mt.group(1).strip()
            if not title:
                ma = re.search(r'<img[^>]+alt="([^"]+)"', block)
                title = ma.group(1).strip() if ma else ""
            if not title:
                continue
            # 封面用 webp 规律地址，不用 data-src 的签名 jpeg（见文件头注释）
            pic = f"{self.siteUrl}/video/webp/{slug}.webp"
            remarks = ""
            mr = re.search(r'text-sm opacity-50[^"]*">\s*([^<]+?)\s*</div>', block)
            if mr:
                remarks = mr.group(1).strip()
            out.append({
                "vod_id": slug,
                "vod_name": title,
                "vod_pic": pic,
                "vod_remarks": remarks,
            })
        return out

    def homeContent(self, *args, **kwargs):
        result = {"class": self.categories, "filters": {}, "list": []}
        try:
            html = self._fetch(self.siteUrl + "/")
            result["list"] = self._parse_list(html)
        except Exception:
            pass
        return result

    def categoryContent(self, *args, **kwargs):
        tid = args[0] if args else "censored"
        pg = args[1] if len(args) > 1 else 1
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        url = f"{self.siteUrl}/category/{tid}/"
        if pg > 1:
            url = f"{self.siteUrl}/category/{tid}/{pg}/"
        try:
            html = self._fetch(url)
            lst = self._parse_list(html)
        except Exception:
            lst = []
        return {"page": pg, "pagecount": 9999, "limit": 24, "total": 9999, "list": lst}

    # ---------- 详情 ----------
    def _parse_detail(self, html, slug):
        title = ""
        mh = re.search(r"<h1[^>]*>(.*?)</h1>", html, re.S)
        if mh:
            title = self._clean(mh.group(1))
        pic = ""
        mo = re.search(r'og:image"[^>]+content="([^"]+)"', html)
        if mo:
            pic = mo.group(1)
        tags = [t.strip() for t in re.findall(r'video:tag" content="([^"]+)"', html) if t.strip()]
        desc = ""
        md = re.search(r'<meta name="description" content="([^"]*)"', html)
        if md:
            desc = md.group(1)[:500]
        return {
            "vod_id": slug,
            "vod_name": title if title else slug,
            "vod_pic": pic,
            "vod_remarks": "/".join(tags),
            "vod_content": desc,
            "vod_play_from": "正片",
            "vod_play_url": f"正片$/embed/{quote(slug)}/",
        }

    def detailContent(self, *args, **kwargs):
        ids = args[0] if args else ""
        if isinstance(ids, (list, tuple)):
            ids = ids[0] if ids else ""
        slug = str(ids).strip().strip("/")
        slug = re.sub(r"^watch/", "", slug)
        if not slug:
            return {"list": []}
        try:
            html = self._fetch(f"{self.siteUrl}/watch/{quote(slug)}/")
        except Exception:
            return {"list": []}
        return {"list": [self._parse_detail(html, slug)]}

    # ---------- 搜索 ----------
    def searchContent(self, *args, **kwargs):
        key = args[0] if args else ""
        pg = args[1] if len(args) > 1 else 1
        try:
            pg = int(pg)
        except Exception:
            pg = 1
        if pg < 1:
            pg = 1
        if not key:
            return {"list": []}
        kw = quote(str(key).strip().lower())
        url = f"{self.siteUrl}/search/{kw}/"
        if pg > 1:
            url = f"{self.siteUrl}/search/{kw}/{pg}/"
        try:
            html = self._fetch(url)
            lst = self._parse_list(html)
        except Exception:
            lst = []
        return {"page": pg, "pagecount": 9999, "limit": 24, "total": 9999, "list": lst}

    # ---------- 播放 ----------
    def playerContent(self, *args, **kwargs):
        pid = args[1] if len(args) > 1 else ""
        if not pid:
            return {"parse": 1, "url": ""}
        if ".m3u8" in pid:
            return {"parse": 0, "url": pid, "header": self.headers}
        url = pid if pid.startswith("http") else self.siteUrl + pid
        try:
            html = self._fetch(url)
        except Exception:
            return {"parse": 1, "url": url}
        # embed 页：<source src="...m3u8...">
        m = re.search(r'<source[^>]+src="([^"]+\.m3u8[^"]*)"', html)
        if m:
            return {"parse": 0, "url": m.group(1), "header": self.headers}
        # 兜底：watch 页里找 og:video 的 embed 地址再抓一层
        me = re.search(r'og:video"[^>]+content="([^"]+/embed/[^"/]+/)"', html)
        if me:
            try:
                html2 = self._fetch(me.group(1))
                m2 = re.search(r'<source[^>]+src="([^"]+\.m3u8[^"]*)"', html2)
                if m2:
                    return {"parse": 0, "url": m2.group(1), "header": self.headers}
            except Exception:
                pass
        return {"parse": 1, "url": url}
