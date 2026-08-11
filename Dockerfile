FROM python:3.12-slim

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY . .

ENV PAYBOT_DB=/data/paybot.sqlite3
VOLUME ["/data"]
EXPOSE 8000

CMD ["sh", "-c", "uvicorn paybot.web:app --host 0.0.0.0 --port ${PORT:-8000}"]
