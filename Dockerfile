# upstream исходники тянутся сюда, в репозитории их нет
FROM alpine/git:latest AS src
ARG UPSTREAM_REPO=https://github.com/lehuygiang28/gemini-proxy.git
ARG UPSTREAM_REF=main
WORKDIR /src
# ответ меняется, когда апстрим двигается — иначе слой с clone кэшируется навсегда
# и UPSTREAM_REF=main тянул бы протухшую копию
ADD https://api.github.com/repos/lehuygiang28/gemini-proxy/commits/${UPSTREAM_REF} /tmp/upstream.json
RUN git init -q . \
    && git remote add origin "$UPSTREAM_REPO" \
    && git fetch -q --depth 1 origin "$UPSTREAM_REF" \
    && git checkout -q FETCH_HEAD

FROM node:22.22-alpine AS base
RUN corepack enable
WORKDIR /app

# отдельный слой из манифестов: bump UPSTREAM_REF не сбрасывает установленные зависимости
FROM base AS deps
COPY --from=src /src/package.json /src/pnpm-lock.yaml /src/pnpm-workspace.yaml /src/.npmrc ./
COPY --from=src /src/apps/api/package.json apps/api/
COPY --from=src /src/apps/web/package.json apps/web/
COPY --from=src /src/packages/appwrite/package.json packages/appwrite/
COPY --from=src /src/packages/cli/package.json packages/cli/
COPY --from=src /src/packages/cloudflare/package.json packages/cloudflare/
COPY --from=src /src/packages/core/package.json packages/core/
COPY --from=src /src/packages/database/package.json packages/database/
COPY --from=src /src/packages/vercel/package.json packages/vercel/
RUN pnpm install --frozen-lockfile

FROM deps AS build-api
COPY --from=src /src ./
RUN pnpm --filter api build

# tsdown бандлит всё (noExternal), рантайму node_modules не нужны
FROM node:22.22-alpine AS api
WORKDIR /app
# --use-env-proxy: глобальный fetch уважает HTTP_PROXY/HTTPS_PROXY/NO_PROXY (пусто — ходит напрямую)
ENV NODE_ENV=production API_PORT=9090 NODE_OPTIONS=--use-env-proxy
COPY --from=build-api /app/apps/api/dist ./apps/api/dist
EXPOSE 9090
CMD ["node", "apps/api/dist/index.mjs"]

FROM deps AS build-web
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_ANON_SUPABASE_KEY
ENV NEXT_PUBLIC_SUPABASE_URL=$NEXT_PUBLIC_SUPABASE_URL \
    NEXT_PUBLIC_ANON_SUPABASE_KEY=$NEXT_PUBLIC_ANON_SUPABASE_KEY \
    NEXT_TELEMETRY_DISABLED=1
COPY --from=src /src ./
# Next сам определяет корень монорепы и кладёт standalone/ по этому пути — вытаскиваем
# фактический корень вместо того, чтобы патчить upstream-конфиг
RUN pnpm --filter web build \
    && SERVER=$(find apps/web/.next/standalone -path '*/apps/web/server.js' | head -1) \
    && test -n "$SERVER" \
    && mkdir -p /out \
    && cp -a "${SERVER%/apps/web/server.js}/." /out/

FROM node:22.22-alpine AS web
WORKDIR /app
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0 NEXT_TELEMETRY_DISABLED=1 \
    NODE_OPTIONS=--use-env-proxy
COPY --from=build-web /out ./
COPY --from=build-web /app/apps/web/.next/static ./apps/web/.next/static
COPY --from=build-web /app/apps/web/public ./apps/web/public
EXPOSE 3000
CMD ["node", "apps/web/server.js"]
