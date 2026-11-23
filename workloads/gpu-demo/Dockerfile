FROM pytorch/pytorch:2.15.0-cuda13.2-cudnn9-runtime
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    HOME=/tmp \
    TMPDIR=/tmp \
    XDG_CACHE_HOME=/tmp/.cache \
    HF_HOME=/models \
    HF_HUB_DISABLE_TELEMETRY=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1
# ffmpeg decodes browser recordings (webm/ogg) and mp3/m4a uploads for speech-to-text
RUN apt-get update \
 && apt-get install -y --no-install-recommends ffmpeg \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
 && groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid 10001 --no-create-home app
COPY app.py .
ARG APP_VERSION=dev
ENV APP_VERSION=${APP_VERSION}
USER 10001
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
