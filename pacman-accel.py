import logging
import requests
from flask import Flask, redirect

with open("/etc/pacman.d/mirrorlist-accel", "r") as f:
    mirrors = [mirror for mirror in f.read().split('\n')
               if mirror and not mirror[0] == "#"]

app = Flask(__name__)
app.logger.setLevel(logging.INFO)

@app.route('/<path:path>')
def download_302(path):
    # Set TIER 0/1 mirrors as the last one, for:
    #  - DB syncing
    #  - Download fallback
    # These two use cases always the same server for consistency.
    mirror = mirrors[-1]

    if not path.endswith('.db'):
        # Find a faster mirror with the requested file present
        for mirror in mirrors[:-1]:
            response = requests.head(mirror + path)
            if response.status_code == 200:
                break

    app.logger.info('redirecting to %s', mirror + path)
    return redirect(mirror + path, code=302)


if __name__ == '__main__':
   app.run()
