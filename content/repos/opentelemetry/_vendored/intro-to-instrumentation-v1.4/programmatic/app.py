import random
import re
import urllib3

import requests
from flask import Flask, render_template, request
from breeds import breeds

app = Flask(__name__)

HITS = 0


@app.route('/')
def index():
    global HITS
    HITS = HITS + 1
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
