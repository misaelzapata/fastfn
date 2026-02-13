# 1x1 transparent PNG
PNG_B64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO7ZK5QAAAAASUVORK5CYII="


def handler(event):
    return {
        "status": 200,
        "headers": {"Content-Type": "image/png"},
        "is_base64": True,
        "body_base64": PNG_B64,
    }
