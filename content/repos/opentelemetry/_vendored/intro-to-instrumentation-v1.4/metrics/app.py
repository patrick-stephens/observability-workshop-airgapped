import random
import re
import urllib3

import requests
from flask import Flask, render_template, request
from breeds import breeds

from opentelemetry.trace import set_tracer_provider, get_current_span
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter

from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.jinja2 import Jinja2Instrumentor
from opentelemetry.instrumentation.requests import RequestsInstrumentor
from prometheus_flask_exporter import PrometheusMetrics
from prometheus_client import Counter

provider = TracerProvider()
processor = SimpleSpanProcessor(OTLPSpanExporter(endpoint="http://localhost:4318/v1/traces"))
provider.add_span_processor(processor)

set_tracer_provider(provider)

app = Flask("hello-otel")
FlaskInstrumentor().instrument_app(app)
Jinja2Instrumentor().instrument()
RequestsInstrumentor().instrument()
metrics = PrometheusMetrics(app)

HITS_COUNTER = Counter('hits_counter', 'count of homepage loads')

HITS = 0


@app.route('/')
def index():
    span = get_current_span()
    global HITS
    HITS = HITS + 1
    span.set_attribute("hits", HITS)
    trace_id = '{:032x}'.format(span.get_span_context().trace_id)
    HITS_COUNTER.inc(1, exemplar={"trace_id": trace_id, "trace_url": f"http://localhost:16686/trace/{trace_id}"})
    msg = f'This webpage has been viewed {HITS} times'
    return msg


@app.route("/rolldice")
def roll_dice():
    result = do_roll()
    return result


def do_roll():
    r = str(random.randint(1, 6))
    return r


@app.route('/doggo', methods=["GET", "POST"])
def fetch_dog():
    if request.method == 'POST':
        breed = request.form['breed-search']
        try:
            validate_breed(breed)
        except ValueError as e:
            return render_template('random-pet-pic.html', error=e)
        resp = requests.get(f'https://dog.ceo/api/breed/{breed}/images/random')
        image_src = resp.json()["message"]
    else:
        resp = requests.get("https://dog.ceo/api/breeds/image/random")
        image_src = resp.json()["message"]
        breed = get_breed(image_src)

    return render_template('random-pet-pic.html', img_src=image_src, breed=breed, error=None)


def get_breed(url):
    path = urllib3.util.parse_url(url).path
    match = re.search(r"/breeds/([^/]+)/", path)
    if match:
        result = match.group(1)
        return result


def validate_breed(breed):
    if breed not in breeds:
        raise ValueError("No breed found.")
    return


if __name__ == "__main__":
    app.run()
