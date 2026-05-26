# Static Site Assets

Shared for all static sites.

## Favicon Generation (macOS)

`sips` for sizes. Only generate sizes you reference.

⚠️ Non-square source → crop center → pad square. `sips -z` on rectangle squashes/clips.

```bash
SRC="static/images/source-logo.png"
# Crop tight (--cropOffset row col)
cp "$SRC" /tmp/favicon_src.png
sips /tmp/favicon_src.png --cropToHeightWidth 1348 1700 --cropOffset 0 600
# Pad to square (hex no #)
sips /tmp/favicon_src.png --padToHeightWidth 1700 1700 --padColor 110A33
# Resize each
for size in 16 32 180; do
  cp /tmp/favicon_src.png /tmp/fav_work.png
  sips /tmp/fav_work.png -z $size $size
  cp /tmp/fav_work.png "static/images/favicon-${size}x${size}.png"
done
```

Square source: skip crop/pad — `sips -z $size $size "$SRC" --out ...`.

**SVG source** — render to PNG with `qlmanage` first. ⚠️ SVG `width`/`height` must match target (`viewBox` stays):

```bash
sed -i '' 's/width="50" height="50"/width="512" height="512"/' /tmp/logo.svg
qlmanage -t -s 512 -o /tmp/ /tmp/logo.svg 2>/dev/null
```

Generate `favicon.ico` (bundles 16+32) with Python:

```bash
python3 -c "
import struct
def read(p): return open(p,'rb').read()
imgs = [read('static/images/favicon-16x16.png'), read('static/images/favicon-32x32.png')]
sizes = [(struct.unpack('>II', d[16:24]) + (len(d),)) for d in imgs]
n = len(imgs); header = struct.pack('<HHH', 0, 1, n); offset = 6 + n * 16; entries = b''
for w,h,l in sizes:
    entries += struct.pack('<BBBBHHII', w if w<256 else 0, h if h<256 else 0, 0,0,1,32,l,offset); offset += l
open('static/favicon.ico','wb').write(header+entries+b''.join(imgs))
"
```

Sizes: `16x16`/`32x32` browser tab; `180x180` iOS home. Skip `192`/`512` unless adding `manifest.json`. `<head>`:

```html
<link rel="icon" href="/favicon.ico" sizes="any" />
<link
  rel="icon"
  type="image/png"
  sizes="32x32"
  href="/images/favicon-32x32.png"
/>
<link
  rel="icon"
  type="image/png"
  sizes="16x16"
  href="/images/favicon-16x16.png"
/>
<link rel="apple-touch-icon" href="/images/favicon-180x180.png" />
```

## robots.txt

`static/robots.txt` → build copies to `public/`:

```
User-agent: *
Allow: /
```

## og:description

Every page: `<meta name="description">` AND `<meta property="og:description">`. Separate tags, both required.
