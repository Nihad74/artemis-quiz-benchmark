"""SVG charts of the Track B report (decision D21). Standard library only; report.py imports this module.

Two chart types, both built from per-run values of valid runs (D6: requests are never pooled over runs):

- interval_chart: one panel per metric. A row per side shows every per-run value as a dot, the median of the runs as a
  tick, and the 95% bootstrap interval over runs as a bar.
- scaling_chart: one panel per metric. The x axis is the number of students; each side is a line through the medians
  of its run sets, with the 95% bootstrap interval as a whisker.

An axis is logarithmic when all values are positive and span more than a factor of 20 (the baseline and the candidate
can differ by two orders of magnitude). A dashed line marks the bound of a hypothesis (D16) where one applies.
"""

import math
from html import escape

WIDTH = 760
COLORS = {"A": "#4c78a8", "B": "#e45756"}  # Tableau blue and red: distinguishable with common colour blindness
FONT = 'font-family="Helvetica, Arial, sans-serif"'


def _number(value):
    """1 234 for large values, 12.3 for medium, 3 significant digits for small ones; never exponent notation."""
    if abs(value) >= 100:
        return f"{round(value):,}".replace(",", " ")
    if abs(value) >= 10:
        return f"{value:.1f}".removesuffix(".0")
    return f"{value:.3g}"


class Axis:
    """A linear or logarithmic mapping of [low, high] onto [start, end] pixels, with readable ticks."""

    def __init__(self, values, start, end):
        values = [v for v in values if v is not None and math.isfinite(v)]
        low, high = (min(values), max(values)) if values else (0.0, 1.0)
        self.log = low > 0 and high / low > 20
        if self.log:
            self.low, self.high = 10 ** math.floor(math.log10(low)), 10 ** math.ceil(math.log10(high))
        else:
            low = min(low, 0.0)
            step = self._step(high - low)
            self.low, self.high = math.floor(low / step) * step, math.ceil(high / step) * step
            if self.high == self.low:
                self.high = self.low + step
        self.start, self.end = start, end

    @staticmethod
    def _step(span):
        raw = (span or 1.0) / 5
        magnitude = 10 ** math.floor(math.log10(raw))
        return next(m * magnitude for m in (1, 2, 5, 10) if m * magnitude >= raw)

    def __call__(self, value):
        if self.log:
            fraction = (math.log10(value) - math.log10(self.low)) / (math.log10(self.high) - math.log10(self.low))
        else:
            fraction = (value - self.low) / (self.high - self.low)
        return self.start + fraction * (self.end - self.start)

    def ticks(self):
        if self.log:
            decades = range(round(math.log10(self.low)), round(math.log10(self.high)) + 1)
            multiples = (1, 2, 5) if len(decades) <= 3 else (1,)
            return [m * 10**d for d in decades for m in multiples if self.low <= m * 10**d <= self.high]
        step = self._step(self.high - self.low)
        count = round((self.high - self.low) / step)
        return [self.low + i * step for i in range(count + 1)]


def _svg(height, title, body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{WIDTH}" height="{height}" viewBox="0 0 {WIDTH} {height}" {FONT} '
            f'font-size="11"><title>{escape(title)}</title><rect width="100%" height="100%" fill="white"/>{"".join(body)}</svg>\n')


def _legend(sides, y):
    body, x = [], 20
    for side, name in sides.items():
        body.append(f'<rect x="{x}" y="{y - 9}" width="10" height="10" fill="{COLORS[side]}"/>'
                    f'<text x="{x + 15}" y="{y}">{escape(f"{side}: {name}")}</text>')
        x += 30 + 7 * len(f"{side}: {name}")
    return body


def _bound(axis, bound, top, bottom):
    """A vertical dashed line at the bound of a hypothesis (D16), if the axis holds it."""
    if bound is None or not axis.low <= bound <= axis.high:
        return []
    p = axis(bound)
    # The label goes to the left of the line when the line is near the right edge of the plot.
    anchor, x = ("end", p - 3) if p > axis.end - 60 else ("start", p + 3)
    return [f'<line x1="{p:.1f}" y1="{top}" x2="{p:.1f}" y2="{bottom}" stroke="#555" stroke-dasharray="4 3"/>'
            f'<text x="{x:.1f}" y="{top + 9}" text-anchor="{anchor}" fill="#555" font-size="9">bound {_number(bound)}</text>']


def interval_chart(title, sides, panels, note):
    """sides: {"A": name, "B": name}. panels: [{label, bound, A: {values, median, low, high}, B: ...}]; an absent side or
    a side without values is shown as "no valid run". Returns the SVG text."""
    left, right, row = 170, WIDTH - 20, 22
    body = [f'<text x="20" y="20" font-size="13" font-weight="bold">{escape(title)}</text>'] + _legend(sides, 38)
    y = 60
    for panel in panels:
        values = [v for side in "AB" for v in (panel.get(side) or {}).get("values", [])]
        values += [panel[side][key] for side in "AB" if panel.get(side) for key in ("low", "high") if panel[side].get(key) is not None]
        if panel.get("bound") is not None:
            values.append(panel["bound"])
        axis = Axis(values, left, right)
        body.append(f'<text x="20" y="{y + 12}" font-weight="bold">{escape(panel["label"])}'
                    f'{" (log scale)" if axis.log else ""}</text>')
        top = y + 18
        for index, side in enumerate("AB"):
            cy = top + 10 + index * row
            data = panel.get(side) or {}
            summary = f"median {_number(data['median'])}, n={len(data['values'])}" if data.get("values") else "no valid run"
            body.append(f'<text x="20" y="{cy + 4}" fill="{COLORS[side]}">{side}</text>'
                        f'<text x="36" y="{cy + 4}" fill="{COLORS[side]}" font-size="10">{escape(summary)}</text>')
            if not data.get("values"):
                continue
            if data.get("low") is not None:
                body.append(f'<line x1="{axis(data["low"]):.1f}" y1="{cy}" x2="{axis(data["high"]):.1f}" y2="{cy}" '
                            f'stroke="{COLORS[side]}" stroke-width="6" stroke-opacity="0.35"/>')
            for value in data["values"]:
                body.append(f'<circle cx="{axis(value):.1f}" cy="{cy}" r="3" fill="none" stroke="{COLORS[side]}"/>')
            m = axis(data["median"])
            body.append(f'<line x1="{m:.1f}" y1="{cy - 7}" x2="{m:.1f}" y2="{cy + 7}" stroke="{COLORS[side]}" stroke-width="2"/>')
        bottom = top + 2 * row + 4
        body += _bound(axis, panel.get("bound"), top, bottom)
        body.append(f'<line x1="{left}" y1="{bottom}" x2="{right}" y2="{bottom}" stroke="#333"/>')
        for tick in axis.ticks():
            x = axis(tick)
            body.append(f'<line x1="{x:.1f}" y1="{bottom}" x2="{x:.1f}" y2="{bottom + 4}" stroke="#333"/>'
                        f'<text x="{x:.1f}" y="{bottom + 15}" text-anchor="middle" font-size="9">{_number(tick)}</text>')
        y = bottom + 30
    body.append(f'<text x="20" y="{y + 4}" fill="#555" font-size="10">{escape(note)}</text>')
    return _svg(y + 16, title, body)


def scaling_chart(title, sides, scales, panels, note):
    """scales: the student counts on the x axis. panels: [{label, bound, A: {students: (median, low, high)}, B: ...}]; a
    low and high of None means fewer than two valid runs. Returns the SVG text."""
    left, right, height = 80, WIDTH - 30, 150
    body = [f'<text x="20" y="20" font-size="13" font-weight="bold">{escape(title)}</text>'] + _legend(sides, 38)
    step = (right - left) / max(len(scales), 1)
    xs = {students: left + step * (i + 0.5) for i, students in enumerate(scales)}
    offset = {"A": -6, "B": 6}
    y = 60
    for panel in panels:
        values = [v for side in "AB" for point in (panel.get(side) or {}).values() for v in point if v is not None]
        if panel.get("bound") is not None:
            values.append(panel["bound"])
        top, bottom = y + 22, y + 22 + height
        axis = Axis(values, bottom, top)
        body.append(f'<text x="20" y="{y + 12}" font-weight="bold">{escape(panel["label"])}'
                    f'{" (log scale)" if axis.log else ""}</text>')
        body.append(f'<line x1="{left}" y1="{top}" x2="{left}" y2="{bottom}" stroke="#333"/>'
                    f'<line x1="{left}" y1="{bottom}" x2="{right}" y2="{bottom}" stroke="#333"/>')
        for tick in axis.ticks():
            p = axis(tick)
            body.append(f'<line x1="{left - 4}" y1="{p:.1f}" x2="{right}" y2="{p:.1f}" stroke="#ddd"/>'
                        f'<text x="{left - 6}" y="{p + 3:.1f}" text-anchor="end" font-size="9">{_number(tick)}</text>')
        if panel.get("bound") is not None and axis.low <= panel["bound"] <= axis.high:
            p = axis(panel["bound"])
            body.append(f'<line x1="{left}" y1="{p:.1f}" x2="{right}" y2="{p:.1f}" stroke="#555" stroke-dasharray="4 3"/>'
                        f'<text x="{right}" y="{p - 3:.1f}" text-anchor="end" fill="#555" font-size="9">bound {_number(panel["bound"])}</text>')
        for students, x in xs.items():
            body.append(f'<text x="{x:.1f}" y="{bottom + 15}" text-anchor="middle" font-size="9">{students} students</text>')
        for side in "AB":
            points = sorted((students, point) for students, point in (panel.get(side) or {}).items() if students in xs)
            line = " ".join(f"{xs[s] + offset[side]:.1f},{axis(p[0]):.1f}" for s, p in points)
            if len(points) > 1:
                body.append(f'<polyline points="{line}" fill="none" stroke="{COLORS[side]}" stroke-width="1.5"/>')
            for students, (median, low, high) in points:
                x = xs[students] + offset[side]
                if low is not None:
                    body.append(f'<line x1="{x:.1f}" y1="{axis(low):.1f}" x2="{x:.1f}" y2="{axis(high):.1f}" stroke="{COLORS[side]}"/>')
                body.append(f'<circle cx="{x:.1f}" cy="{axis(median):.1f}" r="3.5" fill="{COLORS[side]}"/>')
        y = bottom + 34
    body.append(f'<text x="20" y="{y}" fill="#555" font-size="10">{escape(note)}</text>')
    return _svg(y + 12, title, body)
