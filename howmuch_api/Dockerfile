FROM python:3.12-slim
WORKDIR /app
COPY howmuch_api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY howmuch_api ./howmuch_api
ENV HOWMUCH_DB=/data/howmuch-ios.sqlite3
EXPOSE 8080
CMD ["uvicorn","howmuch_api.main:app","--host","0.0.0.0","--port","8080","--no-access-log"]
