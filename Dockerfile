FROM python:3.12-slim
WORKDIR /app
COPY pyproject.toml README.md ./
COPY fleetwatch ./fleetwatch
RUN pip install --no-cache-dir . && useradd -m app && mkdir /data && chown app /data
USER app
VOLUME /data
EXPOSE 8765
HEALTHCHECK --interval=30s CMD python -c "import urllib.request as u; u.urlopen('http://127.0.0.1:8765/healthz')"
ENTRYPOINT ["fleetwatch"]
CMD ["serve", "--host", "0.0.0.0", "--db", "/data/fleetwatch.db", "--config", "/data/config.json"]
