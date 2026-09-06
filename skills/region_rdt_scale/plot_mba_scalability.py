#!/usr/bin/env python3
"""Plot region-aware MBA scalability results.

Reads the two-column data files produced by mba_scalability_remote.sh and
renders two plots:

  * mba_scalability_mlc.(png|svg) - throttle level (x) vs MLC memory bandwidth
  * mba_scalability_mbm.(png|svg) - throttle level (x) vs region0 MBM bytes

matplotlib is used when available (PNG output). If matplotlib is not
installed the script falls back to a dependency-free SVG renderer so plots
are always produced.

Usage:
  plot_mba_scalability.py --mlc mba_scalability_mlc.txt \
                          --mbm mba_scalability_mbm.txt \
                          --outdir .

SPDX-License-Identifier: GPL-2.0
"""
import argparse
import os
import sys

XLABEL = "Region throttle level (MB_REGION<n> OPT/MIN/MAX)"


def load_xy(path):
    """Load whitespace separated 'x y' rows, skipping comments/blank lines."""
    xs, ys = [], []
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            parts = line.split()
            if len(parts) < 2:
                continue
            try:
                xs.append(float(parts[0]))
                ys.append(float(parts[1]))
            except ValueError:
                continue
    return xs, ys


# --------------------------------------------------------------------------
# matplotlib backend (preferred)
# --------------------------------------------------------------------------
def plot_matplotlib(plt, xs, ys, outpath, title, ylabel, color):
    fig, ax = plt.subplots(figsize=(8, 5))
    ax.plot(xs, ys, marker="o", linestyle="-", color=color)
    ax.set_xlabel(XLABEL)
    ax.set_ylabel(ylabel)
    ax.set_title(title)
    ax.grid(True, linestyle="--", alpha=0.5)
    fig.tight_layout()
    fig.savefig(outpath, dpi=120)
    plt.close(fig)
    print(f"[+] Wrote {outpath}")


# --------------------------------------------------------------------------
# Dependency-free SVG backend (fallback)
# --------------------------------------------------------------------------
def plot_svg(xs, ys, outpath, title, ylabel, color):
    W, H = 800, 500
    ml, mr, mt, mb = 90, 30, 50, 70  # margins
    pw, ph = W - ml - mr, H - mt - mb

    xmin, xmax = min(xs), max(xs)
    ymin, ymax = 0.0, max(ys) if max(ys) > 0 else 1.0
    if xmax == xmin:
        xmax = xmin + 1
    if ymax == ymin:
        ymax = ymin + 1

    def sx(x):
        return ml + (x - xmin) / (xmax - xmin) * pw

    def sy(y):
        return mt + ph - (y - ymin) / (ymax - ymin) * ph

    parts = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
        f'font-family="sans-serif">'
    )
    parts.append(f'<rect width="{W}" height="{H}" fill="white"/>')
    parts.append(
        f'<text x="{W/2}" y="25" text-anchor="middle" font-size="16" '
        f'font-weight="bold">{title}</text>'
    )
    # Axes.
    parts.append(
        f'<line x1="{ml}" y1="{mt}" x2="{ml}" y2="{mt+ph}" stroke="black"/>'
    )
    parts.append(
        f'<line x1="{ml}" y1="{mt+ph}" x2="{ml+pw}" y2="{mt+ph}" stroke="black"/>'
    )
    # Gridlines + tick labels (5 divisions each axis).
    for i in range(6):
        gy = mt + ph - i / 5 * ph
        yval = ymin + i / 5 * (ymax - ymin)
        parts.append(
            f'<line x1="{ml}" y1="{gy}" x2="{ml+pw}" y2="{gy}" stroke="#ddd"/>'
        )
        parts.append(
            f'<text x="{ml-8}" y="{gy+4}" text-anchor="end" '
            f'font-size="11">{yval:.3g}</text>'
        )
        gx = ml + i / 5 * pw
        xval = xmin + i / 5 * (xmax - xmin)
        parts.append(
            f'<text x="{gx}" y="{mt+ph+18}" text-anchor="middle" '
            f'font-size="11">{xval:.3g}</text>'
        )
    # Data polyline + points.
    pts = " ".join(f"{sx(x):.1f},{sy(y):.1f}" for x, y in zip(xs, ys))
    parts.append(
        f'<polyline points="{pts}" fill="none" stroke="{color}" '
        f'stroke-width="2"/>'
    )
    for x, y in zip(xs, ys):
        parts.append(
            f'<circle cx="{sx(x):.1f}" cy="{sy(y):.1f}" r="3" fill="{color}"/>'
        )
    # Axis labels.
    parts.append(
        f'<text x="{ml+pw/2}" y="{H-15}" text-anchor="middle" '
        f'font-size="13">{XLABEL}</text>'
    )
    parts.append(
        f'<text x="20" y="{mt+ph/2}" text-anchor="middle" font-size="13" '
        f'transform="rotate(-90 20 {mt+ph/2})">{ylabel}</text>'
    )
    parts.append("</svg>")

    with open(outpath, "w") as fh:
        fh.write("\n".join(parts))
    print(f"[+] Wrote {outpath}")


def make_plot(path, outdir, stem, title, ylabel, color, plt):
    if not os.path.exists(path):
        print(f"[!] Missing {path}", file=sys.stderr)
        return False
    xs, ys = load_xy(path)
    if not xs:
        print(f"[!] No data points in {path}; skipping", file=sys.stderr)
        return False
    if plt is not None:
        plot_matplotlib(
            plt, xs, ys, os.path.join(outdir, stem + ".png"), title, ylabel, color
        )
    else:
        plot_svg(xs, ys, os.path.join(outdir, stem + ".svg"), title, ylabel, color)
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--mlc", required=True, help="mba_scalability_mlc.txt path")
    ap.add_argument("--mbm", required=True, help="mba_scalability_mbm.txt path")
    ap.add_argument("--outdir", default=".", help="output directory for plots")
    args = ap.parse_args()

    os.makedirs(args.outdir, exist_ok=True)

    plt = None
    try:
        import matplotlib

        matplotlib.use("Agg")
        import matplotlib.pyplot as _plt

        plt = _plt
    except Exception:
        print(
            "[!] matplotlib not available - falling back to built-in SVG renderer",
            file=sys.stderr,
        )

    ok = True
    mlc_stem = os.path.splitext(os.path.basename(args.mlc))[0]
    mbm_stem = os.path.splitext(os.path.basename(args.mbm))[0]
    ok &= make_plot(
        args.mlc,
        args.outdir,
        mlc_stem,
        "MBA scalability: MLC memory bandwidth vs throttle level",
        "MLC memory bandwidth (MB/sec)",
        "tab:blue" if plt else "#1f77b4",
        plt,
    )
    ok &= make_plot(
        args.mbm,
        args.outdir,
        mbm_stem,
        "MBA scalability: resctrl region MBM vs throttle level",
        "resctrl region MBM total bytes (per window)",
        "tab:red" if plt else "#d62728",
        plt,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
