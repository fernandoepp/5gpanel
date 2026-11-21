FROM python:3.12-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt && useradd -r -u 10001 panel
COPY app ./app
# Les carpetes compartides (vboxsf, SMB...) poden copiar fitxers amb 0600/0700
RUN chmod -R a+rX,go-w /srv/app
USER panel
EXPOSE 8443
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8443", \
     "--ssl-certfile", "/certs/panel5g-web.crt", "--ssl-keyfile", "/certs/panel5g-web.key", \
     "--no-server-header"]
