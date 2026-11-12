# The deploys CLI on Linux, for CI. Build from the repository root:
#   docker build -f integrations/docker/Dockerfile -t deploys .
# Run (keys from the environment, never baked into the image):
#   docker run --rm -e VERCEL_TOKEN -e RENDER_API_KEY -e GH_TOKEN \
#     -v "$PWD/deploys-config:/config" deploys changed --json
# Pinned by digest (the multi-arch index), so a rebuild gets the same base. To update:
#   docker buildx imagetools inspect node:22-bookworm-slim   (the Digest: line)
FROM node:25-bookworm-slim@sha256:81db02c4b671288a03915da9534dbd54f96d0e7c24d80ccc54f5b36b2e684370

ARG VERCEL_CLI_VERSION=65.12.1

# bsdextrautils has `column`, used by the table output of status and the lists.
# gh comes from GitHub's own apt repo (Debian's is far behind), as cli/cli's docs/install_linux.md says.
RUN apt-get update \
 && apt-get install -y --no-install-recommends bash jq curl ca-certificates git bsdextrautils \
 && mkdir -p -m 755 /etc/apt/keyrings \
 && curl -fsSL -o /etc/apt/keyrings/githubcli-archive-keyring.gpg https://cli.github.com/packages/githubcli-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --no-fund --no-audit "vercel@${VERCEL_CLI_VERSION}" \
 && npm cache clean --force

COPY deploys /usr/local/bin/deploys
# VERSION next to the script, so `deploys --version` names the release.
COPY VERSION /usr/local/bin/VERSION
# The platforms, one file each. DEPLOYS_DIR says where they are (not next to the script here).
COPY providers /usr/local/lib/deploys/providers
# lib/ (team mode, GitLab) is found next to the script itself.
COPY lib /usr/local/bin/lib
RUN chmod 0755 /usr/local/bin/deploys && chmod 0644 /usr/local/lib/deploys/providers/*.sh
ENV DEPLOYS_DIR=/usr/local/lib/deploys

# Config (vercel-repos.json, vercel-team, ignored.json) lives in a volume, not in the image.
ENV DEPLOYS_CONFIG=/config USER=node
RUN mkdir -p /config && chown node:node /config
USER node
WORKDIR /home/node

ENTRYPOINT ["deploys"]
CMD ["doctor"]
