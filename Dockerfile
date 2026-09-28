FROM python:3.13-slim-trixie

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN apt-get update \
    && apt-get install --no-install-recommends -y iverilog poppler-utils ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY requirements-fastapi.txt /app/requirements-fastapi.txt
RUN pip install --no-cache-dir -r /app/requirements-fastapi.txt
COPY . /app
RUN mkdir -p /app/runs /app/app/backend/.runtime /app/assets/spec

USER 1000:1000
EXPOSE 8765 8766
CMD ["uvicorn", "fastapi_server:app", "--app-dir", "app/backend", "--host", "0.0.0.0", "--port", "8765"]
