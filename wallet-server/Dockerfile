FROM node:22-alpine
WORKDIR /app
COPY package.json ./
COPY src ./src
ENV NODE_ENV=production DATABASE_PATH=/data/cashline.db PORT=8787
# the SQLite file lives on a mounted volume so it survives redeploys
RUN mkdir -p /data && chown node:node /data
VOLUME /data
USER node
EXPOSE 8787
CMD ["node", "--disable-warning=ExperimentalWarning", "src/index.ts"]
