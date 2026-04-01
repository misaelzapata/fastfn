package main

import "fmt"

const (
	awesomeComposeURL    = "https://github.com/docker/awesome-compose.git"
	awesomeComposeCommit = "18f59bdb09ecf520dd5758fbf90dec314baec545"

	streamlitURL    = "https://github.com/streamlit/demo-self-driving.git"
	streamlitCommit = "10583da39d514d8f0a8b410793c415258abc83ce"

	fastAPIRealworldURL    = "https://github.com/nsidnev/fastapi-realworld-example-app.git"
	fastAPIRealworldCommit = "029eb7781c60d5f563ee8990a0cbfb79b244538c"

	nextPortfolioURL    = "https://github.com/vercel/nextjs-portfolio-starter.git"
	nextPortfolioCommit = "90cfee0f74c25bb3688369a0587e435f8b8f114d"
)

func defaultMatrixCases() []matrixCase {
	return []matrixCase{
		{
			Name:        "streamlit-demo",
			Description: "Streamlit app from a public repo with an overlay Dockerfile and base path routing.",
			Repo: &repoRef{
				URL:      streamlitURL,
				Commit:   streamlitCommit,
				LocalDir: "/tmp/fastfn-repo-bench/streamlit-demo",
			},
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: streamlitDockerfile(),
				Port:              8501,
				Routes:            []string{"/streamlit", "/streamlit/*"},
				HealthPath:        "/streamlit/",
			},
			Verify: verifySpec{
				Path:           "/streamlit/",
				ExpectContains: "Streamlit",
			},
			Notes: []string{
				"Overlay Dockerfile is benchmark-only because the upstream repo is not containerized.",
			},
		},
		{
			Name:        "flask-compose",
			Description: "Flask app from docker/awesome-compose with a benchmark overlay Dockerfile for current Python packaging.",
			Repo:        awesomeComposeRepo("nginx-wsgi-flask/flask"),
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: flaskComposeDockerfile(),
				Port:              5000,
				Routes:            []string{"/*"},
				HealthPath:        "/flask-health-check",
				Command:           []string{"gunicorn", "-w", "3", "-t", "60", "-b", "0.0.0.0:5000", "app:app"},
			},
			Verify: verifySpec{
				Path:           "/flask-health-check",
				ExpectContains: "success",
			},
			Notes: []string{
				"Overlay Dockerfile avoids old pip metadata resolution failures from the upstream 2021 base image.",
			},
		},
		{
			Name:        "fastapi-realworld",
			Description: "FastAPI RealWorld app backed by resident Postgres over internal networking.",
			Repo: &repoRef{
				URL:      fastAPIRealworldURL,
				Commit:   fastAPIRealworldCommit,
				LocalDir: "/tmp/fastfn-repo-bench/fastapi-realworld",
			},
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: fastAPIRealworldDockerfile(),
				Port:              8000,
				Routes:            []string{"/api/*", "/docs", "/openapi.json"},
				HealthPath:        "/api/tags",
				Env: map[string]string{
					"APP_ENV":      "dev",
					"SECRET_KEY":   "fastfn-bench-secret",
					"DATABASE_URL": "postgresql://postgres:postgres@postgres.internal:5432/rwdb",
				},
			},
			Services: []workloadSpec{
				postgresService("postgres", "rwdb", "postgres", "postgres", "fastapi-realworld-postgres"),
			},
			Verify: verifySpec{
				Path:           "/api/tags",
				ExpectContains: "\"tags\"",
			},
		},
		{
			Name:        "nextjs-portfolio",
			Description: "Next.js app from a public repo with an overlay Dockerfile and explicit base path.",
			Repo: &repoRef{
				URL:      nextPortfolioURL,
				Commit:   nextPortfolioCommit,
				LocalDir: "/tmp/fastfn-repo-bench/nextjs-portfolio-starter",
			},
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: nextJSPortfolioDockerfile(),
				Port:              3000,
				Routes:            []string{"/nextjs", "/nextjs/*"},
				HealthPath:        "/nextjs/",
			},
			Verify: verifySpec{
				Path:           "/nextjs/",
				ExpectContains: "<!DOCTYPE html>",
			},
			Notes: []string{
				"Overlay Dockerfile sets NEXT_BASE_PATH=/nextjs for route-stable benchmarking.",
			},
		},
		{
			Name:        "registry-whoami",
			Description: "Direct image workload pulled from Docker Hub instead of a local repo.",
			App: workloadSpec{
				Name:       "app",
				Image:      "traefik/whoami:v1.10.2",
				Port:       80,
				Routes:     []string{"/whoami", "/whoami/*"},
				HealthPath: "/whoami",
			},
			Verify: verifySpec{
				Path:           "/whoami",
				ExpectContains: "Hostname:",
			},
		},
		{
			Name:        "collision-two-postgres",
			Description: "Generated checker app that validates two equal OCI services can share the same native port without collapsing names or aliases.",
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: collisionCheckerDockerfile(),
				Port:              8000,
				Routes:            []string{"/check"},
				HealthPath:        "/ready",
				Files: map[string]string{
					"package.json": collisionCheckerPackageJSON(),
					"server.js":    collisionCheckerServerJS(),
				},
			},
			Services: []workloadSpec{
				postgresService("postgres-main", "main_db", "postgres", "postgres", "collision-postgres-main"),
				postgresService("postgres-analytics", "analytics_db", "postgres", "postgres", "collision-postgres-analytics"),
			},
			Verify: verifySpec{
				Path:           "/check",
				ExpectContains: "\"postgres_main\"",
			},
		},
		{
			Name:        "django-compose",
			Description: "Django app from docker/awesome-compose using sqlite and ALLOWED_HOSTS configured through env.",
			Repo:        awesomeComposeRepo("django/app"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           8000,
				Routes:         rootRoutes(),
				HealthPath:     "/admin/login/",
				Env: map[string]string{
					"ALLOWED_HOSTS": "*",
				},
			},
			Verify: verifySpec{
				Path:           "/admin/login/",
				ExpectContains: "Django administration",
			},
		},
		{
			Name:        "flask-mongo",
			Description: "Flask app backed by Mongo using the short internal service alias `mongo`.",
			Repo:        awesomeComposeRepo("nginx-flask-mongo/flask"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           9090,
				Routes:         rootRoutes(),
				HealthPath:     "/",
				Env: map[string]string{
					"FLASK_SERVER_PORT": "9090",
				},
			},
			Services: []workloadSpec{
				mongoService("mongo", "flask-mongo"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "MongoDB client",
			},
		},
		{
			Name:        "flask-mysql",
			Description: "Flask + MySQL compose backend with a benchmark overlay Dockerfile that pins a Werkzeug-compatible dependency set.",
			Repo:        awesomeComposeRepo("nginx-flask-mysql/backend"),
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: flaskMySQLDockerfile(),
				Port:              5000,
				Routes:            rootRoutes(),
				HealthPath:        "/",
				Files: map[string]string{
					"fastfn-secrets/db-password": "fastfn-mysql-secret",
				},
			},
			Services: []workloadSpec{
				mysqlService("db", "example", "fastfn-mysql-secret", "flask-mysql-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Blog post #1",
			},
		},
		{
			Name:        "go-compose",
			Description: "Go HTTP backend from docker/awesome-compose with no extra services.",
			Repo:        awesomeComposeRepo("nginx-golang/backend"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           80,
				Routes:         rootRoutes(),
				HealthPath:     "/",
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Hello from Docker!",
			},
		},
		{
			Name:        "go-postgres",
			Description: "Go backend from docker/awesome-compose querying Postgres through the `db` alias.",
			Repo:        awesomeComposeRepo("nginx-golang-postgres/backend"),
			App: workloadSpec{
				Name:             "app",
				DockerfilePath:   "Dockerfile",
				DockerfileAppend: copySecretAppend("fastfn-secrets/db-password", "/run/secrets/db-password"),
				Port:             8000,
				Routes:           rootRoutes(),
				HealthPath:       "/",
				Files: map[string]string{
					"fastfn-secrets/db-password": "fastfn-postgres-secret",
				},
			},
			Services: []workloadSpec{
				postgresService("db", "example", "postgres", "fastfn-postgres-secret", "go-postgres-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Blog post #",
			},
		},
		{
			Name:        "go-mysql",
			Description: "Go backend from docker/awesome-compose querying MySQL through the `db` alias.",
			Repo:        awesomeComposeRepo("nginx-golang-mysql/backend"),
			App: workloadSpec{
				Name:             "app",
				DockerfilePath:   "Dockerfile",
				DockerfileAppend: copySecretAppend("fastfn-secrets/db-password", "/run/secrets/db-password"),
				Port:             8000,
				Routes:           rootRoutes(),
				HealthPath:       "/",
				Files: map[string]string{
					"fastfn-secrets/db-password": "fastfn-go-mysql-secret",
				},
			},
			Services: []workloadSpec{
				mysqlService("db", "example", "fastfn-go-mysql-secret", "go-mysql-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Blog post #",
			},
		},
		{
			Name:        "node-redis",
			Description: "Node.js app from docker/awesome-compose using a resident Redis service.",
			Repo:        awesomeComposeRepo("nginx-nodejs-redis/web"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           5000,
				Routes:         rootRoutes(),
				HealthPath:     "/",
			},
			Services: []workloadSpec{
				redisService("redis", "node-redis"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Number of visits is:",
			},
		},
		{
			Name:        "express-mongodb",
			Description: "Express + MongoDB backend from docker/awesome-compose using a benchmark overlay Dockerfile for a current Node base image.",
			Repo:        awesomeComposeRepo("react-express-mongodb/backend"),
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: expressMongoDockerfile(),
				Port:              3000,
				Routes:            []string{"/api", "/api/*"},
				HealthPath:        "/api",
				Env: map[string]string{
					"NODE_ENV": "development",
				},
			},
			Services: []workloadSpec{
				mongoService("mongo", "express-mongodb"),
			},
			Verify: verifySpec{
				Path:           "/api",
				ExpectContains: "\"success\":true",
			},
			Notes: []string{
				"Overlay Dockerfile avoids the legacy dev-env stage that no longer builds cleanly on the upstream Debian Buster base image.",
			},
		},
		{
			Name:        "express-mysql",
			Description: "Express + MySQL backend from docker/awesome-compose using a copied secret file and env-driven DB config.",
			Repo:        awesomeComposeRepo("react-express-mysql/backend"),
			App: workloadSpec{
				Name:             "app",
				DockerfilePath:   "Dockerfile",
				DockerfileAppend: copySecretAppend("fastfn-secrets/db-password", "/run/secrets/db-password"),
				Port:             80,
				Routes:           rootRoutes(),
				HealthPath:       "/",
				Files: map[string]string{
					"fastfn-secrets/db-password": "fastfn-express-mysql-secret",
				},
				Env: map[string]string{
					"DATABASE_HOST":     "db",
					"DATABASE_PORT":     "3306",
					"DATABASE_DB":       "example",
					"DATABASE_USER":     "root",
					"DATABASE_PASSWORD": "/run/secrets/db-password",
				},
			},
			Services: []workloadSpec{
				mysqlService("db", "example", "fastfn-express-mysql-secret", "express-mysql-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Hello from MySQL",
			},
		},
		{
			Name:        "spring-postgres",
			Description: "Spring Boot + Postgres backend from docker/awesome-compose using the built-in schema and seed data.",
			Repo:        awesomeComposeRepo("spring-postgres/backend"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           8080,
				Routes:         rootRoutes(),
				HealthPath:     "/",
				Env: map[string]string{
					"POSTGRES_DB":       "example",
					"POSTGRES_PASSWORD": "fastfn-spring-postgres-secret",
				},
			},
			Services: []workloadSpec{
				postgresService("db", "example", "postgres", "fastfn-spring-postgres-secret", "spring-postgres-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Hello from Docker!",
			},
		},
		{
			Name:        "java-mysql",
			Description: "Spring Boot + MySQL backend from docker/awesome-compose using direct MYSQL_* envs.",
			Repo:        awesomeComposeRepo("react-java-mysql/backend"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           8080,
				Routes:         rootRoutes(),
				HealthPath:     "/",
				Env: map[string]string{
					"MYSQL_HOST":     "db",
					"MYSQL_PASSWORD": "fastfn-java-mysql-secret",
				},
			},
			Services: []workloadSpec{
				mysqlService("db", "example", "fastfn-java-mysql-secret", "java-mysql-db"),
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "\"name\":\"Docker\"",
			},
		},
		{
			Name:        "rust-postgres",
			Description: "Rust + Postgres backend from docker/awesome-compose using a benchmark overlay Dockerfile for a current Rust toolchain.",
			Repo:        awesomeComposeRepo("react-rust-postgres/backend"),
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: rustPostgresDockerfile(),
				Port:              8000,
				Routes:            []string{"/users"},
				HealthPath:        "/users",
				Env: map[string]string{
					"ADDRESS":     "0.0.0.0:8000",
					"PG_HOST":     "db",
					"PG_DBNAME":   "example",
					"PG_USER":     "postgres",
					"PG_PASSWORD": "fastfn-rust-postgres-secret",
				},
			},
			Services: []workloadSpec{
				postgresService("db", "example", "postgres", "fastfn-rust-postgres-secret", "rust-postgres-db"),
			},
			Verify: verifySpec{
				Path:           "/users",
				ExpectContains: "[",
			},
			Notes: []string{
				"Overlay Dockerfile replaces the upstream development image so the benchmark uses a current Rust toolchain and a production binary.",
			},
		},
		{
			Name:        "apache-php",
			Description: "Apache + PHP sample from docker/awesome-compose with a benchmark overlay that copies the app into the Apache document root.",
			Repo:        awesomeComposeRepo("apache-php/app"),
			App: workloadSpec{
				Name:              "app",
				DockerfileContent: apachePHPDockerfile(),
				Port:              80,
				Routes:            rootRoutes(),
				HealthPath:        "/",
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Hello World!",
			},
			Notes: []string{
				"Overlay Dockerfile keeps the upstream sample simple while ensuring the benchmark image actually serves the checked-in PHP app.",
			},
		},
		{
			Name:        "aspnet-mssql",
			Description: "ASP.NET sample from docker/awesome-compose, benchmarked as a public app workload.",
			Repo:        awesomeComposeRepo("aspnet-mssql/app/aspnetapp"),
			App: workloadSpec{
				Name:           "app",
				DockerfilePath: "Dockerfile",
				Port:           80,
				Routes:         rootRoutes(),
				HealthPath:     "/",
				Env: map[string]string{
					"ASPNETCORE_URLS": "http://0.0.0.0:80",
				},
			},
			Verify: verifySpec{
				Path:           "/",
				ExpectContains: "Learn how to build ASP.NET apps",
			},
		},
	}
}

func awesomeComposeRepo(subdir string) *repoRef {
	return &repoRef{
		URL:      awesomeComposeURL,
		Commit:   awesomeComposeCommit,
		LocalDir: "/tmp/fastfn-repo-bench/awesome-compose",
		Subdir:   subdir,
	}
}

func postgresService(name, database, user, password, volumeName string) workloadSpec {
	return workloadSpec{
		Name:         name,
		Image:        "postgres:16",
		Port:         5432,
		VolumeName:   volumeName,
		VolumeTarget: "/var/lib/postgresql/data",
		Env: map[string]string{
			"POSTGRES_DB":       database,
			"POSTGRES_USER":     user,
			"POSTGRES_PASSWORD": password,
		},
	}
}

func mysqlService(name, database, rootPassword, volumeName string) workloadSpec {
	return workloadSpec{
		Name:         name,
		Image:        "mysql:5.7.44",
		Port:         3306,
		VolumeName:   volumeName,
		VolumeTarget: "/var/lib/mysql",
		Env: map[string]string{
			"MYSQL_DATABASE":      database,
			"MYSQL_ROOT_HOST":     "%",
			"MYSQL_ROOT_PASSWORD": rootPassword,
		},
	}
}

func mongoService(name, volumeName string) workloadSpec {
	return workloadSpec{
		Name:         name,
		Image:        "mongo:7",
		Port:         27017,
		VolumeName:   volumeName,
		VolumeTarget: "/data/db",
	}
}

func redisService(name, volumeName string) workloadSpec {
	return workloadSpec{
		Name:         name,
		Image:        "redis:7",
		Port:         6379,
		VolumeName:   volumeName,
		VolumeTarget: "/data",
	}
}

func copySecretAppend(sourcePath, targetPath string) string {
	return fmt.Sprintf("COPY %s %s", sourcePath, targetPath)
}

func rootRoutes() []string {
	return []string{"/", "/*"}
}

func streamlitDockerfile() string {
	return `FROM python:3.11-slim

WORKDIR /app

COPY Pipfile ./
RUN pip install --no-cache-dir streamlit==1.9.2 "altair<5" opencv-python-headless

COPY . ./

ENV STREAMLIT_BROWSER_GATHER_USAGE_STATS=false
ENV STREAMLIT_SERVER_HEADLESS=true

EXPOSE 8501

CMD ["streamlit", "run", "streamlit_app.py", "--server.address=0.0.0.0", "--server.port=8501", "--server.baseUrlPath=/streamlit"]
`
}

func flaskComposeDockerfile() string {
	return `FROM python:3.11-slim

WORKDIR /app

COPY . ./

RUN pip install --no-cache-dir Flask==3.0.3 gunicorn==22.0.0

EXPOSE 5000

CMD ["gunicorn", "-w", "3", "-t", "60", "-b", "0.0.0.0:5000", "app:app"]
`
}

func flaskMySQLDockerfile() string {
	return `FROM python:3.10-slim

WORKDIR /code

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt "Werkzeug<3"

COPY . ./
COPY fastfn-secrets/db-password /run/secrets/db-password

ENV FLASK_APP=hello.py
ENV FLASK_ENV=development
ENV FLASK_RUN_PORT=5000
ENV FLASK_RUN_HOST=0.0.0.0

EXPOSE 5000

CMD ["flask", "run"]
`
}

func expressMongoDockerfile() string {
	return `FROM node:20-bookworm-slim

WORKDIR /usr/src/app

COPY package*.json ./
RUN npm install --no-fund --no-audit

COPY . ./

EXPOSE 3000

CMD ["npm", "run", "start"]
`
}

func fastAPIRealworldDockerfile() string {
	return `FROM python:3.10-slim

ENV PYTHONUNBUFFERED=1
ENV POETRY_NO_INTERACTION=1
ENV POETRY_VIRTUALENVS_CREATE=false

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends netcat-openbsd && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

COPY poetry.lock pyproject.toml ./
RUN pip install --no-cache-dir "poetry>=1.7,<2" && \
    poetry install --only main --no-root

COPY . .

EXPOSE 8000

CMD ["sh", "-lc", "alembic upgrade head && exec uvicorn --host=0.0.0.0 app.main:app"]
`
}

func nextJSPortfolioDockerfile() string {
	return `FROM node:20-bookworm-slim

WORKDIR /app

COPY package.json ./
RUN npm install --no-fund --no-audit

COPY . ./

ENV NODE_ENV=production
ENV PORT=3000
ENV HOSTNAME=0.0.0.0
ENV NEXT_BASE_PATH=/nextjs

RUN npm run build

EXPOSE 3000

CMD ["npm", "run", "start", "--", "-H", "0.0.0.0", "-p", "3000"]
`
}

func rustPostgresDockerfile() string {
	return `FROM rust:1.88-bookworm AS builder

WORKDIR /code

COPY Cargo.toml ./
COPY src ./src
COPY migrations ./migrations

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV ROCKET_ENV=production

COPY --from=builder /code/target/release/react-rust-postgres /usr/local/bin/react-rust-postgres

EXPOSE 8000

CMD ["react-rust-postgres"]
`
}

func apachePHPDockerfile() string {
	return `FROM php:8.2-apache

WORKDIR /var/www/html

COPY . /var/www/html/

RUN chown -R www-data:www-data /var/www/html

EXPOSE 80

CMD ["apache2-foreground"]
`
}

func collisionCheckerDockerfile() string {
	return `FROM node:20-alpine

WORKDIR /app

COPY package.json ./
RUN npm install --no-fund --no-audit

COPY . ./

EXPOSE 8000

CMD ["node", "server.js"]
`
}

func collisionCheckerPackageJSON() string {
	return `{
  "name": "collision-checker",
  "private": true,
  "type": "module",
  "dependencies": {
    "express": "4.21.2",
    "pg": "8.13.1"
  }
}
`
}

func collisionCheckerServerJS() string {
	return `import express from "express";
import pg from "pg";

const { Pool } = pg;

const app = express();

function newPool(host, port, database) {
  return new Pool({
    host,
    port,
    user: "postgres",
    password: "postgres",
    database,
    connectionTimeoutMillis: 3000,
    idleTimeoutMillis: 30000,
    max: 2,
  });
}

async function versionFor(pool) {
  const versionRow = await pool.query("select version() as version");
  return versionRow.rows[0].version;
}

app.get("/ready", (_req, res) => {
  res.json({ ok: true });
});

app.get("/check", async (_req, res) => {
  const mainHost = process.env.SERVICE_POSTGRES_MAIN_HOST || "postgres-main.internal";
  const mainPort = Number(process.env.SERVICE_POSTGRES_MAIN_PORT || "5432");
  const analyticsHost = process.env.SERVICE_POSTGRES_ANALYTICS_HOST || "postgres-analytics.internal";
  const analyticsPort = Number(process.env.SERVICE_POSTGRES_ANALYTICS_PORT || "5432");
  const mainPool = newPool(mainHost, mainPort, "main_db");
  const analyticsPool = newPool(analyticsHost, analyticsPort, "analytics_db");

  try {
    const payload = {
      postgres_main: {
        host: mainHost,
        port: mainPort,
        database: "main_db",
        version: await versionFor(mainPool),
      },
      postgres_analytics: {
        host: analyticsHost,
        port: analyticsPort,
        database: "analytics_db",
        version: await versionFor(analyticsPool),
      },
      POSTGRES_HOST: process.env.POSTGRES_HOST || null,
    };
    res.json(payload);
  } catch (error) {
    res.status(500).json({
      error: error instanceof Error ? error.message : String(error),
      postgres_main: {
        host: mainHost,
        port: mainPort,
      },
      postgres_analytics: {
        host: analyticsHost,
        port: analyticsPort,
      },
      POSTGRES_HOST: process.env.POSTGRES_HOST || null,
    });
  } finally {
    void mainPool.end().catch(() => {});
    void analyticsPool.end().catch(() => {});
  }
});

app.listen(8000, "0.0.0.0");
`
}
