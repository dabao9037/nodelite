#!/usr/bin/env python3
import os
import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "app.main:app",
        host="127.0.0.1",
        port=int(os.getenv("PANEL_INTERNAL_PORT", "18080")),
        proxy_headers=True,
        forwarded_allow_ips="127.0.0.1",
    )
