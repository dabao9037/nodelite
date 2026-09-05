FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends nftables iptables iproute2 \
    && rm -rf /var/lib/apt/lists/*
COPY netguard.py /netguard.py
RUN chmod 0555 /netguard.py
CMD ["python3", "/netguard.py", "daemon"]
