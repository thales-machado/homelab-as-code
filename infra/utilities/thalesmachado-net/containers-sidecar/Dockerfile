FROM denoland/deno:alpine

WORKDIR /app
COPY index.ts .

EXPOSE 3001
CMD ["deno", "run", "--allow-net", "--allow-env", "index.ts"]
