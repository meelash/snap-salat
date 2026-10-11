# Snap Salat example server. No dependencies to install: just Node.
FROM node:22-alpine
WORKDIR /app
COPY package.json server.mjs ./
COPY src ./src
ENV NODE_ENV=production HOST=0.0.0.0 PORT=8080 DATA_DIR=/data
RUN mkdir -p /data && chown node:node /data
VOLUME /data
EXPOSE 8080
USER node
HEALTHCHECK --interval=30s --timeout=5s CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null || exit 1
CMD ["node", "--disable-warning=ExperimentalWarning", "server.mjs"]
