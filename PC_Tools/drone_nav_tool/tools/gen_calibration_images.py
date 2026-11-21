"""보정 마법사용 자세 참고 이미지 생성.

images/drone_top.png(드론 윗면 사진, 안테나가 위쪽)를 돌려 6단계 자세 그림을 만들고
기수·꼬리·L·R 표시를 넣는다. 기수가 안테나 쪽인 세트(a_)와 USB 쪽인 세트(u_)를 모두 만든다.

실행: python tools/gen_calibration_images.py   (Pillow 필요, 결과: assets/calibration/*.png)
"""
import math
import os

from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "images", "drone_top.png")
OUT = os.path.join(ROOT, "assets", "calibration")

CANVAS = 520
PHOTO_MAX = 300
LABEL_R = 190  # 중심에서 라벨까지 거리 (px)
FONT = "C:/Windows/Fonts/malgunbd.ttf"

# 사진 기준(안테나 위) 방향 벡터, 화면 좌표(y 아래)
NOSE, TAIL, LEFT, RIGHT = (0, -1), (0, 1), (-1, 0), (1, 0)

# (파일명, 시계 방향 회전 각도, 뒤집기, 바닥선, 제목)
STEPS = [
    ("step1", 0, False, False, "1 수평 — 윗면이 위로, 바닥에 평평하게"),
    ("step2", 0, False, True, "2 기수 위로 — 꼬리를 바닥에"),
    ("step3", 180, False, True, "3 기수 아래로 — 기수를 바닥에"),
    ("step4", 90, False, True, "4 오른쪽(R) 면을 바닥에"),
    ("step5", -90, False, True, "5 왼쪽(L) 면을 바닥에"),
    ("step6", 0, True, False, "6 뒤집기 — 윗면이 바닥, 밑면이 위"),
]


def font(size):
    return ImageFont.truetype(FONT, size)


def rot(v, deg):
    t = math.radians(deg)
    x, y = v
    return (x * math.cos(t) - y * math.sin(t), x * math.sin(t) + y * math.cos(t))


def badge(d, center, text, fill, size=26):
    f = font(size)
    l, t, r, b = d.textbbox((0, 0), text, font=f)
    w, h = r - l + 22, b - t + 14
    x, y = center[0] - w / 2, center[1] - h / 2
    d.rounded_rectangle((x, y, x + w, y + h), radius=h / 2, fill=fill)
    d.text((center[0], center[1]), text, font=f, fill="white", anchor="mm")


def arrow(d, center, vec, color):
    # 라벨 안쪽으로 짧은 화살표 (사진 가장자리 → 바깥 방향)
    x0, y0 = center[0] - vec[0] * 48, center[1] - vec[1] * 48
    x1, y1 = center[0] - vec[0] * 26, center[1] - vec[1] * 26
    d.line((x0, y0, x1, y1), fill=color, width=6)
    px, py = -vec[1], vec[0]
    d.polygon([(x1 + vec[0] * 10, y1 + vec[1] * 10), (x1 + px * 9, y1 + py * 9), (x1 - px * 9, y1 - py * 9)], fill=color)


def make(photo, nose_at_antenna, name, cw, flip, ground, title):
    img = photo if nose_at_antenna else photo.rotate(180)
    if flip:
        img = img.transpose(Image.FLIP_LEFT_RIGHT)
    img = img.rotate(-cw, expand=True, resample=Image.BICUBIC)
    if flip:  # 밑면이 보이는 상태라 어둡게
        dark = Image.new("RGBA", img.size, (40, 40, 60, 0))
        alpha = img.getchannel("A").point(lambda a: int(a * 0.45))
        dark.putalpha(alpha)
        img = Image.alpha_composite(img, dark)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (247, 249, 252, 255))
    c = (CANVAS // 2, CANVAS // 2 + (0 if not ground else -14))
    canvas.alpha_composite(img, (c[0] - img.width // 2, c[1] - img.height // 2))
    d = ImageDraw.Draw(canvas)

    def place(v):
        if flip:
            v = (-v[0], v[1])
        v = rot(v, cw)
        return (c[0] + v[0] * LABEL_R, c[1] + v[1] * LABEL_R), v

    for vec, text, color, size in [
        (TAIL, "꼬리", (120, 130, 140), 20),
        (LEFT, "L 왼쪽", (25, 118, 210), 24),
        (RIGHT, "R 오른쪽", (46, 125, 50), 24),
        (NOSE, "기수(앞)", (211, 47, 47), 26),
    ]:
        pos, v = place(vec)
        if vec == NOSE:
            arrow(d, pos, v, color)
        badge(d, pos, text, color, size)

    if ground:
        y = CANVAS - 38
        d.rectangle((30, y, CANVAS - 30, y + 10), fill=(141, 110, 99))
        d.text((CANVAS - 34, y + 22), "바닥", font=font(16), fill=(141, 110, 99), anchor="rm")
    if flip:
        d.text((c[0], c[1]), "밑면", font=font(30), fill="white", anchor="mm", stroke_width=3, stroke_fill=(60, 60, 80))
    d.text((CANVAS // 2, 22), title, font=font(20), fill=(33, 33, 33), anchor="mm")

    prefix = "a_" if nose_at_antenna else "u_"
    canvas.convert("RGB").save(os.path.join(OUT, f"{prefix}{name}.png"), optimize=True)


def remove_white_background(photo):
    """가장자리에서 이어진 흰 배경만 투명하게 (기판의 흰 커넥터는 남긴다)."""
    rgb = photo.convert("RGB")
    key = (255, 0, 255)
    w, h = rgb.size
    for seed in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)]:
        if rgb.getpixel(seed) != key:
            ImageDraw.floodfill(rgb, seed, key, thresh=40)
    out = photo.copy()
    alpha = out.getchannel("A")
    px, ap = rgb.load(), alpha.load()
    for y in range(h):
        for x in range(w):
            if px[x, y] == key:
                ap[x, y] = 0
    out.putalpha(alpha)
    return out


def main():
    os.makedirs(OUT, exist_ok=True)
    photo = remove_white_background(Image.open(SRC).convert("RGBA"))
    s = PHOTO_MAX / max(photo.size)
    photo = photo.resize((round(photo.width * s), round(photo.height * s)), Image.LANCZOS)
    for nose_at_antenna in (True, False):
        for step in STEPS:
            make(photo, nose_at_antenna, *step)
        make(photo, nose_at_antenna, "top", 0, False, False, "윗면 — 기수·L·R 방향")
    print("saved to", OUT)


if __name__ == "__main__":
    main()
