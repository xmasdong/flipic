# PixDeck 图标：一叠照片，最上面一张右上角折起露出下一张。
# 风景剪影的山脊线和树线逐列取自真实照片 yangshuo.jpg（桂林阳朔，Wikimedia Commons，CC0）。
# 用法：python3 scripts/icon/make_icon.py <输出 1024 PNG>（默认蓝灰底）
# 这里生成的是构图底稿；成品 PixDeck-icon-1024.png 是照底稿绘制的插画版。
import os, sys, math
from PIL import Image, ImageDraw, ImageFilter, ImageOps, ImageEnhance
SS=2; W=1024*SS
def L(v): return int(v*SS)

def cover(img, w, h, fx=0.5, fy=0.5):
    iw, ih = img.size; s = max(w/iw, h/ih)
    img = img.resize((max(w,int(iw*s)), max(h,int(ih*s))), Image.LANCZOS)
    iw, ih = img.size; x = int((iw-w)*fx); y = int((ih-h)*fy)
    return img.crop((x, y, x+w, y+h))

def ridge_silhouette(img, w, h, sky_top, sky_bot, far, near, water):
    # 从真实照片逐列提取山脊线和树线，画成干净的剪影：天空、远山、近处树线、水面
    img = cover(img, w, h)
    g = ImageOps.grayscale(img).filter(ImageFilter.GaussianBlur(3))
    px = g.load()
    def smooth(ys, k):
        return [sorted(ys[max(0, x-k):x+k+1])[len(ys[max(0, x-k):x+k+1])//2] for x in range(len(ys))]
    ridge = []
    for x in range(w):
        y = 0
        while y < h-1 and px[x, y] > 200: y += 1
        ridge.append(y)
    ridge = smooth(ridge, 6)
    trees = []
    for x in range(w):
        y = ridge[x] + 40
        while y < h-12 and not (px[x, y] < 55 and (px[x, y+6] + px[x, y+12]) / 2 < 70): y += 1
        trees.append(y)
    trees = smooth(trees, 18)
    water_y = int(h * 0.86)
    out = Image.new('RGB', (w, h)); d = ImageDraw.Draw(out)
    for y in range(h):
        t = y/h; c = tuple(int(sky_top[i]*(1-t)+sky_bot[i]*t) for i in range(3)); d.line([(0, y), (w, y)], fill=c)
    d.polygon([(0, h)] + [(x, ridge[x]) for x in range(w)] + [(w, h)], fill=far)
    d.polygon([(0, h)] + [(x, min(trees[x], water_y)) for x in range(w)] + [(w, h)], fill=near)
    d.rectangle((0, water_y, w, h), fill=water)
    # 水面倒影的几道细亮线
    for i, yy in enumerate((water_y + 14, water_y + 30, water_y + 50)):
        d.line([(w*0.18 + i*30, yy), (w*0.62 - i*24, yy)], fill=tuple(min(255, v+26) for v in water), width=3)
    return out

def gradient_card(w, h, top, bot):
    out = Image.new('RGB', (w, h)); d = ImageDraw.Draw(out)
    for y in range(h):
        t = y/h; d.line([(0, y), (w, y)], fill=tuple(int(top[i]*(1-t)+bot[i]*t) for i in range(3)))
    return out

def print_card(photo, w, h, border):
    card = Image.new('RGBA', (w, h), (250, 249, 246, 255))
    card.paste(cover(photo, w-2*border, h-2*border), (border, border))
    return card

def shadow_of(mask, blur, alpha, dy):
    sh = Image.new('RGBA', mask.size, (0, 0, 0, 0))
    a = mask.point(lambda v: int(v*alpha))
    sh.putalpha(a)
    sh = sh.filter(ImageFilter.GaussianBlur(blur))
    out = Image.new('RGBA', mask.size, (0, 0, 0, 0)); out.alpha_composite(sh, (0, dy))
    return out

def make(out, bg_top, bg_bot, mode='photo'):
    canvas = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    # 主体：824 圆角方形，竖向渐变底色
    body = Image.new('RGBA', (L(824), L(824)))
    bd = ImageDraw.Draw(body)
    for y in range(L(824)):
        t = y/L(824)
        c = tuple(int(bg_top[i]*(1-t)+bg_bot[i]*t) for i in range(3))
        bd.line([(0, y), (L(824), y)], fill=c+(255,))
    m = Image.new('L', body.size, 0)
    ImageDraw.Draw(m).rounded_rectangle((0, 0, L(824)-1, L(824)-1), radius=L(824*0.225), fill=255)
    body.putalpha(m)
    # 图标整体投影
    full = Image.new('L', (W, W), 0); full.paste(m, (L(100), L(100)))
    canvas.alpha_composite(shadow_of(full, L(14), 0.28, L(10)))
    canvas.alpha_composite(body, (L(100), L(100)))

    here = os.path.dirname(os.path.abspath(__file__))
    def box(img, l, t, r, b):
        w, h = img.size; return img.crop((int(w*l), int(h*t), int(w*r), int(h*b)))
    photos = [box(Image.open(os.path.join(here, 'yangshuo.jpg')).convert('RGB'), 0.0, 0.04, 0.56, 0.60)]
    if mode == 'ridge':
        photos = [ridge_silhouette(photos[0], 520, 600, (250, 232, 210), (244, 210, 180), (118, 134, 150), (52, 66, 82), (150, 166, 178)),
                  gradient_card(520, 600, (246, 150, 96), (120, 70, 96)),
                  gradient_card(520, 600, (190, 214, 196), (92, 130, 104))]
        photos = [p.resize((p.width*SS, p.height*SS), Image.LANCZOS) for p in photos]
    cw, ch, br = L(500), L(580), L(18)
    cx, cy = W//2 + L(18), W//2 + L(4)
    layer = Image.new('RGBA', (W, W), (0, 0, 0, 0))

    def place(card, angle, dx, dy):
        r = card.rotate(angle, resample=Image.BICUBIC, expand=True)
        x = cx - r.width//2 + dx; y = cy - r.height//2 + dy
        msk = Image.new('L', (W, W), 0); msk.paste(r.split()[3], (x, y))
        layer.alpha_composite(shadow_of(msk, L(10), 0.30, L(6)))
        layer.alpha_composite(r, (x, y))

    # 叠在最下面的一张，向左转一点
    place(print_card(photos[2], cw, ch, br), 8, -L(40), L(10))
    # 下一张，正放，被上面一张折角时露出来
    place(print_card(photos[1], cw, ch, br), 3, -L(20), L(4))

    # 最上面一张，右上角沿对角线折起
    top = print_card(photos[0], cw, ch, br)
    f = L(170)
    cut = Image.new('L', (cw, ch), 255)
    ImageDraw.Draw(cut).polygon([(cw-f, 0), (cw, 0), (cw, f)], fill=0)
    a = top.split()[3]; top.putalpha(Image.composite(a, Image.new('L', a.size, 0), cut))
    x0 = cx - cw//2; y0 = cy - ch//2
    tm = Image.new('L', (W, W), 0); tm.paste(top.split()[3], (x0, y0))
    layer.alpha_composite(shadow_of(tm, L(12), 0.32, L(8)))
    layer.alpha_composite(top, (x0, y0))

    # 折过来的纸背：三角形，对角线翻折后的位置，带浅灰渐变和投影
    p1 = (x0+cw-f, y0); p2 = (x0+cw, y0+f); p3 = (x0+cw-f, y0+f)
    flap_m = Image.new('L', (W, W), 0); ImageDraw.Draw(flap_m).polygon([p1, p2, p3], fill=255)
    layer.alpha_composite(shadow_of(flap_m, L(9), 0.35, L(5)))
    flap = Image.new('RGBA', (W, W), (0, 0, 0, 0)); fd = ImageDraw.Draw(flap)
    steps = 64
    for i in range(steps):
        t = i/steps
        c = int(244 - 54*t)
        q1 = (p1[0] + (p2[0]-p1[0])*t*0, p1[1])
        fd.polygon([(p3[0] + (p1[0]-p3[0])*0, p3[1]), (p1[0]+(p2[0]-p1[0])*(1-t), p1[1]+(p2[1]-p1[1])*(1-t)),
                    (p1[0]+(p2[0]-p1[0])*(1-(t+1/steps)), p1[1]+(p2[1]-p1[1])*(1-(t+1/steps)))], fill=(c, c, c-2, 255))
    flap.putalpha(Image.composite(flap.split()[3], Image.new('L', (W, W), 0), flap_m))
    layer.alpha_composite(flap)

    # 照片层裁进图标主体
    clip = Image.new('L', (W, W), 0); clip.paste(m, (L(100), L(100)))
    layer.putalpha(Image.composite(layer.split()[3], Image.new('L', (W, W), 0), clip))
    canvas.alpha_composite(layer)
    # 淡亮边，深色程序坞上也有轮廓
    rim = Image.new('RGBA', (W, W), (0, 0, 0, 0))
    ImageDraw.Draw(rim).rounded_rectangle((L(100)+1, L(100)+1, L(924)-2, L(924)-2), radius=L(824*0.225), outline=(255, 255, 255, 46), width=L(2))
    canvas.alpha_composite(rim)
    canvas.resize((1024, 1024), Image.LANCZOS).save(out)

if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'PixDeck-icon-1024.png'
    make(out, (92, 110, 130), (56, 68, 84), 'ridge')
