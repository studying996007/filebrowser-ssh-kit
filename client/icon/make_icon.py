#!/usr/bin/env python3
"""Generate the desktop launcher icon: blue rounded square + white folder, colour matching the web button #2d6cdf.
Outputs: icon.png (1024px), icon.ico (multi-size, Windows), icon.icns (if Pillow supports it, macOS).
Regenerate: python3 make_icon.py
"""
import os
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
S = 1024
BLUE = (45, 108, 223, 255)       # #2d6cdf
WHITE = (255, 255, 255, 255)
FLAP = (210, 224, 248, 255)      # light blue for the folder front-flap depth effect

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# Blue rounded background
d.rounded_rectangle([70, 70, S - 70, S - 70], radius=200, fill=BLUE)

# Folder: draw the tab first, then the body on top — the overlap gives the classic "tab sticking up" look
d.rounded_rectangle([250, 338, 540, 452], radius=34, fill=WHITE)     # tab
d.rounded_rectangle([232, 404, 792, 742], radius=44, fill=WHITE)     # body (back panel)
d.rounded_rectangle([262, 486, 762, 742], radius=34, fill=FLAP)      # front flap (light blue)

img.save(os.path.join(HERE, "icon.png"))
img.save(os.path.join(HERE, "icon.ico"),
         sizes=[(16, 16), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])

# .icns is optional: write it directly if Pillow supports it, saving the macOS installer from calling iconutil
try:
    icns = img.resize((1024, 1024))
    icns.save(os.path.join(HERE, "icon.icns"))
    print("wrote: icon.png, icon.ico, icon.icns")
except Exception as e:
    print("wrote: icon.png, icon.ico  (icns skipped: %s -- the macOS installer will convert with iconutil)" % e)
