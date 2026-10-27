"""Approximates what Android 17 (Evolution X cnb) extracts from a static wallpaper.

Follows, step by step, the code read from the server's revisions:
  SystemUI ImageWallpaperColorExtractor.createMiniBitmap  (nearest-neighbour downscale to <= 112*112 px)
  WallpaperColors.fromBitmap                              (CelebiQuantizer, 128 colours)
  CelebiQuantizer = WuQuantizer (5-bit histogram) + WSMeansQuantizer (CIE Lab D50, seed 0x42688)
  ColorScheme.getSeedColors (frameworks/libs/systemui monet): HCT hue/chroma scoring
Java details that change results are emulated: int32 overflow in WuQuantizer's sums, java.util.Random,
java.util.HashMap iteration order.
"""
import math
import numpy as np

MASK48 = (1 << 48) - 1


def i32(v):
    v &= 0xFFFFFFFF
    return v - (1 << 32) if v & 0x80000000 else v


class JavaRandom:
    def __init__(self, seed):
        self.seed = (seed ^ 0x5DEECE66D) & MASK48

    def next(self, bits):
        self.seed = (self.seed * 0x5DEECE66D + 0xB) & MASK48
        return i32(self.seed >> (48 - bits))

    def next_int(self, bound):
        r = self.next(31)
        m = bound - 1
        if bound & m == 0:
            return i32((bound * r) >> 31)
        u = r
        while True:
            r = u % bound
            if i32(u - r + m) >= 0:
                return r
            u = self.next(31)


def java_hashmap_order(keys_in_insertion_order):
    """Iteration order of a java.util.HashMap<Integer,...> filled with merge() in this order: buckets
    ascending, and within a bucket newest first (merge() puts a new node at the head of its bin)."""
    n = len(keys_in_insertion_order)
    cap = 16
    while n > cap * 0.75:
        cap *= 2
    def bucket(k):
        h = k & 0xFFFFFFFF
        return (h ^ (h >> 16)) & (cap - 1)
    idx = sorted(range(n), key=lambda i: (bucket(keys_in_insertion_order[i]), -i))
    return [keys_in_insertion_order[i] for i in idx]


# ------------------------------------------------------------------ colour science
def srgb_to_linear(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.04045, c / 12.92, ((c + 0.055) / 1.055) ** 2.4)


def linear_to_srgb(c):
    c = np.asarray(c, dtype=np.float64)
    return np.where(c <= 0.0031308, c * 12.92, 1.055 * np.power(np.maximum(c, 0), 1 / 2.4) - 0.055)


SRGB_TO_XYZ = np.array([[0.41233895, 0.35762064, 0.18051042],
                        [0.2126, 0.7152, 0.0722],
                        [0.01932141, 0.11916382, 0.95034478]])
XYZ_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ)
BRADFORD = np.array([[0.8951, 0.2664, -0.1614], [-0.7502, 1.7135, 0.0367], [0.0389, -0.0685, 1.0296]])
D65 = np.array([0.95047, 1.0, 1.08883])
D50 = np.array([0.964212, 1.0, 0.825188])


def _adapt(src, dst):
    s = BRADFORD @ src
    d = BRADFORD @ dst
    return np.linalg.inv(BRADFORD) @ np.diag(d / s) @ BRADFORD


SRGB_TO_XYZ50 = _adapt(D65, D50) @ SRGB_TO_XYZ
XYZ50_TO_SRGB = np.linalg.inv(SRGB_TO_XYZ50)


def _lab_f(t):
    return np.where(t > 216 / 24389, np.cbrt(t), (841 / 108) * t + 4 / 29)


def _lab_finv(t):
    return np.where(t > 6 / 29, t ** 3, (108 / 841) * (t - 4 / 29))


def rgb8_to_lab50(rgb8):
    """Android ColorSpace.connect(SRGB, CIE_LAB): Bradford to D50, then Lab."""
    lin = srgb_to_linear(np.asarray(rgb8, dtype=np.float64) / 255.0)
    xyz = lin @ SRGB_TO_XYZ50.T
    f = _lab_f(xyz / D50)
    L = 116 * f[..., 1] - 16
    a = 500 * (f[..., 0] - f[..., 1])
    b = 200 * (f[..., 1] - f[..., 2])
    return np.stack([L, a, b], -1).astype(np.float32)


def lab50_to_int(lab):
    lab = np.asarray(lab, dtype=np.float64)
    fy = (lab[..., 0] + 16) / 116
    fx = fy + lab[..., 1] / 500
    fz = fy - lab[..., 2] / 200
    xyz = np.stack([_lab_finv(fx), _lab_finv(fy), _lab_finv(fz)], -1) * D50
    rgb = np.clip(linear_to_srgb(np.clip(xyz @ XYZ50_TO_SRGB.T, 0, 1)), 0, 1)
    rgb = np.nan_to_num(rgb, nan=0.0)
    r, g, b = [(rgb[..., i] * 255.0 + 0.5).astype(np.int64) for i in range(3)]
    return i32_arr(0xFF000000 | (r << 16) | (g << 8) | b)


def i32_arr(v):
    v = np.asarray(v, dtype=np.int64) & 0xFFFFFFFF
    return np.where(v & 0x80000000, v - (1 << 32), v)


def int_to_rgb(c):
    c = int(c) & 0xFFFFFFFF
    return (c >> 16) & 255, (c >> 8) & 255, c & 255


def rgb_to_int(r, g, b):
    return i32(0xFF000000 | (int(r) << 16) | (int(g) << 8) | int(b))


# CAM16, default viewing conditions (material-color-utilities ViewingConditions.DEFAULT)
def _y_from_lstar(l):
    return 100.0 * _lab_finv((l + 16.0) / 116.0)


class VC:
    wp = np.array([95.047, 100.0, 108.883])
    La = (200.0 / math.pi) * _y_from_lstar(50.0) / 100.0
    surround = 2.0
    M = np.array([[0.401288, 0.650173, -0.051461],
                  [-0.250268, 1.204414, 0.045854],
                  [-0.002079, 0.048952, 0.953127]])
    rgbW = M @ wp
    f = 0.8 + surround / 10.0
    c = 0.59 + (0.69 - 0.59) * ((f - 0.9) * 10.0) if f >= 0.9 else 0.525 + (0.59 - 0.525) * ((f - 0.8) * 10.0)
    d = min(max(f * (1.0 - (1.0 / 3.6) * math.exp((-La - 42.0) / 92.0)), 0.0), 1.0)
    nc = f
    rgbD = d * (100.0 / rgbW) + 1.0 - d
    k = 1.0 / (5.0 * La + 1.0)
    k4 = k ** 4
    k4F = 1.0 - k4
    fl = k4 * La + 0.1 * k4F * k4F * np.cbrt(5.0 * La)
    n = _y_from_lstar(50.0) / wp[1]
    z = 1.48 + math.sqrt(n)
    nbb = 0.725 / n ** 0.2
    ncb = nbb
    rgbAF = (fl * rgbD * rgbW / 100.0) ** 0.42
    rgbA = 400.0 * rgbAF / (rgbAF + 27.13)
    aw = (2.0 * rgbA[0] + rgbA[1] + 0.05 * rgbA[2]) * nbb
    Minv = np.linalg.inv(M)


def cam16(rgb8):
    """(hue, chroma, J) arrays for sRGB 8-bit input (..., 3)."""
    lin = srgb_to_linear(np.asarray(rgb8, dtype=np.float64) / 255.0) * 100.0
    xyz = lin @ SRGB_TO_XYZ.T
    rgbC = xyz @ VC.M.T
    rgbD = rgbC * VC.rgbD
    af = (VC.fl * np.abs(rgbD) / 100.0) ** 0.42
    rgbA = np.sign(rgbD) * 400.0 * af / (af + 27.13)
    rA, gA, bA = rgbA[..., 0], rgbA[..., 1], rgbA[..., 2]
    a = (11 * rA - 12 * gA + bA) / 11.0
    b = (rA + gA - 2 * bA) / 9.0
    u = (20 * rA + 20 * gA + 21 * bA) / 20.0
    p2 = (40 * rA + 20 * gA + bA) / 20.0
    hue = np.degrees(np.arctan2(b, a)) % 360.0
    ac = p2 * VC.nbb
    J = 100.0 * np.power(np.maximum(ac / VC.aw, 0), VC.c * VC.z)
    hp = np.where(hue < 20.14, hue + 360, hue)
    eHue = 0.25 * (np.cos(np.radians(hp) + 2.0) + 3.8)
    p1 = 50000.0 / 13.0 * eHue * VC.nc * VC.ncb
    t = p1 * np.hypot(a, b) / (u + 0.305)
    alpha = np.power(np.maximum(t, 0), 0.9) * (1.64 - 0.29 ** VC.n) ** 0.73
    C = alpha * np.sqrt(J / 100.0)
    return hue, C, J


def lstar(rgb8):
    lin = srgb_to_linear(np.asarray(rgb8, dtype=np.float64) / 255.0)
    y = lin @ SRGB_TO_XYZ[1]
    return 116.0 * _lab_f(y) - 16.0


def cam16_to_rgb(J, C, h):
    """Inverse CAM16 (default VC) to linear-ish sRGB 0..1 (unclipped) ."""
    alpha = 0.0 if (C == 0 or J == 0) else C / math.sqrt(J / 100.0)
    t = (alpha / (1.64 - 0.29 ** VC.n) ** 0.73) ** (1.0 / 0.9)
    hr = math.radians(h)
    eHue = 0.25 * (math.cos(hr + 2.0) + 3.8)
    ac = VC.aw * (J / 100.0) ** (1.0 / VC.c / VC.z)
    p1 = eHue * (50000.0 / 13.0) * VC.nc * VC.ncb
    p2 = ac / VC.nbb
    hs, hc = math.sin(hr), math.cos(hr)
    gamma = 23.0 * (p2 + 0.305) * t / (23.0 * p1 + 11.0 * t * hc + 108.0 * t * hs)
    a = gamma * hc
    b = gamma * hs
    rA = (460.0 * p2 + 451.0 * a + 288.0 * b) / 1403.0
    gA = (460.0 * p2 - 891.0 * a - 261.0 * b) / 1403.0
    bA = (460.0 * p2 - 220.0 * a - 6300.0 * b) / 1403.0
    def inv(x):
        base = max(0.0, (27.13 * abs(x)) / (400.0 - abs(x)))
        return math.copysign(1, x) * (100.0 / VC.fl) * base ** (1.0 / 0.42)
    rgbC = np.array([inv(rA), inv(gA), inv(bA)]) / VC.rgbD
    xyz = VC.Minv @ rgbC
    lin = XYZ_TO_SRGB @ (xyz / 100.0)
    return lin


def hct_to_rgb8(h, c, tone):
    """Colour with HCT hue h, chroma <= c (reduced to fit sRGB), and L* = tone."""
    if tone <= 0.0:
        return (0, 0, 0)
    if tone >= 100.0:
        return (255, 255, 255)
    yt = _y_from_lstar(tone) / 100.0
    def solve(cc):
        lo, hi = 0.0, 100.0
        lin = None
        for _ in range(40):
            mid = (lo + hi) / 2
            lin = cam16_to_rgb(mid, cc, h)
            y = SRGB_TO_XYZ[1] @ lin
            if y < yt:
                lo = mid
            else:
                hi = mid
        return lin
    lo, hi = 0.0, c
    best = solve(0.0)
    lin = solve(c)
    if np.all(lin >= -1e-4) and np.all(lin <= 1 + 1e-4):
        best = lin
    else:
        for _ in range(24):
            mid = (lo + hi) / 2
            lin = solve(mid)
            if np.all(lin >= -1e-4) and np.all(lin <= 1 + 1e-4):
                lo, best = mid, lin
            else:
                hi = mid
    srgb = np.clip(linear_to_srgb(np.clip(best, 0, 1)), 0, 1)
    return tuple(int(round(v * 255)) for v in srgb)


# ------------------------------------------------------------------ Wu (AOSP WuQuantizer)
class Box:
    __slots__ = ("r0", "r1", "g0", "g1", "b0", "b1", "vol")

    def __init__(self):
        self.r0 = self.r1 = self.g0 = self.g1 = self.b0 = self.b1 = self.vol = 0


def gi(r, g, b):
    return (r << 10) + (r << 6) + (g << 5) + r + g + b


class Wu:
    SIDE = 33
    TOTAL = 35937

    def quantize(self, pixel_counts, color_count):
        """pixel_counts: list of (int colour, count) in HashMap order."""
        keys = [k for k, _ in pixel_counts]
        if len(keys) <= color_count:
            self.colors = keys
            return self.colors
        W = [0] * self.TOTAL; MR = [0] * self.TOTAL; MG = [0] * self.TOTAL; MB = [0] * self.TOTAL
        MM = [0.0] * self.TOTAL
        for px, cnt in pixel_counts:
            r, g, b = int_to_rgb(px)
            idx = gi((r >> 3) + 1, (g >> 3) + 1, (b >> 3) + 1)
            W[idx] += cnt; MR[idx] += r * cnt; MG[idx] += g * cnt; MB[idx] += b * cnt
            MM[idx] += cnt * (r * r + g * g + b * b)
        S = self.SIDE
        for r in range(1, S):
            area = [0] * S; aR = [0] * S; aG = [0] * S; aB = [0] * S; a2 = [0.0] * S
            for g in range(1, S):
                line = lR = lG = lB = 0; l2 = 0.0
                for b in range(1, S):
                    idx = gi(r, g, b)
                    line += W[idx]; lR += MR[idx]; lG += MG[idx]; lB += MB[idx]; l2 += MM[idx]
                    area[b] += line; aR[b] += lR; aG[b] += lG; aB[b] += lB; a2[b] += l2
                    p = gi(r - 1, g, b)
                    W[idx] = W[p] + area[b]; MR[idx] = MR[p] + aR[b]; MG[idx] = MG[p] + aG[b]
                    MB[idx] = MB[p] + aB[b]; MM[idx] = MM[p] + a2[b]
        self.W, self.MR, self.MG, self.MB, self.MM = W, MR, MG, MB, MM
        cubes = [Box() for _ in range(color_count)]
        vv = [0.0] * color_count
        cubes[0].r1 = cubes[0].g1 = cubes[0].b1 = 32
        nxt = 0
        generated = 0
        i = 1
        while i < color_count:
            if self.cut(cubes[nxt], cubes[i]):
                vv[nxt] = self.variance(cubes[nxt]) if cubes[nxt].vol > 1 else 0.0
                vv[i] = self.variance(cubes[i]) if cubes[i].vol > 1 else 0.0
            else:
                vv[nxt] = 0.0
                i -= 1
            nxt = 0
            temp = vv[0]
            for k in range(1, i + 1):
                if vv[k] > temp:
                    temp = vv[k]; nxt = k
            generated = i + 1
            if temp <= 0.0:
                break
            i += 1
        colors = []
        for c in cubes[:generated]:
            w = self.vol(c, W)
            if w > 0:
                r = int(self.vol(c, MR) / w); g = int(self.vol(c, MG) / w); b = int(self.vol(c, MB) / w)
                colors.append(rgb_to_int(r & 255, g & 255, b & 255))
        self.colors = colors
        return colors

    @staticmethod
    def vol(c, m):
        return i32(m[gi(c.r1, c.g1, c.b1)] - m[gi(c.r1, c.g1, c.b0)] - m[gi(c.r1, c.g0, c.b1)]
                   + m[gi(c.r1, c.g0, c.b0)] - m[gi(c.r0, c.g1, c.b1)] + m[gi(c.r0, c.g1, c.b0)]
                   + m[gi(c.r0, c.g0, c.b1)] - m[gi(c.r0, c.g0, c.b0)])

    def variance(self, c):
        dr = self.vol(c, self.MR); dg = self.vol(c, self.MG); db = self.vol(c, self.MB)
        m = self.MM
        xx = (m[gi(c.r1, c.g1, c.b1)] - m[gi(c.r1, c.g1, c.b0)] - m[gi(c.r1, c.g0, c.b1)]
              + m[gi(c.r1, c.g0, c.b0)] - m[gi(c.r0, c.g1, c.b1)] + m[gi(c.r0, c.g1, c.b0)]
              + m[gi(c.r0, c.g0, c.b1)] - m[gi(c.r0, c.g0, c.b0)])
        hyp = i32(dr * dr + dg * dg + db * db)
        return xx - hyp / self.vol(c, self.W)

    @staticmethod
    def bottom(c, d, m):
        if d == 0:
            return i32(-m[gi(c.r0, c.g1, c.b1)] + m[gi(c.r0, c.g1, c.b0)] + m[gi(c.r0, c.g0, c.b1)] - m[gi(c.r0, c.g0, c.b0)])
        if d == 1:
            return i32(-m[gi(c.r1, c.g0, c.b1)] + m[gi(c.r1, c.g0, c.b0)] + m[gi(c.r0, c.g0, c.b1)] - m[gi(c.r0, c.g0, c.b0)])
        return i32(-m[gi(c.r1, c.g1, c.b0)] + m[gi(c.r1, c.g0, c.b0)] + m[gi(c.r0, c.g1, c.b0)] - m[gi(c.r0, c.g0, c.b0)])

    @staticmethod
    def top(c, d, p, m):
        if d == 0:
            return i32(m[gi(p, c.g1, c.b1)] - m[gi(p, c.g1, c.b0)] - m[gi(p, c.g0, c.b1)] + m[gi(p, c.g0, c.b0)])
        if d == 1:
            return i32(m[gi(c.r1, p, c.b1)] - m[gi(c.r1, p, c.b0)] - m[gi(c.r0, p, c.b1)] + m[gi(c.r0, p, c.b0)])
        return i32(m[gi(c.r1, c.g1, p)] - m[gi(c.r1, c.g0, p)] - m[gi(c.r0, c.g1, p)] + m[gi(c.r0, c.g0, p)])

    def maximize(self, c, d, first, last, wR, wG, wB, wW):
        bR = self.bottom(c, d, self.MR); bG = self.bottom(c, d, self.MG)
        bB = self.bottom(c, d, self.MB); bW = self.bottom(c, d, self.W)
        mx = 0.0; cut = -1
        for i in range(first, last):
            hR = i32(bR + self.top(c, d, i, self.MR)); hG = i32(bG + self.top(c, d, i, self.MG))
            hB = i32(bB + self.top(c, d, i, self.MB)); hW = i32(bW + self.top(c, d, i, self.W))
            if hW == 0:
                continue
            temp = float(i32(hR * hR + hG * hG + hB * hB)) / hW
            hR = i32(wR - hR); hG = i32(wG - hG); hB = i32(wB - hB); hW = i32(wW - hW)
            if hW == 0:
                continue
            temp += float(i32(hR * hR + hG * hG + hB * hB)) / hW
            if temp > mx:
                mx = temp; cut = i
        return cut, mx

    def cut(self, one, two):
        wR = self.vol(one, self.MR); wG = self.vol(one, self.MG); wB = self.vol(one, self.MB); wW = self.vol(one, self.W)
        cR, mR = self.maximize(one, 0, one.r0 + 1, one.r1, wR, wG, wB, wW)
        cG, mG = self.maximize(one, 1, one.g0 + 1, one.g1, wR, wG, wB, wW)
        cB, mB = self.maximize(one, 2, one.b0 + 1, one.b1, wR, wG, wB, wW)
        if mR >= mG and mR >= mB:
            if cR < 0:
                return False
            d = 0
        elif mG >= mR and mG >= mB:
            d = 1
        else:
            d = 2
        two.r1, two.g1, two.b1 = one.r1, one.g1, one.b1
        if d == 0:
            one.r1 = cR; two.r0 = one.r1; two.g0 = one.g0; two.b0 = one.b0
        elif d == 1:
            one.g1 = cG; two.r0 = one.r0; two.g0 = one.g1; two.b0 = one.b0
        else:
            one.b1 = cB; two.r0 = one.r0; two.g0 = one.g0; two.b0 = one.b1
        one.vol = (one.r1 - one.r0) * (one.g1 - one.g0) * (one.b1 - one.b0)
        two.vol = (two.r1 - two.r0) * (two.g1 - two.g0) * (two.b1 - two.b0)
        return True


def wsmeans(start_colors, pixel_counts, max_colors):
    """AOSP WSMeansQuantizer with starting clusters (Lab D50, squared deltaE76)."""
    pixels = np.array([k for k, _ in pixel_counts], dtype=np.int64)
    counts = np.array([c for _, c in pixel_counts], dtype=np.int64)
    rgb = np.stack([(pixels >> 16) & 255, (pixels >> 8) & 255, pixels & 255], -1)
    points = rgb8_to_lab50(rgb)
    srgb = np.array([int_to_rgb(c) for c in start_colors])
    clusters = rgb8_to_lab50(srgb).astype(np.float32)
    k = min(max_colors, len(clusters), len(points))
    clusters = clusters[:k].copy()
    rnd = JavaRandom(0x42688)
    assign = np.array([rnd.next_int(k) for _ in range(len(points))], dtype=np.int64)
    pops = None
    for _ in range(10):
        dmat = ((clusters[:, None, :] - clusters[None, :, :]) ** 2).sum(-1)
        d = ((points[:, None, :] - clusters[None, :, :]) ** 2).sum(-1).astype(np.float32)
        d = np.where(np.isnan(d), np.inf, d)
        prev = d[np.arange(len(points)), assign]
        dd = d.copy()
        dd[np.arange(len(points)), assign] = np.inf
        best = np.argmin(dd, 1)
        bestd = dd[np.arange(len(points)), best]
        better = bestd < prev
        change = np.abs(np.sqrt(bestd) - np.sqrt(prev)) > 3.0
        move = better & change
        if not move.any():
            break
        assign = np.where(move, best, assign)
        pops = np.bincount(assign, weights=counts, minlength=k).astype(np.int64)
        with np.errstate(invalid="ignore", divide="ignore"):
            sums = np.stack([np.bincount(assign, weights=points[:, i] * counts, minlength=k) for i in range(3)], -1)
            clusters = (sums / pops[:, None]).astype(np.float32)
    if pops is None:
        # never recalculated: AOSP leaves mClusterPopulations as the first pixels' counts
        pops = counts[:k].copy()
    ints = lab50_to_int(clusters)
    return [(int(c), int(p)) for c, p in zip(ints, pops)]


def mini_bitmap(img_u8):
    """createScaledBitmap(filter=false) to <= 112*112 px, like ImageWallpaperColorExtractor."""
    h, w = img_u8.shape[:2]
    scale = min(1.0, math.sqrt(112 * 112 / (w * h)))
    nw, nh = max(1, int(scale * w)), max(1, int(scale * h))
    xs = np.minimum(((np.arange(nw) + 0.5) * w / nw).astype(int), w - 1)
    ys = np.minimum(((np.arange(nh) + 0.5) * h / nh).astype(int), h - 1)
    return img_u8[ys][:, xs]


def wallpaper_colors(img_u8):
    """{colour int: population} as WallpaperColors.fromBitmap builds it."""
    mb = mini_bitmap(img_u8)
    flat = mb.reshape(-1, 3).astype(np.int64)
    ints = [rgb_to_int(r, g, b) for r, g, b in flat]
    seen = {}
    for c in ints:
        seen[c] = seen.get(c, 0) + 1
    order = java_hashmap_order(list(seen.keys()))      # QuantizerMap's HashMap iteration order
    pc = [(c, seen[c]) for c in order]
    wu = Wu()
    start = wu.quantize(pc, 128)
    sw = wsmeans(start, pc, 128)
    pop = {}
    for c, p in sorted(sw, key=lambda t: -t[1]):
        pop[c] = p
    return pop, mb


def seed_colors(pop):
    keys = list(pop.keys())
    total = float(sum(pop.values()))
    rgb = np.array([int_to_rgb(k) for k in keys])
    hue, chroma, _ = cam16(rgb)
    prop = {k: pop[k] / total for k in keys}
    hp = [0.0] * 360
    for i, k in enumerate(keys):
        hh = int(round(hue[i])) % 360
        if chroma[i] <= 5:
            continue
        hp[hh] += prop[k]
    hue_prop = {}
    for i, k in enumerate(keys):
        hh = int(round(hue[i]))
        hue_prop[k] = sum(hp[(j % 360 + 360) % 360] for j in range(hh - 15, hh + 16))
    cand = [(i, k) for i, k in enumerate(keys) if chroma[i] >= 5 and hue_prop[k] > 0.01]
    def score(i, k):
        c = chroma[i]
        return 0.7 * 100.0 * hue_prop[k] + (0.1 * (c - 48.0) if c < 48.0 else 0.3 * (c - 48.0))
    scored = sorted(cand, key=lambda t: -score(*t))
    seeds = []
    for dist in range(90, 14, -1):
        seeds = []
        for i, k in scored:
            if any(min(abs(hue[i] - hue[j]), 360 - abs(hue[i] - hue[j])) < dist for j, _ in seeds):
                continue
            seeds.append((i, k))
            if len(seeds) >= 4:
                break
        if seeds:
            break
    out = []
    for i, k in seeds:
        out.append(dict(argb=k, hex="#%02X%02X%02X" % int_to_rgb(k), hue=float(hue[i]), chroma=float(chroma[i]),
                        tone=float(lstar(np.array(int_to_rgb(k)))), score=float(score(i, k)), hue_prop=hue_prop[k]))
    if not out:
        out.append(dict(argb=0xFF1B6EF3, hex="#1B6EF3", hue=None, chroma=None, tone=None, score=None, hue_prop=None))
    return out


def tonal_spot(seed_hex):
    """Rough Material TONAL_SPOT palettes (hue of seed; chroma 36/16/24/6/8) for mock-ups."""
    r, g, b = int(seed_hex[1:3], 16), int(seed_hex[3:5], 16), int(seed_hex[5:7], 16)
    h, c, _ = cam16(np.array([r, g, b]))
    h = float(h)
    pal = {"a1": (h, 36.0), "a2": (h, 16.0), "a3": ((h + 60.0) % 360, 24.0), "n1": (h, 6.0), "n2": (h, 8.0)}
    def tone(name, t):
        hh, cc = pal[name]
        return hct_to_rgb8(hh, cc, t)
    return tone


PETALS = {"blue": ("#76BCFB", "#1842D1"), "green": ("#ACEFB3", "#18A07C"),
          "coral": ("#FDCF8E", "#D33952"), "purple": ("#F3B1FC", "#6B2BBB")}


def nearest_petal(hue):
    best = None
    for name, cols in PETALS.items():
        for which, hx in zip(("light", "deep"), cols):
            rgb = np.array([int(hx[1:3], 16), int(hx[3:5], 16), int(hx[5:7], 16)])
            ph = float(cam16(rgb)[0])
            d = min(abs(hue - ph), 360 - abs(hue - ph))
            if best is None or d < best[0]:
                best = (d, name, which, hx, ph)
    return best
