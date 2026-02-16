import io
import qrcode
import qrcode.image.svg


def handler(event):
    q = event.get("query") or {}
    text = q.get("text") or "pack-qr"
    img = qrcode.make(text, image_factory=qrcode.image.svg.SvgImage)
    buf = io.BytesIO()
    img.save(buf)
    svg = buf.getvalue().decode("utf-8")
    return {
        "status": 200,
        "headers": {"Content-Type": "image/svg+xml; charset=utf-8"},
        "body": svg,
    }
