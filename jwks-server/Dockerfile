# Serves only keys/.well-known/ (the public *.jwks.json files), never the
# demo private .key files that also live under keys/ - the public/private
# split is enforced by directory, not a manually curated file list, so a
# k8s ConfigMap (or this image) can't accidentally pick up a private key.
FROM nginx:1.27-alpine
COPY keys/.well-known/ /usr/share/nginx/html/.well-known/
