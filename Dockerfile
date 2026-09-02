FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh \
    && mkdir -p /data /xray-config \
    && ! grep -RFn --exclude='*.pyc' --exclude-dir=__pycache__ "$(printf '\052\052\052')" /app/app \
    && python -m py_compile app/main.py
EXPOSE 8080
HEALTHCHECK --interval=20s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import json,urllib.request; d=json.load(urllib.request.urlopen('http://127.0.0.1:8080/readyz', timeout=3)); assert d['status']=='ok'"]
ENTRYPOINT ["/entrypoint.sh"]
