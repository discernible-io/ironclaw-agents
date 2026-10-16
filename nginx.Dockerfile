# TLS sidecar for ironclaw-reborn (Podman pod). Mirrors signportal/identyclaw nginx images.
# Pinned base (tag + manifest-list digest). Bump both when upgrading nginx.
#
# INGRESS_PORT must match IRONCLAW_APP_PORT / the pod publish mapping
# (${APP_PORT}:${APP_PORT}). The listen directive is substituted at build time;
# EXPOSE alone is not enough.
# Pin tag+digest (nginx 1.31.7 / Alpine 3.24); bump deliberately on a rebuild schedule.
FROM docker.io/nginx:1.31.7-alpine@sha256:892bb2152464f0c5d8972593a5f5afaf8054552580b699d95f8ff4af08c2d33d

ARG NODE_ENV=development
ARG INGRESS_PORT=8443

RUN apk add --no-cache openssl \
 && rm /etc/nginx/conf.d/default.conf \
 && mkdir -p /app/certs

COPY nginx/nginx.${NODE_ENV}.conf /etc/nginx/nginx.conf

# Bake the host/pod TLS listen port into the config (see __INGRESS_PORT__).
RUN test -n "$INGRESS_PORT" \
 && grep -q '__INGRESS_PORT__' /etc/nginx/nginx.conf \
 && sed -i "s/__INGRESS_PORT__/${INGRESS_PORT}/g" /etc/nginx/nginx.conf \
 && grep -q "listen ${INGRESS_PORT} ssl" /etc/nginx/nginx.conf

RUN chown -R nginx:nginx /etc/nginx/nginx.conf /var/cache/nginx /var/log/nginx /etc/nginx/conf.d /app

USER nginx
EXPOSE ${INGRESS_PORT}

CMD ["nginx", "-g", "daemon off;"]
