"""Картинки для установщика Windows (Inno Setup): тёмный фон, мягкие пятна света, знак приложения."""
import math
import os
from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'installer')
FONT = os.path.join(ROOT, 'assets', 'fonts', 'Inter-Bold.ttf')
BG = (11, 11, 14)


def glow(img, cx, cy, r, color, alpha):
    layer = Image.new('RGBA', img.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    d.ellipse((cx - r, cy - r, cx + r, cy + r), fill=color + (alpha,))
    layer = layer.filter(ImageFilter.GaussianBlur(r * .55))
    img.alpha_composite(layer)


def mark(img, cx, cy, r):
    s = 4  # суперсэмплинг
    size = int(r * 2 * s + 80 * s)
    m = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(m)
    c = size / 2
    R = r * s
    # ореол
    halo = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ImageDraw.Draw(halo).ellipse((c - R - 18 * s, c - R - 18 * s, c + R + 18 * s, c + R + 18 * s), fill=(142, 124, 255, 70))
    m.alpha_composite(halo.filter(ImageFilter.GaussianBlur(22 * s)))
    # диск
    d.ellipse((c - R, c - R, c + R, c + R), fill=(28, 28, 35, 255), outline=(255, 255, 255, 40), width=2 * s)
    # дуга света
    arc = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arc)
    for i in range(90):
        a0 = -200 + i * 2.4
        alpha = int(255 * (i / 90) ** 1.1)
        col = (int(159 + (255 - 159) * i / 90), int(140 + (255 - 140) * i / 90), 255, alpha)
        ad.arc((c - R, c - R, c + R, c + R), a0, a0 + 2.5, fill=col, width=3 * s)
    m.alpha_composite(arc.filter(ImageFilter.GaussianBlur(5 * s)))
    m.alpha_composite(arc)
    # play
    p = R * .62
    tri = [(c - p * .36, c - p * .5), (c + p * .56, c), (c - p * .36, c + p * .5)]
    d.polygon(tri, fill=(240, 238, 255, 255))
    m = m.resize((size // s, size // s), Image.LANCZOS)
    img.alpha_composite(m, (int(cx - m.width / 2), int(cy - m.height / 2)))


def side(w, h, path):
    img = Image.new('RGBA', (w, h), BG + (255,))
    k = w / 410
    glow(img, int(w * .15), int(h * .22), int(170 * k), (88, 64, 200), 150)
    glow(img, int(w * .95), int(h * .78), int(200 * k), (190, 90, 50), 110)
    glow(img, int(w * .5), int(h * .55), int(120 * k), (120, 100, 255), 60)
    mark(img, w / 2, h * .40, 92 * k)
    d = ImageDraw.Draw(img)
    f = ImageFont.truetype(FONT, int(30 * k))
    text = 'DEEP CINEMA'
    sp = int(7 * k)
    tw = sum(d.textlength(ch, font=f) for ch in text) + sp * (len(text) - 1)
    x = (w - tw) / 2
    for ch in text:
        d.text((x, h * .62), ch, font=f, fill=(245, 245, 247))
        x += d.textlength(ch, font=f) + sp
    f2 = ImageFont.truetype(os.path.join(ROOT, 'assets', 'fonts', 'Inter-Medium.ttf'), int(17 * k))
    sub = 'кино и сериалы'
    d.text(((w - d.textlength(sub, font=f2)) / 2, h * .62 + 50 * k), sub, font=f2, fill=(245, 245, 247, 150))
    img.convert('RGB').save(path)


def small(n, path):
    img = Image.new('RGBA', (n, n), BG + (255,))
    mark(img, n / 2, n / 2, n * .40)
    img.convert('RGB').save(path)


def back(w, h, path):
    img = Image.new('RGBA', (w, h), BG + (255,))
    glow(img, int(w * .1), int(h * .1), int(w * .35), (70, 50, 170), 90)
    glow(img, int(w * .95), int(h * .95), int(w * .4), (160, 80, 45), 70)
    img.convert('RGB').save(path)


os.makedirs(OUT, exist_ok=True)
for w, h in [(164, 314), (246, 459), (328, 604), (410, 797)]:
    side(w, h, os.path.join(OUT, f'side-{w}.bmp'))
for n in [55, 83, 110, 138]:
    small(n, os.path.join(OUT, f'small-{n}.bmp'))
back(1000, 760, os.path.join(OUT, 'back.png'))
print('ok')
