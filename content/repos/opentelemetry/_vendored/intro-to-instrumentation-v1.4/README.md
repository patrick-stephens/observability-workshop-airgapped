Intro To Instrumentation
------------------------
This demo is used with the OpenTelemetry workshop found at https://o11y-workshops.gitlab.io/workshop-opentelemetry and is shown using the Podman container tooling.


Install in a container (Podman)
-------------------------------
This is an installation using the provided Python and OpenTelemetry images. You will
run this container on a virtual machine provided by Podman.

**Prerequisites:** Podman v5+ with your podman machine started, Python v3+, OpenTelemetry v1.44, and Jaeger v1.76

1. [Download and unzip this project.](https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip)

2. Build image locally:

```
   $ cd intro-to-instrumentation-VERSION/automatic

   $ podman build -t hello-otel:latest -f Buildfile-auto .
```

3. Run container: 

```text
podman run -i -p 8001:8000 -e FLASK_RUN_PORT=8000 hello-otel:latest opentelemetry-instrument \
	--traces_exporter console \
	--metrics_exporter console \
	--service_name hello-otel \
	flask run --host=0.0.0.0
```

4. Confirm application is running. Open your browser and access http://localhost:8001


Install in a container with instrumentation using Jaeger (Podman)
-----------------------------------------------------------------
This is an installation using the provided images to run a Pod with the
instrumented application and provide visual instrumentation UI with Jaeger. 
You will run this container on a virtual machine provided by Podman.

1. [Download and unzip this project.](https://gitlab.com/o11y-workshops/intro-to-instrumentation/-/archive/v1.4/intro-to-instrumentation-v1.4.zip)

2. Run Pod with application + Jaeger all-in-one containers:

```
   $ cd intro-to-instrumentation-VERSION

   $ podman kube play app_pod.yaml
```

3. Open your browser and make multiple requests to http://localhost:8001 and http://localhost:8001/rolldice

4. Open the Jaeger UI in your browser at http://localhost:16686/search and find your service `hello-otel` and traces


Local
-----
1. CD to dir and create Python virtual environment `python3 -m venv .venv &&. .venv/bin/activate`

2. Install dependencies `pip install -r requirements.txt`

3. Run the application `flask run`

4. Confirm application is running. Open your browser and access http://localhost:5000 || `curl localhost:5000`

Run local Jaeger instance

```
podman run -d --name jaeger \
  -e COLLECTOR_OTLP_ENABLED=true \
  -p 16686:16686 \
  -p 4318:4318 \
  jaegertracing/all-in-one:1.76.0
```


Supporting Articles
-------------------
- [A Hands-on Guide to OpenTelemetry - Intro to Observability](https://www.schabell.org/2024/07/a-hands-on-guide-to-opentelemtry-intro-to-observability.html)


Released versions
-----------------
See the tagged releases for the following versions of the product:

- v1.4 - Supporting OpenTelemetry v1.44, Prometheus v3.13, Jeager 1.76, and the Intro to Instrumentation workshop.

- v1.3 - Supporting OpenTelemetry v1.29, Prometheus v2.54.1, and the Intro to Instrumentation workshop.

- v1.2 - Supporting OpenTelemetry v1.25, Prometheus v2.54.1, and the Intro to Instrumentation workshop.

- v1.1 - Supporting OpenTelemetry v1.25, Prometheus v2.52.0, and the Intro to Instrumentation workshop.

- v1.0 - Supporting OpenTelemetry v1.24 and the Intro to Instrumentation workshop.
