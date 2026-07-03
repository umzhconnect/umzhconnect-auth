# Serves only the public *.jwks.json files, never the demo private .key
# files also present in keys/ - baking the file list in here (rather than
# a k8s ConfigMap keyed off a manually curated path list) makes that
# exclusion enforced at build time instead of relying on someone keeping
# a separate file list in sync.
FROM nginx:1.27-alpine
COPY keys/fulfiller-l2.jwks.json keys/placer-l2.jwks.json /usr/share/nginx/html/
