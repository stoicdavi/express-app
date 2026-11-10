# Express App

A minimal Express app for practicing Docker builds, GitHub Actions, and automatic
container updates with Watchtower. The app serves an HTML greeting at `/` on port
8080.

## Requirements

- Node.js and npm for running locally.
- Docker Engine and the Docker Compose plugin for running containers.
- A Docker Hub account and a GitHub repository for publishing images.

## Run Locally

```bash
npm ci # To install the dependecies
node index.js
```

Open http://localhost:8080. Press `Ctrl+C` to stop the app.

There are no automated tests configured yet;
To check the running app manually:

```bash
curl --fail http://localhost:8080/
```

## Build and Run With Docker

The Dockerfile uses Node.js 26. Stop any other app using port 8080 before starting
the container.

```bash
docker build -t expressapp:latest .
docker run -d --name express-app-local -p 8080:8080 expressapp:latest
```

Open http://localhost:8080.

## To stop and remove this container:

```bash
docker rm -f express-app-local
```

This local image is for manual builds. Use the Docker Hub image below to test
automatic updates.

## Publish With GitHub Actions

The [workflow](.github/workflows/main.yaml) runs on pushes to `main`. It checks out
the code, sets up Docker Buildx, logs in to Docker Hub, and builds and pushes
`DOCKER_USERNAME/express-app:latest`.

In your GitHub repository, open **Settings > Secrets and variables > Actions** and
add these repository secrets:

| Secret | Value |
| --- | --- |
| `DOCKER_USERNAME` | Your Docker Hub username |
| `DOCKER_PASSWORD` | A Docker Hub access token with permission to push images |

Push to `main` and wait for a successful run in the repository's **Actions** tab
before pulling the image.

## Enable Automatic Updates

The [Compose file](docker-compose.yaml) starts only Watchtower, not the Express
app. Start the app separately using the same Docker Hub image and tag that the
workflow publishes. Replace the example username below with your own:

```bash
export DOCKER_USERNAME=your-dockerhub-username
docker pull "$DOCKER_USERNAME/express-app:latest"
docker run -d --name express-app -p 8080:8080 "$DOCKER_USERNAME/express-app:latest"
docker compose up -d
```

Port 8080 and the container name `express-app` must be available.

Watchtower checks for image updates every 60 seconds. When the registry image
changes, it pulls the new image and recreates the running container with its
existing settings. It does not rebuild images or watch local source files.

**Security:** Watchtower mounts `/var/run/docker.sock`, giving it powerful access
to the host's Docker daemon. This configuration has no container filters, so it
can update other running containers too. Only use an updater image you trust.

## Test an Automatic Update

1. Open http://localhost:8080 and note the greeting.
2. Change the greeting in [index.js](index.js), commit it, and push to `main`.
3. Wait for the GitHub Actions build and image push to succeed.
4. Follow Watchtower's logs:

	```bash
	docker logs -f watchtower
	```

5. Allow at least one 60-second polling interval, plus image download and restart
	time, then refresh the browser. The new greeting confirms deployment without a
	manual rebuild or restart. A brief interruption is possible during replacement.

Press `Ctrl+C` to stop following logs without stopping Watchtower.

If the greeting does not change, check the workflow result and Watchtower logs,
and confirm that the app uses the published image name and tag:

```bash
docker inspect express-app --format '{{.Config.Image}}'
docker logs express-app
```

## Stop Containers

```bash
docker compose down
docker stop express-app
docker rm express-app #to remove the container
```

`docker compose down` stops and removes Watchtower only. The separately started
app must be stopped and removed explicitly.
