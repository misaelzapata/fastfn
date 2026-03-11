def handler(event, path):
    """GET /files/* — catch-all, path captures everything after /files/"""
    segments = path.split("/") if path else []
    return {
        "status": 200,
        "body": {
            "path": path,
            "segments": segments,
            "depth": len(segments),
        },
    }
