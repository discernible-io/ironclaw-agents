# TLS sidecar for ironclaw-reborn (Podman pod). Mirrors signportal/identyclaw nginx images.
# Pinned base (tag + manifest-list digest). Bump both when upgrading nginx.
FROM docker.io/nginx:1.31.0-alpine@sha256:f105e3f12187c58ddc3acd09bbe4b9e4a9ab1df855d3d0e511b641077b5e988e

ARG NODE_ENV=development
ARG INGRESS_PORT=5443

RUN apk add --no-cache openssl \
 && rm /etc/nginx/conf.d/default.conf \
 && mkdir -p /app/certs

COPY nginx/nginx.${NODE_ENV}.conf /etc/nginx/nginx.conf

RUN chown -R nginx:nginx /etc/nginx/nginx.conf /var/cache/nginx /var/log/nginx /etc/nginx/conf.d /app

USER nginx
EXPOSE ${INGRESS_PORT}

CMD ["nginx", "-g", "daemon off;"]
