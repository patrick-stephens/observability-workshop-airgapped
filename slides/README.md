# Workshop Slides

Install the local dependencies with `npm install`, then start the live deck with `npm run dev`.
To keep Node and dependencies off the host, start the live server in Docker from the repository root:

```sh
docker run --rm -p 127.0.0.1:3030:3030 \
    --mount "type=bind,src=$PWD/slides,dst=/work" \
    --tmpfs /work/node_modules:rw,exec,size=4294967296,mode=1777 \
    --workdir /work \
    --env npm_config_cache=/tmp/npm-cache \
    node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 \
    sh -lc 'npm ci && npm run dev -- --remote local --bind 0.0.0.0'
```

Run `npm run build` to create the static site in `dist/`, and run `npm run export` to create `export.pdf`.
These commands may need network access while dependencies or the PDF browser are first installed.
The generated site and PDF are excluded from Git.
They bundle the fonts and have no runtime network dependency.

## Container Build

To keep Node, npm dependencies, the browser, and system library installation off the host, run the build from the repository root with Docker.
The image is pinned by version and digest, and `npm ci` uses the committed lockfile.
The bind mount exposes only `slides/`; `node_modules` and the Playwright browser cache live in temporary container storage.

```sh
docker run --rm \
    --mount "type=bind,src=$PWD/slides,dst=/work" \
    --tmpfs /work/node_modules:rw,exec,size=4294967296,mode=1777 \
    --workdir /work \
    --env npm_config_cache=/tmp/npm-cache \
    --env PLAYWRIGHT_BROWSERS_PATH=/tmp/playwright-browsers \
    --env HOST_UID="$(id -u)" \
    --env HOST_GID="$(id -g)" \
    node:24-bookworm-slim@sha256:0e0ff40c39bc087845bfb27465a0df4ea419520094bc35842ff83dd8cbe6f9b6 \
    sh -lc 'npm ci && npx playwright install chromium --with-deps && npm run build && npm run export && chown -R "$HOST_UID:$HOST_GID" package-lock.json dist export.pdf'
```

For the initial dependency capture only, run `npm install` in the same container to generate `package-lock.json`, then retain the lockfile for reproducible builds.
Subsequent builds use `npm ci` so dependency versions are reproducible.

To verify offline operation, build the deck and open `dist/index.html` via `file://`.
Open the browser developer tools and confirm the Network tab shows zero requests to non-localhost origins.
Also open `export.pdf` and confirm that every slide renders.

## Presenter Follow-ups

- Confirm the `http_server_requests_total` metric name, `service` and `status` labels, 5% threshold, and two-minute `for` duration against the running demo. The `DemoHighErrorRate` rule is illustrative because no matching alert rule exists in the repository yet.
- Confirm the `demo` namespace and `app: api` selector against the deployed workload. The `api-deny-dns` policy is illustrative because no Cilium policy exists in the repository yet.
- Confirm each optional workshop URL remains current before presenting.
- The deck contains 16 pages, including the offline acceptance checklist required for the workshop handoff.
