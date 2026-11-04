# -*- coding: utf-8 -*-
"""
Finch·17RIP —— dr_py 版（2026-10-25）
目标站：https://17rip.com（17RIP，MacCMS 站）
已验证的结构（原始 HTML，2026-10-25，只读，未登录、未付费、未点播放、未下载视频流）：
  列表卡片：<a href="/voddetail/{ID}.html"> 内 <img class="... gen-movie-img" data-src="真实封面"
    alt="标题">，src 只是 1x1 gif 占位图；首页轮播卡片用 data-background，列表以 lazy 卡片为准。
  分类：MacCMS vodshow，/vodshow/{ID}-----------.html（ID + 11 个短横线）第 1 页，
    翻页 /vodshow/{ID}--------{页码}---.html（ID + 8 个短横线 + 页码 + 3 个短横线），
    实测 AV（1）第 1、2 页 ID 不重合，翻页真实；站方每页约 47-48 条，壳的一页就直接给整页，
    不按 20 条切片，否则每站页会漏掉 20 多条。
    分类：推荐（首页）、AV（1）、国产（2）、欧美（3）、动漫（4）、网曝门（5）、OnlyFans（33）、其他（35）；
    各分类默认就是按最新排序，所以不再单独设一个和 AV 重复的“最近更新”。
  详情：/voddetail/{ID}.html，封面在 .detail-pic 的 <img data-src> 里，标题在 <title> 里；
    播放只有一条线路 sid=1，/vodplay/{ID}-1-1.html。
  播放：播放页有 var player_aaaa，实测 from=hsckm3u8、encrypt=0、url 就是直链 m3u8；
    playerContent 也按 321AV 的办法处理 encrypt=1（unquote）和 encrypt=2（base64），
    防止其他影片换加密方式时直接失效。
  搜索：/vodsearch/{关键词}-------------.html（关键词 + 13 个短横线），
    翻页 /vodsearch/{关键词}----------{页码}---.html（关键词 + 10 个短横线 + 页码 + 3 个短横线）。
未验证：壳端图片加载是否需要 Referer；其他影片的 player_aaaa 是否都是 encrypt=0 直链。
"""
from base.spider import Spider

import base64
import html as html_lib
import json
import re
from urllib.parse import quote, unquote, urljoin

import requests


class Spider(Spider):
    name = "Finch·17RIP"
    host = "https://17rip.com"
    limit = 20
    headers = {
        "User-Agent": "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36",
        "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
        "Accept-Language": "zh-CN,zh;q=0.9",
    }
    classes = [
        # 注意：不要在这里再加一个“推荐”分类——壳本身会把 homeContent 的列表当作“推荐”页展示，
        # 再加一个就会出现两个“推荐”。同理筛选里也不要自己加“全部”，壳会给每组筛选自动加一个。
        {"type_name": "AV", "type_id": "1"},
        {"type_name": "国产", "type_id": "2"},
        {"type_name": "欧美", "type_id": "3"},
        {"type_name": "动漫", "type_id": "4"},
        {"type_name": "网曝门", "type_id": "5"},
        {"type_name": "OnlyFans", "type_id": "33"},
        {"type_name": "其他", "type_id": "35"},
    ]
    # 每个一级分类下面的小分类（站方 vodshow 导航里的顺序，原样保留，不是按数字排序），
    # 键是一级分类的 type_id，值是 [(小分类名, 小分类 vodshow id)]。
    # 注意：这里不放“全部”——壳会给每组筛选自动加一个“全部”（空值），自己再加就会出现两个“全部”；
    # 选壳那个“全部”时传回来的就是空值，categoryContent 里空值会 fallback 到一级分类本身。
    _subs = {
        "1": [("家庭乱伦", "20"), ("少女萝莉", "21"), ("SM调教", "22"), ("绝顶潮吹", "23"),
              ("魔镜系列", "24"), ("时间停止", "25"), ("催眠洗脑", "26"), ("漫改系列", "27"), ("电车痴汉", "28"),
              ("淫欲痴女", "29"), ("AV解说", "34"), ("人妻熟女", "6"), ("日本无码", "7"), ("美乳巨乳", "8"),
              ("强制侵犯", "9"), ("制服诱惑", "10"), ("绝色佳人", "11"), ("风俗泡泡浴", "12")],
        "2": [("网红主播", "13"), ("国产传媒", "14"), ("探花系列", "15"), ("国产自拍", "16")],
        "3": [("欧美精品", "30")],
        "4": [("日本动漫", "31"), ("3D动漫", "32")],
        "5": [],
        "33": [],
        "35": [("三级电影", "36"), ("AI换脸", "37")],
    }
    _sorts = [("按最新", "time"), ("按最热", "hits"), ("按评分", "score")]

    def _filters(self):
        """dr_py 筛选：每个分类两组——小分类 + 排序，壳里选了之后会把 extend 传回 categoryContent。
        小分类为空的分类（网曝门、OnlyFans）只给排序组，不给空的小分类组；
        排序组也不自己加“默认”，壳自动加的“全部”就是默认（空值）。"""
        out = {}
        for c in self.classes:
            tid = c["type_id"]
            if tid == "home":
                continue
            groups = []
            subs = self._subs.get(tid, [])
            if subs:
                groups.append({"key": "class", "name": "小分类",
                               "value": [{"n": n, "v": v} for n, v in subs]})
            groups.append({"key": "sort", "name": "排序",
                           "value": [{"n": n, "v": v} for n, v in self._sorts]})
            out[tid] = groups
        return out

    def _show_url(self, show_id, sort, pg):
        """MacCMS vodshow 地址：12 个字段用 11 个短横线隔开，
        第 0 位是分类 id，第 2 位是排序（time/hits/score），第 8 位是页码，其余为空。
        用字段拼接而不是手数字符数，排序和翻页组合时也不会错位。"""
        fields = [str(show_id), "", sort or "", "", "", "", "", "", str(pg), "", "", ""]
        return "/vodshow/" + "-".join(fields) + ".html"

    def _clean(self, s):
        s = html_lib.unescape(re.sub(r"<[^>]+>", " ", str(s or "")))
        return re.sub(r"\s+", " ", s).strip()

    def _get(self, path):
        url = path if path.startswith("http") else urljoin(self.host + "/", path.lstrip("/"))
        try:
            r = requests.get(url, headers=self.headers, timeout=15)
            if r.status_code == 200 and len(r.text) > 1000:
                return r.text
        except Exception:
            pass
        return ""

    def _cards(self, html_text):
        out, seen = [], set()
        if not html_text:
            return out
        for m in re.finditer(r'<a[^>]+href="/voddetail/(\d+)\.html"[^>]*>', html_text):
            vid = m.group(1)
            if vid in seen:
                continue
            # 卡片里可能嵌套其他 <a>（演员、标签链接），所以不能用“到第一个 </a>”来截块，
            # 改为从本卡片链接往后找 img，但不超过下一个影片链接，避免串到下一张卡。
            seg = html_text[m.end():m.end() + 3000]
            nxt = re.search(r'href="/voddetail/\d+\.html"', seg)
            if nxt:
                seg = seg[:nxt.start()]
            im = re.search(r'<img[^>]+class="[^"]*gen-movie-img[^"]*"[^>]*>', seg)
            if not im:
                continue
            tag = im.group(0)
            pm = re.search(r'data-src="([^"]+)"', tag)
            am = re.search(r'alt="([^"]+)"', tag)
            title = self._clean(am.group(1)) if am else ""
            # 标题里的【中文】只是“带中文字幕”的标记，不是片名本身，几乎每条 AV 标题都有它；
            # 壳里如果只抽括号内容当标题，就会全部显示成“中文”，所以直接从标题里去掉，
            # 其他括号内容（比如【第1480期】）是片名的一部分，保留。
            title = re.sub(r"【中文(字幕)?】", " ", title)
            title = re.sub(r"\s+", " ", title).strip()
            if not title:
                continue
            seen.add(vid)
            pic = pm.group(1).strip() if pm else ""
            if pic.startswith("//"):
                pic = "https:" + pic
            out.append({"vod_id": vid, "vod_name": title[:120], "vod_pic": pic, "vod_remarks": ""})
        return out

    def homeContent(self, filter=False):
        return {"class": self.classes, "filters": self._filters(), "list": self._cards(self._get("/"))[:self.limit]}

    def categoryContent(self, tid, pg, filter=False, extend=None, content=None, **kwargs):
        # 签名兼容：不同壳传筛选的方式不一样，有的传 extend，有的传 content，有的用关键字，
        # 这里全都接住，免得因为参数名对不上导致筛选失效或报错。
        pg = int(pg) if str(pg).isdigit() else 1
        if pg < 1:
            pg = 1
        tid = str(tid or "home")
        if tid == "home":
            if pg > 1:
                return {"list": [], "page": pg, "pagecount": 1, "limit": self.limit, "total": 0}
            return {"list": self._cards(self._get("/"))[:self.limit], "page": pg, "pagecount": 1, "limit": self.limit, "total": 0}
        ext = extend if isinstance(extend, dict) else (content if isinstance(content, dict) else kwargs)
        sub_id = str(ext.get("class") or "") if isinstance(ext, dict) else ""
        sort = str(ext.get("sort") or "") if isinstance(ext, dict) else ""
        # 小分类的值本身就是一个 vodshow id，选了小分类就按小分类的 id 取列表；
        # “全部”的值就是一级分类本身，和不选效果一样。
        show_id = sub_id if sub_id and sub_id.isdigit() else tid
        path = self._show_url(show_id, sort, pg)
        items = self._cards(self._get(path))
        pagecount = pg + 1 if items else max(pg - 1, 1)
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": len(items) or self.limit, "total": 0}

    def _vid(self, raw):
        m = re.search(r"/voddetail/(\d+)\.html", str(raw or ""))
        if m:
            return m.group(1)
        s = str(raw or "").strip()
        return s if s.isdigit() else ""

    def _player_aaaa(self, play_url):
        """播放页 → player_aaaa → 直链 m3u8（或 None），同时返回 from 名。"""
        html_text = self._get(play_url)
        if not html_text:
            return None, ""
        try:
            idx = html_text.find("var player_aaaa=")
            if idx == -1:
                return None, ""
            obj, _ = json.JSONDecoder().raw_decode(html_text[idx + len("var player_aaaa="):])
            from_name = self._clean(str(obj.get("from") or ""))
            url_field = str(obj.get("url") or "")
            encrypt = str(obj.get("encrypt", "0"))
            if encrypt == "1":
                url_field = unquote(url_field)
            elif encrypt == "2":
                try:
                    url_field = unquote(base64.b64decode(url_field).decode("utf-8", errors="ignore"))
                except Exception:
                    pass
            url_field = url_field.replace("\\/", "/").strip()
            if url_field and ".m3u8" in url_field:
                return url_field, from_name
            # url 字段不是直链时，可能是 base64 JSON（321AV 那种），这里不展开，只返回 None 走 parse=1。
            return None, from_name
        except Exception:
            return None, ""

    def detailContent(self, ids):
        raw = ids[0] if isinstance(ids, (list, tuple)) else ids
        vid = self._vid(raw)
        if not vid:
            return {"list": []}
        html_text = self._get(f"/voddetail/{vid}.html")
        title, pic = "", ""
        if html_text:
            m = re.search(r"<title>(.*?)</title>", html_text, re.S)
            if m:
                title = self._clean(m.group(1))
                title = re.sub(r"\s*-\s*17RIP.*$", "", title)
                title = re.sub(r"【中文(字幕)?】", " ", title)
                title = re.sub(r"\s+", " ", title).strip()
            dm = re.search(r'<div[^>]+class="[^"]*detail-pic[^"]*"[^>]*>(.*?)</div>', html_text, re.S)
            if dm:
                pm = re.search(r'data-src="([^"]+)"', dm.group(1))
                if pm:
                    pic = pm.group(1).strip()
        play_url = f"/vodplay/{vid}-1-1.html"
        stream, from_name = self._player_aaaa(play_url)
        if stream:
            return {"list": [{"vod_id": vid, "vod_name": title or vid, "vod_pic": pic, "vod_remarks": "",
                              "vod_play_from": from_name or "线路1", "vod_play_url": f"正片${stream}"}]}
        # 播放页没解析出直链也不返回空，播放时由 playerContent 再解析一次。
        return {"list": [{"vod_id": vid, "vod_name": title or vid, "vod_pic": pic, "vod_remarks": "",
                          "vod_play_from": "线路1", "vod_play_url": f"正片${play_url}"}]}

    def playerContent(self, flag, id, vipFlags=None):
        raw = str(id or "")
        play_url = raw.split("$")[-1].strip() if "$" in raw else raw.strip()
        if not play_url:
            return {"parse": 0, "url": "", "header": {}}
        if ".m3u8" in play_url or ".mp4" in play_url:
            return {"parse": 0, "url": play_url,
                    "header": {"User-Agent": self.headers["User-Agent"], "Referer": self.host + "/"}}
        if not play_url.startswith("http"):
            play_url = urljoin(self.host + "/", play_url.lstrip("/"))
        stream, _ = self._player_aaaa(play_url)
        if stream:
            return {"parse": 0, "url": stream,
                    "header": {"User-Agent": self.headers["User-Agent"], "Referer": play_url}}
        return {"parse": 1, "url": play_url, "header": {"User-Agent": self.headers["User-Agent"]}}

    def searchContent(self, key, pg, filter=False):
        pg = int(pg) if str(pg).isdigit() else 1
        if pg < 1:
            pg = 1
        key = str(key or "").strip()
        if not key:
            return {"list": []}
        q = quote(key)
        path = f"/vodsearch/{q}-------------.html" if pg == 1 else f"/vodsearch/{q}----------{pg}---.html"
        items = self._cards(self._get(path))
        pagecount = pg + 1 if items else max(pg - 1, 1)
        return {"list": items, "page": pg, "pagecount": pagecount, "limit": len(items) or self.limit, "total": 0}
