FROM python:3.12-slim
RUN apt-get update \
    && apt-get install -y --no-install-recommends iptables iproute2 libnetfilter-conntrack3 \
    && rm -rf /var/lib/apt/lists/*
COPY netguard.py /netguard.py
RUN chmod 0555 /netguard.py
CMD ["sh", "-c", "python3 /netguard.py reconcile && exec sleep infinity"]
