#!/usr/bin/env python3
"""
Rebuild the site's photo derivatives from the graded masters (research/tesla-web/refs/photos/graded, made by
grade.py from the Unsplash originals, git-ignored like all of refs/).

    media.py [mcu charge]

Per slot: landscape 960/1600/2400 and portrait p750 (750×1334) / p1125 (1125×2000), each as WebP (cwebp) and
AVIF (SVT-AV1 via ffmpeg). Crops are the ones the site has always used (recovered from the shipped files).
"""
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
MASTERS = os.path.join(HERE, '..', 'refs', 'photos', 'graded')
OUT = os.path.join(HERE, '..', '..', '..', 'public', 'media')

# crop boxes on the original masters: (w, h, x, y)
SLOTS = {
    'mcu': dict(L=(3500, 2240, 0, 0), P=(1260, 2240, 960, 0)),  # Bram Van Oost 1tm9Rkp_43Q
    'charge': dict(L=(4200, 2800, 0, 0), P=(1575, 2800, 1732, 0)),  # Prometheus OcFDX9_kfLg
}
WEBP_Q = 78
AVIF_CRF = 30


def even(x):
    return int(round(x / 2)) * 2


def build(slot):
    c = SLOTS[slot]
    src = os.path.join(MASTERS, slot + '.png')
    jobs = []
    cw, ch, _, _ = c['L']
    for w in (960, 1600, 2400):
        jobs.append((str(w), c['L'], w, even(w * ch / cw)))
    for w, h in ((750, 1334), (1125, 2000)):
        jobs.append(('p%d' % w, c['P'], w, h))
    with tempfile.TemporaryDirectory() as tmp:
        for tag, (cw, ch, cx, cy), W, H in jobs:
            png = os.path.join(tmp, f'{slot}-{tag}.png')
            vf = f'crop={cw}:{ch}:{cx}:{cy},scale={W}:{H}:flags=lanczos+accurate_rnd+full_chroma_int'
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', src, '-vf', vf, '-pix_fmt', 'rgb24', png], check=True)
            webp = os.path.join(OUT, f'{slot}-{tag}.webp')
            subprocess.run(['cwebp', '-quiet', '-q', str(WEBP_Q), '-m', '6', '-sharp_yuv', '-metadata', 'none', png, '-o', webp], check=True)
            avif = os.path.join(OUT, f'{slot}-{tag}.avif')
            vf = ('scale=out_color_matrix=bt709:out_range=tv,format=yuv420p10le,'
                  'setparams=color_primaries=bt709:color_trc=iec61966-2-1:colorspace=bt709:range=tv')
            subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', png, '-vf', vf, '-c:v', 'libsvtav1', '-crf', str(AVIF_CRF),
                            '-preset', '4', '-svtav1-params', 'tune=0', '-frames:v', '1', avif], check=True, stderr=subprocess.DEVNULL)
            print(f'{slot}-{tag} {W}x{H} webp {os.path.getsize(webp)} avif {os.path.getsize(avif)}', flush=True)


if __name__ == '__main__':
    for s in sys.argv[1:] or list(SLOTS):
        build(s)
