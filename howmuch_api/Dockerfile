FROM python:3.12-slim
WORKDIR /app
COPY howmuch_api/requirements.txt ./requirements.txt
RUN pip install --no-cache-dir -r requirements.txt
COPY howmuch_api ./howmuch_api
# The schedule bot sends shifts as text; read them with the HowMuch bot's own parser.
COPY paybot/__init__.py paybot/parsing.py paybot/howmuch_link.py ./paybot/
ENV HOWMUCH_DB=/data/howmuch-ios.sqlite3
EXPOSE 8080
CMD ["uvicorn","howmuch_api.main:app","--host","0.0.0.0","--port","8080","--no-access-log"]
