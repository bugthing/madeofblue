#!/usr/bin/python3
"""MadeOfBlue screensaver: an autonomous skateboard that grinds, flips, and
progressively scratches, cracks, chips, and bloodies what is on the screen.

In a Wayland/X11 graphical session, madeofblue-screensaver captures the live
screen with grim (falling back to the MadeOfBlue desktop wallpaper), opens a
fullscreen GTK4 + Cairo window, and animates a miniature MadeOfBlue Screaming
Hand skateboard doing grinds along monitor/window ledges, curved powerslides,
flip tricks, and slams that leave gouges, urethane skid marks, glass cracks,
wood/blue paint debris, and blood splatters across the screen.

When run with --tty (or when no graphical display is available), it runs an
equivalent simulation in the terminal using 24-bit half-block characters.
"""

import argparse
import math
import os
import pathlib
import random
import select
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
import tty

WALLPAPER_PATHS = [
    pathlib.Path("/usr/share/backgrounds/madeofblue/madeofblue.jpeg"),
    pathlib.Path(__file__).resolve().parents[3]
    / "usr/share/backgrounds/madeofblue/madeofblue.jpeg",
]

# Signature horizontal rails/ledges aligned with madeofblue.jpeg (normalized 0..1):
# (y_norm, x0_norm, x1_norm, kind)
WORKSHOP_LEDGES = [
    (0.478, 0.148, 0.292, "metal"),   # Left PC case top edge
    (0.503, 0.232, 0.422, "bezel"),   # Left monitor top rail
    (0.720, 0.232, 0.422, "bezel"),   # Left monitor bottom bezel
    (0.502, 0.576, 0.772, "bezel"),   # Right monitor top rail
    (0.722, 0.576, 0.772, "bezel"),   # Right monitor bottom bezel
    (0.706, 0.824, 0.898, "metal"),   # Soldering station top
    (0.842, 0.382, 0.618, "keys"),    # Mechanical keyboard top rail
    (0.786, 0.080, 0.920, "desk"),    # Back edge of workshop desk
    (0.905, 0.060, 0.940, "desk"),    # Front surface of workshop desk
    (0.375, 0.025, 0.135, "wood"),    # Skateboard wall rack
]

# Flat surfaces where the skateboard can carve & powerslide across 2D areas:
# (x0_norm, y0_norm, x1_norm, y1_norm, kind)
SLIDE_ZONES = [
    (0.240, 0.520, 0.415, 0.705, "screen_left"),   # Left monitor screen glass
    (0.585, 0.520, 0.765, 0.705, "screen_right"),  # Right monitor screen glass
    (0.080, 0.790, 0.920, 0.935, "desk_surface"),  # Workshop desk surface
]

TRICK_NAMES = [
    "kickflip",
    "double_kickflip",
    "heelflip",
    "tre_flip",
    "hardflip",
    "pop_shuvit",
    "ollie",
]

GRIND_TYPES = [
    "50-50",
    "5-0",
    "nosegrind",
    "boardslide",
    "noseslide",
    "tailslide",
    "darkslide",
]


def find_wallpaper():
    for path in WALLPAPER_PATHS:
        if path.is_file():
            return path
    return None


def capture_screen_png():
    """Try capturing the live Wayland output via grim before opening our window."""
    if not os.environ.get("WAYLAND_DISPLAY") or not shutil.which("grim"):
        return None
    runtime_dir = os.environ.get("XDG_RUNTIME_DIR") or "/tmp"
    fd, tmp_path = tempfile.mkstemp(
        prefix="madeofblue-screen-", suffix=".png", dir=runtime_dir
    )
    os.close(fd)
    try:
        res = subprocess.run(
            ["grim", "-l", "1", tmp_path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.5,
            check=False,
        )
        if res.returncode == 0 and os.path.getsize(tmp_path) > 0:
            return pathlib.Path(tmp_path)
    except Exception:
        pass
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    return None


def pixbuf_to_cairo_surface(pixbuf, target_w, target_h):
    """Scale and center-crop a GdkPixbuf to (target_w, target_h) as a Cairo ImageSurface."""
    import cairo

    src_w = pixbuf.get_width()
    src_h = pixbuf.get_height()
    n_ch = pixbuf.get_n_channels()
    rowstride = pixbuf.get_rowstride()
    raw = pixbuf.get_pixels()

    src_surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, src_w, src_h)
    dst = memoryview(src_surface.get_data())
    dst_stride = src_surface.get_stride()

    for y in range(src_h):
        s_off = y * rowstride
        d_off = y * dst_stride
        row_bytes = raw[s_off : s_off + src_w * n_ch]
        out_row = bytearray(src_w * 4)
        out_row[0::4] = row_bytes[2::n_ch]  # B
        out_row[1::4] = row_bytes[1::n_ch]  # G
        out_row[2::4] = row_bytes[0::n_ch]  # R
        if n_ch == 4:
            out_row[3::4] = row_bytes[3::4]
        else:
            out_row[3::4] = b"\xff" * src_w
        dst[d_off : d_off + src_w * 4] = out_row
    src_surface.mark_dirty()

    if src_w == target_w and src_h == target_h:
        return src_surface

    out_surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, target_w, target_h)
    cr = cairo.Context(out_surface)
    scale = max(target_w / float(src_w), target_h / float(src_h))
    ox = (target_w - src_w * scale) * 0.5
    oy = (target_h - src_h * scale) * 0.5
    cr.translate(ox, oy)
    cr.scale(scale, scale)
    cr.set_source_surface(src_surface, 0, 0)
    cr.get_source().set_filter(cairo.FILTER_BILINEAR)
    cr.paint()
    return out_surface


def paint_fallback_background(surface):
    """Fallback dark workshop backdrop if neither grim nor wallpaper is available."""
    import cairo

    w = surface.get_width()
    h = surface.get_height()
    cr = cairo.Context(surface)
    grad = cairo.LinearGradient(0, 0, 0, h)
    grad.add_color_stop_rgb(0.0, 0.04, 0.06, 0.11)
    grad.add_color_stop_rgb(0.75, 0.07, 0.10, 0.16)
    grad.add_color_stop_rgb(0.79, 0.05, 0.06, 0.09)
    grad.add_color_stop_rgb(1.0, 0.03, 0.04, 0.06)
    cr.set_source(grad)
    cr.paint()


def detect_screen_ledges(surface):
    """Combine signature workshop rails with strong horizontal contrast edges on screen."""
    w = surface.get_width()
    h = surface.get_height()
    ledges = []

    for yn, x0n, x1n, kind in WORKSHOP_LEDGES:
        ledges.append((yn * h, x0n * w, x1n * w, kind))

    data = memoryview(surface.get_data())
    stride = surface.get_stride()
    grid_w, grid_h = 96, 54
    step_x = max(1, w // grid_w)
    step_y = max(1, h // grid_h)

    def luma(px, py):
        px = min(w - 1, max(0, px))
        py = min(h - 1, max(0, py))
        off = py * stride + px * 4
        return data[off] * 0.114 + data[off + 1] * 0.587 + data[off + 2] * 0.299

    for gy in range(8, grid_h - 5):
        py = gy * step_y
        run_start = None
        for gx in range(2, grid_w - 2):
            px = gx * step_x
            diff_v = abs(luma(px, py + 2) - luma(px, py - 2))
            if diff_v > 38.0:
                if run_start is None:
                    run_start = px
            else:
                if run_start is not None and (px - run_start) >= w * 0.16:
                    ledges.append((float(py), float(run_start), float(px), "window"))
                run_start = None
        if run_start is not None and ((grid_w - 2) * step_x - run_start) >= w * 0.16:
            ledges.append(
                (float(py), float(run_start), float((grid_w - 2) * step_x), "window")
            )

    filtered = []
    for y, x0, x1, kind in ledges:
        duplicate = False
        for fy, fx0, fx1, _ in filtered:
            if abs(y - fy) < h * 0.035 and min(x1, fx1) - max(x0, fx0) > w * 0.10:
                duplicate = True
                break
        if not duplicate:
            filtered.append((y, x0, x1, kind))
    return filtered


class SkateDamageEngine:
    """Autonomous skateboard physics, trick state machine, and persistent screen damage."""

    def __init__(self, surface, seed=None):
        import cairo

        self.surface = surface
        self.w = surface.get_width()
        self.h = surface.get_height()
        self.damage_cr = cairo.Context(self.surface)
        self.rng = random.Random(seed)
        self.scale = max(0.65, min(self.w, self.h) / 1080.0)
        self.board_len = 136.0 * self.scale
        self.board_w = 35.0 * self.scale

        self.ledges = detect_screen_ledges(self.surface)

        # Spawn right from the center leaning skateboard in madeofblue.jpeg!
        self.x = self.w * 0.50
        self.y = self.h * 0.48
        self.z = 55.0 * self.scale
        self.prev_x = self.x
        self.prev_y = self.y

        self.yaw = 0.15
        self.pitch = 0.0
        self.roll = math.pi  # Starts graphic-side out, kickflipping off the center wall!

        self.state = "AIR"
        self.state_t = 0.0
        self.state_dur = 0.72
        self.air_start = (self.x, self.y)
        first_ledge = (
            self.ledges[1]
            if len(self.ledges) > 1
            else (self.h * 0.78, self.w * 0.2, self.w * 0.8, "desk")
        )
        self.air_end = (first_ledge[1] + 40.0 * self.scale, first_ledge[0])
        self.air_height = 110.0 * self.scale
        self.trick = "kickflip"
        self.flip_spins = 1.5  # Half-flip from graphic side to grip-tape landing
        self.yaw_spin = 0.0
        self.base_yaw = math.atan2(
            self.air_end[1] - self.y, self.air_end[0] - self.x
        )
        self.next_action = ("GRIND", first_ledge)

        self.active_ledge = first_ledge
        self.grind_type = "50-50"
        self.grind_dir = 1.0
        self.grind_speed = 500.0 * self.scale

        # Curved slide / carve trajectory state
        self.curve_p0 = (self.x, self.y)
        self.curve_p1 = (self.x, self.y)
        self.curve_p2 = (self.x, self.y)

        self.wheel_phase = 0.0
        self.blood_tire = 0.15
        self.board_wear = 0.12
        self.tricks_since_bail = 0
        self.bails_count = 0
        self.tick_count = 0

        # Transient particles: sparks, debris (wood/blue paint/glass), and active blood drips
        self.sparks = []
        self.debris = []
        self.blood_drips = []

        # Pop burst as the board detaches from the center deck on the wallpaper
        self._spawn_debris_burst(
            self.x, self.y, floor_y=self.h * 0.82, count=10, speed=180.0
        )

    def _spawn_sparks(self, x, y, dir_x, count=4):
        for _ in range(count):
            ang = math.atan2(
                -self.rng.uniform(0.12, 0.92), -dir_x * self.rng.uniform(0.35, 1.15)
            )
            spd = self.rng.uniform(110.0, 330.0) * self.scale
            self.sparks.append(
                [
                    x + self.rng.uniform(-5, 5) * self.scale,
                    y + self.rng.uniform(-2, 2) * self.scale,
                    math.cos(ang) * spd,
                    math.sin(ang) * spd,
                    self.rng.uniform(0.14, 0.36),
                    self.rng.choice(["gold", "orange", "white"]),
                ]
            )

    def _spawn_debris_burst(
        self, x, y, floor_y=None, count=8, speed=170.0, include_glass=False
    ):
        kinds = ["blue_paint", "cyan_paint", "wood", "wood", "grip"]
        if include_glass:
            kinds.extend(["glass", "glass"])
        if floor_y is None:
            floor_y = min(self.h * 0.93, y + self.rng.uniform(4.0, 22.0) * self.scale)
        for _ in range(count):
            ang = self.rng.uniform(-math.pi * 0.92, -math.pi * 0.08)
            spd = self.rng.uniform(40.0, speed) * self.scale
            target_floor = max(
                y + 2.0 * self.scale,
                floor_y + self.rng.uniform(-6.0, 10.0) * self.scale,
            )
            self.debris.append(
                [
                    x + self.rng.uniform(-8, 8) * self.scale,
                    y + self.rng.uniform(-4, 3) * self.scale,
                    math.cos(ang) * spd,
                    math.sin(ang) * spd - 45.0 * self.scale,
                    self.rng.uniform(0, math.tau),
                    self.rng.uniform(-12.0, 12.0),
                    target_floor,
                    self.rng.uniform(1.4, 3.3) * self.scale,
                    self.rng.choice(kinds),
                    0,  # bounce count
                ]
            )

    def _stamp_settled_debris(self, x, y, angle, size, kind):
        cr = self.damage_cr
        cr.save()
        cr.translate(x, y)
        cr.rotate(angle)
        if kind == "blue_paint":
            cr.set_source_rgba(0.14, 0.38, 0.88, 0.78)
        elif kind == "cyan_paint":
            cr.set_source_rgba(0.22, 0.70, 0.96, 0.80)
        elif kind == "wood":
            cr.set_source_rgba(0.78, 0.61, 0.38, 0.76)
        elif kind == "glass":
            cr.set_source_rgba(0.86, 0.95, 1.0, 0.75)
        else:
            cr.set_source_rgba(0.09, 0.10, 0.13, 0.76)
        cr.move_to(-size, -size * 0.38)
        cr.line_to(size * 0.85, -size * 0.18)
        cr.line_to(size * 0.35, size * 0.45)
        cr.line_to(-size * 0.65, size * 0.28)
        cr.close_path()
        cr.fill()
        cr.restore()

    def _stamp_grind_damage(self, x0, y0, x1, y1, grind_type):
        """Carve raw metal/wood scratches, gouges, and paint rub along a ground ledge."""
        cr = self.damage_cr
        s = self.scale
        cr.save()
        cr.set_line_cap(1)

        # Deep dark truck-grind gouge channel
        cr.set_source_rgba(0.05, 0.06, 0.09, 0.76)
        cr.set_line_width(3.0 * s)
        cr.move_to(x0, y0 + self.rng.uniform(-1.0, 1.0) * s)
        cr.line_to(x1, y1 + self.rng.uniform(-1.0, 1.0) * s)
        cr.stroke()

        # Exposed bright raw aluminium / scratched screen pixel edge
        cr.set_source_rgba(0.86, 0.91, 0.98, 0.72)
        cr.set_line_width(1.15 * s)
        cr.move_to(x0, y0 - 1.2 * s + self.rng.uniform(-0.6, 0.6) * s)
        cr.line_to(x1, y1 - 1.2 * s + self.rng.uniform(-0.6, 0.6) * s)
        cr.stroke()

        # Boardslides / darkslides rub blue deck paint & maple wood onto the ledge
        if grind_type in ("boardslide", "noseslide", "tailslide", "darkslide"):
            if self.rng.random() < 0.70:
                cr.set_source_rgba(0.20, 0.64, 0.96, 0.52)
            else:
                cr.set_source_rgba(0.78, 0.60, 0.36, 0.50)
            cr.set_line_width(1.9 * s)
            cr.move_to(x0, y0 + 1.4 * s)
            cr.line_to(x1, y1 + 1.4 * s)
            cr.stroke()

        # Fine diagonal chatter marks chewing into the bezel/rail
        if self.rng.random() < 0.55:
            mx = 0.5 * (x0 + x1)
            my = 0.5 * (y0 + y1)
            dx = self.rng.uniform(-7.0, 7.0) * s
            dy = self.rng.uniform(-4.0, 5.0) * s
            cr.set_source_rgba(0.76, 0.84, 0.94, 0.48)
            cr.set_line_width(0.85 * s)
            cr.move_to(mx - dx * 0.4, my - dy * 0.4)
            cr.line_to(mx + dx, my + dy)
            cr.stroke()

        cr.restore()

    def _stamp_wheel_tracks(self, x0, y0, x1, y1, yaw, is_powerslide=False):
        """Stamp curved 4-wheel urethane skid marks or bloody wheel tracks onto the screen."""
        cr = self.damage_cr
        s = self.scale
        cr.save()
        cr.set_line_cap(1)

        perp_x = -math.sin(yaw)
        perp_y = math.cos(yaw)
        ax_x = math.cos(yaw)
        ax_y = math.sin(yaw)

        offsets = [
            (-0.32 * self.board_len, -0.38 * self.board_w),
            (-0.32 * self.board_len, 0.38 * self.board_w),
            (0.32 * self.board_len, -0.38 * self.board_w),
            (0.32 * self.board_len, 0.38 * self.board_w),
        ]

        for lx, ly in offsets:
            wx = ax_x * lx + perp_x * ly
            wy = (ax_y * lx + perp_y * ly) * 0.55
            if is_powerslide:
                # Dark burnt rubber/urethane skid mark
                cr.set_source_rgba(0.07, 0.08, 0.10, 0.48)
                cr.set_line_width(3.2 * s)
                cr.move_to(x0 + wx, y0 + wy)
                cr.line_to(x1 + wx, y1 + wy)
                cr.stroke()

                # Visible warm urethane scuff streak + fine screen glass scratch
                cr.set_source_rgba(0.82, 0.78, 0.68, 0.36)
                cr.set_line_width(1.35 * s)
                cr.move_to(x0 + wx + 0.9 * s, y0 + wy)
                cr.line_to(x1 + wx + 0.9 * s, y1 + wy)
                cr.stroke()

            if self.blood_tire > 0.03:
                alpha = min(0.64, self.blood_tire * (0.56 if is_powerslide else 0.34))
                cr.set_source_rgba(0.58, 0.04, 0.08, alpha)
                cr.set_line_width((2.3 if is_powerslide else 1.5) * s)
                cr.move_to(x0 + wx, y0 + wy)
                cr.line_to(x1 + wx, y1 + wy)
                cr.stroke()

        cr.restore()

    def _stamp_scuff_mark(self, x, y, yaw, intensity=1.0):
        """Stamp black grip-tape / tail-pop scuff & wood scratch on takeoff or landing."""
        cr = self.damage_cr
        s = self.scale
        cr.save()
        cr.translate(x, y)
        cr.rotate(yaw)

        cr.set_source_rgba(0.06, 0.07, 0.09, 0.42 * intensity)
        cr.scale(1.0, 0.42)
        cr.arc(0, 0, 13.0 * s * intensity, 0, math.tau)
        cr.fill()

        cr.set_source_rgba(0.82, 0.87, 0.94, 0.40 * intensity)
        cr.set_line_width(0.95 * s)
        for _ in range(4):
            sx = self.rng.uniform(-11.0, 3.0) * s
            sy = self.rng.uniform(-4.5, 4.5) * s
            cr.move_to(sx, sy)
            cr.line_to(
                sx + self.rng.uniform(7.0, 16.0) * s,
                sy + self.rng.uniform(-1.8, 1.8) * s,
            )
            cr.stroke()
        cr.restore()

    def _stamp_glass_crack(self, x, y, severity=1.0):
        """Crack and chip the screen 'glass' on a hard slam or bail."""
        cr = self.damage_cr
        s = self.scale * severity
        cr.save()

        # Impact crater (chipped white/cyan glass core)
        cr.set_source_rgba(0.04, 0.06, 0.10, 0.82)
        cr.arc(x, y, 4.2 * s, 0, math.tau)
        cr.fill()
        cr.set_source_rgba(0.86, 0.95, 1.0, 0.88)
        cr.arc(x, y, 2.2 * s, 0, math.tau)
        cr.fill()

        num_rays = self.rng.randint(6, 10)
        ray_paths = []
        for i in range(num_rays):
            base_ang = (i / float(num_rays)) * math.tau + self.rng.uniform(-0.24, 0.24)
            length = self.rng.uniform(22.0, 76.0) * s
            steps = self.rng.randint(4, 6)
            pts = [(x, y)]
            cx, cy = x, y
            ang = base_ang
            for step in range(1, steps + 1):
                ang += self.rng.uniform(-0.26, 0.26)
                seg = (length / steps) * self.rng.uniform(0.75, 1.25)
                cx += math.cos(ang) * seg
                cy += math.sin(ang) * seg
                pts.append((cx, cy))

                if step in (2, 3) and self.rng.random() < 0.50:
                    b_ang = ang + self.rng.choice([-1, 1]) * self.rng.uniform(0.35, 0.75)
                    b_len = seg * self.rng.uniform(0.7, 1.35)
                    bx = cx + math.cos(b_ang) * b_len
                    by = cy + math.sin(b_ang) * b_len
                    self._stroke_crack_segment(cr, [(cx, cy), (bx, by)], 0.7 * s)

            ray_paths.append(pts)
            self._stroke_crack_segment(cr, pts, 1.05 * s)

        for ring_idx in range(1, 3):
            for i in range(len(ray_paths)):
                p1 = ray_paths[i]
                p2 = ray_paths[(i + 1) % len(ray_paths)]
                if (
                    ring_idx < len(p1)
                    and ring_idx < len(p2)
                    and self.rng.random() < 0.68
                ):
                    self._stroke_crack_segment(
                        cr, [p1[ring_idx], p2[ring_idx]], 0.65 * s
                    )

        cr.restore()

    def _stroke_crack_segment(self, cr, pts, width):
        cr.set_source_rgba(0.03, 0.04, 0.08, 0.84)
        cr.set_line_width(width * 1.3)
        cr.move_to(pts[0][0], pts[0][1] + 0.9)
        for px, py in pts[1:]:
            cr.line_to(px, py + 0.9)
        cr.stroke()

        cr.set_source_rgba(0.84, 0.95, 1.0, 0.78)
        cr.set_line_width(width * 0.8)
        cr.move_to(pts[0][0], pts[0][1])
        for px, py in pts[1:]:
            cr.line_to(px, py)
        cr.stroke()

    def _stamp_blood_splatter(self, x, y, dir_angle, severity=1.0):
        """Splash organic crimson blood smear & fine droplets from a skate injury."""
        cr = self.damage_cr
        s = self.scale * severity
        cr.save()

        # Directional skid smear along the impact vector
        smear_len = self.rng.uniform(14.0, 28.0) * s
        cr.save()
        cr.translate(x, y)
        cr.rotate(dir_angle)
        cr.set_line_cap(1)
        cr.set_source_rgba(0.46, 0.03, 0.06, 0.84)
        cr.set_line_width(7.5 * s)
        cr.move_to(-3.0 * s, 0)
        cr.line_to(smear_len, 0)
        cr.stroke()

        cr.set_source_rgba(0.64, 0.06, 0.09, 0.80)
        cr.set_line_width(4.2 * s)
        cr.move_to(0, -1.0 * s)
        cr.line_to(smear_len * 0.85, 0.8 * s)
        cr.stroke()
        cr.restore()

        # Organic central pool clusters
        for i in range(self.rng.randint(4, 7)):
            ox = self.rng.uniform(-7.0, 10.0) * s
            oy = self.rng.uniform(-5.0, 5.0) * s
            rx = self.rng.uniform(2.8, 7.2) * s
            ry = rx * self.rng.uniform(0.55, 0.95)
            cr.save()
            cr.translate(x + ox, y + oy)
            cr.rotate(self.rng.uniform(0, math.tau))
            cr.scale(1.0, ry / max(1.0, rx))
            if i % 2 == 0:
                cr.set_source_rgba(0.44, 0.02, 0.05, 0.88)
            else:
                cr.set_source_rgba(0.68, 0.06, 0.10, 0.84)
            cr.arc(0, 0, rx, 0, math.tau)
            cr.fill()
            cr.restore()

        # Fine high-velocity spatter mist and droplets
        for _ in range(self.rng.randint(14, 24)):
            ang = dir_angle + self.rng.uniform(-1.25, 1.25)
            dist = self.rng.uniform(8.0, 48.0) * s
            dx = x + math.cos(ang) * dist
            dy = y + math.sin(ang) * dist
            rad = self.rng.uniform(0.8, 2.6) * s
            stretch = self.rng.uniform(1.1, 2.2)

            cr.save()
            cr.translate(dx, dy)
            cr.rotate(ang)
            cr.scale(stretch, 1.0)
            cr.set_source_rgba(
                self.rng.uniform(0.42, 0.72),
                0.03,
                0.06,
                self.rng.uniform(0.72, 0.92),
            )
            cr.arc(0, 0, rad, 0, math.tau)
            cr.fill()
            cr.restore()

        # 1 or 2 thin gravity drips trickling down
        for _ in range(self.rng.randint(1, 2)):
            self.blood_drips.append(
                [
                    x + self.rng.uniform(-6.0, 8.0) * s,
                    y + self.rng.uniform(1.0, 4.0) * s,
                    self.rng.uniform(14.0, 28.0) * self.scale,
                    self.rng.uniform(14.0, 44.0) * s,
                    self.rng.uniform(1.1, 2.1) * self.scale,
                ]
            )

        cr.restore()
        self.blood_tire = 1.0

    def _choose_next_line(self):
        """Pick the next ledge to grind, surface to powerslide/carve, or sketchy bail."""
        self.tricks_since_bail += 1
        will_bail = (
            self.tricks_since_bail >= 6 and self.rng.random() < 0.35
        ) or (self.tricks_since_bail >= 3 and self.rng.random() < 0.12)

        r = self.rng.random()
        if r < 0.38:
            # Jump onto a 2D surface (monitor glass or desk surface) for a curved powerslide, carve, or slam!
            zone = self.rng.choice(SLIDE_ZONES)
            zx0, zy0, zx1, zy1, zkind = (
                zone[0] * self.w,
                zone[1] * self.h,
                zone[2] * self.w,
                zone[3] * self.h,
                zone[4],
            )
            land_x = self.rng.uniform(zx0 + 25.0 * self.scale, zx1 - 25.0 * self.scale)
            land_y = self.rng.uniform(zy0 + 15.0 * self.scale, zy1 - 15.0 * self.scale)
            if will_bail:
                self._launch_air(
                    land_x, land_y, ("BAIL", (land_y, zx0, zx1, zkind))
                )
            else:
                act = "POWERSLIDE" if self.rng.random() < 0.72 else "CRUISE"
                self._launch_air(
                    land_x, land_y, (act, (zx0, zy0, zx1, zy1, zkind))
                )
            return

        candidates = []
        for ledge in self.ledges:
            if ledge == self.active_ledge:
                continue
            ly, lx0, lx1, kind = ledge
            if kind == "wood" and self.rng.random() < 0.70:
                continue
            mid_x = 0.5 * (lx0 + lx1)
            dist = math.hypot(mid_x - self.x, ly - self.y)
            if 75.0 * self.scale < dist < self.w * 0.75:
                candidates.append(ledge)
        if not candidates:
            candidates = [l for l in self.ledges if l != self.active_ledge] or self.ledges

        target_ledge = self.rng.choice(candidates)
        ly, lx0, lx1, _ = target_ledge
        span = max(40.0 * self.scale, lx1 - lx0)

        if will_bail:
            land_x = lx0 + self.rng.uniform(0.2, 0.8) * span
            next_act = ("BAIL", target_ledge)
        else:
            if self.rng.random() < 0.5:
                land_x = lx0 + min(span * 0.25, 45.0 * self.scale)
            else:
                land_x = lx1 - min(span * 0.25, 45.0 * self.scale)
            next_act = ("GRIND", target_ledge)

        self._launch_air(land_x, ly, next_act)

    def _launch_air(self, target_x, target_y, next_action):
        """Pop an ollie or flip trick from (self.x, self.y) to (target_x, target_y)."""
        self._stamp_scuff_mark(self.x, self.y, self.yaw, intensity=0.80)
        self._spawn_debris_burst(
            self.x, self.y, floor_y=self.y + 4.0 * self.scale, count=5, speed=130.0
        )

        self.state = "AIR"
        self.state_t = 0.0
        dist = math.hypot(target_x - self.x, target_y - self.y)
        self.state_dur = max(0.48, min(0.95, 0.42 + dist / (760.0 * self.scale)))
        self.air_start = (self.x, self.y)
        self.air_end = (target_x, target_y)
        self.air_height = max(
            65.0 * self.scale,
            min(190.0 * self.scale, 55.0 * self.scale + dist * 0.28),
        )
        self.next_action = next_action

        travel_ang = math.atan2(target_y - self.y, target_x - self.x)
        self.base_yaw = travel_ang
        self.trick = self.rng.choice(TRICK_NAMES)

        if self.trick == "kickflip":
            self.flip_spins = 1.0
            self.yaw_spin = 0.0
        elif self.trick == "double_kickflip":
            self.flip_spins = 2.0
            self.yaw_spin = 0.0
        elif self.trick == "heelflip":
            self.flip_spins = -1.0
            self.yaw_spin = 0.0
        elif self.trick == "tre_flip":
            self.flip_spins = 1.0
            self.yaw_spin = math.tau
        elif self.trick == "hardflip":
            self.flip_spins = 1.0
            self.yaw_spin = math.pi
        elif self.trick == "pop_shuvit":
            self.flip_spins = 0.0
            self.yaw_spin = math.pi
        else:
            self.flip_spins = 0.0
            self.yaw_spin = 0.0

    def _start_grind(self, ledge):
        ly, lx0, lx1, _ = ledge
        self.state = "GRIND"
        self.state_t = 0.0
        self.active_ledge = ledge
        self.y = ly
        self.z = 0.0

        mid = 0.5 * (lx0 + lx1)
        self.grind_dir = 1.0 if self.x <= mid else -1.0
        self.grind_speed = self.rng.uniform(420.0, 610.0) * self.scale
        self.grind_type = self.rng.choice(GRIND_TYPES)

        rail_yaw = 0.0 if self.grind_dir > 0 else math.pi
        if self.grind_type == "50-50":
            self.yaw = rail_yaw
            self.pitch = 0.0
            self.roll = 0.0
        elif self.grind_type == "5-0":
            self.yaw = rail_yaw
            self.pitch = 0.36
            self.roll = 0.0
        elif self.grind_type == "nosegrind":
            self.yaw = rail_yaw
            self.pitch = -0.36
            self.roll = 0.0
        elif self.grind_type == "boardslide":
            self.yaw = rail_yaw + math.pi * 0.5
            self.pitch = 0.0
            self.roll = 0.0
        elif self.grind_type == "noseslide":
            self.yaw = rail_yaw + math.pi * 0.45
            self.pitch = -0.22
            self.roll = 0.0
        elif self.grind_type == "tailslide":
            self.yaw = rail_yaw - math.pi * 0.45
            self.pitch = 0.22
            self.roll = 0.0
        elif self.grind_type == "darkslide":
            self.yaw = rail_yaw + math.pi * 0.35
            self.pitch = 0.0
            self.roll = math.pi

        self._stamp_scuff_mark(self.x, self.y, rail_yaw, intensity=0.95)
        self._spawn_sparks(self.x, self.y, self.grind_dir, count=8)

    def _setup_surface_curve(self, zone):
        zx0, zy0, zx1, zy1, _ = zone
        p0 = (self.x, self.y)
        p2 = (
            self.rng.uniform(zx0 + 25.0 * self.scale, zx1 - 25.0 * self.scale),
            self.rng.uniform(zy0 + 12.0 * self.scale, zy1 - 12.0 * self.scale),
        )
        if math.hypot(p2[0] - p0[0], p2[1] - p0[1]) < 110.0 * self.scale:
            p2 = (
                zx1 - 30.0 * self.scale
                if self.x < 0.5 * (zx0 + zx1)
                else zx0 + 30.0 * self.scale,
                self.rng.uniform(zy0 + 12.0 * self.scale, zy1 - 12.0 * self.scale),
            )
        mid_x = 0.5 * (p0[0] + p2[0]) + self.rng.uniform(-70.0, 70.0) * self.scale
        mid_y = max(
            zy0 + 8.0 * self.scale,
            min(
                zy1 - 8.0 * self.scale,
                0.5 * (p0[1] + p2[1]) + self.rng.uniform(-45.0, 45.0) * self.scale,
            ),
        )
        self.curve_p0 = p0
        self.curve_p1 = (mid_x, mid_y)
        self.curve_p2 = p2

    def _eval_curve(self, u):
        om = 1.0 - u
        x = (
            om * om * self.curve_p0[0]
            + 2.0 * om * u * self.curve_p1[0]
            + u * u * self.curve_p2[0]
        )
        y = (
            om * om * self.curve_p0[1]
            + 2.0 * om * u * self.curve_p1[1]
            + u * u * self.curve_p2[1]
        )
        tx = 2.0 * om * (self.curve_p1[0] - self.curve_p0[0]) + 2.0 * u * (
            self.curve_p2[0] - self.curve_p1[0]
        )
        ty = 2.0 * om * (self.curve_p1[1] - self.curve_p0[1]) + 2.0 * u * (
            self.curve_p2[1] - self.curve_p1[1]
        )
        return x, y, math.atan2(ty, tx)

    def _start_powerslide(self, zone):
        self.state = "POWERSLIDE"
        self.state_t = 0.0
        self.state_dur = self.rng.uniform(0.45, 0.72)
        self.z = 0.0
        self.roll = 0.0
        self.pitch = 0.05
        self._setup_surface_curve(zone)
        self.grind_dir = self.rng.choice([-1.0, 1.0])
        self._spawn_debris_burst(
            self.x, self.y, floor_y=self.y + 6.0 * self.scale, count=5, speed=115.0
        )

    def _start_cruise(self, zone):
        self.state = "CRUISE"
        self.state_t = 0.0
        self.state_dur = self.rng.uniform(0.42, 0.75)
        self.z = 0.0
        self.roll = 0.0
        self.pitch = 0.0
        self._setup_surface_curve(zone)
        self._stamp_scuff_mark(self.x, self.y, self.yaw, intensity=0.70)

    def _start_bail(self, ledge):
        """Violent slam: crack screen glass and/or splash blood, scatter paint & splinters!"""
        self.state = "BAIL"
        self.state_t = 0.0
        self.state_dur = self.rng.uniform(0.85, 1.20)
        self.active_ledge = ledge
        self.z = 0.0
        self.tricks_since_bail = 0
        self.bails_count += 1
        self.board_wear = min(1.0, self.board_wear + 0.14)

        severity = self.rng.uniform(0.88, 1.22)
        # Always crack or chip the glass on a slam; splash blood from injury on ~65% of slams
        self._stamp_glass_crack(self.x, self.y, severity=severity)
        if self.bails_count == 1 or self.rng.random() < 0.65:
            self._stamp_blood_splatter(
                self.x, self.y, self.base_yaw, severity=severity * 0.92
            )
        self._stamp_scuff_mark(self.x, self.y, self.base_yaw, intensity=1.25)
        self._spawn_debris_burst(
            self.x,
            self.y,
            floor_y=self.y + 12.0 * self.scale,
            count=12,
            speed=230.0,
            include_glass=True,
        )
        self._spawn_sparks(self.x, self.y, math.cos(self.base_yaw), count=10)

        self.roll = math.pi
        self.pitch = self.rng.uniform(-0.18, 0.18)
        self.grind_dir = 1.0 if math.cos(self.base_yaw) >= 0 else -1.0
        self.grind_speed = self.rng.uniform(220.0, 340.0) * self.scale

    def update(self, dt):
        self.tick_count += 1
        self.prev_x, self.prev_y = self.x, self.y
        self.state_t += dt

        if self.state == "AIR":
            u = min(1.0, self.state_t / max(0.01, self.state_dur))
            sx, sy = self.air_start
            ex, ey = self.air_end
            self.x = sx + (ex - sx) * u
            self.y = sy + (ey - sy) * u
            self.z = 4.0 * self.air_height * u * (1.0 - u)
            self.pitch = math.sin((1.0 - 2.0 * u) * math.pi * 0.5) * 0.42
            self.roll = u * self.flip_spins * math.tau
            self.yaw = self.base_yaw + u * self.yaw_spin
            self.wheel_phase += dt * 18.0

            if u >= 1.0:
                self.z = 0.0
                act, target = self.next_action
                if act == "GRIND":
                    self._start_grind(target)
                elif act == "POWERSLIDE":
                    self._start_powerslide(target)
                elif act == "BAIL":
                    self._start_bail(target)
                else:
                    self._start_cruise(target)

        elif self.state == "GRIND":
            ly, lx0, lx1, _ = self.active_ledge
            nx = self.x + self.grind_dir * self.grind_speed * dt
            ny = ly + self.rng.uniform(-0.8, 0.8) * self.scale
            self._stamp_grind_damage(self.x, self.y, nx, ny, self.grind_type)
            self.x, self.y = nx, ny
            self.board_wear = min(1.0, self.board_wear + dt * 0.04)

            if self.tick_count % 2 == 0:
                self._spawn_sparks(self.x, self.y, self.grind_dir, count=3)
            if self.tick_count % 8 == 0:
                self._spawn_debris_burst(
                    self.x,
                    self.y,
                    floor_y=self.y + 8.0 * self.scale,
                    count=1,
                    speed=95.0,
                )

            margin = 20.0 * self.scale
            if (
                self.x <= lx0 + margin
                or self.x >= lx1 - margin
                or self.state_t >= 0.95
            ):
                self._choose_next_line()

        elif self.state == "POWERSLIDE":
            raw_u = min(1.0, self.state_t / max(0.01, self.state_dur))
            # Ease-out deceleration curve
            u = 1.0 - (1.0 - raw_u) ** 1.85
            nx, ny, tangent_ang = self._eval_curve(u)
            # Deck whipped ~75 degrees sideways relative to travel curve!
            self_yaw = tangent_ang + self.grind_dir * (1.22 - 0.35 * raw_u)
            self.yaw = self_yaw
            self._stamp_wheel_tracks(
                self.x, self.y, nx, ny, self.yaw, is_powerslide=True
            )
            self.x, self.y = nx, ny
            self.blood_tire = max(0.0, self.blood_tire - dt * 0.32)
            if raw_u >= 1.0:
                self._choose_next_line()

        elif self.state == "CRUISE":
            u = min(1.0, self.state_t / max(0.01, self.state_dur))
            nx, ny, tangent_ang = self._eval_curve(u)
            self.yaw = tangent_ang
            self._stamp_wheel_tracks(
                self.x, self.y, nx, ny, self.yaw, is_powerslide=False
            )
            self.x, self.y = nx, ny
            self.wheel_phase += dt * 24.0
            self.blood_tire = max(0.0, self.blood_tire - dt * 0.25)
            if u >= 1.0:
                self._choose_next_line()

        elif self.state == "BAIL":
            u = min(1.0, self.state_t / max(0.01, self.state_dur))
            if u < 0.55:
                cur_spd = self.grind_speed * (1.0 - u / 0.55)
                nx = max(
                    35.0 * self.scale,
                    min(
                        self.w - 35.0 * self.scale,
                        self.x + self.grind_dir * cur_spd * dt,
                    ),
                )
                self._stamp_grind_damage(self.x, self.y, nx, self.y, "darkslide")
                self.x = nx
                self.yaw += dt * 3.6 * self.grind_dir
                self.roll = math.pi + math.sin(u * 18.0) * 0.22 * (1.0 - u)
            elif u < 0.82:
                self.roll = math.pi
            else:
                flip_u = (u - 0.82) / 0.18
                self.roll = math.pi * (1.0 - flip_u)
                self.z = math.sin(flip_u * math.pi) * 24.0 * self.scale
            if u >= 1.0:
                self.roll = 0.0
                self.z = 0.0
                self._choose_next_line()

        # Update flying grind sparks
        alive_sparks = []
        gravity = 720.0 * self.scale
        for sp in self.sparks:
            sp[0] += sp[2] * dt
            sp[1] += sp[3] * dt
            sp[3] += gravity * dt
            sp[4] -= dt
            if sp[4] > 0:
                alive_sparks.append(sp)
        self.sparks = alive_sparks

        # Update flying debris particles; bounce once on target floor, then settle permanently
        alive_debris = []
        for db in self.debris:
            db[0] += db[2] * dt
            db[1] += db[3] * dt
            db[3] += gravity * 0.9 * dt
            db[4] += db[5] * dt
            floor_y = db[6]
            if db[1] >= floor_y:
                db[1] = floor_y
                if db[9] == 0 and abs(db[3]) > 45.0 * self.scale:
                    # One small bounce on the ledge/desk before settling
                    db[3] = -db[3] * 0.28
                    db[2] *= 0.45
                    db[9] = 1
                    alive_debris.append(db)
                else:
                    if 0 <= db[0] < self.w and 0 <= db[1] < self.h:
                        self._stamp_settled_debris(
                            db[0], db[1], db[4], db[7], db[8]
                        )
            elif 0 <= db[0] < self.w and 0 <= db[1] < self.h:
                alive_debris.append(db)
        self.debris = alive_debris

        # Update slowly trickling blood drips directly onto the damage surface
        alive_drips = []
        cr = self.damage_cr
        for dr in self.blood_drips:
            dx, dy, spd, rem, width = dr
            step = min(rem, spd * dt)
            if step > 0.1 and 0 <= dy < self.h - 2:
                cr.save()
                cr.set_source_rgba(0.56, 0.03, 0.06, 0.84)
                cr.set_line_width(width)
                cr.set_line_cap(1)
                cr.move_to(dx, dy)
                cr.line_to(dx, dy + step)
                cr.stroke()
                cr.restore()
                dr[1] += step
                dr[3] -= step
                if dr[3] > 0.5:
                    alive_drips.append(dr)
        self.blood_drips = alive_drips

    def draw(self, cr):
        """Render the damaged screen, active sparks/debris, and 2.5D skateboard."""
        cr.set_source_surface(self.surface, 0, 0)
        cr.paint()

        s = self.scale

        for dx, dy, _, _, ang, _, _, size, kind, _ in self.debris:
            cr.save()
            cr.translate(dx, dy)
            cr.rotate(ang)
            if kind == "blue_paint":
                cr.set_source_rgba(0.15, 0.40, 0.91, 0.95)
            elif kind == "cyan_paint":
                cr.set_source_rgba(0.24, 0.74, 0.99, 0.95)
            elif kind == "wood":
                cr.set_source_rgba(0.85, 0.68, 0.44, 0.95)
            elif kind == "glass":
                cr.set_source_rgba(0.90, 0.97, 1.0, 0.92)
            else:
                cr.set_source_rgba(0.12, 0.13, 0.16, 0.92)
            cr.move_to(-size, -size * 0.42)
            cr.line_to(size * 0.9, -size * 0.2)
            cr.line_to(size * 0.4, size * 0.5)
            cr.line_to(-size * 0.7, size * 0.32)
            cr.close_path()
            cr.fill()
            cr.restore()

        cr.save()
        cr.set_line_cap(1)
        for sx, sy, vx, vy, life, col in self.sparks:
            alpha = min(1.0, life * 4.0)
            if col == "white":
                cr.set_source_rgba(1.0, 0.98, 0.90, alpha)
            elif col == "gold":
                cr.set_source_rgba(1.0, 0.82, 0.24, alpha)
            else:
                cr.set_source_rgba(1.0, 0.46, 0.10, alpha)
            cr.set_line_width(1.9 * s)
            cr.move_to(sx, sy)
            cr.line_to(sx - vx * 0.028, sy - vy * 0.028)
            cr.stroke()
        cr.restore()

        self._draw_skateboard(cr)

    def _deck_capsule_path(self, cr, half_len, half_w):
        flat = max(2.0, half_len - half_w)
        cr.new_path()
        cr.arc(flat, 0, half_w, -math.pi * 0.5, math.pi * 0.5)
        cr.arc(-flat, 0, half_w, math.pi * 0.5, math.pi * 1.5)
        cr.close_path()

    def _draw_skateboard(self, cr):
        s = self.scale
        half_len = 0.5 * self.board_len * max(0.55, math.cos(self.pitch * 0.75))
        up_cos = math.cos(self.roll)
        sin_roll = math.sin(self.roll)
        vis_half_w = 0.5 * self.board_w * max(0.20, abs(up_cos))

        # Ground shadow beneath the board
        cr.save()
        shadow_scale = max(0.45, 1.0 - self.z / (260.0 * s))
        shadow_alpha = max(0.16, 0.50 * shadow_scale)
        cr.translate(self.x + self.z * 0.16, self.y + 7.0 * s + self.z * 0.12)
        cr.rotate(self.yaw)
        cr.scale(1.0, 0.42)
        self._deck_capsule_path(
            cr,
            half_len * (0.95 + 0.15 * (1.0 - shadow_scale)),
            0.5 * self.board_w,
        )
        cr.set_source_rgba(0.0, 0.0, 0.0, shadow_alpha)
        cr.fill()
        cr.restore()

        cr.save()
        cr.translate(self.x, self.y - self.z)
        cr.rotate(self.yaw)
        pitch_shift = math.sin(self.pitch) * 14.0 * s

        if up_cos >= 0.0:
            self._draw_trucks_and_wheels(
                cr, half_len, up_cos, sin_roll, under_deck=True
            )
            self._draw_deck_ply_edge(
                cr, half_len, vis_half_w, sin_roll, pitch_shift
            )
            self._draw_deck_top_grip(cr, half_len, vis_half_w, pitch_shift)
        else:
            self._draw_deck_ply_edge(
                cr, half_len, vis_half_w, sin_roll, pitch_shift
            )
            self._draw_deck_bottom_graphic(cr, half_len, vis_half_w, pitch_shift)
            self._draw_trucks_and_wheels(
                cr, half_len, up_cos, sin_roll, under_deck=False
            )

        cr.restore()

    def _draw_deck_ply_edge(
        self, cr, half_len, vis_half_w, sin_roll, pitch_shift
    ):
        s = self.scale
        cr.save()
        cr.translate(-pitch_shift * 0.15, sin_roll * 3.2 * s)
        self._deck_capsule_path(cr, half_len + 1.4 * s, vis_half_w + 1.4 * s)
        cr.set_source_rgb(0.78, 0.61, 0.38)
        cr.fill_preserve()
        cr.set_source_rgb(0.42, 0.30, 0.17)
        cr.set_line_width(1.2 * s)
        cr.stroke()
        cr.restore()

    def _draw_deck_top_grip(self, cr, half_len, vis_half_w, pitch_shift):
        s = self.scale
        cr.save()
        self._deck_capsule_path(cr, half_len, vis_half_w)
        cr.set_source_rgb(0.09, 0.10, 0.13)
        cr.fill_preserve()
        cr.clip()

        cr.set_source_rgba(1.0, 1.0, 1.0, 0.07)
        cr.arc(half_len * 0.78, 0, vis_half_w * 1.1, 0, math.tau)
        cr.fill()
        cr.set_source_rgba(0.0, 0.0, 0.0, 0.25)
        cr.arc(-half_len * 0.78, 0, vis_half_w * 1.1, 0, math.tau)
        cr.fill()

        # MadeOfBlue diagonal blue grip-tape cutout reveal
        cr.set_source_rgb(0.18, 0.45, 0.94)
        cr.set_line_width(3.4 * s)
        cr.move_to(-half_len * 0.18, -vis_half_w * 1.2)
        cr.line_to(-half_len * 0.04, vis_half_w * 1.2)
        cr.stroke()

        cr.set_source_rgba(0.65, 0.62, 0.56, 0.26 + 0.25 * self.board_wear)
        cr.set_line_width(1.9 * s)
        cr.move_to(-half_len * 0.45, -vis_half_w * 0.3)
        cr.line_to(half_len * 0.35, vis_half_w * 0.25)
        cr.stroke()

        if self.blood_tire > 0.1:
            cr.set_source_rgba(0.64, 0.05, 0.09, min(0.72, self.blood_tire))
            cr.arc(half_len * 0.42, vis_half_w * 0.32, 3.8 * s, 0, math.tau)
            cr.fill()

        cr.set_source_rgb(0.74, 0.78, 0.84)
        for tx in (-half_len * 0.54, half_len * 0.54):
            for bx in (-2.4 * s, 2.4 * s):
                for by in (-vis_half_w * 0.36, vis_half_w * 0.36):
                    cr.arc(tx + bx, by, 1.05 * s, 0, math.tau)
                    cr.fill()

        self._deck_capsule_path(cr, half_len, vis_half_w)
        cr.set_source_rgba(0.32, 0.36, 0.44, 0.65)
        cr.set_line_width(1.3 * s)
        cr.stroke()
        cr.restore()

    def _draw_deck_bottom_graphic(self, cr, half_len, vis_half_w, pitch_shift):
        s = self.scale
        cr.save()
        self._deck_capsule_path(cr, half_len, vis_half_w)
        cr.set_source_rgb(0.08, 0.10, 0.14)
        cr.fill_preserve()
        cr.clip()

        # Worn maple wood tail & nose rash
        cr.set_source_rgba(0.80, 0.62, 0.38, 0.85)
        cr.arc(-half_len * 0.96, 0, vis_half_w * 0.82, 0, math.tau)
        cr.fill()
        cr.arc(half_len * 0.98, -vis_half_w * 0.25, vis_half_w * 0.62, 0, math.tau)
        cr.fill()

        # Center Blue Screaming Hand graphic
        cr.save()
        w_ratio = vis_half_w / max(1.0, 0.5 * self.board_w)
        cr.scale(1.0, w_ratio)
        hs = s * 0.95

        cr.set_source_rgb(0.78, 0.11, 0.15)
        cr.arc(-11.0 * hs, 6.0 * hs, 6.5 * hs, 0, math.tau)
        cr.fill()

        cr.set_source_rgb(0.22, 0.71, 0.98)
        cr.arc(0, 0, 12.0 * hs, 0, math.tau)
        cr.fill()
        finger_angles = [-1.1, -0.55, 0.0, 0.55, 1.15]
        finger_lens = [15.0, 18.0, 19.0, 17.0, 13.0]
        cr.set_line_cap(1)
        for fang, flen in zip(finger_angles, finger_lens):
            cr.set_source_rgb(0.22, 0.71, 0.98)
            cr.set_line_width(5.2 * hs)
            cr.move_to(math.cos(fang) * 6.0 * hs, math.sin(fang) * 6.0 * hs)
            cr.line_to(math.cos(fang) * flen * hs, math.sin(fang) * flen * hs)
            cr.stroke()

        cr.set_source_rgb(0.06, 0.07, 0.10)
        cr.arc(1.0 * hs, 0.5 * hs, 6.4 * hs, 0, math.tau)
        cr.fill()

        cr.set_source_rgb(0.86, 0.18, 0.20)
        cr.arc(-1.0 * hs, 2.2 * hs, 3.8 * hs, 0, math.pi)
        cr.fill()
        cr.set_source_rgb(0.92, 0.94, 0.96)
        cr.arc(2.2 * hs, -3.4 * hs, 2.6 * hs, 0, math.pi)
        cr.fill()
        cr.restore()

        cr.set_source_rgba(0.82, 0.66, 0.42, 0.45 + 0.35 * self.board_wear)
        cr.set_line_width(1.2 * s)
        for sy in (-0.35, 0.05, 0.42):
            cr.move_to(-half_len * 0.35, vis_half_w * sy)
            cr.line_to(half_len * 0.35, vis_half_w * (sy + 0.08))
            cr.stroke()

        self._deck_capsule_path(cr, half_len, vis_half_w)
        cr.set_source_rgba(0.78, 0.61, 0.38, 0.9)
        cr.set_line_width(1.5 * s)
        cr.stroke()
        cr.restore()

    def _draw_trucks_and_wheels(
        self, cr, half_len, up_cos, sin_roll, under_deck=True
    ):
        s = self.scale
        cr.save()
        y_shift = (5.0 * up_cos if under_deck else -4.0 * up_cos) * s
        axle_half_w = 0.5 * self.board_w * (0.95 if not under_deck else 0.88)

        for tx in (-half_len * 0.54, half_len * 0.54):
            cr.set_source_rgb(0.68, 0.72, 0.78)
            cr.set_line_width(3.6 * s)
            cr.move_to(tx, -axle_half_w + y_shift)
            cr.line_to(tx, axle_half_w + y_shift)
            cr.stroke()

            cr.set_source_rgb(0.45, 0.49, 0.55)
            cr.arc(tx, y_shift, 4.2 * s, 0, math.tau)
            cr.fill()
            cr.set_source_rgb(0.18, 0.48, 0.95)
            cr.arc(tx, y_shift, 2.2 * s, 0, math.tau)
            cr.fill()

            for wy in (-axle_half_w + y_shift, axle_half_w + y_shift):
                cr.save()
                cr.translate(tx, wy)
                w_rad_x = 5.4 * s
                w_rad_y = 3.2 * s
                cr.set_source_rgb(0.92, 0.90, 0.83)
                cr.rectangle(-w_rad_x, -w_rad_y, w_rad_x * 2.0, w_rad_y * 2.0)
                cr.fill()
                if self.blood_tire > 0.05:
                    cr.set_source_rgba(
                        0.68, 0.05, 0.09, min(0.82, self.blood_tire * 0.88)
                    )
                    cr.rectangle(
                        -w_rad_x, -w_rad_y, w_rad_x * 1.2, w_rad_y * 2.0
                    )
                    cr.fill()
                cr.set_source_rgb(0.20, 0.22, 0.26)
                cr.set_line_width(1.0 * s)
                cr.rectangle(-w_rad_x, -w_rad_y, w_rad_x * 2.0, w_rad_y * 2.0)
                cr.stroke()
                cr.restore()

        cr.restore()


def load_initial_surface(width, height, force_wallpaper=False):
    """Capture the live screen or load madeofblue.jpeg into a Cairo ImageSurface."""
    import cairo
    import gi

    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import GdkPixbuf

    shot_path = None if force_wallpaper else capture_screen_png()
    img_path = shot_path or find_wallpaper()
    try:
        if img_path is not None:
            pixbuf = GdkPixbuf.Pixbuf.new_from_file(str(img_path))
            return pixbuf_to_cairo_surface(pixbuf, width, height)
    except Exception:
        pass
    finally:
        if shot_path is not None:
            try:
                shot_path.unlink()
            except OSError:
                pass

    surface = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    paint_fallback_background(surface)
    return surface


def run_gui(app_id="madeofblue-screensaver", preview=False, force_wallpaper=False):
    """Run the fullscreen GTK4 + Cairo screensaver window."""
    import gi

    gi.require_version("Gdk", "4.0")
    gi.require_version("Gtk", "4.0")
    from gi.repository import Gdk, GLib, Gtk

    GLib.set_prgname(app_id)
    Gtk.init()

    display = Gdk.Display.get_default()
    if display is None:
        return False

    width, height = 1920, 1080
    monitors = display.get_monitors()
    if monitors.get_n_items() > 0:
        geom = monitors.get_item(0).get_geometry()
        if geom.width > 0 and geom.height > 0:
            width, height = geom.width, geom.height

    surface = load_initial_surface(width, height, force_wallpaper=force_wallpaper)
    engine = [SkateDamageEngine(surface)]

    loop = GLib.MainLoop()
    win = Gtk.Window()
    win.set_title("Screensaver")
    win.set_decorated(False)
    win.fullscreen()

    blank_cursor = Gdk.Cursor.new_from_name("none", None)
    if blank_cursor is not None:
        win.set_cursor(blank_cursor)

    area = Gtk.DrawingArea()
    area.set_hexpand(True)
    area.set_vexpand(True)

    def on_resize(_area, new_w, new_h):
        if new_w > 100 and new_h > 100 and (
            new_w != engine[0].w or new_h != engine[0].h
        ):
            new_surf = load_initial_surface(new_w, new_h, force_wallpaper=True)
            engine[0] = SkateDamageEngine(new_surf)

    def on_draw(_area, cr, _w, _h):
        engine[0].draw(cr)

    area.connect("resize", on_resize)
    area.set_draw_func(on_draw)
    win.set_child(area)

    start_time = time.monotonic()
    last_time = [start_time]
    initial_pointer = [None]

    def quit_screensaver(*_):
        if loop.is_running():
            loop.quit()
        return True

    key_ctrl = Gtk.EventControllerKey()
    key_ctrl.connect("key-pressed", quit_screensaver)
    win.add_controller(key_ctrl)

    click_ctrl = Gtk.GestureClick()
    click_ctrl.connect("pressed", quit_screensaver)
    win.add_controller(click_ctrl)

    if not preview:
        motion_ctrl = Gtk.EventControllerMotion()

        def on_motion(_ctrl, mx, my):
            if time.monotonic() - start_time < 0.6:
                initial_pointer[0] = (mx, my)
                return
            if initial_pointer[0] is None:
                initial_pointer[0] = (mx, my)
                return
            if (
                math.hypot(
                    mx - initial_pointer[0][0], my - initial_pointer[0][1]
                )
                > 24.0
            ):
                quit_screensaver()

        motion_ctrl.connect("motion", on_motion)
        win.add_controller(motion_ctrl)

    win.connect("close-request", quit_screensaver)

    def on_tick():
        now = time.monotonic()
        dt = min(0.05, max(0.004, now - last_time[0]))
        last_time[0] = now
        engine[0].update(dt)
        area.queue_draw()
        return GLib.SOURCE_CONTINUE

    GLib.timeout_add(16, on_tick)  # ~60 FPS
    signal.signal(signal.SIGTERM, lambda *_: quit_screensaver())
    signal.signal(signal.SIGHUP, lambda *_: quit_screensaver())

    win.present()
    loop.run()
    return True


def surface_to_terminal_ansi(surface, cols, rows):
    """Downsample a Cairo ARGB32 ImageSurface into 24-bit half-block ANSI cells."""
    w = surface.get_width()
    h = surface.get_height()
    data = memoryview(surface.get_data())
    stride = surface.get_stride()
    fb_h = rows * 2

    out = ["\x1b[H"]
    last = None
    for r in range(rows):
        y_top = min(h - 1, int((2 * r + 0.5) * h / fb_h))
        y_bot = min(h - 1, int((2 * r + 1.5) * h / fb_h))
        row_top = y_top * stride
        row_bot = y_bot * stride
        out.append("\x1b[%d;1H" % (r + 1))
        for c in range(cols):
            px = min(w - 1, int((c + 0.5) * w / cols)) * 4
            t_off = row_top + px
            b_off = row_bot + px
            fg = (data[t_off + 2], data[t_off + 1], data[t_off])
            bg = (data[b_off + 2], data[b_off + 1], data[b_off])
            pair = (fg, bg)
            if pair != last:
                out.append(
                    "\x1b[38;2;%d;%d;%dm\x1b[48;2;%d;%d;%dm" % (fg + bg)
                )
                last = pair
            out.append("▀")
    return "".join(out)


def run_tty(force_wallpaper=False):
    """Run the same Cairo skateboard & screen-damage simulation inside any truecolour terminal."""
    import cairo

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

    engine = None
    frame_surface = None
    frame_cr = None
    cols, rows = 80, 24
    fps = 20
    frame_dt = 1.0 / fps

    try:
        while True:
            start = time.monotonic()
            if resized[0]:
                resized[0] = False
                size = (
                    os.get_terminal_size(out.fileno())
                    if out.isatty()
                    else os.terminal_size((80, 24))
                )
                cols = max(20, size.columns)
                rows = max(10, size.lines)
                sim_w = cols * 8
                sim_h = rows * 16
                base_surf = load_initial_surface(
                    sim_w, sim_h, force_wallpaper=force_wallpaper
                )
                engine = SkateDamageEngine(base_surf)
                frame_surface = cairo.ImageSurface(
                    cairo.FORMAT_ARGB32, sim_w, sim_h
                )
                frame_cr = cairo.Context(frame_surface)
                out.write("\x1b[0m\x1b[2J")

            engine.update(frame_dt)
            engine.draw(frame_cr)
            out.write(surface_to_terminal_ansi(frame_surface, cols, rows))
            out.flush()

            wait = max(0.0, frame_dt - (time.monotonic() - start))
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


def render_demo(output_path, frames=900, width=1920, height=1080, seed=42):
    """Simulate `frames` ticks at 60 FPS over madeofblue.jpeg and save a PNG snapshot."""
    import cairo

    surface = load_initial_surface(width, height, force_wallpaper=True)
    engine = SkateDamageEngine(surface, seed=seed)
    dt = 1.0 / 60.0
    for _ in range(frames):
        engine.update(dt)

    out_surf = cairo.ImageSurface(cairo.FORMAT_ARGB32, width, height)
    cr = cairo.Context(out_surf)
    engine.draw(cr)
    out_surf.write_to_png(str(output_path))


def main():
    parser = argparse.ArgumentParser(description="MadeOfBlue skateboard screensaver")
    parser.add_argument(
        "--app-id",
        default="madeofblue-screensaver",
        help="Wayland application ID for window rules and process matching",
    )
    parser.add_argument(
        "--preview",
        action="store_true",
        help="Preview mode (ignores minor mouse motion; exits on key or click)",
    )
    parser.add_argument(
        "--tty",
        action="store_true",
        help="Render in the current terminal with 24-bit half-block characters",
    )
    parser.add_argument(
        "--wallpaper",
        action="store_true",
        help="Always use madeofblue.jpeg instead of capturing the live screen",
    )
    parser.add_argument(
        "--render-demo",
        metavar="PNG_PATH",
        help="Render a simulated snapshot to PNG_PATH and exit",
    )
    parser.add_argument(
        "--frames",
        type=int,
        default=900,
        help="Number of 60 FPS frames to simulate for --render-demo",
    )
    args = parser.parse_args()

    if args.render_demo:
        render_demo(args.render_demo, frames=args.frames)
        return

    if not args.tty and (
        os.environ.get("WAYLAND_DISPLAY") or os.environ.get("DISPLAY")
    ):
        try:
            if run_gui(
                app_id=args.app_id,
                preview=args.preview,
                force_wallpaper=args.wallpaper,
            ):
                return
        except Exception:
            pass

    run_tty(force_wallpaper=args.wallpaper)


if __name__ == "__main__":
    main()
