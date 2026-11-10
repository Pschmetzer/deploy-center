# The deploys CLI on Linux, for CI. Build from the repository root:
#   docker build -f integrations/docker/Dockerfile -t deploys .
# Run (keys from the environment, never baked into the image):
#   docker run --rm -e VERCEL_TOKEN -e RENDER_API_KEY -e GH_TOKEN \
#     -v "$PWD/deploys-config:/config" deploys changed --json
FROM node:22-bookworm-slim

ARG VERCEL_CLI_VERSION=65.12.1

# bsdextrautils has `column`, used by the table output of status and the lists.
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash jq curl ca-certificates git gh bsdextrautils \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --no-fund --no-audit "vercel@${VERCEL_CLI_VERSION}" \
 && npm cache clean --force

COPY deploys /usr/local/bin/deploys
RUN chmod 0755 /usr/local/bin/deploys

# Config (vercel-repos.json, vercel-team, ignored.json) lives in a volume, not in the image.
ENV DEPLOYS_CONFIG=/config USER=node
RUN mkdir -p /config && chown node:node /config
USER node
WORKDIR /home/node

ENTRYPOINT ["deploys"]
CMD ["doctor"]
