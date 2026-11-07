#!/usr/bin/python3
"""MadeOfBlue screensaver: a retro pixel-art skater rolling through a night city.

Draws "pixels" with the upper-half-block character in 24-bit colour, two pixels
per terminal cell, so it runs inside any truecolour terminal. madeofblue-screensaver
opens it fullscreen in foot. Any key quits; Noctalia's idle resume kills it on
any other activity.
"""

import os
import random
import select
import signal
import sys
import termios
import time
import tty

FPS = 15
FRAME = 1.0 / FPS
SPEED = 2  # road pixels per frame, before scaling
JUMP_FRAMES = 16
JUMP_HEIGHT = 14  # sprite pixels at the top of an ollie

# A small, NES-flavoured palette. Index 0 is "transparent" in sprites.
PALETTE = {
    "sky0": (8, 10, 32),
    "sky1": (14, 18, 52),
    "sky2": (24, 30, 78),
    "sky3": (40, 44, 104),
    "star": (240, 240, 210),
    "star_dim": (120, 120, 150),
    "moon": (236, 232, 180),
    "city_far": (30, 34, 82),
    "city_near": (18, 20, 50),
    "window": (250, 210, 90),
    "window_off": (44, 46, 96),
    "kerb": (110, 110, 130),
    "road": (52, 52, 64),
    "road_dark": (40, 40, 50),
    "line": (230, 200, 60),
    "cone": (252, 116, 40),
    "cone_band": (250, 250, 250),
    "outline": (12, 12, 20),
    "skin": (252, 188, 140),
    "cap": (40, 110, 240),
    "shirt": (60, 188, 252),
    "pants": (24, 56, 160),
    "shoe": (248, 248, 248),
    "board": (200, 76, 12),
    "wheel": (188, 188, 188),
    "text": (60, 188, 252),
}

SPRITE_KEY = {
    ".": None,
    "K": "outline",
    "S": "skin",
    "H": "cap",
    "T": "shirt",
    "P": "pants",
    "W": "shoe",
    "B": "board",
    "G": "wheel",
}

# Right-facing skater, 14 x 16. Frames alternate while rolling; TUCK is the ollie.
ROLL_A = [
    "....KKKK......",
    "...KHHHHK.....",
    "..KHHHHHHHK...",
    "...KSSSKSK....",
    "...KSSSSSK....",
    "....KTTTK.....",
    "...KTTTTTK....",
    "..KSKTTTKSK...",
    "...K.TTT.K....",
    "....KPPPPK....",
    "....KPKKPK....",
    "...KPK..KPK...",
    "...KWK..KWK...",
    ".KBBBBBBBBBBK.",
    "..KGK....KGK..",
    "...K......K...",
]
ROLL_B = [
    "....KKKK......",
    "...KHHHHK.....",
    "..KHHHHHHHK...",
    "...KSSSKSK....",
    "...KSSSSSK....",
    "....KTTTK.....",
    "...KTTTTTK....",
    "...KSTTTSK....",
    "....KTTTK.....",
    "....KPPPPK....",
    "....KPKPPK....",
    "...KPK.KPK....",
    "...KWK.KWK....",
    ".KBBBBBBBBBBK.",
    "..KGK....KGK..",
    "...K......K...",
]
TUCK = [
    "....KKKK......",
    "...KHHHHK.....",
    "..KHHHHHHHK...",
    "...KSSSKSK....",
    "...KSSSSSK....",
    ".KSKTTTTKSK...",
    "..KKTTTTTKK...",
    "....KTTTK.....",
    "...KPPPPPK....",
    "..KPPKKKPPK...",
    "..KWK...KWK...",
    ".KBBBBBBBBBBK.",
    "..KGK....KGK..",
    "...K......K...",
    "..............",
    "..............",
]
CONE = [
    "...KK...",
    "..KCCK..",
    "..KCCK..",
    ".KWWWWK.",
    ".KCCCCK.",
    "KCCCCCCK",
    "KKKKKKKK",
]
CONE_KEY = {".": None, "K": "outline", "C": "cone", "W": "cone_band"}


def rgb_escape(fg, bg):
    return "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm" % (fg + bg)


class Scene:
    def __init__(self, cols, rows):
        self.cols = max(cols, 20)
        self.rows = max(rows, 10)
        self.w = self.cols
        self.h = self.rows * 2
        # Sprite pixels become scale x scale screen pixels so the skater stays
        # chunky on large displays.
        self.scale = max(1, self.h // 48)
        self.ground_y = int(self.h * 0.78)
        self.rng = random.Random(1987)
        self.stars = [
            (self.rng.randrange(self.w), self.rng.randrange(int(self.h * 0.5)), self.rng.random())
            for _ in range(max(12, self.w * self.h // 220))
        ]
        self.far = self._skyline(self.rng, 6, 18, 0.32)
        self.near = self._skyline(self.rng, 8, 24, 0.22)
        self.sky = self._sky()
        self.skater_x = self.w // 4
        self.cones = []
        self.next_cone = self.w + self.rng.randrange(20, 60)
        self.jump_t = None
        self.distance = 0

    def _sky(self):
        bands = ["sky0", "sky1", "sky2", "sky3"]
        rows = []
        for y in range(self.ground_y):
            f = y / max(1, self.ground_y - 1) * (len(bands) - 1)
            lo = int(f)
            hi = min(lo + 1, len(bands) - 1)
            frac = f - lo
            row = []
            for x in range(self.w):
                # Ordered 2x2 dither between neighbouring bands, the way
                # 8-bit games faked gradients.
                threshold = ((x & 1) * 2 + (y & 1)) / 4.0
                row.append(PALETTE[bands[hi] if frac > threshold else bands[lo]])
            rows.append(row)
        return rows

    def _skyline(self, rng, min_w, max_w, height_frac):
        """One repeating strip of buildings: list of (width, height, windows)."""
        buildings = []
        total = 0
        max_h = int(self.h * height_frac)
        while total < self.w * 2:
            bw = rng.randrange(min_w, max_w) * self.scale
            bh = rng.randrange(max_h // 3, max_h + 1)
            lit = {
                (wx, wy)
                for wx in range(2, bw - 2, 3)
                for wy in range(3, bh - 2, 4)
                if rng.random() < 0.35
            }
            buildings.append((bw, bh, lit))
            total += bw + rng.randrange(0, 3)
        return buildings, total

    def blit(self, fb, sprite, key, x0, y0):
        s = self.scale
        for sy, line in enumerate(sprite):
            for sx, ch in enumerate(line):
                name = key[ch]
                if name is None:
                    continue
                colour = PALETTE[name]
                for dy in range(s):
                    y = y0 + sy * s + dy
                    if 0 <= y < self.h:
                        row = fb[y]
                        for dx in range(s):
                            x = x0 + sx * s + dx
                            if 0 <= x < self.w:
                                row[x] = colour

    def draw_skyline(self, fb, layer, colour, speed, tick):
        buildings, period = layer
        offset = int(tick * speed) % period
        x = -offset
        base = self.ground_y
        while x < self.w:
            for bw, bh, lit in buildings:
                if x >= self.w:
                    break
                for bx in range(max(0, x), min(self.w, x + bw)):
                    for by in range(base - bh, base):
                        fb[by][bx] = colour
                for wx, wy in lit:
                    px, py = x + wx, base - bh + wy
                    if 0 <= px < self.w and 0 <= py < base:
                        fb[py][px] = PALETTE["window"]
                x += bw + 1

    def update(self, tick):
        speed = SPEED * self.scale
        self.distance += speed
        for cone in self.cones:
            cone[0] -= speed
        self.cones = [c for c in self.cones if c[0] > -10 * self.scale]
        self.next_cone -= speed
        if self.next_cone <= 0:
            self.cones.append([self.w, 0])
            self.next_cone = self.rng.randrange(self.w // 3, self.w) + 30
        # Pop an ollie when a cone gets close.
        if self.jump_t is None:
            for cone in self.cones:
                gap = cone[0] - (self.skater_x + 14 * self.scale)
                if 0 <= gap <= 6 * self.scale:
                    self.jump_t = 0
        if self.jump_t is not None:
            self.jump_t += 1
            if self.jump_t > JUMP_FRAMES:
                self.jump_t = None

    def render(self, tick):
        fb = [row[:] for row in self.sky]
        fb.extend([PALETTE["road"]] * self.w for _ in range(self.h - self.ground_y))

        for sx, sy, phase in self.stars:
            twinkle = (tick // 6 + int(phase * 10)) % 10
            if twinkle:
                fb[sy][sx] = PALETTE["star" if twinkle > 3 else "star_dim"]

        # Moon
        mr = 3 * self.scale
        mx, my = self.w - self.w // 6, self.h // 7
        for y in range(my - mr, my + mr + 1):
            for x in range(mx - mr, mx + mr + 1):
                if (x - mx) ** 2 + (y - my) ** 2 <= mr * mr and 0 <= y < self.h and 0 <= x < self.w:
                    fb[y][x] = PALETTE["moon"]

        self.draw_skyline(fb, self.far, PALETTE["city_far"], 0.25 * SPEED * self.scale, tick)
        self.draw_skyline(fb, self.near, PALETTE["city_near"], 0.5 * SPEED * self.scale, tick)

        # Kerb, road texture and the scrolling centre line.
        for x in range(self.w):
            fb[self.ground_y][x] = PALETTE["kerb"]
        line_y = self.ground_y + (self.h - self.ground_y) * 2 // 3
        for x in range(self.w):
            if ((x + self.distance) // (6 * self.scale)) % 2 == 0:
                for t in range(self.scale):
                    if line_y + t < self.h:
                        fb[line_y + t][x] = PALETTE["line"]
            if (x + self.distance) % 7 == 0:
                fb[min(self.h - 1, self.ground_y + 2)][x] = PALETTE["road_dark"]

        ride_y = self.ground_y + 2 * self.scale
        for cx, _ in self.cones:
            self.blit(fb, CONE, CONE_KEY, cx, ride_y - len(CONE) * self.scale)

        if self.jump_t is not None:
            # Parabolic hop, long and high enough to clear a cone.
            t = self.jump_t / float(JUMP_FRAMES)
            lift = int(4 * t * (1 - t) * JUMP_HEIGHT * self.scale)
            sprite = TUCK
            sprite_h = 14
        else:
            lift = 0
            sprite = ROLL_A if (tick // 4) % 2 == 0 else ROLL_B
            sprite_h = 16
        top = ride_y - sprite_h * self.scale - lift
        self.blit(fb, sprite, SPRITE_KEY, self.skater_x, top)
        return fb

    def encode(self, fb, tick):
        out = ["\x1b[H"]
        last = None
        for r in range(self.rows):
            top = fb[2 * r]
            bottom = fb[2 * r + 1]
            out.append("\x1b[%d;1H" % (r + 1))
            for x in range(self.w):
                pair = (top[x], bottom[x])
                if pair != last:
                    out.append(rgb_escape(pair[0], pair[1]))
                    last = pair
                out.append("▀")
        # Blinking prompt, arcade attract-mode style.
        if (tick // (FPS // 2)) % 2 == 0:
            msg = " PRESS ANY KEY "
            row = self.rows - 1
            col = max(1, (self.cols - len(msg)) // 2 + 1)
            out.append("\x1b[%d;%dH\x1b[1m" % (row, col))
            out.append(rgb_escape(PALETTE["text"], PALETTE["road"]))
            out.append(msg)
            out.append("\x1b[22m")
            last = None
        return "".join(out)


def main():
    out = sys.stdout
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd) if os.isatty(fd) else None
    resized = [True]

    def on_winch(*_):
        resized[0] = True

    def on_term(*_):
        raise SystemExit(0)

    signal.signal(signal.SIGWINCH, on_winch)
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGHUP, on_term)

    if saved is not None:
        tty.setcbreak(fd)
    out.write("\x1b[?1049h\x1b[?25l")
    out.flush()
    scene = None
    tick = 0
    try:
        while True:
            start = time.monotonic()
            if resized[0]:
                resized[0] = False
                size = os.get_terminal_size(out.fileno()) if out.isatty() else os.terminal_size((80, 24))
                scene = Scene(size.columns, size.lines)
                out.write("\x1b[0m\x1b[2J")
            scene.update(tick)
            out.write(scene.encode(scene.render(tick), tick))
            out.flush()
            tick += 1
            wait = max(0.0, FRAME - (time.monotonic() - start))
            try:
                ready, _, _ = select.select([fd], [], [], wait)
            except InterruptedError:
                continue
            if ready:
                return
    except KeyboardInterrupt:
        pass
    finally:
        out.write("\x1b[0m\x1b[?25h\x1b[?1049l")
        out.flush()
        if saved is not None:
            termios.tcsetattr(fd, termios.TCSADRAIN, saved)


if __name__ == "__main__":
    main()
