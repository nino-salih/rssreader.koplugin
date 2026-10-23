#!/usr/bin/env python3
"""Writes the local test feeds of the emulator (RSS 2.0) plus their images.

Usage: make_feeds.py OUT_DIR BASE_URL
Feeds go to OUT_DIR/feeds/<slug>.xml, images to OUT_DIR/img/<name>.jpg
(ImageMagick `convert`). Dates are relative to now, so "Today" has entries.
Only test data: no real account, no network beyond the local HTTP server.
"""
import email.utils
import os
import subprocess
import sys
import time
from xml.sax.saxutils import escape

FEEDS = {
    "void-herald": ("Void Herald", "novel"),
    "long-chronicle": ("The Long and Winding Chronicle of Everything That Happened Today", "novel"),
    "orbital": ("Orbital Mechanics Daily", "Science & Technology News Digest"),
    "lab-notes": ("Lab Notes", "Science & Technology News Digest"),
    "loose-ends": ("Loose Ends", None),
}

WORDS = ("the quick brown fox jumps over the lazy dog while the archive keeps every story "
         "for later reading on a quiet evening without any network at all").split()

COLORS = ["#555555", "#888888", "#333333", "#aaaaaa", "#666666", "#999999"]


def paragraph(seed, count):
    return " ".join(WORDS[(seed * 7 + i * 3) % len(WORDS)] for i in range(count)).capitalize() + "."


def make_image(path, label, color, size):
    if os.path.exists(path):
        return
    subprocess.run(["convert", "-size", size, "xc:" + color, "-gravity", "center",
                    "-pointsize", "48", "-fill", "white", "-annotate", "0", label, path], check=True)


# Feeds whose image-less articles link to a local page with an og:image (WebP):
# the sync takes the card image from there (og:image fallback). The other
# image-less articles link to a page without preview image (card placeholder).
OG_FEEDS = ("void-herald", "orbital")


def page_html(base, slug, index):
    meta = ""
    if slug in OG_FEEDS:
        meta = f'<meta property="og:image" content="/img/{slug}-{index}-og.webp">'
    return f"<html><head><title>{slug} {index}</title>{meta}</head><body><p>Article page</p></body></html>"


# Image reuse (block 10): these articles of the "Second" account share an image
# URL resp. an article link with "Void Herald" of "Test Feeds". The sync copies
# the stored file instead of downloading it and reuses the known og:image.
SHARED_IMAGE = {("loose-ends", 1): "void-herald-1"}
SHARED_LINK = {("loose-ends", 5): "void-herald-5"}  # index 5: no image in the text


def item_xml(base, slug, title, index, now):
    img = f"{slug}-{index}"
    banner = SHARED_IMAGE.get((slug, index), img)
    published = email.utils.formatdate(now - index * 5 * 3600, usegmt=True)
    body = [f"<h1>{escape(title)} {index}</h1>"]
    link = f"https://example.org/{slug}/{index}"
    if index % 3 != 2:  # some articles without images
        body.append(f'<p><img src="{base}/img/{banner}-1200x675.jpg" width="1200" height="675"></p>')
    else:
        link = f"{base}/pages/{SHARED_LINK.get((slug, index), f'{slug}-{index}')}.html"
    for p in range(6):
        body.append(f"<p>{paragraph(index + p, 40 + p * 5)}</p>")
        if p == 2 and index % 2 == 0:
            body.append(f'<figure><img src="{base}/img/{img}-inline.jpg"><figcaption>Figure {index}</figcaption></figure>')
    body.append(f'<p>Read more at <a href="https://example.org/{slug}/{index}">example.org</a>.</p>')
    html = "\n".join(body)
    return (f"<item><title>{escape(title)} {index}: {escape(paragraph(index, 6))}</title>"
            f"<link>{link}</link><guid>https://example.org/{slug}/{index}</guid>"
            f"<pubDate>{published}</pubDate><description>{escape(html)}</description></item>")


def main():
    out, base = sys.argv[1], sys.argv[2].rstrip("/")
    os.makedirs(os.path.join(out, "feeds"), exist_ok=True)
    os.makedirs(os.path.join(out, "img"), exist_ok=True)
    os.makedirs(os.path.join(out, "pages"), exist_ok=True)
    now = int(time.time())
    for n, (slug, (title, _folder)) in enumerate(FEEDS.items()):
        items = []
        for index in range(1, 9):
            color = COLORS[(n + index) % len(COLORS)]
            make_image(os.path.join(out, "img", f"{slug}-{index}-1200x675.jpg"), f"{title[:12]} {index}", color, "1200x675")
            make_image(os.path.join(out, "img", f"{slug}-{index}-inline.jpg"), f"inline {index}", COLORS[index % 6], "800x500")
            if index % 3 == 2:
                if slug in OG_FEEDS:
                    make_image(os.path.join(out, "img", f"{slug}-{index}-og.webp"), f"og:image {index}", "#444444", "1200x630")
                with open(os.path.join(out, "pages", f"{slug}-{index}.html"), "w", encoding="utf-8") as handle:
                    handle.write(page_html(base, slug, index))
            items.append(item_xml(base, slug, title, index, now))
        rss = (f'<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>{escape(title)}</title>'
               f"<link>https://example.org/{slug}</link><description>test feed</description>"
               + "".join(items) + "</channel></rss>")
        with open(os.path.join(out, "feeds", slug + ".xml"), "w", encoding="utf-8") as handle:
            handle.write(rss)


if __name__ == "__main__":
    main()
