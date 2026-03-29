import json
import requests

def handler(event):
    # Verify we can import requests
    version = requests.__version__
    
    return {
        "status": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "message": "Hello from Python with Deps!",
            "requests_version": version
        })
    }
