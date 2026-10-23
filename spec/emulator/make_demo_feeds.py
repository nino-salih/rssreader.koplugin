#!/usr/bin/env python3
"""Writes the demo feeds of the emulator (RSS 2.0): chapters of public-domain books.

Usage: make_demo_feeds.py OUT_DIR BASE_URL [FONT_FILE]
The script downloads the plain-text books from Project Gutenberg into OUT_DIR/books
(once, the files stay there as a cache). It removes the Project Gutenberg header and
footer, splits the chapters and writes one feed per book to OUT_DIR/feeds/<slug>.xml,
one article per chapter. Card images are grayscale ImageMagick drawings (gradient and
book title) in OUT_DIR/img. Dates are relative to now, so "Today" has entries.
The book texts never go into the repo: OUT_DIR is outside of it (spec/emulator/run.sh).
"""
import email.utils
import html
import os
import re
import subprocess
import sys
import time
import urllib.request
from xml.sax.saxutils import escape

CHAPTERS = 8

# slug, ebook number, feed title, author, folder, heading pattern, title on the next line.
# The pattern matches one line. Group 1 is the chapter number, group 2 (optional) the name.
BOOKS = [
    ("moby-dick", 2701, "Moby-Dick", "Herman Melville", "Classics",
     r"CHAPTER (\d+)\. (.+?)\.?", False),
    ("pride-and-prejudice", 1342, "Pride and Prejudice", "Jane Austen", "Classics",
     r"(?:CHAPTER|Chapter) ([IVXLC]+)\.\]?", False),
    ("alice", 11, "Alice's Adventures in Wonderland", "Lewis Carroll", "Classics",
     r"CHAPTER ([IVXLC]+)\.", True),
    ("sherlock-holmes", 1661, "The Adventures of Sherlock Holmes", "Arthur Conan Doyle", "Classics",
     r"([IVX]+)\. ([A-Z][A-Z’'\- ]+)", False),
    ("treasure-island", 120, "Treasure Island", "Robert Louis Stevenson", "Adventure",
     r"([IVX]+)", True),
    ("time-machine", 35, "The Time Machine", "H. G. Wells", "Adventure",
     r" ?([IVX]+)\.", True),
]

# Background tones per book (dark end, light end of the gradient).
TONES = [("#3c3c3c", "#d4d4d4"), ("#6a6a6a", "#ececec"), ("#505050", "#e0e0e0"),
         ("#2e2e2e", "#bdbdbd"), ("#464646", "#cfcfcf"), ("#5e5e5e", "#e6e6e6")]

SMALL_WORDS = {"a", "an", "and", "at", "by", "in", "of", "on", "the", "to", "with"}


def roman(text):
    if text.isdigit():
        return int(text)
    values = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}
    total = 0
    for i, char in enumerate(text):
        value = values[char]
        total += -value if i + 1 < len(text) and values[text[i + 1]] > value else value
    return total


def title_case(text):
    if not text.isupper():
        return text
    words = text.lower().split()
    return " ".join(w if i > 0 and w in SMALL_WORDS else w[:1].upper() + w[1:] for i, w in enumerate(words))


def download(path, number):
    if os.path.exists(path):
        return
    url = f"https://www.gutenberg.org/cache/epub/{number}/pg{number}.txt"
    request = urllib.request.Request(url, headers={"User-Agent": "rssreader-koplugin emulator demo"})
    with urllib.request.urlopen(request, timeout=60) as response:
        data = response.read()
    with open(path + ".part", "wb") as handle:
        handle.write(data)
    os.replace(path + ".part", path)


def body_text(raw):
    """The book text between the Project Gutenberg start and end lines."""
    text = raw.replace("\r\n", "\n")
    start = re.search(r"^\*\*\* ?START OF TH(?:E|IS) PROJECT GUTENBERG.*$", text, re.M)
    end = re.search(r"^\*\*\* ?END OF TH(?:E|IS) PROJECT GUTENBERG.*$", text, re.M)
    return text[start.end() if start else 0:end.start() if end else len(text)]


def chapters(text, pattern, name_next_line):
    """List of (number, name, text). A heading can show more than once (table of
    contents): the last one with a long text wins."""
    heading = re.compile(r"^" + pattern + r"$")
    lines = text.split("\n")
    marks = [i for i, line in enumerate(lines) if heading.match(line)]
    found = {}
    for n, start in enumerate(marks):
        match = heading.match(lines[start])
        stop = marks[n + 1] if n + 1 < len(marks) else len(lines)
        name = match.group(2) if match.lastindex and match.lastindex >= 2 else None
        first = start + 1
        if name_next_line:
            while first < stop and not lines[first].strip():
                first += 1
            if first < stop:
                name = lines[first].strip()
                first += 1
        chunk = "\n".join(lines[first:stop])
        if len(chunk) > 3000:
            found[roman(match.group(1))] = (name and title_case(name.strip()), chunk, start)
    ordered = sorted(found.items(), key=lambda item: item[1][2])
    return [(number, name, chunk) for number, (name, chunk, _start) in ordered][:CHAPTERS]


def paragraphs_html(chunk):
    chunk = re.sub(r"\[Illustration(?:[^\[\]]|\[[^\]]*\])*\]", "", chunk)
    out = []
    for block in re.split(r"\n\s*\n", chunk):
        text = " ".join(block.split())
        if not text or text.startswith("[") or re.match(r"^PART [A-Z]+--", text):
            continue
        text = html.escape(text, quote=False)
        text = re.sub(r"_([^_]+)_", r"<i>\1</i>", text)
        if re.fullmatch(r"[IVX]+\.", text):  # section number inside a story
            out.append(f"<h3>{text}</h3>")
        else:
            out.append(f"<p>{text}</p>")
    return "\n".join(out)


def make_image(path, font, book_title, label, tone, angle):
    """Grayscale card image: gradient, a light panel with a frame, title and chapter."""
    if os.path.exists(path):
        return
    dark, light = tone
    # The chapter line in the italic cut of the same font, if there is one.
    italic = font.replace("-Bold.", "-Italic.")
    label_font = italic if italic != font and os.path.exists(italic) else font
    subprocess.run([
        "convert", "-size", "1200x675", "-define", f"gradient:angle={angle}", f"gradient:{dark}-{light}",
        "-fill", "rgba(255,255,255,0.86)", "-draw", "rectangle 110,150 1090,525",
        "-fill", "none", "-stroke", "#1e1e1e", "-strokewidth", "3", "-draw", "rectangle 130,170 1070,505",
        "-stroke", "none",
        "(", "-size", "880x170", "-background", "none", "-fill", "#141414", "-font", font,
        "-gravity", "center", f"caption:{book_title}", ")",
        "-gravity", "center", "-geometry", "+0-55", "-composite",
        "(", "-size", "820x64", "-background", "none", "-fill", "#2a2a2a", "-font", label_font,
        "-gravity", "center", f"caption:{label}", ")",
        "-gravity", "center", "-geometry", "+0+95", "-composite",
        "-colorspace", "Gray", "-quality", "85", path], check=True)


def item_xml(base, slug, author, number, name, chunk, published, image):
    title = f"Chapter {number}: {name}" if name and not slug.startswith("sherlock") else (name or f"Chapter {number}")
    # A local page without preview image: the sync never asks another site for an og:image.
    link = f"{base}/pages/{slug}-{number}.html"
    body = []
    if image:
        body.append(f'<p><img src="{base}/img/{image}" width="1200" height="675"></p>')
    body.append(paragraphs_html(chunk))
    return (f"<item><title>{escape(title)}</title><link>{escape(link)}</link>"
            f"<guid>demo:{slug}:{number}</guid><dc:creator>{escape(author)}</dc:creator>"
            f"<pubDate>{email.utils.formatdate(published, usegmt=True)}</pubDate>"
            f"<description>{escape(chr(10).join(body))}</description></item>"), title


def main():
    out, base = sys.argv[1], sys.argv[2].rstrip("/")
    font = sys.argv[3] if len(sys.argv) > 3 and os.path.exists(sys.argv[3]) else "DejaVu-Serif-Bold"
    for sub in ("books", "feeds", "img", "pages"):
        os.makedirs(os.path.join(out, sub), exist_ok=True)
    now = int(time.time())
    for b, (slug, number, feed_title, author, _folder, pattern, name_next_line) in enumerate(BOOKS):
        path = os.path.join(out, "books", f"pg{number}.txt")
        download(path, number)
        with open(path, encoding="utf-8-sig") as handle:
            found = chapters(body_text(handle.read()), pattern, name_next_line)
        items = []
        for i, (chapter, name, chunk) in enumerate(found):
            # Chapter 1 of every book is the newest article (a few hours old).
            published = now - b * 40 * 60 - i * 9 * 3600
            image = None
            # Most chapters with a card image, every fourth without. Moby-Dick chapter 1
            # has none: its first page in the quick reader starts with the text.
            if (i + b) % 4 != 0:
                image = f"{slug}-{chapter}.jpg"
                label = f"Chapter {chapter}" + (f" · {name}" if name else "")
                make_image(os.path.join(out, "img", image), font, feed_title, label, TONES[b % len(TONES)],
                           90 + 35 * i)
            with open(os.path.join(out, "pages", f"{slug}-{chapter}.html"), "w", encoding="utf-8") as handle:
                handle.write(f"<html><head><title>{escape(feed_title)}</title></head>"
                             "<body><p>Chapter page</p></body></html>")
            xml, title = item_xml(base, slug, author, chapter, name, chunk, published, image)
            items.append(xml)
            print(f"{feed_title}: {title} ({len(chunk)} chars)")
        rss = ('<?xml version="1.0" encoding="UTF-8"?>'
               '<rss version="2.0" xmlns:dc="http://purl.org/dc/elements/1.1/"><channel>'
               f"<title>{escape(feed_title)}</title><link>https://www.gutenberg.org/ebooks/{number}</link>"
               f"<description>{escape(author)}, from Project Gutenberg</description>"
               + "".join(items) + "</channel></rss>")
        with open(os.path.join(out, "feeds", slug + ".xml"), "w", encoding="utf-8") as handle:
            handle.write(rss)


if __name__ == "__main__":
    main()
