FROM n8nio/n8n:latest
USER root
RUN mkdir -p /opt/custom-modules && cd /opt/custom-modules && npm init -y && npm install ioredis
ENV NODE_PATH=/opt/custom-modules/node_modules
USER node
